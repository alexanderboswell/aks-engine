#!/bin/bash

# Script file to install the docker hello-world container

# Exit immediately if we error
set -e

log() {
    echo $(date) $1
}

wait_for_kubernetes() {
    log "Waiting for kubectl to be available"
    kubernetesStarted=1
    for i in {1..600}; do
        if [ -e /usr/local/bin/kubectl ]
        then
            if /usr/local/bin/kubectl cluster-info
            then
                log "kubernetes started"
                kubernetesStarted=0
                break
            fi
        else
            if /usr/bin/docker ps | grep apiserver
            then
                log "kubernetes started"
                kubernetesStarted=0
                break
            fi
        fi
        sleep 1
    done
    if [ $kubernetesStarted -ne 0 ]
    then
        log "kubernetes did not start"
        exit 1
    fi
}

install_helm() {
    log "installing helm" 
    # Download helm install script from helm github
    curl -LO https://git.io/get_helm.sh
    # Set read / write access on file to only the current user
    chmod 700 get_helm.sh
    # Run install script
    ./get_helm.sh
    log "installed helm"
}

add_jetstack() {
    log "adding jetstack to helm"
    # Known work around
    if [ ! -z "$HELM_HOME" ]
    then 
        rm -rf $HELM_HOME
        mkdir $HELM_HOME
        export HELM_HOME=$(cd $HELM_HOME && pwd)
    else 
        export HELM_HOME=$(pwd)
    fi

    helm init --client-only
    helm repo update
    helm repo add jetstack https://charts.jetstack.io
    log "added jetstack to helm"
}

create_tiller_pod() {
    log "creating tiller pod" 

    # Create tiller pod on linux agent pool
    helm init --service-account tiller --node-selectors "beta.kubernetes.io/os"="linux" 

    log "started tiller pod" 

    log "waiting for tiller pod to be ready" 
    kubectl -n kube-system wait --for=condition=Ready pod -l name=tiller --timeout=350s
    log "found ready tiller pod"
    kubectl -n kube-system get pods -l name=tiller
}

install_ingress_controller() {
    # Install ingress controller with https passthrough
    kubectl create namespace windows-admin-center
    helm repo update

    log "validating public ip address"
    log $1
    if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "public ip address is valid"
        log "started installing ingress controller"

        helm install stable/nginx-ingress --name nginx-ingress --namespace windows-admin-center \
        --set-string controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"="linux" \
        --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"="linux" \
        --set-string controller.service.loadBalancerIP=$1

        log "installed ingress controller"

        kubectl get service -l app=nginx-ingress --namespace windows-admin-center
    else
        log "$1 is not a ip address, fail"
    fi
}

install_cert_manager() {
    add_jetstack
    log "starting install of cert manager"

    # Install cert manager
    kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.10/deploy/manifests/00-crds.yaml
    kubectl create namespace cert-manager
    kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true

    # Install cert manager on linux nodes
    helm install --name cert-manager  --namespace cert-manager --version v0.10.0 \
    --set nodeSelector."beta\.kubernetes\.io/os"="linux" \
    --set webhook.nodeSelector."beta\.kubernetes\.io/os"="linux" \
    --set cainjector.nodeSelector."beta\.kubernetes\.io/os"="linux" jetstack/cert-manager

    log "waiting for cert-manager pods to be ready" 
    kubectl wait --for=condition=Ready pods --all=true --namespace cert-manager --timeout=550s
    log "cert-manager pods ready"
}

parse_credentials() {
    creds_array=($(echo $CREDENTIALS | tr " " "\n"))

    AZURECR_USERNAME=${creds_array[0]}
    AZURECR_PASSWORD=${creds_array[1]}
    AAD_CLIENT_ID=${creds_array[2]}
    AAD_CLIENT_SECRET=${creds_array[3]}
    AAD_COOKIE_SECRET=${creds_array[4]}
}

find_and_replace() {
    # 1. text to replace
    # 2. new text
    # 3. file to search
    sed -i -e "s/$1/$2/g" $3
}

# Start of script

log "Deploying Windows Admin Center container"  
wait_for_kubernetes

parse_credentials

install_helm 

# Enable tiller rbac
kubectl apply -f helm-rbac.yaml  

log "applied helm-rbac.yaml"  

create_tiller_pod

install_ingress_controller $IPADDRESS

install_cert_manager

# Known work around for cert-manager server to be ready to take requests
sleep 5m

# Create cluster issuer
kubectl apply -f cluster-issuer.yaml
log "applied cluster-issuer.yaml"  

# Create secret for pulling Windows Admin Center Image
kubectl create secret docker-registry msftsme.acr.secret --docker-server=msftsme.azurecr.io --docker-username=$AZURECR_USERNAME --docker-password=$AZURECR_PASSWORD --namespace windows-admin-center

# Create service account for accessing k8s API from Windows Admin Center
kubectl apply -f service-account.yaml
log "applied service-account.yaml"  

# Deploy Windows Admin Center
kubectl apply -f windows-admin-center.yaml
log "applied windows-admin-center.yaml"  

# Update yaml file with passed in AAD credentials
find_and_replace "CLIENT_ID_REPLACE" $AAD_CLIENT_ID oauth2-proxy.yaml
find_and_replace "CLIENT_SECRET_REPLACE" $AAD_CLIENT_SECRET oauth2-proxy.yaml
find_and_replace "COOKIE_SECRET_REPLACE" $AAD_COOKIE_SECRET oauth2-proxy.yaml

# Setup oauth proxy
kubectl apply -f oauth2-proxy.yaml


find_and_replace "HOST_NAME_REPLACE" $DNS_FQDN ingress.yaml

# Create ingress route
kubectl apply -f ingress.yaml
log "applied ingress.yaml"

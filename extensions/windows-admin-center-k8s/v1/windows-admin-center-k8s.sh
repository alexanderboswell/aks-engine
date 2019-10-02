#!/bin/bash

# Script file to install the docker hello-world container

# exit immediately if we error
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
    kubectl create namespace ingress-basic 
    helm repo update

    log "validating public ip address"
    log $1
    if [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "public ip address is valid"
        log "started installing ingress controller"

        helm install stable/nginx-ingress --name nginx-ingress --namespace ingress-basic \
        --set-string controller.replicaCount=2 --set controller.nodeSelector."beta\.kubernetes\.io/os"="linux" \
        --set defaultBackend.nodeSelector."beta\.kubernetes\.io/os"="linux" \
        --set-string controller.service.loadBalancerIP=$1

        log "installed ingress controller"

        kubectl get service -l app=nginx-ingress --namespace ingress-basic
    else
        log "1 is not a ip address, fail"
    fi
}

install_cert_manager() {
    add_jetstack
    log "starting install of cert manager"

    # install cert manager
    kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.10/deploy/manifests/00-crds.yaml
    kubectl create namespace cert-manager
    kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true

    # install cert manager on linux nodes
    helm install --name cert-manager  --namespace cert-manager --version v0.10.0 \
    --set nodeSelector."beta\.kubernetes\.io/os"="linux" \
    --set webhook.nodeSelector."beta\.kubernetes\.io/os"="linux" \
    --set cainjector.nodeSelector."beta\.kubernetes\.io/os"="linux" jetstack/cert-manager

    log "waiting for cert-manager pods to be ready" 
    kubectl wait --for=condition=Ready pods --all=true --namespace cert-manager --timeout=550s
    log "cert-manager pods ready"
}

# start of script

log "Deploying Windows Admin Center container"  
wait_for_kubernetes

# eval $1

install_helm 

# Enable tiller rbac
kubectl apply -f helm-rbac.yaml  

log "applied helm-rbac.yaml"  

create_tiller_pod

install_ingress_controller $1

install_cert_manager

# create cluster issuer
kubectl apply -f cluster-issuer.yaml
log "applied cluster-issuer.yaml"  

#Deploy Windows Admin Center 
kubectl apply -f wac-container.yaml
log "applied wac-container.yaml"  

# setup oauth proxy
kubectl apply -f oauth2-proxy.yaml

# create ingress route
kubectl apply -f wac-ingress.yaml
log "applied wac-ingress.yaml"  
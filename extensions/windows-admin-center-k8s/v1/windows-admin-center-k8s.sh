#!/bin/bash

# Script file to install the docker hello-world container

set -e

echo $(date) " - Starting Script"

echo $(date) " - Waiting for API Server to start"
kubernetesStarted=1
for i in {1..600}; do
    if [ -e /usr/local/bin/kubectl ]
    then
        if /usr/local/bin/kubectl cluster-info
        then
            echo "kubernetes started"
            kubernetesStarted=0
            break
        fi
    else
        if /usr/bin/docker ps | grep apiserver
        then
            echo "kubernetes started"
            kubernetesStarted=0
            break
        fi
    fi
    sleep 1
done
if [ $kubernetesStarted -ne 0 ]
then
    echo "kubernetes did not start"
    exit 1
fi

# Deploy container
echo $(date) " - Deploying Windows Admin Center container"

# Download helm install script from helm github
curl -LO https://git.io/get_helm.sh
# Set read / write access on file to only the current user
chmod 700 get_helm.sh
# Run install script
./get_helm.sh

# Enable tiller rbac
kubectl apply -f helm-rbac.yaml

# Install ingress controller with https passthrough
kubectl create namespace ingress-basic

# Create tiller pod on linux agent pool
helm init --service-account tiller --node-selectors "beta.kubernetes.io/os"="linux"

helm repo update

helm install stable/nginx-ingress --name nginx-ingress --namespace ingress-basic \
--set controller.replicaCount=2 --set controller.nodeSelector."beta.kubernetes.io/os"=linux \
--set defaultBackend.nodeSelector."beta.kubernetes.io/os"=linux \
--set controller.extraArgs.enable-ssl-passthrough=""

kubectl get service -l app=nginx-ingress --namespace ingress-basic
# Not solved yet
# Will setup a public ip in azure so that we can connect to Windows Admin Center through the ingress controller
# $ip = "52.183.79.40"
# $dns = "wac-aks"
# $publicid = az network public-ip list --query "[?ipAddress!=null]|[?contains(ipAddress, '$ip')].[id]" --output tsv
# az network public-ip update --ids $publicid --dns-name $dns


# install cert manager
kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.10/deploy/manifests/00-crds.yaml
kubectl create namespace cert-manager
kubectl label namespace cert-manager certmanager.k8s.io/disable-validation=true
helm repo add jetstack https://charts.jetstack.io
helm repo update

# install cert manager on linux nodes
helm install --name cert-manager --namespace cert-manager --version v0.10.0 \
--set nodeSelector."beta.kubernetes.io/os"=linux \
--set webhook.nodeSelector."beta.kubernetes.io/os"=linux \
--set cainjector.nodeSelector."beta.kubernetes.io/os"=linux jetstack/cert-manager

# create cluster issuer
kubectl apply -f cluster-issuer.yaml

# create ingress route
kubectl apply -f wac-ingress.yaml

# Deploy Windows Admin Center 
kubectl apply -f wac-container.yml

echo $(date) " - Deploying Windows Admin Center complete"
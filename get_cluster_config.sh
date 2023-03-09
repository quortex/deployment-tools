#!/usr/bin/env bash
#
# The purpose of this script is to compute a cluster Config from a given ServiceAccount.

set -Eeuo pipefail

SERVICE_ACCOUNT=
NAMESPACE=default
CLUSTER_NAME=default

function help() {
    cat <<EOF
Compute a cluster Config from a given ServiceAccount.
It requests the different kubernetes resources in order to build a cluster
Config for a given ServiceAccount.
Usage : $0 -s SERVICE_ACCOUNT [options]

Mandatory arguments :
    -s SERVICE_ACCOUNT    The name of the ServiceAccount to use for the config.
Available options :
    -n NAMESPACE      The namespace of the ServiceAccount to use for the config. (default ${NAMESPACE}).
    -c CLUSTER_NAME   Set the name of the cluster (default ${CLUSTER_NAME}).
    -h                Display this help.
EOF
}

while getopts "s:n:c:h" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    s)
        SERVICE_ACCOUNT=$OPTARG
        ;;
    n)
        NAMESPACE=$OPTARG
        ;;
    c)
        CLUSTER_NAME=$OPTARG
        ;;
    esac
done

if [ "${SERVICE_ACCOUNT}" == "" ]; then
    echo "ServiceAccount name was not specified, aborting !"
    exit 1
fi

# Get Kubernetes control plane address
cluster_info=$(kubectl cluster-info | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2};?)?)?[mGK]//g")
regex="Kubernetes control plane is running at (https:\/\/[a-zA-Z0-9\.\-]*)"
[[ ${cluster_info} =~ ${regex} ]]
[[ -n ${BASH_VERSION} ]] && k8s_cp_address=( "${BASH_REMATCH[1]}" )

# Compute ServiceAccount secret name.
secret_name=$(kubectl get serviceaccount ${SERVICE_ACCOUNT} --namespace=${NAMESPACE} -o=jsonpath='{.secrets[0].name}')

# Get certificate authority data and token
ca=$(kubectl --namespace="${NAMESPACE}" get secret/"${secret_name}" -o=jsonpath='{.data.ca\.crt}')
token=$(kubectl --namespace="${NAMESPACE}" get secret/"${secret_name}" -o=jsonpath='{.data.token}' | base64 --decode)

echo "
---
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      certificate-authority-data: ${ca}
      server: ${k8s_cp_address}
contexts:
  - name: ${SERVICE_ACCOUNT}@${CLUSTER_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      namespace: ${NAMESPACE}
      user: ${SERVICE_ACCOUNT}
users:
  - name: ${SERVICE_ACCOUNT}
    user:
      token: ${token}
current-context: ${SERVICE_ACCOUNT}@${CLUSTER_NAME}
"

#!/bin/bash

# Bash strict mode
set -euo pipefail
IFS=$'\n\t'

# Constants
NORMAL='\e[0m'
GREEN='\e[32m'
YELLOW='\e[33m'

# List of all kind of services to reconcile, the order is not important
SERVICE_KINDS=(
    "dynamicrouter"
    "drmmanager"
    "encrypt"
    "dashmanifestgen"
    "hlsmanifestgen"
    "packager"
    "xaudio"
    "xcode"
    "xsubtitles"
    "segmenter"
)

# List of the ainodes to reconcile in order, written <name of the ainode>,<pod manager used>,<should the script wait after>
AINODE_BATCH=(
    "lbalancer-main,deployment,true"
    "dynamicrouter-main,deployment,true"
    "drmmanager-main,deployment,true"
    "encrypt-main,deployment,true"
    "dashmanifestgen-main,deployment,false"
    "hlsmanifestgen-main,deployment,false"
    "packager-main,deployment,true"
    "xaudio-main,deployment,false"
    "xsubtitles-main,deployment,false"
    "xcode-ska,deployment,true"
    "xcode-main,deployment,false"
    "xcode-backup,deployment,true"
    "segmenter-main,deployment,false"
)

# Programm arguments parsing
NAMESPACE=""
WORKFLOWPOOL=""
WAIT_TIME="120"

function help() {
    cat <<EOF
Reconciles manually ainodes in a specific order.
Usage : $0 -n NAMESPACE -w WORKFLOWPOOL [options]
Mandatory arguments :
    -n NAMESPACE         Set namespace of the workflowpool.
    -w WORKFLOWPOOL :    Set the worflowpool name.
Available options :
    -h                   Display this help.
    -t                   Override the default time in seconds between batch, by default 120.
EOF
}

while getopts ":n:w:t:h" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    n)
        NAMESPACE=$OPTARG
        ;;
    w)
        WORKFLOWPOOL=$OPTARG
        ;;
    t)
        WAIT_TIME=$OPTARG
        ;;
    *)
        echo "Unsupported flag provided : $OPTARG".
        help
        exit 1
        ;;
    esac
done

if [ "$NAMESPACE" == "" ]; then
    echo "Namespace was not specified, aborting"
    exit 1
fi

if [ "$WORKFLOWPOOL" == "" ]; then
    echo "WorkflowPool was not specified, aborting"
    exit 1
fi

# Start kubernetes proxy
kubectl proxy -p 0 >proxy.port &
pid="$!"
sleep 3
kill -0 "${pid}"
api_port=$(cut -d':' -f 2 <proxy.port)
echo "API Proxy started on port $api_port (pid $pid)"

# Make sure to stop the proxy when this script ends (this function will be executed only at EXIT)
function cleanup() {
    echo "Stopping proxy"
    kill -9 "$pid" || true
    rm proxy.port
}
trap cleanup EXIT

export ENABLE_WEBHOOKS="false"
export SVC_RESOLVER_KUBEPROXY="true"
export KUBEPROXY_HOST="localhost:${api_port}"

if [ "$(kubectl get namespace ${NAMESPACE})" == "" ]; then
    echo "Namespace ${NAMESPACE} does not exist, exiting."
    exit 1
fi

# Reconciles all workflowpool to apply the changes
echo -e "${GREEN}Starting reconciliation of all workflowpools...${NORMAL}"
for name in $(kubectl get workflowpool -n "${NAMESPACE}" -o name | cut -d / -f 2); do
    echo -e "${GREEN}Reconciling workflowpool ${name} ${NORMAL}"
    quortex-operator --enable-dev-logs --reconcile-resource "workflowpool/${NAMESPACE}/${name}"
done

# Reconciles all services to apply the changes
echo -e "${GREEN}Starting reconciliation of all services...${NORMAL}"
for kind in "${SERVICE_KINDS[@]}"; do
    for name in $(kubectl get "${kind}" -n "${NAMESPACE}" -o name | cut -d / -f 2); do
        exist=$(kubectl -n "${NAMESPACE}" get deployment --selector="operator.quortex.io/service-name=${name}" | wc -l)
        if [ $exist -eq 0 ]; then
            echo -e "${GREEN}Skipping ${kind} ${name}, no deployment found ${NORMAL}"
            continue
        fi
        echo -e "${GREEN}Reconciling ${kind} ${name} ${NORMAL}"
        quortex-operator --enable-dev-logs --reconcile-resource "${kind}/${NAMESPACE}/${name}"
    done
done

# Reconciles ainodes in provider order
echo -e "${GREEN}Starting reconciliation of all ainodes...${NORMAL}"
for ainode in "${AINODE_BATCH[@]}"; do
    name=$(echo "${ainode}" | cut -d "," -f 1)
    kind=$(echo "${ainode}" | cut -d "," -f 2)
    wait=$(echo "${ainode}" | cut -d "," -f 3)
    changed="false"

    exist=$(kubectl -n "${NAMESPACE}" get deployment --selector="operator.quortex.io/workload-name=${WORKFLOWPOOL}-${name},operator.quortex.io/workload=ainode" | wc -l)
    if [ $exist -eq 0 ]; then
        echo -e "${GREEN}Skipping ainode ${name}, no deployment found ${NORMAL}"
        continue
    fi

    echo -e "${GREEN}Reconciling ainode ${name} ${NORMAL}"
    # In the case this command don't succeed, oldspec should contain "none", thus be different from newspec
    oldspec=$(kubectl get "${kind}" "${WORKFLOWPOOL}-${name}-ainode" -n "${NAMESPACE}" -o jsonpath="{.spec}" || echo "none")
    quortex-operator --enable-dev-logs --reconcile-resource "ainode/${NAMESPACE}/${WORKFLOWPOOL}-${name}"
    newspec=$(kubectl get "${kind}" "${WORKFLOWPOOL}-${name}-ainode" -n "${NAMESPACE}" -o jsonpath="{.spec}")
    if [ "${oldspec}" != "${newspec}" ]; then
        changed="true"
    fi

    # Wait for rollout to be completed
    echo -e "${GREEN}Waiting for rollout to be complete ${NORMAL}"
    kubectl rollout status "${kind}" "${WORKFLOWPOOL}-${name}-ainode" -n "${NAMESPACE}"

    if [[ $wait == "true" ]]; then
        if [[ $changed == "false" ]]; then
            echo -e "${GREEN}Batch done without update ${NORMAL}"
        else
            echo -e "${YELLOW}Batch done with updates, waiting ${WAIT_TIME} seconds ${NORMAL}"
            sleep "${WAIT_TIME}"
        fi
    fi
done

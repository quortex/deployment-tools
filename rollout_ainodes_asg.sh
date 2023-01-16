#!/bin/bash

# This script aim to rollout all ainodes, which is usefull when rollouting nodes to upgrade a kubernetes version.
# All pods on ainode nodegroups will be forced to reschedule on new nodes.
# Old nodes will stay unschedulable until being removed by cluster-autoscaler

# Bash strict mode
set -euo pipefail

# Constants
NORMAL="\033[0m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"

# List of the ainodes/mongo/backend to reschedule in order, written <name>,<suffix>,<pod manager used>,<should the script wait after>
AINODES_BATCHS=(
  "shield,,deployment,true"
  "lbalancer-main,-ainode,deployment,true"
  "dynamicrouter-main,-ainode,deployment,true"
  "drmmanager-main,-ainode,deployment,true"
  "encrypt-main,-ainode,deployment,true"
  "dashmanifestgen-main,-ainode,deployment,false"
  "hlsmanifestgen-main,-ainode,deployment,false"
  "packager-main,-ainode,deployment,true"
  "xaudio-main,-ainode,deployment,false"
  "xsubtitles-main,-ainode,deployment,false"
  "xcode-ska,-ainode,deployment,true"
  "xcode-main,-ainode,deployment,false"
  "xcode-backup,-ainode,deployment,true"
  "segmenter-main,-ainode,deployment,false"
)

# Programm arguments parsing
NAMESPACE="reference"
WORKFLOWPOOL="quortex-reference"
WAIT_TIME="120"
AINODE_NODEGROUP_SELECTOR="group=ainodes-fix-group"

function help() {
  cat <<EOF
Reschedule ainodes in a specific order.
Usage : $0 -n NAMESPACE -w WORKFLOWPOOL [options]
Mandatory arguments :
    -n NAMESPACE         Set namespace of the workflowpool.
    -w WORKFLOWPOOL :    Set the worflowpool name.
Available options :
    -h                   Display this help.
    -t                   Override the default time in seconds between batch, by default 120.
    -l                   Override Ainode nodegroup label, default is group=ainodes-fix-group.
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
  l)
    AINODE_NODEGROUP_SELECTOR=$OPTARG
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

if [ "$(kubectl get namespace ${NAMESPACE})" == "" ]; then
  echo "Namespace ${NAMESPACE} does not exist, exiting."
  exit 1
fi

echo -e "${GREEN}Cordon all ainode nodes ${NORMAL}"
kubectl cordon --selector "${AINODE_NODEGROUP_SELECTOR}"

# Reschedule workflow deployments in order
echo -e "${GREEN}Rescheduling all ainodes...${NORMAL}"
for deploy in "${AINODES_BATCHS[@]}"; do
  name=$(echo "${deploy}" | cut -d "," -f 1)
  type=$(echo "${deploy}" | cut -d "," -f 2)
  kind=$(echo "${deploy}" | cut -d "," -f 3)
  wait=$(echo "${deploy}" | cut -d "," -f 4)

  echo -e "${GREEN}Rescheduling ${kind} ${name} ${NORMAL}"
  kubectl rollout restart "${kind}/${WORKFLOWPOOL}-${name}${type}" -n "${NAMESPACE}"
  kubectl rollout status "${kind}/${WORKFLOWPOOL}-${name}${type}" -n "${NAMESPACE}"

  if [[ $wait == "true" ]]; then
    echo -e "${YELLOW}Ainode needs to populate cache, waiting ${WAIT_TIME} seconds ${NORMAL}"
    sleep "${WAIT_TIME}"
  fi
done

# Drain all currently cordonned nodes
# The pods left should be drainable in parallel if respecting PDB
echo -e "${GREEN}Finally drain all ainodes already cordonned nodes...${NORMAL}"
nodes_to_rollout=$(
  kubectl get nodes \
    --selector "${AINODE_NODEGROUP_SELECTOR}" \
    --field-selector spec.unschedulable=true \
    -o name
)
echo "The following nodes will be drained : ${nodes_to_rollout}"
for node in ${nodes_to_rollout}; do
  kubectl drain --ignore-daemonsets --delete-emptydir-data "${node}"
done

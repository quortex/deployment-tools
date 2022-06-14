#!/bin/bash
# All pods on ainode nodegroups will be forced to reschedule on new nodes.
# Old nodes will stay unschedulable until being removed
# by cluster-autoscaler

# Bash strict mode
set -euo pipefail

# Constants
NORMAL='\e[0m'
GREEN='\e[32m'
YELLOW='\e[33m'

# List of the ainodes/mongo/backend to reschedule in order, written <name>,<suffix>,<pod manager used>,<should the script wait after>
BATCH=(
  "shield,,deployment,true"
  "lbalancer-main,-ainode,statefulset,true"
  "dynamicrouter-main,-ainode,statefulset,true"
  "drmmanager-main,-ainode,statefulset,true"
  "encrypt-main,-ainode,statefulset,true"
  "dashmanifestgen-main,-ainode,statefulset,false"
  "hlsmanifestgen-main,-ainode,statefulset,false"
  "packager-main,-ainode,statefulset,true"
  "xaudio-main,-ainode,statefulset,false"
  "xsubtitles-main,-ainode,statefulset,false"
  "xcode-ska,-ainode,statefulset,true"
  "xcode-main,-ainode,statefulset,false"
  "xcode-backup,-ainode,statefulset,true"
  "segmenter-main,-ainode,statefulset,false"
  "cache,-mongodb,statefulset,false"
  "configuration,-mongodb,statefulset,false"
  "dashmanifestgen-main,-backend,false"
  "drmmanager-main,-backend,deployment,false"
  "encrypt-main,-backend,deployment,false"
  "hlsmanifestgen-main,-backend,deployment,false"
  "packager-main,-backend,deployment,false"
  "segmenter-main,-backend,deployment,false"
  "xaudio-main,-backend,deployment,false"
  "xcode-main,-backend,deployment,false"
  "xsubtitles-main,-backend,deployment,false"
)

# Programm arguments parsing
NAMESPACE=""
WORKFLOWPOOL=""
WAIT_TIME="120"
AINODE_NODEGROUP_LABEL="group=ainodes-fix-group"

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
    AINODE_NODEGROUP_LABEL=$OPTARG
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
kubectl cordon -l ${AINODE_NODEGROUP_LABEL}

# Reconciles ainodes in provider order
echo -e "${GREEN}Starting restart of all ainodes...${NORMAL}"
for deploy in "${BATCH[@]}"; do
  name=$(echo "${deploy}" | cut -d "," -f 1)
  type=$(echo "${deploy}" | cut -d "," -f 2)
  kind=$(echo "${deploy}" | cut -d "," -f 3)
  wait=$(echo "${deploy}" | cut -d "," -f 4)

  echo -e "${GREEN}Rescheduling deployment ${name} ${NORMAL}"
  kubectl rollout restart ${kind}/${WORKFLOWPOOL}-${name}${type} -n "${NAMESPACE}"

  # Wait for rollout to be completed
  echo -e "${GREEN}Waiting for rollout to be complete ${NORMAL}"
  kubectl rollout status "${kind}" "${WORKFLOWPOOL}-${name}${type}" -n "${NAMESPACE}"

  if [[ $wait == "true" ]]; then
    echo -e "${YELLOW}Ainode needs to populate cache, waiting ${WAIT_TIME} seconds ${NORMAL}"
    sleep "${WAIT_TIME}"
  fi
done

#!/bin/bash

# This script cordon ainodes-fix-group nodes and reschedules all pods :
# - It rollout ainodes in provided order
# - It rollout rtmp stack by stack
# - It drains everything left on the ASG
# Old nodes will stay unschedulable until being removed by cluster-autoscaler

# Bash strict mode
set -euo pipefail
trap 'wickStrictModeFail $?' ERR

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
RTMP_STACKS=()
NAMESPACE=""
WORKFLOWPOOL=""
AINODE_WAIT_TIME="120"
RTMP_WAIT_TIME="30"
AINODE_NODEGROUP_SELECTOR="group=ainodes-fix-group"

function help() {
  cat <<EOF
This script reschedules all pods on ainodes-fix-group :
- It rollout ainodes in provided order
- It rollout rtmp stack in provided order
- It drains everything left on the ASG
Usage : $0 -n NAMESPACE -w WORKFLOWPOOL [options]
Mandatory arguments :
    -n NAMESPACE         Set namespace of the workflowpool.
    -w WORKFLOWPOOL :    Set the worflowpool name.
Available options :
    -h                   Display this help.
    -s                   Add a rtmp stack to rollout splitted, can be used several times, by default none.
    -t                   Override the default time in seconds between ainodes batch, by default ${AINODE_WAIT_TIME}.
    -r                   Override the default time in seconds between rtmp stacks, by default ${RTMP_WAIT_TIME}.
    -l                   Override Ainode nodegroup label, by default ${AINODE_NODEGROUP_SELECTOR}.
EOF
}

while getopts ":n:w:t:s:r:l:h" opt; do
  case "$opt" in
  h)
    help
    exit 0
    ;;
  n) NAMESPACE="${OPTARG}" ;;
  w) WORKFLOWPOOL="${OPTARG}" ;;
  s) RTMP_STACKS+=("${OPTARG}") ;;
  t) AINODE_WAIT_TIME="${OPTARG}" ;;
  r) RTMP_WAIT_TIME="${OPTARG}" ;;
  l) AINODE_NODEGROUP_SELECTOR="${OPTARG}" ;;
  *)
    echo "Unsupported flag provided : ${OPTARG}".
    help
    exit 1
    ;;
  esac
done

if [ -z "${NAMESPACE}" ]; then
  echo "Namespace was not specified, aborting"
  exit 1
fi

if [ -z "${WORKFLOWPOOL}" ]; then
  echo "WorkflowPool was not specified, aborting"
  exit 1
fi

if [ -z "$(kubectl get namespace ${NAMESPACE})" ]; then
  echo "Namespace ${NAMESPACE} does not exist, exiting."
  exit 1
fi

echo -e "${YELLOW}This script will take the following actions :${NORMAL}"
echo "* nodes matching \"${AINODE_NODEGROUP_SELECTOR}\" will be cordonned"
echo "* ainodes of workflow \"${WORKFLOWPOOL}\" in \"${NAMESPACE}\" will be rollouted in order waiting ${AINODE_WAIT_TIME}s between batchs"
echo "* rtmp stacks [${RTMP_STACKS[*]+${RTMP_STACKS[*]}}] in \"${NAMESPACE}\" will be rollouted in order waiting ${RTMP_WAIT_TIME}s between batchs"
echo "* nodes matching \"${AINODE_NODEGROUP_SELECTOR}\" will be drained"
read -rp "Continue? [y/n] " answer

if [[ "${answer}" != "y" ]]; then
  echo "Did not receive [y], exiting."
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
    echo -e "${YELLOW}Ainode needs to populate cache, waiting ${AINODE_WAIT_TIME} seconds ${NORMAL}"
    sleep "${AINODE_WAIT_TIME}"
  fi
done

# Reschedule rtmp deployments stack by stack
# This is a naive method, which should not affect HA rtmp stream, but has 43 + 12s of black due to jumping to a loadbalancer to the next.
# It has been choosen over doing them separately since util preStop is implemented it only increase the global black duration (35 + 45s).
for stack in ${RTMP_STACKS[@]+"${RTMP_STACKS[@]}"}; do
  echo -e "${GREEN}Rescheduling all rtmp loadbalancers and handlers related to stack ${stack}...${NORMAL}"
  kubectl -n "${NAMESPACE}" rollout restart deployment \
    --selector "app.kubernetes.io/name in (rtmp-loadbalancer,rtmp-handler),app.kubernetes.io/instance=${stack}"
  kubectl -n "${NAMESPACE}" rollout status deployment \
    --selector "app.kubernetes.io/name in (rtmp-loadbalancer,rtmp-handler),app.kubernetes.io/instance=${stack}"

  sleep "${RTMP_WAIT_TIME}"
done

# Drain all currently cordonned nodes
# The pods left should be drainable in parallel if respecting PDB
echo -e "${GREEN}Finally drain all ainodes already cordonned nodes...${NORMAL}"
read -ra nodes_to_rollout < <(
  kubectl get nodes \
    --selector "${AINODE_NODEGROUP_SELECTOR}" \
    --field-selector spec.unschedulable=true \
    -o jsonpath="{.items[*]['metadata.name']}{'\n'}"
)

echo -e "${YELLOW}The following nodes will be drained : ${nodes_to_rollout[*]}${NORMAL} "
kubectl drain --ignore-daemonsets --delete-emptydir-data "${nodes_to_rollout[@]}"

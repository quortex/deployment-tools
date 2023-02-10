#!/bin/bash

set -euo pipefail

OVERPROVISIONER_NAMESPACE=cluster-overprovisioner
OVERPROVISIONER_DEPLOYMENT=cluster-overprovisioner-captures-overprovisioner
CAPTURE_NAMESPACE=reference
CAPTURE_IMAGE=$(
  kubectl -n "${CAPTURE_NAMESPACE}" get deployments \
    --selector app.kubernetes.io/name=capture \
    -o jsonpath='{.items[*].spec.containers[*].image}' |
    tr -s '[[:space:]]' '\n' | sort | uniq | head -n 1
)

# Colors
end="\033[0m"
black="\033[0;30m"
blackb="\033[1;30m"
white="\033[0;37m"
whiteb="\033[1;37m"
red="\033[0;31m"
redb="\033[1;31m"
green="\033[0;32m"
greenb="\033[1;32m"
yellow="\033[0;33m"
yellowb="\033[1;33m"
blue="\033[0;34m"
blueb="\033[1;34m"
purple="\033[0;35m"
purpleb="\033[1;35m"
lightblue="\033[0;36m"
lightblueb="\033[1;36m"

function green {
  echo -e "${green}${1}${end}"
}

function greenb {
  echo -e "${greenb}${1}${end}"
}

function white {
  echo -e "${white}${1}${end}"
}

function whiteb {
  echo -e "${whiteb}${1}${end}"
}

function yellow {
  echo -e "${yellow}${1}${end}"
}

function yellowb {
  echo -e "${yellowb}${1}${end}"
}

function redb {
  echo -e "${redb}${1}${end}"
}

function fail_and_exit {
  redb "${1}"
  exit 1
}

function drain {
  yellow "Draining ${1}"
  kubectl drain "${1}" --ignore-daemonsets=true --delete-emptydir-data=true --timeout=120s --skip-wait-for-delete-timeout=1
  green "${1} successfully drained."
}

function releaseip {
  local pending_pods_count
  externalip_name=$(
    kubectl get externalips \
      -o jsonpath="{.items[?(@.spec.nodeName==\"${1}\")].metadata.name}"
  )

  for ip in ${externalip_name}; do
    green "Disassociate EIP ${ip} from ${1}"
    kubectl patch externalips "${ip}" --type=merge -p '{"spec": {"nodeName": ""}}'
  done
}

function kubestatic_unlabel {
  green "Remove kubestatic label on node ${1}"
  kubectl label node "${1}" kubestatic.quortex.io/externalip-auto-assign-
}

function check_capture_status {
  echo -n "Checking that all capture pods are running... "
  local pending_pods_count
  pending_pods_count=$(
    kubectl -n "${CAPTURE_NAMESPACE}" get pods \
      --selector app.kubernetes.io/name=capture \
      --field-selector status.phase!=Running -o name | wc -w
  )
  if [ "${pending_pods_count}" -ne 0 ]; then
    fail_and_exit "All capture pods are not in a Running state, I can't continue."
  fi
  echo -e "${green}Ok${end}"
}

function check_overprovisioner_status {
  echo -n "Checking that all captures-overprovisioner pods are running... "
  local pending_pods_count
  pending_pods_count=$(
    kubectl -n "${OVERPROVISIONER_NAMESPACE}" get pods \
      --selector app.cluster-overprovisioner/deployment=captures-overprovisioner \
      --field-selector status.phase!=Running -o name | wc -w
  )
  if [ "${pending_pods_count}" -ne 0 ]; then
    fail_and_exit "Some overprovisioner pods are in a Pending state, I can't continue."
  fi
  echo -e "${green}Ok${end}"
}

function check_overprovisioner_image {
  echo -n "Capture overprovisioner image... "
  local overprovisioner_image
  overprovisioner_image=$(
    kubectl -n "${OVERPROVISIONER_NAMESPACE}" get deployment "${OVERPROVISIONER_DEPLOYMENT}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}'
  )

  if [ "${overprovisioner_image}" != "${CAPTURE_IMAGE}" ]; then
    echo -e "${yellowb}You should set it to the most used capture image.${end}"
  else
    echo -e "${green}Ok${end}"
  fi
}

function now {
  date +%s
}

[[ ! $(which kubectl) ]] && fail_and_exit "kubectl CLI not found"

check_capture_status
check_overprovisioner_status
check_overprovisioner_image
white "Note that unschedulable capture nodes will be ignored."
echo
echo
whiteb "Kube context                       : $(kubectl config current-context)"
whiteb "Capture overprovisioner deployment : ${OVERPROVISIONER_DEPLOYMENT}"
whiteb "Capture overprovisioner namespace  : ${OVERPROVISIONER_NAMESPACE}"
whiteb "Most used capture image            : ${CAPTURE_IMAGE}"
echo -n "Continue? y/n "
read -r answer

if [[ "${answer}" != "y" ]]; then
  fail_and_exit "Did not receive [y], exiting."
fi

# List the nodes that are currently schedulable
nodes_to_rollout=$(
  kubectl get nodes \
    --selector group=captures-fix-group \
    --field-selector spec.unschedulable=false \
    -o jsonpath="{.items[*]['metadata.name']}"
)
whiteb "The following nodes will be processed : ${nodes_to_rollout}"

green "Cordoning ${nodes_to_rollout} ..."
for node in ${nodes_to_rollout}; do
  kubectl cordon "${node}"
done

green "Remove kubestatic label on ${nodes_to_rollout} ..."
for node in ${nodes_to_rollout}; do
  kubectl label node "${node}" kubestatic.quortex.io/externalip-auto-assign-
done

# First rollout overprovisioner nodes
overprovisioner_nodes=$(
  kubectl -n "${OVERPROVISIONER_NAMESPACE}" get pod \
    --selector app.cluster-overprovisioner/deployment=captures-overprovisioner \
    --sort-by=.spec.nodeName -o jsonpath="{.items[*]['spec.nodeName']}" | uniq
)
green "Draining all nodes with overprovisioner"
for node in ${overprovisioner_nodes}; do
  yellow "Draining ${node}"
  kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s
done

green "Wait for capture overprovisioners to be rescheduled and ready"
kubectl -n "${OVERPROVISIONER_NAMESPACE}" wait pod --for=condition=ready --timeout=10m \
  --selector "app.cluster-overprovisioner/deployment=captures-overprovisioner"

for node in ${nodes_to_rollout}; do
  # Get some info about the cluster state
  capture_pods=$(
    kubectl get pods -A \
      --selector app.kubernetes.io/name=capture \
      --field-selector "spec.nodeName=${node}" \
      -o jsonpath="{.items[*]['metadata.name']}"
  )

  # probably only overprovisioner pods on this node, skipping
  if [[ -z "${capture_pods}" ]]; then
    whiteb "Node ${node} does not have any captures, skipping"
    continue
  fi

  whiteb "Migrating the node ${node}"

  # Make an overprovisioner node (any of them) available for capture pods
  overprovisioner_node=$(
    kubectl -n "${OVERPROVISIONER_NAMESPACE}" get pod \
      --selector app.cluster-overprovisioner/deployment=captures-overprovisioner \
      -o jsonpath="{.items[0]['spec.nodeName']}"
  )

  # Start capture migration
  stamp=$(now)
  kubestatic_unlabel "${node}"
  yellow "==> Unlabeling capture node took $(($(now) - stamp))s."

  start_downtime=$(now)
  releaseip "${node}"
  yellow "==> Release EIP from capture node took $(($(now) - start_downtime))s."

  stamp=$(now)
  for pod in ${capture_pods}; do
    kubectl -n "${CAPTURE_NAMESPACE}" delete pod --force=true "${pod}"
  done
  yellow "==> Force deleted ${capture_pods} in $(($(now) - stamp))s."

  stamp=$(now)
  releaseip "${overprovisioner_node}"
  yellow "==> Release EIP from overprovisioner node took $(($(now) - stamp))s."

  stamp=$(now)
  drain "${node}"
  yellow "==> Draining took $(($(now) - stamp))s."

  # wait for capture pods to be scheduled on new node
  stamp=$(now)
  pending_capture_pods=$(
    kubectl -n "${CAPTURE_NAMESPACE}" get pods \
      --selector app.kubernetes.io/name=capture \
      --field-selector status.phase!=Running \
      -o jsonpath="{.items[*]['metadata.name']}"
  )
  for pod in ${pending_capture_pods}; do
    green "Waiting for ${pod} to be scheduled..."
    kubectl -n "${CAPTURE_NAMESPACE}" wait pod "${pod}" \
      --for=condition=ready --timeout=5m
  done
  end_downtime=$(now)

  yellow "==> Waiting for capture pod to be ready took $((end_downtime - stamp))s."
  yellowb "==> capture pods on ${node} were unavailable for $((end_downtime - start_downtime)) seconds."

  green "Wait for overprovisioners to be rescheduled and ready"
  kubectl -n "${OVERPROVISIONER_NAMESPACE}" wait pod \
    --for=condition=ready --timeout=10m \
    --selector "app.cluster-overprovisioner/deployment=captures-overprovisioner"
done

#!/bin/bash

set -eu pipeline

OVERPROVISIONER_NAMESPACE=cluster-overprovisioner
OVERPROVISIONER_DEPLOYMENT=cluster-overprovisioner-captures-overprovisioner
CAPTURE_NAMESPACE=reference
CAPTURE_IMAGE=$(
  kubectl get deployment -n reference -o json |
    jq -r '.items[] | select(.metadata.name | endswith("capture")) | .spec.template.spec.containers[0].image' |
    head -1
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
  redb "$1"
  exit 1
}

function drain {
  yellow "Draining $1"
  kubectl drain $1 --ignore-daemonsets=true --delete-emptydir-data=true --timeout=120s --skip-wait-for-delete-timeout=1
  green "$1 successfully drained."
}

function releaseip {
  externalip_name=$(
    kubectl get externalips -o json |
      jq -r --arg n $1 '.items[] | select(.spec.nodeName == $n) | .metadata.name'
  )

  for ip in $externalip_name; do
    green "Disassociate EIP $ip from $1"
    kubectl patch externalips $ip --type=merge -p '{"spec": {"nodeName": ""}}'
  done
}

function kubestatic_unlabel {
  green "Remove kubestatic label on node $1"
  kubectl label node $1 kubestatic.quortex.io/externalip-auto-assign-
}

function check_capture_status {
  echo -n "No capture pod should be pending, checking... "
  for status in $(kubectl -n $CAPTURE_NAMESPACE get pods \
    -l app.kubernetes.io/name=capture -o json |
    jq -r .items[].status.phase); do
    if [[ ${status} != "Running" ]]; then
      fail_and_exit "All capture pods are not in a Running state, I can't continue."
    fi
  done
  echo -e "${green}Ok${end}"
}

function check_overprovisioner_status {
  echo -n "No capture overprovisioner should be pending, checking... "
  for status in $(kubectl get -n $OVERPROVISIONER_NAMESPACE pods \
    -l app.cluster-overprovisioner/deployment=captures-overprovisioner -o json |
    jq -r .items[].status.phase); do
    if [[ ${status} == "Pending" ]]; then
      fail_and_exit "Some overprovisioner pods are in a Pending state, I can't continue."
    fi
  done
  echo -e "${green}Ok${end}"
}

function disable_unschedulable_ipassign {
  green "Make sure unschedulable node can not receive IP"
  local unschedulable_nodes=$(
    kubectl get nodes -l group=captures-fix-group -o json |
      jq -r '.items[] | select(.spec.unschedulable = true) | .metadata.name'
  )

  for node in ${unschedulable_nodes}; do
    kubestatic_unlabel $node
  done
}

function cordon_all {
  green "First, cordon all schedulable capture nodes.."
  nodes=$(
    kubectl get nodes -l group=captures-fix-group -o json |
      jq -r '.items[] | select(.spec.unschedulable != true) | .metadata.name'
  )

  for node in ${nodes}; do
    kubectl cordon ${node}
  done
}

function check_OP_image {
  echo -n "Capture overprovisioner image should match capture pod, checking... "
  OP_IMAGE=$(
    kubectl get deployment -n ${OVERPROVISIONER_NAMESPACE} ${OVERPROVISIONER_DEPLOYMENT} -o json |
      jq -r .spec.template.spec.containers[0].image
  )

  [[ ${OP_IMAGE} == ${CAPTURE_IMAGE} ]] || fail_and_exit "You must set capture overprovisioner image as the capture pod."
  echo -e "${green}Ok${end}"
}

function check_OP_GCR_secret {
  echo -n "Capture overprovisioner should have a secret and reference it to access GCR capture image, checking... "
  kubectl get secret -n ${OVERPROVISIONER_NAMESPACE} quortex-gcr > /dev/null 2>&1 || fail_and_exit "quortex-gcr secret is missing in namespace ${OVERPROVISIONER_NAMESPACE}"

  # check OP has a imagePullSecret block that points to existing secret
  OP_DEPLOY_SECRET_NAME=$(
    kubectl get deployment -n ${OVERPROVISIONER_NAMESPACE} ${OVERPROVISIONER_DEPLOYMENT} -o json |
      jq -r .spec.template.spec.imagePullSecrets[0].name 2>/dev/null
  )
  [[ ${OP_DEPLOY_SECRET_NAME} != "quortex-gcr" ]] && fail_and_exit "You must set the GCR image pull secret in capture overprovisioner deployment."

  echo -e "${green}Ok${end}"
}

function now {
  date +%s
}

[[ ! $(which kubectl) ]] && fail_and_exit "kubectl CLI not found"

check_capture_status
check_OP_image
check_OP_GCR_secret
check_overprovisioner_status
white "Note that unschedulable capture nodes will be ignored."
echo
echo
whiteb "Capture overprovisioner deployment : ${OVERPROVISIONER_DEPLOYMENT}"
whiteb "Capture overprovisioner namespace  : ${OVERPROVISIONER_NAMESPACE}"
whiteb "Capture image                      : ${CAPTURE_IMAGE}"
whiteb "Kube context                       : $(kubectl config current-context)"
echo -n "Continue? y/n "
read answer

if [[ $answer != "y" ]]; then
  fail_and_exit "Did not receive [y], exiting."
fi

disable_unschedulable_ipassign
cordon_all
#update_OP_image

# First rollout overprovisioner nodes
OP_nodesName=$(
  kubectl get pod -n $OVERPROVISIONER_NAMESPACE \
    -l app.cluster-overprovisioner/deployment=captures-overprovisioner -o json |
    jq -r .items[].spec.nodeName | uniq
)
green "Draining all nodes with overprovisioner"
for node in $OP_nodesName; do
  yellow "Draining ${node}"
  kubectl drain ${node} --ignore-daemonsets=true --delete-emptydir-data=true --force --timeout=120s
done

OP_podsName=$(
  kubectl get pod -n $OVERPROVISIONER_NAMESPACE \
    -l app.cluster-overprovisioner/deployment=captures-overprovisioner \
    -o name
)

green "Wait for capture overprovisioners to reschedule..."
TIMEOUT=300
for pod in $OP_podsName; do
  nodeName=null
  while [[ $nodeName == "null" ]]; do
    echo "nodename=$nodeName, waiting."
    # If nodeName is non-null then we consider it to be acceptable
    nodeName=$(
      kubectl get -n ${OVERPROVISIONER_NAMESPACE} ${pod} -o json |
        jq -r .spec.nodeName
    )
    sleep 1

    TIMEOUT=$((TIMEOUT - 1))
    if [[ $TIMEOUT -lt 0 ]]; then
      fail_and_exit capture overprovisioner never scheduled.
    fi
  done
  white "$pod is scheduled."
done

for node in ${nodes}; do
  # Get some info about the cluster state
  capture_pods=$(
    kubectl get pods -A --field-selector spec.nodeName=${node} |
      grep capture | awk '{print $2}'
  )
  # probably only overprovisioner pods on this node, skipping
  [[ -z $capture_pods ]] && continue

  white "Working on ${node}"

  # Make an OP node (any of them) available for capture pods
  OP_nodeName=$(
    kubectl get pod -n cluster-overprovisioner \
      -l app.cluster-overprovisioner/deployment=captures-overprovisioner \
      -o json |
      jq -r .items[0].spec.nodeName
  )

  # Start capture migration
  start_downtime=$(now)
  kubestatic_unlabel $node
  yellow "==> Unlabeling capture node took $(($(now) - start_downtime))s."
  stamp=$(now)

  green "Free $OP_nodeName overprovisioner node"
  kubectl uncordon $OP_nodeName
  yellow "==> Making overprovisioner node schedulable took $(($(now) - stamp))s."
  stamp=$(now)

  releaseip $node
  yellow "==> Release EIP from capture node took $(($(now) - stamp))s."
  stamp=$(now)

  for pod in ${capture_pods}; do
    kubectl delete pod --force=true -n ${CAPTURE_NAMESPACE} ${pod}
    yellow "==> Force deleted pod ${pod} in $(($(now) - stamp))s."
    stamp=$(now)
  done

  releaseip $OP_nodeName
  yellow "==> Release EIP from overprovisioner node took $(($(now) - stamp))s."
  stamp=$(now)

  drain $node
  yellow "==> Draining took $(($(now) - start_downtime))s."
  stamp=$(now)

  # wait for capture pods to be scheduled on new node
  pending_capture_pods=$(
    kubectl get pods -n $CAPTURE_NAMESPACE -o json |
      jq -r '.items[] | select(.status.phase == "Pending") | .metadata.name'
  )
  for pod in $pending_capture_pods; do
    green "Waiting for $pod to be scheduled..."
    kubectl wait -n $CAPTURE_NAMESPACE --for=condition=ready pod ${pod} --timeout=300s
  done
  yellow "==> Waiting for capture pod to be ready took $(($(now) - stamp))s."
  end_downtime=$(date +%s)
  yellowb "==> capture pods on ${node} were unavailable for $((end_downtime - start_downtime)) seconds."

  # wait for OP pods to be scheduled
  OP_podsName=$(
    kubectl get pod -n ${OVERPROVISIONER_NAMESPACE} \
      -l app.cluster-overprovisioner/deployment=captures-overprovisioner \
      -o name
  )
  green "Wait for overprovisioners to be rescheduled too"
  for pod in ${OP_podsName}; do
    green "Waiting for ${pod} to be scheduled..."
    nodeName=null
    while [[ $nodeName == "null" ]]; do
      # If nodeName is non-null then we consider it to be acceptable
      nodeName=$(
        kubectl get -n ${OVERPROVISIONER_NAMESPACE} ${pod} -o json |
          jq -r .spec.nodeName
      )
      sleep 1

      TIMEOUT=$((TIMEOUT - 1))

      if [[ $TIMEOUT -lt 0 ]]; then
        fail_and_exit capture overprovisioner never scheduled.
      fi

    done
    white "$pod is scheduled."
  done
done

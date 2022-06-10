#!/bin/bash

set -eu pipeline

OVERPROVISIONER_NAMESPACE=cluster-overprovisioner
OVERPROVISIONER_DEPLOYMENT=cluster-overprovisioner-captures-overprovisioner
CAPTURE_NAMESPACE=reference
#KUBESTATIC_NAMESPACE=kubestatic-system
#KUBESTATIC_DEPLOYMENT=kubestatic

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

function redb {
	echo -e "${redb}${1}${end}"
}

function fail_and_exit {
	redb "$1"
	exit 1
}

function drain {
	yellow "Draining $1"
	kubectl drain $1 --ignore-daemonsets=true --delete-emptydir-data=true --timeout=120s
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
									-l app.kubernetes.io/name=capture -o json | \
									jq -r .items[].status.phase)
	do
		if [[ ${status} != "Running" ]]
		then
			fail_and_exit "All capture pods are not in a Running state, I can't continue."
		fi
	done
	echo -e "${green}Ok${end}"
}

function check_overprovisioner_status {
	echo -n "No capture overprovisioner should be pending, checking... "
	for status in $(kubectl get -n $OVERPROVISIONER_NAMESPACE pods \
									-l app.cluster-overprovisioner/deployment=captures-overprovisioner -o json \
									| jq -r .items[].status.phase)
	do
		if [[ ${status} != "Running" ]]
		then
			fail_and_exit "All overprovisioner pods are not in a Running state, I can't continue."
		fi
	done
	echo -e "${green}Ok${end}"
}
[[ ! $(which kubectl) ]] && fail_and_exit "kubectl CLI not found"

check_capture_status
check_overprovisioner_status
echo; echo
whiteb "context:     $(kubectl config current-context)"
echo -n "Continue? y/n "
read answer

if [[ $answer != "y" ]];
then
	fail_and_exit "Did not receive [y], exiting."
fi

green "First, cordon all schedulable capture nodes.."
nodes=$(
	kubectl get nodes -l group=captures-fix-group -o json |
		jq -r '.items[] | select(.spec.unschedulable != true) | .metadata.name'
)
for node in ${nodes}; do
	kubectl cordon ${node}
done

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
	green "Draining ${node} successful"
done

OP_podsName=$(
	kubectl get pod -n $OVERPROVISIONER_NAMESPACE \
		-l app.cluster-overprovisioner/deployment=captures-overprovisioner \
		-o name
)

green "Wait for capture overprovisioners to reschedule..."
for pod in $OP_podsName; do
	kubectl wait -n ${OVERPROVISIONER_NAMESPACE} --for=condition=ready ${pod} --timeout=300s
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

	# Drain capture node
	drain $node
	kubestatic_unlabel $node
	releaseip $node

	# Make an OP node (any of them) available for capture pods
	OP_nodeName=$(
		kubectl get pod -n cluster-overprovisioner \
			-l app.cluster-overprovisioner/deployment=captures-overprovisioner \
			-o json |
			jq -r .items[0].spec.nodeName
	)
	green "Free $OP_nodeName overprovisioner node"
	kubectl uncordon $OP_nodeName
	releaseip $OP_nodeName

	# wait for capture pods to be scheduled on new node
	pending_capture_pods=$(
		kubectl get pods -n $CAPTURE_NAMESPACE -o json |
			jq -r '.items[] | select(.status.phase == "Pending") | .metadata.name'
	)
	for pod in $pending_capture_pods; do
		green "Waiting for $pod to be scheduled..."
		kubectl wait -n $CAPTURE_NAMESPACE --for=condition=ready pod ${pod} --timeout=300s
	done

	# wait for OP pods to be scheduled
	OP_podsName=$(
		kubectl get pod -n ${OVERPROVISIONER_NAMESPACE} \
			-l app.cluster-overprovisioner/deployment=captures-overprovisioner \
			-o name
	)
	green "Wait for overprovisioners to be rescheduled too"
	for pod in ${OP_podsName}; do
		green "Waiting for ${pod} to be scheduled..."
		kubectl wait -n ${OVERPROVISIONER_NAMESPACE} --for=condition=ready ${pod} --timeout=300s
	done
done

#!/bin/bash
# All ainode will be forces to reschedule on new nodes.
# Old nodes will stay unschedulable until being removed
# by cluster-autoscaler

# Bash strict mode
set -euo pipefail

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
	"lbalancer-main,statefulset,true"
	"dynamicrouter-main,statefulset,true"
	"drmmanager-main,statefulset,true"
	"encrypt-main,statefulset,true"
	"dashmanifestgen-main,statefulset,false"
	"hlsmanifestgen-main,statefulset,false"
	"packager-main,statefulset,true"
	"xaudio-main,statefulset,false"
	"xsubtitles-main,statefulset,false"
	"xcode-ska,statefulset,true"
	"xcode-main,statefulset,false"
	"xcode-backup,statefulset,true"
	"segmenter-main,statefulset,false"
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
for ainode in "${AINODE_BATCH[@]}"; do
	name=$(echo "${ainode}" | cut -d "," -f 1)
	kind=$(echo "${ainode}" | cut -d "," -f 2)
	wait=$(echo "${ainode}" | cut -d "," -f 3)
	changed="false"

	echo -e "${GREEN}Reconciling ainode ${name} ${NORMAL}"
	kubectl rollout restart ${kind}/${WORKFLOWPOOL}-${name}-ainode -n "${NAMESPACE}"

	# Wait for rollout to be completed
	echo -e "${GREEN}Waiting for rollout to be complete ${NORMAL}"
	kubectl rollout status "${kind}" "${WORKFLOWPOOL}-${name}-ainode" -n "${NAMESPACE}"

	if [[ $wait == "true" ]]; then
		echo -e "${YELLOW}Ainode needs to populate cache, waiting ${WAIT_TIME} seconds ${NORMAL}"
		sleep "${WAIT_TIME}"
	fi
done

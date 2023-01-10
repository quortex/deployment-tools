#!/bin/bash
# This script will connect to all RTMP handler pods and output the
# Input name. This may be useful if you want to make sure multiple
# streams from a single groupID are not on the same handler.

set -eu pipeline

HANDLER_NAMESPACE=reference

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

function get_input_name_from_stream {
	kubectl get streams -n ${HANDLER_NAMESPACE} -o json |
		jq -r --arg key $1 '.items[] | select(.spec.streamKey == $key) | .metadata.name'
}

[[ ! $(which kubectl) ]] && fail_and_exit "kubectl CLI not found"

whiteb "context:     $(kubectl config current-context)"
echo -n "Continue? y/n "
read answer

if [[ $answer != "y" ]];
then
	fail_and_exit "Did not receive [y], exiting."
fi

handlers=$(kubectl get pods -n ${HANDLER_NAMESPACE} -l app.kubernetes.io/name=rtmp-handler -o name)

for handler in $handlers; do
	kubectl -n ${HANDLER_NAMESPACE} port-forward ${handler} 8082:8080 > /dev/null 2>&1 &
	sleep 2

	handled_streams=$(curl -s http://localhost:8082/streams | jq -r .[])
	[[ -n ${handled_streams} ]] && \
		green "${handler} handles streams [${handled_streams}]" || \
		yellow "${handler} does not handle any stream"
	for key in ${handled_streams}; do
		input_name=$(
			kubectl get streams -n ${HANDLER_NAMESPACE} -o json |
				jq -r --arg k $key '.items[] | select(.spec.streamKey == $k) | .metadata.name'
		)
		white "${handler} -> input : ${input_name}"
	done

	pid=$(jobs -l -p)
	kill ${pid}

	sleep 1
done

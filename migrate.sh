#!/bin/bash

set -eu pipeline

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

function fail_and_exit {
  redb "$1"
  exit 1
}

RELEASE="quortex"
NAMESPACE="reference"

# Internal constants
INPUTS_PATH=`pwd`/inputs
LIVEENDPOINTS_PATH=`pwd`/liveendpoints

function help() {
    cat <<EOF
Migrate workflow from a cluster to another
Usage : $0 -b BLUE_CONTEXT -g GREEN_CONTEXT -i CONF_FOLDER [options]

Mandatory arguments :
    -i CONF_FOLDER     Set the folder from which read URLs and write back configurations.
    -b BLUE_CONTEXT     Kubernetes context for blue (source) cluster.
    -g GREEN_CONTEXT    Kubernetes context for green (destination) cluster.

Available options :
    -r RELEASE          Set helm release in which to apply this configuration (defaults to quortex).
    -n NAMESPACE        Set namespace in which to apply this configuration (defaults to reference).
    -o OUTPUT_FOLDER    Set the folder to output the files, instead of the input one.
    -h                  Display this help.
EOF
}


while getopts ":i:b:g:r:n:h" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    i)
        CONF_FOLDER=$OPTARG
        ;;
    b)
        BLUE_CONTEXT=$OPTARG
        ;;
    g)
        GREEN_CONTEXT=$OPTARG
        ;;
    n)
        NAMESPACE=$OPTARG
        ;;
    r)
        RELEASE=$OPTARG
        ;;
    esac
done

function check_deps {
  [[ -x getconfig.sh ]] || fail_and_exit "Missing script getconfig.sh (or bad permissions?)"
  [[ -x pushconfig.sh ]] || fail_and_exit "Missing script pushconfig.sh (or bad permissions?)"
}

function confirm_args {
    echo -e "${yellow}Using source context (blue) ${BLUE_CONTEXT}${end}"
    echo -e "${yellow}Using destination context (green) ${GREEN_CONTEXT}${end}"
    echo -en "${white}Do you confirm [y/n] ? ${end}"
    read ans

    if [[ $ans != "y" ]]; then
      fail_and_exit "You refused my offer, exiting."
    fi
}

function use_context {
    kubectl config use-context $1
}

function bluekctl {
  kubectl --context ${BLUE_CONTEXT} "$@"
}

function greenkctl {
  kubectl --context ${GREEN_CONTEXT} "$@"
}

function dump_blue_config {
  use_context ${BLUE_CONTEXT}

  # Workflow conf
  echo -e "${white}Download workflow configuration from ${BLUE_CONTEXT}${end}"
  ./getconfig -n ${NAMESPACE} -r ${RELEASE} -i ${CONF_FOLDER}

  # Inputs
  local inputs=$(kubectl get inputs -o name)
  for input in inputs
    do
      name=$(echo ${input} | cut -d/ -f2)
      echo -e "${white}Dumping input ${name} to ${INPUTS_PATH}/${name}.yaml${end}"
      kubectl get ${input} -o yaml > ${INPUTS_PATH}/${name}.yaml
    done

  # Liveendpoints
  local liveendpoints=$(kubectl get liveendpoints -o name)
  for l in liveendpoints
    do
      name=$(echo ${l} | cut -d/ -f2)
      echo -e "${white}Dumping liveendpoint ${name} to ${LIVEENDPOINTS_PATH}/${name}.yaml${end}"
      kubectl get ${l} -o yaml > ${LIVEENDPOINTS_PATH}/${name}.yaml
    done
  # todo:
  # apiendpoints
}

function pushconfig_to_green {
  use_context ${GREEN_CONTEXT}

  # Workflow conf
  echo -e "${white}Push workflow configuration to ${GREEN_CONTEXT}${end}"
  ./pushconfig -n ${NAMESPACE} -r ${RELEASE} -f ${CONF_FOLDER}

  # liveendpoints
  local liveendpoints=$()
}

check_deps
confirm_args
dump_blue_config
pushconfig_to_green

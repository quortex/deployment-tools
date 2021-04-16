#!/bin/bash
#
# The purpose of this script is to perform node-by-node cluster rolling updates.
# It allows to make the targeted nodes unschedulable and to drain them one by one.

# Largely inspired by this script https://github.com/travelaudience/kubernetes-utils/blob/master/cluster-upgrade/drain-nodes.sh and adapted according to our needs.

COUNT_PODS="kubectl get pods --all-namespaces -o wide"
POD_COUNT=2
INFO_ONLY=false
NO_COLOR=false
NON_INTERRACTIVE=false
NAMES=()
LABELS=()

function output_help {
    echo "Drain out nodes based on names and labels";
    echo "";
    echo "Examples:";
    echo "  By name:";
    echo "    # drain nodes foo and bar";
    echo "    `basename $0` foo bar";
    echo "";
    echo "  By labels:";
    echo "    # drain nodes matching selectors";
    echo "    `basename $0` -l foo=bar -l bar=baz";
    echo "";
    echo "Options:";
    echo "  -l  --selector  selectors (label query) to filter nodes on";
    echo "  -c  --count     count of non-running pods (completed/error) in the cluster before starting draining process (default 2)";
    echo "      --dry-run   simulate nodes drain";
    echo "  -y  --yes       run non interractively";
    echo "      --no-color  remove the additional color from the output";
}


while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -l|--selector)
    LABELS+=("-l $2")
    shift
    shift
    ;;
    -c|--count)
    POD_COUNT="$2"
    shift
    shift
    ;;
    --dry-run)
    INFO_ONLY=true
    shift
    ;;
    --no-color)
    NO_COLOR=true
    shift
    ;;
    -y|--yes)
    NON_INTERRACTIVE=true
    shift
    shift
    ;;
    -h|--help)
    output_help
    exit 0
    shift
    ;;
    *)
    NAMES+=("$1")
    shift
    ;;
esac
done

# ----------------
#  ECHO COLORING
# ----------------

# $1 content to echo
# $2 color
function c_echo {
    if [ "$NO_COLOR" = true ] ; then
        echo $1
    fi
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
    case $2 in
        red)
            printf "${RED}%b${NC}\n" "${1}"
        ;;
        green)
            printf "${GREEN}%b${NC}\n" "${1}"
        ;;
        yellow)
            printf "${YELLOW}%b${NC}\n" "${1}"
        ;;
        cyan)
            printf "${CYAN}%b${NC}\n" "${1}"
        ;;
        *)
            printf "%b\n" "${1}"
    esac
}

# ----------------
#  HELPER FUNCTIONS
# ----------------

function are_pods_not_running() {
    local counter
    counter=0
    while read -r w1 w2 w3 w4 w5 ; do
        if [ $w4 != "Running" ] && [ $w4 != "STATUS" ]; then
            let counter=counter+1
        fi
    done <<< "$($COUNT_PODS)"
    if [ "$counter" -gt "$1" ] ; then
        true
    else
        false
    fi
}

# $1 nodeName
# $2 additional flag
function drain_node() {
    local output
    c_echo ""
    c_echo " $ kubectl drain --ignore-daemonsets --delete-local-data $2 $1"
    kubectl drain --ignore-daemonsets --delete-local-data $2 $1
}

function wait_for_pods_to_migrate() {
    c_echo "Waiting for all (no less than $POD_COUNT) pods to start running again"
    while are_pods_not_running $POD_COUNT ; do
        printf "."
        sleep 5
    done
    c_echo "   done waiting"
}

# $1 nodeName
function echo_resource_usage() {
    c_echo "  resource usage for: $1  " "cyan"
    c_echo "  ------------------------"
    c_echo "$(kubectl describe node $1 | grep Allocated -A 5 |
            grep -ve Event -ve Allocated -ve percent -ve --)"
    c_echo ""
}

if are_pods_not_running $POD_COUNT ; then
    c_echo "Not enough pods are running. Adjust with -c option, and/or" "red"
    c_echo "  check which pods are running/not:" "red"
    c_echo "    $COUNT_PODS | grep -ve Running"
    exit 2
fi

#  create an array of the names, so they don't change while script is running
GET_NODES="kubectl get nodes ${NAMES[@]} ${LABELS[@]} --no-headers"
NODES=()
c_echo "These are the nodes that will be drained:"
while read -r n_name n_status n_role n_age n_version ; do
    c_echo "  $n_name"
    NODES+=($n_name)
done <<< "$($GET_NODES)"

if [ ${#NODES[@]} -eq 0 ]; then
    c_echo "No nodes found matching names and labels !" "red"
    c_echo ""
    exit 0
fi

# dry run stop here
if [ "$INFO_ONLY" = true ] ; then
    exit 0
fi

c_echo ""
if [ "$NON_INTERRACTIVE" = false ] ; then
    echo -n "Continue... [ENTER]"
    read cnt
fi

# mark each Node as unschedulable
for n in "${NODES[@]}" ; do
    c_echo "$(kubectl cordon $n)"
done

for n in "${NODES[@]}" ; do
    c_echo ""
    c_echo "Draining $n..." "cyan"
    c_echo ""
    echo_resource_usage $n

    if [ "$NON_INTERRACTIVE" = false ] ; then
        echo -n "Confirm node drain... [ENTER]"
        read ready
    fi

    drain_node $n ""
    wait_for_pods_to_migrate
    c_echo ""
done
c_echo "No more nodes to check!" "green"

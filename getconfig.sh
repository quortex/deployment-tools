#!/bin/bash
#
# Script Name: getconfig.sh
#
# Description: This scripts retrieves configurations from each service in the Quortex workflow.
#

VERSION="1.0.0"

INPUT_FOLDER=""
OUTPUT_FOLDER=""

RELEASE=""
NAMESPACE=""

SCHEME="https"
APIGATEWAY_URL=""
CURL_AUTH_ARGUMENTS=""
CURL_COMMON_ARGUMENTS="--silent --show-error --connect-timeout 10 --fail"
SED_SANITIZE_REGEXP='s/\$[A-Za-z{}_]+/{}/' # Replace all environment variables with {} to sanitize templates

SORT_OUTPUT="false"

function help() {
    cat <<EOF
Retrive configurations via the kubernetes API or the API Gateway.
Usage : $0 -n NAMESPACE -r RELEASE -i INPUT_FOLDER [options]

Mandatory arguments :
    -i INPUT_FOLDER     Set the folder from which read URLs and write if no output is provided.
    -r RELEASE          Set helm release in which to apply this configuration.
    -n NAMESPACE        Set namespace in which to apply this configuration.

Available options :
    -o OUTPUT_FOLDER    Set the folder to output the files, instead of the input one.
    -A URL              Set the URL of the external API which will be used instead of the internal one.
    -u CREDENTIALS      Set the user and password to use with the external API (following the format "user:password").
    -I                  Insecure mode, use HTTP instead of HTTPS with the external API.
    -s                  Sort pulled configuration.
    -h                  Display this help.
EOF
}

while getopts ":i:o:r:n:A:u:shI" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    i)
        INPUT_FOLDER=$OPTARG
        ;;
    o)
        OUTPUT_FOLDER=$OPTARG
        ;;
    r)
        RELEASE=$OPTARG
        ;;
    n)
        NAMESPACE=$OPTARG
        ;;
    s)
        SORT_OUTPUT="true"
        ;;
    A)
        APIGATEWAY_URL=$OPTARG
        ;;
    I)
        SCHEME="http"
        ;;
    u)
        CURL_AUTH_ARGUMENTS="-u $OPTARG"
        ;;
    esac
done

if [ "$INPUT_FOLDER" == "" ]; then
    echo "Input folder was not specified, aborting"
    exit 1
elif [ "$RELEASE" == "" ]; then
    echo "Release was not specified, aborting"
    exit 1
elif [ "$NAMESPACE" == "" ]; then
    echo "Namespace was not specified, aborting"
    exit 1
fi

if [ "$OUTPUT_FOLDER" == "" ]; then
    # If output is empty, use input folder as output folder
    OUTPUT_FOLDER=$INPUT_FOLDER
else
    # Create the output folder if non-existent
    mkdir -p "$OUTPUT_FOLDER"
fi

# --- Arguments ---
echo "Arguments provided :"
echo "INPUT FOLDER: $FOLDER"
echo "OUTPUT FOLDER: $FOLDER"
echo "RELEASE: $RELEASE"
echo "NAMESPACE: $NAMESPACE"
if [ $APIGATEWAY_URL ]; then
    echo "USING: APIGATEWAY (${SCHEME}://${APIGATEWAY_URL})"
else
    echo "USING: KUBEPROXY"
fi

################ UTILITARY FUNCTIONS ################

function warning() {
    echo "$@" 1>&2
}

function error() {
    echo "$@" 1>&2
    exit 1
}

################ KUBEPROXY RELATED FUNCTIONS ################

function make_proxy() {
    # Start kube proxy
    proxy_logfile="proxy.log"

    kubectl proxy -p 0 >$proxy_logfile &
    pid=$!

    # Prepare cleanup
    function cleanup() {
        echo "Stopping proxy"
        kill -9 "$pid" || true
        rm $proxy_logfile
    }
    trap cleanup EXIT

    # Wait for the proxy to be started a maximum of 3 seconds
    i=0
    while [ ! "$(cat $proxy_logfile 2>/dev/null | wc -c)" -gt 0 ]; do
        if [ $i -eq 30 ]; then
            error "Could not start proxy : $(cat proxy.log)"
        else
            sleep 0.1
            i=$(($i + 1))
        fi
    done

    proxy_port=$(cat $proxy_logfile | cut -d':' -f 2)
    echo "API Proxy started on port $proxy_port (pid $pid)"
}

################ BUSINESS LOGIC FUNCTIONS ################

function make_url() {
    local service=$1
    local path=$2

    if [ $APIGATEWAY_URL ]; then
        url="${SCHEME}://${APIGATEWAY_URL}/${service}${path}"
    elif [ $proxy_port ]; then
        url="http://localhost:$proxy_port/api/v1/namespaces/${NAMESPACE}/services/${RELEASE}-${service}:api/proxy${path}"
    else
        error "Internal error : cannot make url if APIGATEWAY_URL is not provided and the proxy is not started."
    fi
    echo $url
}

function append_config_to_file() {
    local config=$1
    local url=$2
    local file=$3

    tmp_file=$(mktemp)
    cat "$file" |
        jq --sort-keys --arg url $url --argfile conf $config \
            '. += [{"url": $url, "confs" : $conf}]' >"$tmp_file"
    cat "$tmp_file" >"$file"
    rm -f "$tmp_file"
}

function sort_file() {
    local file=$1
    tmp_file=$(mktemp)
    cat "$file" |
        jq '. |= sort_by(.url)' |
        jq '.[].confs |= sort_by(.name)' >"$tmp_file"
    cat "$tmp_file" >"$file"
    rm -f "$tmp_file"
}

# MAIN :

if [ ! $APIGATEWAY_URL ]; then
    make_proxy
fi

config_files=$(find -L $INPUT_FOLDER -iname "*.json" -type f -printf "%p\n" | sort)
tmp_dir=$(mktemp -d)

for config_file in $config_files; do
    service_config_list=$(cat "${config_file}" | sed -E $SED_SANITIZE_REGEXP | jq .)
    service_name=$(basename -- "${config_file}" | sed -E 's/(.*).json/\1/')

    # For each elements in the root list
    index=0
    while [ TRUE ]; do
        service_config_i=$(cat $config_file  | sed -E $SED_SANITIZE_REGEXP | jq .[$index])
        if [ "$service_config_i" == "null" ]; then
            break
        fi
        path=$(echo $service_config_i | jq -r .url)
        url=$(make_url $service_name $path)

        tmp_config=$(mktemp)
        echo "Retrieving $service_name -> $path"
        curl $CURL_COMMON_ARGUMENTS $CURL_AUTH_ARGUMENTS -X GET "$url" -o "$tmp_config"
        code=$?
        if [ $code -eq 22 ]; then
            warning "Could not reach $url, a 4XX was returned."
        elif [ $code -ne 0 ]; then
            error "Could not download from $url, error $code."
        else
            # If file dosn't exist, prefill it with an empty array
            if [ ! -f "$tmp_dir/$service_name.json" ]; then
                echo "[]" >"$tmp_dir/$service_name.json"
            fi

            # Append the content of the file to the json
            append_config_to_file "$tmp_config" "$path" "$tmp_dir/$service_name.json"

            # If sorting is wanted, sort files
            if [ $SORT_OUTPUT == "true" ]; then
                sort_file "$tmp_dir/$service_name.json"
            fi
        fi
        rm -f $tmp_config

        index=$(($index + 1))
    done
done

for config_file in $config_files; do
    service_name=$(basename -- "${config_file}" | sed -E 's/(.*).json/\1/')
    if [ -f "$tmp_dir/$service_name.json" ]; then
        cp "$tmp_dir/$service_name.json" "$OUTPUT_FOLDER/$service_name.json"
    fi
done

rm -rf $tmp_dir

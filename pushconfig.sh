#!/bin/bash
#
# Script Name: pushconfig.sh
#
# Description: This scripts pushes configurations to each service in the Quortex workflow.
#

FOLDER=""
SCHEME="https"
APPLY="backend,ainode,unit"
VERSION="3.2.0"
NO_DRY_RUN=true
TEST_MODE=false
PRINT_SUBST=true
VERBOSE=false
RELEASE=""
NAMESPACE=""
APIGATEWAY_URL=""
CURL_AUTH_ARGUMENTS=""
CURL_COMMON_ARGUMENTS="--silent --show-error --connect-timeout 10 --fail"
EXTENSION_OVERRIDE=""

function help() {
    cat <<EOF
Applies a configuration. Relies on the kubernetes API or on the API gateway.
Usage : $0 -n NAMESPACE -r RELEASE -f CONFIG_FOLDER [options]

Mandatory arguments :
    -f CONFIG_FOLDER     Set the folder from which read URLs and write if no output is provided.
    -r RELEASE           Set helm release in which to apply this configuration.
    -n NAMESPACE         Set namespace in which to apply this configuration.

Available options :
    -a SELECTOR defines the pattern to match on files where configurations will be applied. Defaults to "$APPLY".
    -s                   Set substitution variables.
    -b                   Set substitution variables as base64.
    -A URL               Set the URL of the external API which will be used instead of the internal one.
    -u CREDENTIALS       Set the user and password to use with the external API (following the format "user:password").
    -I                   Insecure mode, use HTTP instead of HTTPS with the external API.
    -V                   Be verbose.
    -d                   Use this script in dry run: no change will be made.
    -h                   Display this help.
    -o                   Override extension of .json configuration file. If set, any file named confXXX.json-<override-extension> will be used instead of confXXX.json.
    -t                   Enable TEST mode. TEST mode activates dry run mode (-d) and does not estiblish connection with any k8s cluster.
EOF
}

while getopts ":f:a:r:n:s:b:A:u:hvdIHVo:t" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    V)
        VERBOSE=true
        ;;
    H)
        PRINT_SUBST=false
        ;;
    d)
        NO_DRY_RUN=false
        ;;
    A)
        APIGATEWAY_URL=$OPTARG
        ;;
    u)
        CURL_AUTH_ARGUMENTS="-u $OPTARG"
        ;;
    I)
        SCHEME="http"
        ;;
    f)
        FOLDER=$OPTARG
        ;;
    a)
        APPLY=$OPTARG
        ;;
    r)
        RELEASE=$OPTARG
        ;;
    n)
        NAMESPACE=$OPTARG
        ;;
    s)
        SUBST+=("$OPTARG")
        ;;
    b)
        BSUBST+=("$OPTARG")
        ;;
    o)
        EXTENSION_OVERRIDE=$OPTARG
        ;;
    t)
        NO_DRY_RUN=false
        TEST_MODE=true
        ;;
    *)
        echo "Unsupported flag provided : $OPTARG".
        help
        exit 1
        ;;
    esac
done

if [ "$FOLDER" == "" ]; then
    echo "Input folder was not specified, aborting"
    exit 1
fi

# --- Arguments ---
echo "Arguments provided :"
echo "CONFIGURATION FOLDER: $FOLDER"
echo "RELEASE: $RELEASE"
echo "NAMESPACE: $NAMESPACE"
if [ $PRINT_SUBST = true ]; then
    echo "SUBSTITUTION VARIABLES: [${SUBST[@]} ${BSUBST[@]}]"
else
    echo "SUBSTITUTION VARIABLES: HIDDEN"
fi

if [ $APIGATEWAY_URL ]; then
    echo "USING: APIGATEWAY (${SCHEME}://${APIGATEWAY_URL})"
else
    echo "USING: KUBEPROXY"
fi

# We store all substitution variables to explicitly envsubst on these variables only
VARS=
for val in ${SUBST[@]}
do
    VARS=${VARS:+$VARS }\$"$(cut -d'=' -f1 <<<$val)"
done
for val in ${BSUBST[@]}
do
    VARS=${VARS:+$VARS }\$"$(cut -d'=' -f1 <<<$val)"
done

REMUUID_FUNCTION='
def walk(f):
  . as $in
  | if type == "object" then
      reduce keys[] as $key
        ( {}; . + { ($key):  ($in[$key] | walk(f)) } ) | f
    elif type == "array" then map( walk(f) ) | f
    else f
    end;

walk(if type == "object" then del(.uuid) else . end)
'

# This function is responsible for putting or posting configurations. Although a lot
# of things can be factorized, this functions is quite simple: it takes a table of
# new configurations and a table of existing configurations in parameter.
#
# For every new conf, it will iterate over existing conf to check if a configuration
# with the same content, name, location or regex exists.
# - If the conf are identical, it will do nothing
# - If the conf differs but have the same name, location or regex, it will put
# - If no existing conf is found, it will put.
#
# Having "location" and "regex" is a bit hackish here. If the ainodes configuration had
# a "name" field, this function could be reduced by a factor or 2 or 3!

function add_config() {
    local new=$1
    local exi=$2
    local url=$3
    exi_main=$exi
    num_new=$(echo $new | jq length)

    for n in $(seq 0 $(($num_new - 1))); do
        new_conf=$(echo $new | jq .[$n])
        new_uuid=$(echo $new_conf | jq -r .uuid)
        new_conf=$(echo $new_conf | jq "$REMUUID_FUNCTION")

        new_md5="$(echo $new_conf | md5sum)"
        new_name="$(echo $new_conf | jq -r .name)"
        new_location="$(echo $new_conf | jq .location)"
        new_regex="$(echo $new_conf | jq .regex)"

        exi=$exi_main
        num_exi=$(echo $exi | jq length)

        action="post"
        exi_conf=""

        for e in $(seq 0 $(($num_exi - 1))); do
            exi_conf=$(echo $exi | jq .[$e])
            exi_uuid=$(echo $exi_conf | jq -r .uuid)
            exi_conf=$(echo $exi_conf | jq "$REMUUID_FUNCTION")

            exi_md5="$(echo $exi_conf | md5sum)"
            exi_name=$(echo $exi_conf | jq -r .name)
            exi_location=$(echo $exi_conf | jq .location)
            exi_regex=$(echo $exi_conf | jq .regex)

            # If the conf are bit identical, obvisouly do nothing!
            if [ "$new_md5" == "$exi_md5" ]; then
                action="idle"
                break
            fi

            # If the name of the conf is the same, but content is different, we have to put
            if [ "$new_name" != "null" ] && [ "$new_name" == "$exi_name" ]; then
                action="put"
                break
            fi

            # If the uuid is the same, but content is different, let's put
            if [ "$new_uuid" != "null" ] && [ "$new_uuid" == "$exi_uuid" ]; then
                action="put"
                break
            fi

            # If the location is the same, but content is different, let's put
            if [ "$new_location" != "null" ] && [ "$new_location" == "$exi_location" ]; then
                action="put"
                break
            fi

            # If the location is the same, but content is different, let's put
            if [ "$new_regex" != "null" ] && [ "$new_regex" == "$exi_regex" ]; then
                action="put"
                break
            fi
        done

        if [ "$action" == "idle" ] || [ "$action" == "put" ] || [ "$action" == "post" ]; then
            if [ "$exi_conf" != "" ]; then
                # Remove this entry from existinf conf to speed up the processing
                if [ "$exi_name" != "null" ]; then
                    exi_main=$(echo $exi_main | jq ". | del(.[] | select(.name==\"$exi_name\"))")
                fi
                if [ "$exi_location" != "null" ]; then
                    exi_main=$(echo $exi_main | jq ". | del(.[] | select(.location==$exi_location))")
                fi
                if [ "$exi_regex" != "null" ]; then
                    exi_main=$(echo $exi_main | jq ". | del(.[] | select(.regex==$exi_regex))")
                fi
                if [ "$exi_uuid" != "null" ]; then
                    exi_main=$(echo $exi_main | jq ". | del(.[] | select(.uuid==\"$exi_uuid\"))")
                fi
            fi
        fi

        if [ "$action" == "post" ]; then
            tmp=$(mktemp)
            echo $new_conf >$tmp
            printf "+"
            $VERBOSE && printf "\nWill post $(echo new_conf | jq .)"
            $NO_DRY_RUN && curl $CURL_AUTH_ARGUMENTS $CURL_COMMON_ARGUMENTS -X POST -H "Content-Type: application/json" "${url}" -d@$tmp
            rm $tmp
        elif [ "$action" == "put" ]; then
            tmp=$(mktemp)
            # Use name if exists, or uuid if exists
            if [ "$exi_uuid" != "null" ]; then
                echo $new_conf | jq ". += {\"uuid\":\"$exi_uuid\"}" >$tmp
                $VERBOSE && printf "\nWill put $(echo $new_conf | jq .)"
                $NO_DRY_RUN && curl $CURL_AUTH_ARGUMENTS $CURL_COMMON_ARGUMENTS -X PUT -H "Content-Type: application/json" "${url}/${exi_uuid}" -d@$tmp
            elif [ "$exi_name" != "null" ]; then
                echo $new_conf >$tmp
                $VERBOSE && printf "\nWill put $(echo $new_conf | jq .)"
                $NO_DRY_RUN && curl $CURL_AUTH_ARGUMENTS $CURL_COMMON_ARGUMENTS -X PUT -H "Content-Type: application/json" "${url}/${exi_name}" -d@$tmp
            else
                echo "WTF"
            fi
            rm $tmp
            printf "*"
        else
            $VERBOSE && printf "\nNot touching $(echo $exi_conf | jq .)"
            printf "."
        fi
    done
}

# This function is responsible for deleting configurations. Although a lot
# of things can be factorized, this functions is quite simple: it takes a table of
# new configurations and a table of existing configurations in parameter.
#
# Having "location" and "regex" is a bit hackish here. If the ainodes configuration had
# a "name" field, this function could be reduced by a factor or 2 or 3!
function delete_config() {
    local new=$1
    local exi=$2
    local url=$3
    new_main=$new
    num_exi=$(echo $exi | jq length)

    for e in $(seq 0 $(($num_exi - 1))); do
        exi_conf=$(echo $exi | jq .[$e])
        exi_uuid=$(echo $exi_conf | jq -r .uuid)
        exi_conf=$(echo $exi_conf | jq "$REMUUID_FUNCTION")

        exi_md5="$(echo $exi_conf | md5sum)"
        exi_name="$(echo $exi_conf | jq -r .name)"
        exi_location="$(echo $exi_conf | jq .location)"
        exi_regex="$(echo $exi_conf | jq .regex)"

        new=$new_main
        num_new=$(echo $new | jq length)

        new_conf=""
        action="delete"
        for n in $(seq 0 $(($num_new - 1))); do
            new_conf=$(echo $new | jq .[$n])
            new_uuid=$(echo $new_conf | jq -r .uuid)
            new_conf=$(echo $new_conf | jq "$REMUUID_FUNCTION")

            new_md5="$(echo $new_conf | md5sum)"
            new_name="$(echo $new_conf | jq -r .name)"
            new_location="$(echo $new_conf | jq .location)"
            new_regex="$(echo $new_conf | jq .regex)"

            # If the conf are bit identical, obvisouly do nothing!
            if [ "$new_md5" == "$exi_md5" ]; then
                action="idle"
                break
            fi

            # If the name of the conf is the same, but content is different, do not delete
            if [ "$new_name" != "null" ] && [ "$new_name" == "$exi_name" ]; then
                action="idle"
                break
            fi

            # If the uuid is the same, but content is different, let's put
            if [ "$new_uuid" != "null" ] && [ "$new_uuid" == "$exi_uuid" ]; then
                action="put"
                break
            fi

            # If the location is the same, but content is different, do not delete
            if [ "$new_location" != "null" ] && [ "$new_location" == "$exi_location" ]; then
                action="idle"
                break
            fi
            # If the location is the same, but content is different, do not delete
            if [ "$new_regex" != "null" ] && [ "$new_regex" == "$exi_regex" ]; then
                action="idle"
                break
            fi
        done

        if [ "$action" == "idle" ] && [ "$new_conf" != "" ]; then
            # Remove this entry from existing conf to speed up the processing
            if [ "$new_name" != "null" ]; then
                new_main=$(echo $new_main | jq ". | del(.[] | select(.name==\"$new_name\"))")
            fi
            if [ "$new_location" != "null" ]; then
                new_main=$(echo $new_main | jq ". | del(.[] | select(.location==$new_location))")
            fi
            if [ "$new_regex" != "null" ]; then
                new_main=$(echo $new_main | jq ". | del(.[] | select(.regex==$new_regex))")
            fi
        fi
        if [ "$action" == "delete" ]; then
            printf "-"
            if [ "$exi_uuid" != "null" ]; then
                $VERBOSE && printf "\nDeleting $(echo $exi_conf | jq .)"
                $NO_DRY_RUN && curl $CURL_AUTH_ARGUMENTS $CURL_COMMON_ARGUMENTS -X DELETE "${url}/${exi_uuid}"
            elif [ "$exi_name" != "null" ]; then
                $VERBOSE && printf "\nDeleting $(echo $exi_conf | jq .)"
                $NO_DRY_RUN && curl $CURL_AUTH_ARGUMENTS $CURL_COMMON_ARGUMENTS -X DELETE "${url}/${exi_name}"
            else
                echo "Unhandled Error : delete action without uuid or name."
            fi
        else
            $VERBOSE && printf "\nNot touching $(echo $exi_conf | jq .)"
            printf "."
        fi
    done
}

function update_configuration() {
    # Get all substitutions variables and export them for envsubst !
    for val in "${SUBST[@]}"; do
        K="$(cut -d'=' -f1 <<<$val)"
        V="$(cut -d'=' -f2- <<<$val)"
        declare "$K"="$V"
        export "$K"
    done

    # Get all base64 substitutions variables and export them for envsubst !
    for val in "${BSUBST[@]}"; do
        K="$(cut -d'=' -f1 <<<$val)"
        # Base64 should contain = sign so we use regex with sed to get text after first = sign
        V="$(echo $val | sed -r 's/[^=]*=(.*)/\1/g' | base64 --decode)"
        declare "$K"="$V"
        export "$K"
    done

    selector=$1
    api_port=$2
    config_files=$(find -L $FOLDER -iname "*.json" -type f -printf "%p\n" | grep -v -E "_([^_]+).json$" | sort)

    for configfile in $config_files; do
        if [ $(echo $configfile | grep $selector | wc -l) -eq 0 ]; then
            continue
        fi

        # Check extension override
        if [ ! -z "${EXTENSION_OVERRIDE}" ]; then
            pattern="${configfile%.*}_${EXTENSION_OVERRIDE}.json"
            if [ -f "${pattern}" ]; then
                echo "OVERRIDE: use '${pattern}' file instead of default ${configfile}"
                configfile="${pattern}"
            fi
        fi

        filename=$(basename -- "${configfile}") # Name of the file, without repertory
        output_name="${filename%.*}"            # remove the .json file extension
        service="${output_name%%_*}"            # service name is the 1st part of the filename, before "_"
        if [ $APIGATEWAY_URL ]; then
            base_url="${SCHEME}://${APIGATEWAY_URL}/${service}"
        else
            base_url="http://localhost:${api_port}/api/v1/namespaces/${NAMESPACE}/services/${RELEASE}-${service}:api/proxy"
        fi

        i=0
        ! $NO_DRY_RUN && printf "[DRY RUN] "
        printf "Updating $service"
        while [ TRUE ]; do
            # Read configuration
            config=$(eval "envsubst <$configfile '"$VARS"' | jq .[$i]")
            if [ "$config" == "null" ]; then
                break
            elif [ -z "$config" ]; then
                echo ""
                echo '/!\ /!\ /!\ '
                echo "/!\ /!\ /!\ WARNING: There is an error with file ${filename}: corrupted/invalid. Ignoring the file."
                echo '/!\ /!\ /!\ '
                echo ""
                break
            fi

            # Retreive and compose path
            path=$(echo $config | jq -r .url)
            full_url="$base_url$path"

            # Get new confs
            new_confs=$(echo $config | jq .confs | jq -S .)

            # Get existing confs
            tmp=$(mktemp)
            curl $CURL_AUTH_ARGUMENTS $CURL_COMMON_ARGUMENTS -X GET "${full_url}" -o $tmp
            # Check if the result looks like json
            json=$(cat $tmp | grep '{' | wc -l)
            if [ $json -gt 0 ]; then
                existing_confs=$(cat $tmp | jq -S .)
            else
                existing_confs="{}"
            fi
            add_config "$new_confs" "$existing_confs" "$full_url"
            delete_config "$new_confs" "$existing_confs" "$full_url"

            i=$(($i + 1))
        done
        printf '\n'
    done
}

api_port=0
if ! $TEST_MODE; then
    if [ ! $APIGATEWAY_URL ]; then
        # Start a kubectl proxy in the background, to access the services API
        kubectl proxy -p 0 >proxy.port &
        pid="$!"
        sleep 3
        kill -0 "${pid}" # Check that the proxy is started (the command "kill -0" returns an error status when the pid does not exist)

        api_port=$(cat proxy.port | cut -d':' -f 2)
        echo "API Proxy started on port $api_port (pid $pid)"

        # Make sure to stop the proxy when this script ends (this function will be executed only at EXIT)
        function cleanup() {
            echo "Stopping proxy"
            kill -9 "$pid" || true
            rm proxy.port
        }
        trap cleanup EXIT
    fi
else
    echo "[TEST MODE] Do not start kubectl proxy"
fi

for selector in $(echo "$APPLY" | tr "," " "); do
    update_configuration $selector $api_port
done

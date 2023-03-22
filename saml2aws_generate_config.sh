#!/bin/bash
#
# This script is based on saml2aws in order to list the available roles and
# automatically generate a config for aws cli containing the profiles matching
# the different accounts / roles. Generated profiles use the credential_process
# feature to execute saml2aws login automatically.

set -euo pipefail

ACCOUNT_REGEX="^Account: ([^[:space:]]*).*"
ROLE_REGEX="arn:aws:iam::.*:role\/([^[:space:]]*)"
account=

# Retrieve role list from saml2aws
roles_list=$(saml2aws list-roles --skip-prompt)
num_lines=$(echo "$roles_list" | wc -l)
current_line=0

# Iterate over role list to generate aws config
echo "$roles_list" | while read line; do
  current_line=$(($current_line + 1))

  # Capture AWS account alias
  if [[ $line =~ $ACCOUNT_REGEX ]]
  then
    account="${BASH_REMATCH[1]}"
    echo "## ${line}"
    echo "##"
  fi

  # Capture role name
  if [[ $line =~ $ROLE_REGEX ]]
  then
    role_arn=$line
    role_name="${BASH_REMATCH[1]}"
    profile="${account}/${role_name}"
    echo "[profile ${profile}]"
    echo "output = json"
    echo "credential_process = saml2aws login --skip-prompt --quiet --credential-process --role ${role_arn} --profile ${profile}-saml2aws"
    if [[ $current_line -ne $num_lines ]]
    then 
      echo ""
    fi
  fi
done

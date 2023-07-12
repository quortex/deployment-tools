#!/bin/bash
#
# The purpose of this script is to provision the resources needed to store
# terraform states on AZURE. It will provision a container on Azure Storage account as well as a
# container to support state locking and consistency checking.
#
# Official documentation about terraform state in Azure Storage Account =>
# https://developer.hashicorp.com/terraform/language/settings/backends/azurerm
# Bash strict mode
set -euo pipefail

RESOURCE_GROUP_NAME=administration
SUBSCRIPTION=

function help() {
    cat <<EOF
Provision the resources needed to store terraform states on Azure.
A storage account is created and container for store state.
Usage : $0 -a STORAGE_ACCOUNT -c STORAGE_CONTAINER [options]

Mandatory arguments :
    -a         The name of Storage Account.
    -c         The name of Storage Container.
Available options :
    -s          The name of the subscription.
    -r         The name of Ressource Group (default $RESOURCE_GROUP_NAME).
    -h           Display this help.
EOF
}

while getopts "h:r:a:c:s" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    r)
        RESOURCE_GROUP_NAME=$OPTARG
        ;;
    a)
        STORAGE_ACCOUNT_NAME=$OPTARG
        ;;
    c)
        CONTAINER_NAME=$OPTARG
        ;;
    s)
        SUBSCRIPTION=$OPTARG
        ;;
    *)
        echo "Unsupported flag provided : ${OPTARG}".
        help
        exit 1
        ;;
    esac
done

if [ "$NAME" == "" ]; then
    echo "Name was not specified, aborting !"
    exit 1
fi

if [ "$SUBSCRIPTION" == "" ]; then
    echo "Subscription not specified, the subscription is the default sub of the account."
    SUBSCRIPTION=$(az account list --query "[?isDefault].id | [0]" -o tsv)
fi

export AZURE_extension_use_dynamic_install=yes_without_prompt

# Create Storage Account
echo "Creating storage account : ${STORAGE_ACCOUNT_NAME}"
az storage account create \
    --name "${STORAGE_ACCOUNT_NAME}" \
    --resource-group "${RESOURCE_GROUP_NAME}" \
    --sku Standard_LRS \
    --encryption-services blob

# Create Storage Account Container
echo "Creating Storage Account : ${CONTAINER_NAME}"
az storage container create \
    --name "${CONTAINER_NAME}" \
    --account-name "${STORAGE_ACCOUNT_NAME}" \
    --auth-mode login

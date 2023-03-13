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

REGION=westeurope
NAME=
RESOURCE_GROUP_NAME=administration
SUBSCRIPTION=

function help() {
    cat <<EOF
Provision the resources needed to store terraform states on Azure.
A storage account is created and container for store state.
Usage : $0 -n NAME [options]

Mandatory arguments :
    -n NAME      Set the name of created resources.
Available options :
    -r          The name of the region (default $REGION).
    -s          The name of the subscription.
    -rg         The name of Ressource Group (default $RESOURCE_GROUP_NAME).
    -st         The name of Storage Account.
    -ct         The name of Container.
    -h           Display this help.
EOF
}

while getopts "n:s:r:h:rg:st:ct" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    r)
        REGION=$OPTARG
        ;;
    n)
        NAME=$OPTARG
        ;;
    rg)
        RESOURCE_GROUP_NAME=$OPTARG
        ;;
    st) 
        STORAGE_ACCOUNT_NAME=$OPTARG
        ;;
    ct)
        CONTAINER_NAME=$OPTARG
        ;;
    s)
        SUBSCRIPTION=$OPTARG
        ;;

    esac
done

if [ "$NAME" == "" ]; then
    echo "Name was not specified, aborting !"
    exit 1
fi

if [ "$SUBSCRIPTION" == "" ]; then
    echo "Subscription not specified, the subscription is the default sub of the account."
    SUBSCRIPTION=$(az account list --query [].id)
    #Format subscription id
    SUBSCRIPTION="${SUBSCRIPTION/]/}"
    SUBSCRIPTION="${SUBSCRIPTION/[/}"
    SUBSCRIPTION="${SUBSCRIPTION//\"/}"
    SUBSCRIPTION="${SUBSCRIPTION// /}"
    SUBSCRIPTION="${SUBSCRIPTION//\n/}"
fi

#az account create --enrollment-account-name toto1 --offer-type 0003P --display-name toto1 --owner-object-id cab314e7-8f50-41b9-ad3c-75f31066ea98
#az account set --name toto1


#Set var with name input
STORAGE_ACCOUNT_NAME=${NAME}staccount
CONTAINER_NAME=tfstate${STORAGE_ACCOUNT_NAME}

export AZURE_extension_use_dynamic_install=yes_without_prompt
user=$(az ad signed-in-user show --query userPrincipalName --output tsv)


# Create Storage Account
echo "Creating storage account : ${RESOURCE_GROUP_NAME}"
res=$(az storage account create --resource-group $RESOURCE_GROUP_NAME --name $STORAGE_ACCOUNT_NAME --sku Standard_LRS --encryption-services blob)

echo "Creating Storage Account : ${RESOURCE_GROUP_NAME}"
# Create Storage Account Container
res=$(az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME --auth-mode login)

echo "storage_account_name: $STORAGE_ACCOUNT_NAME"
echo "container_name: $CONTAINER_NAME"

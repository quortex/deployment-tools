#!/bin/bash
#
# The purpose of this script is to provision the resources needed to store
# terraform states on AWS. It will provision a bucket on Amazon S3 as well as a
# Dynamo DB table to support state locking and consistency checking.
#
# Official documentation about terraform state in S3 =>
# https://www.terraform.io/language/settings/backends/s3

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
    -r          The name of the region.
    -s          The name of the subscription.
    -rg         The name of Ressource Group.
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
#Set var with name input
STORAGE_ACCOUNT_NAME=${NAME}staccount
CONTAINER_NAME=tfstate${STORAGE_ACCOUNT_NAME}

res=$(az config set extension.use_dynamic_install=yes_without_prompt)
user=$(az ad signed-in-user show --query userPrincipalName --output tsv)
subid=$(az account subscription list --query [].subscriptionId)
#Create RG
#res=$(az group create --name $RESOURCE_GROUP_NAME --location $REGION)

echo "Creating ressource group : ${RESOURCE_GROUP_NAME}"
# Create Storage Account
res=$(az storage account create --resource-group $RESOURCE_GROUP_NAME --name $STORAGE_ACCOUNT_NAME --sku Standard_LRS --encryption-services blob --allow-blob-public-acces)

echo "Creating Storage Account : ${RESOURCE_GROUP_NAME}"
# Create Storage Account Container
res=$(az storage container create --name $CONTAINER_NAME --account-name $STORAGE_ACCOUNT_NAME --auth-mode login)

echo "storage_account_name: $STORAGE_ACCOUNT_NAME"
echo "container_name: $CONTAINER_NAME"

echo $USER
echo
echo az role assignment create --assignee $user --role "Storage Blob Data Owner" --scope "/subscriptions/$SUBSCRIPTION/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME/blobServices/default/containers/$CONTAINER_NAME"

user=$(az role assignment create --assignee $user --role "Storage Blob Data Owner" --scope "/subscriptions/${SUBSCRIPTION}/resourceGroups/$RESOURCE_GROUP_NAME/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT_NAME" )
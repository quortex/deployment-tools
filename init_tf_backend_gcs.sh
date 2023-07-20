#!/bin/bash
#
# The purpose of this script is to provision the resources needed to store
# terraform states on GCS. It will provision a bucket on Google gcs. This backend
# supports state locking by default.
#
# Official documentation about terraform state in gcs =>
# https://www.terraform.io/language/settings/backends/gcs

REGION=eu
NAME=
PROJECT=quortex-199114
PUBLIC_ACCESS=off
INTERACTIVE=true

function help() {
    cat <<EOF
Provision the resources needed to store terraform states on GCS.
It will provision a bucket on Google gcs. This backend
supports state locking by default.
Usage : $0 -n NAME [options]

Mandatory arguments :
    -n NAME      Set the name of created resources.
Available options :
    -r REGION                   Specify the region in which to create the resources (default $REGION).
    -p PROJECT                  Specify the project name (default $PROJECT)
    -b PUBLIC_ACCESS            Whether to block public access for gcs bucket (default $PUBLIC_ACCESS)
    -y                          Execute script in non interactive mode.
    -h                          Display this help.
EOF
}

while getopts "n:r:p:b:yh" opt; do
    case "$opt" in
    h)
        help
        exit 0
        ;;
    n)
        NAME=$OPTARG
        ;;
    r)
        REGION=$OPTARG
        ;;
    p)
        PROJECT=$OPTARG
        ;;
    b)
        PUBLIC_ACCESS=$OPTARG
        ;;
    y)
        INTERACTIVE=false
        ;;
    esac
done

if [ "$NAME" == "" ]; then
    echo "Name was not specified, aborting !"
    exit 1
fi

bucket_name="$PROJECT-tfstate-$NAME"

if [ "$INTERACTIVE" == true ]; then
    echo "This will create a gcs bucket on $PROJECT project named $bucket_name"
    echo "In region $REGION"
    echo ""
    read -p "Continue (y/n)?" CONT
    if [ "$CONT" != "y" ]; then
        echo "Aborting !";
        exit 0
    fi
fi

# create GCS bucket

echo "Creating bucket : ${bucket_name}"
gsutil mb -p $PROJECT -l $REGION -b $PUBLIC_ACCESS gs://$bucket_name


# add self as admin
my_user=$(gcloud config get account)
gsutil iam ch user:${my_user}:admin gs://$bucket_name

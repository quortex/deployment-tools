#!/bin/bash
#
# The purpose of this script is to provision the resources needed to store
# terraform states on AWS. It will provision a bucket on Amazon S3 as well as a
# Dynamo DB table to support state locking and consistency checking.
#
# Official documentation about terraform state in S3 =>
# https://www.terraform.io/language/settings/backends/s3

REGION=eu-west-1
NAME=
PREFIXED=true
BLOCK_PUBLIC_ACCESS=true
INTERACTIVE=true

function help() {
    cat <<EOF
Provision the resources needed to store terraform states on AWS.
A bucket on Amazon S3 will be created, as well as a Dynamo DB table to support
state locking and consistency checking.
Usage : $0 -n NAME [options]

Mandatory arguments :
    -n NAME      Set the name of created resources.
Available options :
    -r REGION                   Specify the region in which to create the resources (default $REGION).
    -p PREFIXED                 Whether to prefix the name with "<ACCOUNT ID>-tfstate-" (default $PREFIXED)
    -b BLOCK_PUBLIC_ACCESS      Whether to block public access for s3 bucket (default $BLOCK_PUBLIC_ACCESS)
    -y                          Execute script in non interactive mode.
    -h                          Display this help.
EOF
}

while getopts "n:r:p:yh" opt; do
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
        PREFIXED=$OPTARG
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

if [ "$PREFIXED" == true ]; then
    NAME=$(aws sts get-caller-identity --query "Account" --output text)-tfstate-$NAME
fi

if [ "$INTERACTIVE" == true ]; then
    echo "This will create an s3 bucket and a dynamodb table named $NAME"
    echo "In region $REGION"
    echo ""
    read -p "Continue (y/n)?" CONT
    if [ "$CONT" != "y" ]; then
        echo "Aborting !";
        exit 0
    fi
fi

# Management of the creation of the s3 bucket.
#
res=$(aws s3api create-bucket --bucket ${NAME} \
  --region ${REGION} \
  --create-bucket-configuration LocationConstraint=${REGION} \
  --acl private 2>&1)

echo "Creating bucket : ${NAME}"
case $res in
  *"BucketAlreadyOwnedByYou"*)
    echo "Bucket already owned !"
    ;;
  *"BucketAlreadyExists"*)
    echo "Bucket already exists !"
    exit 1
    ;;
  \S)
    echo ${res}
    exit 1
    ;;
esac

# Management of the bucket public access block configuration.
#
if [ "$BLOCK_PUBLIC_ACCESS" == true ]; then
    echo "Creating bucket public access block configuration : ${NAME}"
    aws s3api put-public-access-block --bucket ${NAME} \
    --region ${REGION} \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi


# Management of the creation of the DynamoDB table.
#
echo "Creating DynamoDB table : ${NAME}"
res=$(aws dynamodb create-table --table-name ${NAME} \
  --region ${REGION} \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST 2>&1)

case $res in
  *"ResourceInUseException"*)
    echo "DynamoDB table already owned !"
    ;;
  \S)
    echo ${res}
    exit 1
    ;;
esac

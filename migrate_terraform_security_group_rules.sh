#!/bin/bash

# Bash script for AWS infrastructures declared with Terraform.
# Migrate from inline rules in aws_security_group, to individual aws_security_group_rule resources.
#
#
# Context: in terraform, the egress/ingress rules for a security group can be declared "inline" (inside the terraform "aws_security_group" resource) or as individual "aws_security_group_rule" resources.
# 
# Unfortunately, when Terraform tries to update an existing infrastructure to migrate from "inline" to separate rules, it does not know that the separate rules are the same as the inline rules. Therefore, Terraform will try to create new rules, but there will be a conflict in AWS.
# 
# Instead, this script imports the existing AWS rules declared "inline" in the security groups, into the terraform state as separate "aws_security_group_rule" resources.
#
# Requirements: terraform, jq
#
# Usage:
#   ./import_sg_rules.sh [--dry-run] [TERRAFORM_ARGS ...]


function output_help {
    echo "Migrates from terraform inline security_group rules to individual security_group_rule resources";
    echo "";
    echo "Options:";
    echo "      --dry-run        just show the commands that will be executed";
}


INFO_ONLY=false
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    --dry-run)
    INFO_ONLY=true
    shift
    ;;
    -h|--help)
    output_help
    exit 0
    shift
    ;;
    *)
    TERRAFORM_ARGS+=("$1")
    shift
    ;;
esac
done

# List the individual "aws_security_group_rule" resources (from the terraform plan output)
tf_plan=$(mktemp)
terraform plan -out="${tf_plan}" ${TERRAFORM_ARGS[@]}
planned_rules=`terraform show -json ${tf_plan} | jq -c -r ".planned_values.root_module.child_modules[] | .resources[] | select(.type==\"aws_security_group_rule\")"`

# Read security groups from current Terraform state
terraform show -json \
| jq -c -r ".values.root_module.child_modules[] | .resources[] | select(.type==\"aws_security_group\")" \
| while read -r security_group; 
    do 
        sg_id=`echo $security_group | jq -r '.values.id'`
        echo "security group $(echo $security_group | jq -c '{address: .address, id: .values.id}')"

        # Parse the ingress rules declared inline in the security group
        echo "[ingress rules]"
        ingress_rules=`echo $security_group | jq -c '.values.ingress[] | {cidr_blocks: .cidr_blocks[], from_port: .from_port, to_port: .to_port, protocol: .protocol} | .cidr_blocks=[.cidr_blocks]'`
        echo "$ingress_rules" \
        | while read -r rule
            do 
                if [ -z "$rule" ]
                then 
                echo "no ingress rule. skip"
                break
                fi

                # Find an "aws_security_group_rule" resource (from terraform plan) that matches this rule
                rule_resource_json=$(echo "$planned_rules" | jq -c -r --argjson toto "$rule" "select(.values.security_group_id==\"$sg_id\" and .values.type==\"ingress\") | select(.values|contains(\$toto))")
                if [ -z "$rule_resource_json" ]
                then
                    echo "Could not find a aws_security_group_rule in the planned resources, that matches this inline rule"
                else
                    echo "$rule_resource_json" | jq -r -c '[.address, .values.type, .values.protocol, .values.from_port, .values.to_port, .values.cidr_blocks[0]] | @tsv' \
                    | while read -r r_addr r_type r_prot r_from_port r_to_port r_cidr
                    do
                        if [ "$r_prot" == "-1" ]; then r_prot="all"; fi
                        cmd="terraform import ${TERRAFORM_ARGS[@]} ${r_addr} ${sg_id}_${r_type}_${r_prot}_${r_from_port}_${r_to_port}_${r_cidr}"
                        echo $cmd
                        if [ "$INFO_ONLY" != "true" ]
                        then
                            ${cmd}
                        fi
                    done
                fi
            done 

        # Parse the egress rules declared inline in the security group
        echo "[egress rules]"
        egress_rules=`echo $security_group | jq -c '.values.egress[] | {cidr_blocks: .cidr_blocks[], from_port: .from_port, to_port: .to_port, protocol: .protocol} | .cidr_blocks=[.cidr_blocks]'`
        echo "$egress_rules" \
        | while read -r rule
            do 
                if [ -z "$rule" ]
                then 
                echo "no ingress rule. skip"
                break
                fi

                # Find an "aws_security_group_rule" resource (from terraform plan) that matches this rule
                rule_resource_json=$(echo "$planned_rules" | jq -c -r --argjson toto "$rule" "select(.values.security_group_id==\"$sg_id\" and .values.type==\"egress\") | select(.values|contains(\$toto))")
                if [ -z "$rule_resource_json" ]
                then
                    echo "Could not find an aws_security_group_rule in the planned resources, that matches this inline rule"
                else
                    echo "$rule_resource_json" | jq -r -c '[.address, .values.type, .values.protocol, .values.from_port, .values.to_port, .values.cidr_blocks[0]] | @tsv' \
                    | while read -r r_addr r_type r_prot r_from_port r_to_port r_cidr
                    do
                        if [ "$r_prot" == "-1" ]; then r_prot="all"; fi
                        cmd="terraform import ${TERRAFORM_ARGS[@]} ${r_addr} ${sg_id}_${r_type}_${r_prot}_${r_from_port}_${r_to_port}_${r_cidr}"
                        echo $cmd
                        if [ "$INFO_ONLY" != "true" ]
                        then
                            ${cmd}
                        fi
                    done
                fi                
            done 

        echo ""
    done

if [ "$INFO_ONLY" == "true" ]
then
    echo "Complete (dry-run enabled)"
else
    echo "Complete"
fi

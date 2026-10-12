#!/usr/bin/env bash

# Deletes all midterm resources tagged with Course=CS446whitman


set -euo pipefail

export AWS_DEFAULT_REGION="us-east-1"
export COURSE="CS446whitman"

echo "Deleting resources tagged Course=$COURSE in $AWS_DEFAULT_REGION"

# Terminate the EC2 instance first.
INSTANCE_IDS="$(aws ec2 describe-instances --filters "Name=tag:Course,Values=$COURSE" \
"Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --query 'Reservations[].Instances[].InstanceId' \
--output text)"

# If instance found, delete all with the keypair Course=CS446whitman
if [[ -n "$INSTANCE_IDS" && "$INSTANCE_IDS" != "None" ]]; then
  echo "Terminating instance(s): $INSTANCE_IDS"
  echo "May take a few minutes..."
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS >/dev/null
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
fi

# Delete tagged EC2 SSH key pair
KEY_NAMES="$(aws ec2 describe-key-pairs --filters "Name=tag:Course,Values=$COURSE" \
--query 'KeyPairs[].KeyName' --output text)"

for KEY_NAME in $KEY_NAMES; do
  [[ "$KEY_NAME" == "None" ]] && continue
  echo "Deleting EC2 key pair: $KEY_NAME"
  aws ec2 delete-key-pair --key-name "$KEY_NAME"
done

# Delete the VPC and its components
VPC_IDS="$(aws ec2 describe-vpcs --filters "Name=tag:Course,Values=$COURSE" \
--query 'Vpcs[].VpcId' --output text)"

for VPC_ID in $VPC_IDS; do
  [[ "$VPC_ID" == "None" ]] && continue

  # Delete custom security groups. AWS deletes the default group with the VPC.
  SECURITY_GROUP_IDS="$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)"

  for SECURITY_GROUP_ID in $SECURITY_GROUP_IDS; do
    [[ "$SECURITY_GROUP_ID" == "None" ]] && continue
    echo "Deleting security group: $SECURITY_GROUP_ID"
    aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID"
  done

  # Delete subnets
  SUBNET_IDS="$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].SubnetId' --output text)"

  for SUBNET_ID in $SUBNET_IDS; do
    [[ "$SUBNET_ID" == "None" ]] && continue
    echo "Deleting subnet: $SUBNET_ID"
    aws ec2 delete-subnet --subnet-id "$SUBNET_ID"
  done

  # Detach and delete internet gateways
  INTERNET_GATEWAY_IDS="$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[].InternetGatewayId' --output text)"

  for INTERNET_GATEWAY_ID in $INTERNET_GATEWAY_IDS; do
    [[ "$INTERNET_GATEWAY_ID" == "None" ]] && continue
    echo "Deleting internet gateway: $INTERNET_GATEWAY_ID"
    aws ec2 detach-internet-gateway \
    --internet-gateway-id "$INTERNET_GATEWAY_ID" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway \
    --internet-gateway-id "$INTERNET_GATEWAY_ID"
  done

  # Deleting the VPC also deletes its main route table, default security group,
  # and default network ACL.
  echo "Deleting VPC: $VPC_ID"
  aws ec2 delete-vpc --vpc-id "$VPC_ID"
done

echo "Teardown complete."

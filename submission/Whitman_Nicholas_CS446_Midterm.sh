#!/usr/bin/env bash

# ===============================================================
# CS 446 Midterm — OpenCSUSM
# Name: Nicholas Whitman
# Campus ID: 201361763
# Lane: gpu
# ===============================================================

# Run this script with ./Whitman_Nicholas_CS446_Midterm.sh {1|2|3|4|5|6} to execute the individual stages IN ORDER

# The following is the outline and overall justification for the resources that I am putting together for this midterm:
	# GPU/CPU Decision: In order to comply with the initial suggestion of using vLLM, I have opted to use a GPU based instance. I actually was able to get vLLM to run on a CPU based instance very easily. It turns out that vLLM has an official Docker image which would allow me to avoid having to build from source. However, to stay more aligned with the stages outlined in the midterm PDF, I kept with the GPU based instance. Therefore, anyone running this script needs a 4+ vCPU quota authorization on their account. Plus, with a GPU based instance it will be easier to scale up the LLM to be more capable. If I kept with the CPU, I would not be able to do that due to the rapidly scaling compute required.
	
	# Instance type and AMI: Considering that I needed to keep overall power (and thus cost) low, I opted to use a g6f.xlarge instance type. This instance type provides me with 4 vCPUs, 16Gb of memory, and 100 Gb of root device storage. More importantly, I have fractional NVIDIA L4 GPU access, which gives me about 2.79 Gb of GPU memory at my disposal. This is not a lot, but for a very small model it is just enough. The combination of adequate memory, but limited GPU access kept costs low; About 0.237 USD/hr for On-Demand Linux. At this rate I expect to get over 420 hours of uptime with a $100 dollar budget. For my AMI, I needed something that was guaranteed to have the necessary drivers and GPU support. Per the AWS documentation, a Deep Learning AMI (DLAMI) has pre-installed GPU software and is great for "trying out new frameworks, testing new models, or training new models." While this may be excessive for hosting a tiny llm, I do not have to worry about compatibility issues if I want to scale this upwards. More importantly, this AMI supports the g6f.xlarge instance type.
	
	# Model: Per the instructions, I wanted to keep the model well under 1B parameters. On the hugging face website I found what seems to be a very popular public model series called Qwen3, which in my case only has 0.6B parameters. In total, the model was about 1.5 Gb in size, making it relatively fast to download to the EC2 instance. The small size/time requirement also made test and troubleshooting deployments very quick. In my test runs of this script I barely had to wait more than a minute or two for vLLM to acquire and serve the model.
	
	# Resource Setup: To maintain a clear separation of resources from default/preexisting ones, all of the necessary resources for an EC2 deployment and remote access are created. These include: A VPC, Subnet, Routing Table, Security group (with ingress rule), Internet Gateway, Access Key Pair, and of course the EC2 instance itself.
	
	# NOTICE: All resources created by this script are tagged with the key-value pair Course=CS446whitman to make teardown easier. 
	# NOTICE: This script will also produce a state file (to save environment variables between stages) and a sshMidtermTemp.pem key file within the directory that you are running it in. Running the script a second time requires you to delete the old key first.
	# The provided midterm_teardown.sh script will delete all resources tagged with Course=CS446whitman (everything created in THIS script)
	 

set -euo pipefail

# Create the state file to save all important environment variables
STATE_FILE="./opencsusm.state"

# Set the environment variables
export REGION="us-east-1"
export ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
export MODEL="Qwen/Qwen3-0.6B"
export INSTANCE="g6f.xlarge" # On-demand linux pricing is about 0.2375 USD per hour
export PORT="8000"
export COURSE="CS446whitman"
export AZ="us-east-1a"
export MYIP="$(curl https://checkip.amazonaws.com)"
export MYIPCIDR="$MYIP/32"
export KEYNAME="sshMidtermTemp"
export KEYPEMFILE="$KEYNAME.pem"

echo "Account:  $ACCOUNT"
echo "Region:   $REGION"
echo "Model:    $MODEL"
echo "Instance: $INSTANCE"

# Part 1: Show the account quota for what will follow. The user requires a 4+ vCPU quota
one()
{
    # Since we are running a GPU instance, we need to make sure that our G and VT vCPU quota is raised. For the g6f.xlarge instance type,
    # we need a quota of 4+ vCPUs
	echo "Part 1: Showing the account quota for what will follow"
	echo "Account needs at least a 4 vCPU quota to complete this script."
	aws service-quotas get-service-quota --region us-east-1 --service-code ec2 \
	--quota-code L-DB2E81BA --query '{quota:Quota.QuotaName,value:Quota.Value}' --output table

	# Since we are breaking this script into separately executable parts, we must save the environment variables into the STATE_FILE
	cat >"$STATE_FILE" <<EOF
	REGION="$REGION"
	ACCOUNT="$ACCOUNT"
	MODEL="$MODEL"
	INSTANCE="$INSTANCE"
	PORT="$PORT"
	COURSE="$COURSE"
	AZ="$AZ"
	MYIP="$MYIP"
	MYIPCIDR="$MYIPCIDR"
	KEYNAME="$KEYNAME"
	KEYPEMFILE="$KEYPEMFILE"
EOF

	echo "End Part 1: Continue with ./opencsusm.sh 2"
}

# Part 2 - Startup: Creates the VPC, Subnet, Security Group, Gateway, and SSH ingress rules. Fetches routing table and creates link to IG. 
# Then, it creates the EC2 instance using a temp key-pair.
two()
{
	#Fetch environment variables
	source "$STATE_FILE"

	# First, fetch the AMI ID 
	# I am choosing to use the AWS Deep Learning Base AMI with Single CUDA. Its documentation page says that the deep learning AMIs
	# (while mostly for training) are prefectly suitable for testing models quickly. It comes with the necessary drivers and other GPU resources/dependencies that
	# I figure are necessary to get vLLM up and running without issue.
	AMI="$(aws ssm get-parameter --name /aws/service/deeplearning/ami/x86_64/base-with-single-cuda-amazon-linux-2023/latest/ami-id \
	--query Parameter.Value --output text)"

	# Next, I will create a VPC with CIDR 10.10.0.0/16.
	VPC="$(aws ec2 create-vpc --cidr-block 10.10.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Course,Value=$COURSE}]" \
	--query Vpc.VpcId --output text)"
	# Before continuing, I am making sure that the VPC creation goes through, hence the wait command.
	aws ec2 wait vpc-available --vpc-ids "$VPC"

	# Create 1 subnet with CIDR 10.10.1.0/24 on the VPC we just made. For now it will be in the us-east-1a availability zone
	SUBNET="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.10.1.0/24 --availability-zone "$AZ" \
	--tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=midterm-subnet},{Key=Course,Value=$COURSE}]" \
	--query Subnet.SubnetId --output text)"

	# Here we fetch the ID of the default routing table that was created when we created the VPC. We will add a route to the IG with this.
	ROUTE_TABLE="$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" Name=association.main,Values=true \
	--query 'RouteTables[0].RouteTableId' --output text)"
	# Tag the route table to make teardown easier
	aws ec2 create-tags --resources "$ROUTE_TABLE" --tags "Key=Course,Value=$COURSE"

	# Create a new security group with NO inbound rules. We will set SSH ingress rules in a bit.
	SECURITY_GROUP="$(aws ec2 create-security-group --group-name midterm-securitygroup --vpc-id "$VPC" --description "CS446 Midterm" \
	--tag-specifications "ResourceType=security-group,Tags=[{Key=Course,Value=$COURSE}]" --query 'GroupId' --output text)" 

	# Create and attach an Internet Gateway to our vpc such that we can access it over SSH
	INTERNET_GATEWAY="$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Course,Value=$COURSE}]" \
	--query InternetGateway.InternetGatewayId --output text)"
	# Attaches the gateway to our VPC
	aws ec2 attach-internet-gateway --internet-gateway-id "$INTERNET_GATEWAY" --vpc-id "$VPC"

	# Create an internet-facing route with our Gateway (destination 0.0.0.0)
	aws ec2 create-route --route-table-id "$ROUTE_TABLE" --destination-cidr-block 0.0.0.0/0 --gateway-id "$INTERNET_GATEWAY"

	# Establish the ingress rules for our instance: Only SSH from OUR IP address.
	aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP" --protocol tcp --port 22 --cidr "$MYIPCIDR"

	# Create the temporary key-pair for the upcoming EC2 instance so we can actually ssh into it.
	aws ec2 create-key-pair --key-name "$KEYNAME" --key-type ed25519 --tag-specifications "ResourceType=key-pair,Tags=[{Key=Course,Value=$COURSE}]" \
	--query KeyMaterial --output text >"$KEYPEMFILE"
	
	# Apply the necessary permissions to the pem file for our ssh command
	chmod 400 "$KEYPEMFILE"

	# Start up the EC2 instance using our key-pair and AMI/VPC details. Mark storage as delete-on-terminate
	INSTANCE_ID="$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE" --count 1 --subnet-id "$SUBNET" --security-group-ids "$SECURITY_GROUP" \
	--associate-public-ip-address --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=100,VolumeType=gp3,DeleteOnTermination=true}" \
	--tag-specifications "ResourceType=instance,Tags=[{Key=Course,Value=$COURSE}]" \
	--key-name "$KEYNAME" --query 'Instances[0].InstanceId' --output text)"

	#Now we wait for everything to Start
	echo "Instance ID: $INSTANCE_ID"
	echo "Instance is starting..."
	aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
	
	#Fetch the public IPv4 address of the instance so we can actually connect to it.
	IPADDR="$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

	echo "Public IP: $IPADDR"
	echo "Port: $PORT"
	
	echo "The instance is now created. You can use the following command to connect." 
	echo "Use ./opencsusm.sh 3 to automate the vLLM installation"
	
	cat <<EOF
	ssh -i "$KEYPEMFILE" -N -L "$PORT:127.0.0.1:$PORT" ec2-user@"$IPADDR"
EOF
	
	# Save new info to state file
	cat >>"$STATE_FILE" <<EOF
	INSTANCE_ID="$INSTANCE_ID"
	IPADDR="$IPADDR"
EOF
}

# Part three creates an SSH tunnel and installs vLLM on the EC2 instance
three()
{
	# Reload environment variables
	source "$STATE_FILE"
	echo "Part 3: Connecting to the EC2 instance to install vLLM"
	
	# Wait for the instance to be ready
	echo "Waiting for the EC2 instance to initialize..."
	aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

	echo "Installing vLLM..."
	# Connect and install vllm: Do not retain downloads - in order to save space
	ssh -i "$KEYPEMFILE" -L "$PORT:127.0.0.1:$PORT" ec2-user@"$IPADDR" 'set -e; sudo /usr/bin/python3.12 -m pip install \
	--no-cache-dir vllm; /usr/local/bin/vllm --version'

	echo "vLLM installed." 
	echo "Run ./opencsusm.sh 4 to install and serve the Qwen3 LLM"
}

# Part 4 will download and serve the Qwen model on vLLM
four()
{
	# Reload environment variables
	source "$STATE_FILE"
	echo "Part 4: Installing and serving the Qwen3 0.6B model..."

	# Connect to the intance. Because the g6f.xlarge instance type has fractional access to GPU power, and only about 2.79 Gb of GPU memory, we need
	# to limit memory utilization to 70% and the max model length to 1024 to ensure that everything will download and initiate properly.
	# Nohup allows the process to keep running after this script ends
	ssh -i "$KEYPEMFILE" ec2-user@"$IPADDR" "nohup /usr/local/bin/vllm serve \"$MODEL\" --host 127.0.0.1 \
	--port \"$PORT\" --gpu-memory-utilization 0.70 --max-model-len 1024 --max-num-seqs 1 --enforce-eager >/dev/null 2>&1 < /dev/null &"
	
	echo "The LLM installation has been initiated."
	echo "Allow 1-2 minutes for Qwen3 installation, then:"
	echo "Use ./opencsusm.sh 5 to display the tunnel command"
}

# Print out the ssh command to use in a second terminal
five()
{
	source "$STATE_FILE"
	echo "Use the following command in a second terminal to establish a secure connection."
	echo "Make sure to leave the second terminal running."

	cat <<EOF
	ssh -i "$KEYPEMFILE" -N -L "$PORT:127.0.0.1:$PORT" ec2-user@"$IPADDR"
EOF

	echo "Now use ./opencsusm.sh 6 to show the command to talk with the llm."
}

six()
{
	source "$STATE_FILE"
	echo "In this terminal, use the following curl command to talk to the LLM; Replace the \"content\" field with your message"
	echo "The reply will also be in JSON format. Look for the content field for it."
	cat <<EOF
	curl -sS localhost:"$PORT"/v1/chat/completions -H 'Content-Type: application/json' -d '{"model": "Qwen/Qwen3-0.6B", "messages": [{"role": "user", "content": "I am John."}], "chat_template_kwargs": {"enable_thinking": false}, "max_tokens": 20, "temperature": 0}'
EOF
}

# Case selector
case "${1:-}" in
    1)
        one
        ;;
    2)
        two
        ;;
    3)
        three
        ;;
    4)
        four
        ;;
	5)
        five
        ;;
	6)
        six
        ;;
    *)
        echo "Usage: bash opencsusm.sh {1|2|3|4|5|6} IN ORDER"
        exit 1
        ;;
esac

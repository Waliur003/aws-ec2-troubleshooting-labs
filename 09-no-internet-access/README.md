# Lab 09 — Amazon EC2 No Internet Access

## Overview

This hands-on lab demonstrates how to troubleshoot an Amazon EC2 instance that cannot communicate with the public internet because of a missing default route in its VPC route table.

The simulated production incident involves an Amazon Linux 2023 EC2 instance launched into a dedicated subnet. Initially, the instance has working internet connectivity. We then deliberately remove the subnet's route to the internet gateway, investigate the resulting connection failures, and restore connectivity.

The lab uses a dedicated subnet and route table inside an existing default VPC to avoid disrupting other AWS resources.

**Troubleshooting workflow:**

Working Baseline → Introduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-009 |
| AWS Services | Amazon EC2, VPC |
| Components | Subnet, Route Table, Internet Gateway, Security Group |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, SSH, Bash, curl |
| Problem | EC2 cannot access public internet |
| Root Cause | Missing `0.0.0.0/0` route |
| Remediation | Restore route to internet gateway |
| Verification | Successful outbound HTTPS and SSH |

---

## 1. Production Incident Scenario

### Incident Description

A company hosts a Linux application on Amazon EC2.

The instance needs outbound internet connectivity for software updates and external API requests.

During a network configuration change, the subnet's default route to the internet gateway is accidentally removed.

The instance remains in the `running` state, but outbound communication with public internet endpoints fails.

### Expected Behavior

The instance should be able to reach external HTTPS services.

```bash
curl -I https://example.com
```

Expected response:

```text
HTTP/2 200
```

The actual HTTP version may vary.

### Actual Behavior

The instance cannot establish outbound HTTPS connections.

A typical symptom is:

```text
curl: (28) Connection timed out
```

Public SSH connectivity can also fail because the instance no longer has a route for responses to internet-based clients.

### Potential Business Impact

- Failed software updates
- External API connectivity failures
- Interrupted application integrations
- Failed dependency downloads
- Deployment failures
- Loss of administrative SSH access
- Application service degradation

### Investigation Objective

Identify whether the connectivity problem is caused by routing, security groups, network ACLs, DNS resolution, the internet gateway, or operating-system configuration.

---

## 2. Network Architecture

### Working Architecture

```text
                  Internet
                     |
                     |
              Internet Gateway
                     |
                     |
              Default VPC
                     |
                     |
            Lab 09 Route Table
          0.0.0.0/0 → Internet Gateway
                     |
                     |
             Lab 09 Subnet
                     |
                     |
                Amazon EC2
              Amazon Linux 2023
                     |
                     |
              Outbound HTTPS
                     |
                     v
                 HTTP 200
```

### Broken Architecture

```text
                  Internet
                     |
                     |
              Internet Gateway
                     |
                     X
              Missing Route
                     |
                     |
            Lab 09 Route Table
               Local Route Only
                     |
                     |
             Lab 09 Subnet
                     |
                     |
                Amazon EC2
                     |
                     |
          Outbound HTTPS Request
                     |
                     X
              Connection Fails
```

### Corrected Architecture

```text
             Amazon EC2
                  |
                  v
            Lab 09 Subnet
                  |
                  v
         Dedicated Route Table
                  |
          0.0.0.0/0 → IGW
                  |
                  v
           Internet Gateway
                  |
                  v
               Internet
                  |
                  v
           External HTTPS
                  |
                  v
             HTTP 200 OK
```

---

## 3. Understanding AWS VPC Networking

### Virtual Private Cloud

Amazon VPC provides a logically isolated network for AWS resources.

It contains networking components such as subnets, route tables, gateways, and security groups.

### Subnet

A subnet is a range of IP addresses within a VPC.

EC2 instances are launched into subnets.

A subnet with a route to an internet gateway is commonly called a public subnet.

An individual EC2 instance also needs a public IPv4 address, or another suitable arrangement, for direct IPv4 internet communication through that gateway.

### Internet Gateway

An internet gateway allows communication between the VPC and the public internet when routing and other required network configuration are correct.

### Route Table

A route table determines where network traffic is directed.

Example:

| Destination | Target | Purpose |
|---|---|---|
| VPC CIDR | local | Communication inside VPC |
| `0.0.0.0/0` | Internet Gateway | Public IPv4 internet routing |

### Default Route

```text
0.0.0.0/0
```

This destination matches IPv4 addresses not covered by a more specific route.

For a public subnet, its default IPv4 route typically points to the attached internet gateway.

### Security Group

A security group controls permitted traffic for associated network interfaces.

Security groups are stateful and contain allow rules.

### Network ACL

A network ACL controls traffic at the subnet boundary.

Unlike security groups, network ACLs are stateless and support both allow and deny rules.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- Python 3
- SSH client
- curl
- EC2 and VPC management permissions
- Git and GitHub

### Security Considerations

- Use a dedicated disposable subnet.
- Use a dedicated route table.
- Never modify the default VPC's main route table for this exercise.
- Restrict SSH to a trusted public IP address.
- Store SSH private keys outside GitHub.
- Verify resource ownership before deleting anything.
- Preserve the default VPC and its existing internet gateway.

### Cost Considerations

The exercise can incur charges for EC2 usage, EBS storage, public IPv4 addresses, and data transfer.

---

## 5. Prepare AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export INSTANCE_NAME="cloud-lab09-network-instance"
export SUBNET_NAME="cloud-lab09-public-subnet"
export RT_NAME="cloud-lab09-route-table"
export SG_NAME="cloud-lab09-network-sg"
export KEY_NAME="cloud-lab09-network-key"

export PROJECT_TAG="EC2-Troubleshooting-Lab09"
```

### Step 2 — Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Step 3 — Identify Default VPC

```bash
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

Stop if no default VPC exists.

### Step 4 — Identify Internet Gateway

```bash
export IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query 'InternetGateways[0].InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

echo "$IGW_ID"
```

Expected:

```text
igw-xxxxxxxxxxxxxxxxx
```

We reuse the existing internet gateway instead of creating or modifying one.

### Step 5 — Find a Supported Availability Zone

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Select a compatible Availability Zone:

```bash
export LAB_AZ="REPLACE_WITH_SUPPORTED_AZ"
```

### Step 6 — Find a Non-Overlapping CIDR

Inspect the VPC's CIDR blocks:

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].CidrBlockAssociationSet' \
  --output json \
  --region "$AWS_REGION"
```

Inspect existing subnet CIDRs:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"
```

Choose an available CIDR inside the VPC that does not overlap any existing subnet.

A `/28` subnet is sufficient for this isolated exercise.

```bash
export LAB_CIDR="REPLACE_WITH_UNUSED_VPC_CIDR"
```

---

## 6. Create Dedicated Subnet

### Step 1 — Check Existing Lab Resources

```bash
aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=$SUBNET_NAME" \
  --query 'Subnets[].SubnetId' \
  --output text \
  --region "$AWS_REGION"
```

Do not create a duplicate.

### Step 2 — Create Subnet

```bash
export SUBNET_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --availability-zone "$LAB_AZ" \
  --cidr-block "$LAB_CIDR" \
  --tag-specifications \
    "ResourceType=subnet,Tags=[{Key=Name,Value=$SUBNET_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected subnet state: `available`.

---

## 7. Create Dedicated Route Table

### Step 1 — Check Existing Route Tables

```bash
aws ec2 describe-route-tables \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=tag:Name,Values=$RT_NAME" \
  --query 'RouteTables[].RouteTableId' \
  --output text \
  --region "$AWS_REGION"
```

### Step 2 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=route-table,Tags=[{Key=Name,Value=$RT_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Add Internet Gateway Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected routes:

```text
VPC_CIDR      local
0.0.0.0/0     igw-xxxxxxxx
```

### Step 5 — Associate Route Table with Subnet

```bash
export RT_ASSOC_ID=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Verify Association

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

The association must reference the dedicated Lab 09 subnet.

---

## 8. Create SSH Credentials

### Step 1 — Create SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 2 — Configure Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab09-network-key.pem"
```

Verify the file does not already exist:

```bash
test ! -e "$KEY_FILE" || echo "Local key already exists"
```

Check the AWS key pair:

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new lab, `InvalidKeyPair.NotFound` is expected.

### Step 3 — Create Key Pair

Only when the AWS name and local file path are unused:

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$KEY_FILE"

chmod 400 "$KEY_FILE"
```

Never commit the private key.

---

## 9. Create Security Group

### Step 1 — Retrieve Client Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')

echo "$MY_IP"
```

### Step 2 — Check Existing Security Group

```bash
aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

### Step 3 — Create Dedicated Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "EC2 Lab09 internet connectivity troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow SSH

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Outbound Permissions

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json \
  --region "$AWS_REGION"
```

The default outbound allow rule is normally present on newly created security groups.

This ensures that outbound HTTPS is not intentionally blocked by security group configuration.

---

## 10. Launch EC2 Instance

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for Existing Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate instance.

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for Readiness

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Retrieve Public IPv4

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "$PUBLIC_IP"
```

### Step 6 — Connect Over SSH

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

For real production access, verify the host-key fingerprint through a trusted method before accepting it.

---

## 11. Establish Working Internet Connectivity

The following commands run inside the EC2 instance.

### Check 1 — Linux Routing Table

```bash
ip route
```

Expected:

```text
default via VPC_GATEWAY_IP dev PRIMARY_INTERFACE
```

This is the guest operating system's routing table, not the AWS VPC route table.

### Check 2 — Verify DNS

```bash
getent ahostsv4 example.com
```

Expected: one or more resolved IPv4 addresses.

### Check 3 — Test Outbound HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTP response.

### Check 4 — Verify Status Code

```bash
curl -4 -sS \
  -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  --max-time 15 \
  https://example.com
```

Expected, if the endpoint is healthy:

```text
HTTP Status: 200
```

### Baseline Findings

| Check | Expected Finding |
|---|---|
| EC2 | Running |
| Status checks | OK |
| Public IPv4 | Assigned |
| Security group | SSH and outbound traffic permitted |
| Subnet route | Internet gateway route present |
| DNS | Working |
| Outbound HTTPS | Successful |

---

## 12. Configure Connectivity Logging

A periodic connectivity check helps capture the failure and recovery.

### Step 1 — Create Directory

Inside EC2:

```bash
sudo mkdir -p /opt/ec2-lab09
```

### Step 2 — Create Test Script

```bash
sudo tee /opt/ec2-lab09/connectivity-check.sh > /dev/null <<'EOF'
#!/bin/bash

for attempt in $(seq 1 36); do
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if curl -4 -fsS \
        --connect-timeout 3 \
        --max-time 5 \
        -o /dev/null \
        https://example.com; then

        echo "$timestamp HTTPS SUCCESS"
    else
        echo "$timestamp HTTPS FAILURE"
    fi

    sleep 10
done
EOF
```

### Step 3 — Set Permissions

```bash
sudo chmod 755 /opt/ec2-lab09/connectivity-check.sh
```

### Step 4 — Start Background Monitoring

```bash
sudo systemd-run \
  --unit=lab09-connectivity \
  --collect \
  /opt/ec2-lab09/connectivity-check.sh
```

### Step 5 — Verify Service

```bash
sudo systemctl status lab09-connectivity.service --no-pager
```

The script records HTTPS connectivity for approximately six minutes.

Exit EC2:

```bash
exit
```

---

## 13. Introduce the Routing Failure

**Warning:** These commands intentionally disconnect Lab 09 from the public internet. Modify only the dedicated route table.

### Step 1 — Verify Route Table Ownership

From WSL2:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].{Routes:Routes,Associations:Associations,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

- The route table has the Lab 09 project tag.
- It is associated with the dedicated Lab 09 subnet.
- It is not the VPC main route table.
- Its default route points to the internet gateway.

### Step 2 — Remove the Default Route

```bash
aws ec2 delete-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 3 — Verify Removal

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the VPC local route remains, while `0.0.0.0/0` is absent.

### Step 4 — Test SSH

```bash
ssh \
  -o ConnectTimeout=5 \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP" \
  hostname
```

Expected: timeout or connection failure.

### Observation

The instance is still running, but its subnet cannot route internet-bound IPv4 traffic through the gateway.

Outbound HTTPS and inbound public SSH are affected.

---

## 14. Troubleshooting Investigation

### Check 1 — Inspect EC2 Configuration

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,Subnet:SubnetId,SecurityGroups:SecurityGroups}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 2 — Inspect Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 3 — Verify Subnet Association

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

### Check 4 — Inspect Route Table

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output json \
  --region "$AWS_REGION"
```

### Check 5 — Inspect Internet Gateway

```bash
aws ec2 describe-internet-gateways \
  --internet-gateway-ids "$IGW_ID" \
  --query 'InternetGateways[0].Attachments' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the internet gateway remains attached to the intended VPC.

### Investigation Findings

| Check | Finding |
|---|---|
| EC2 state | Running |
| Public IPv4 | Assigned |
| Security group | Unchanged |
| Internet gateway | Attached |
| Subnet association | Dedicated route table |
| VPC local route | Present |
| Internet gateway default route | Missing |
| SSH | Unreachable |
| Outbound HTTPS | Unavailable |
| Root cause | Incorrect VPC routing |

---

## 15. Root Cause Analysis

### Root Cause

The dedicated subnet's route table no longer contains the required default route:

```text
0.0.0.0/0 → Internet Gateway
```

### Technical Explanation

An EC2 instance may have a public IPv4 address and permissive security group rules but still lack internet access.

The subnet's effective route table must direct internet-bound IPv4 traffic to the appropriate gateway.

When the default route is missing, traffic destined for external networks has no matching internet route.

### Root Cause Flow

```text
EC2 Application Sends HTTPS Request
                |
                v
         Linux Default Route
                |
                v
          VPC Route Table
                |
                v
     No Internet Gateway Route
                |
                v
        Traffic Cannot Proceed
                |
                v
       Internet Request Fails
```

### Five Whys

1. **Why couldn't the instance access the internet?** External traffic could not be routed.
2. **Why couldn't it be routed?** The subnet route table lacked a default internet route.
3. **Why was the route missing?** The route was deliberately removed during the simulation.
4. **Why did the instance remain running?** EC2 power state is separate from public internet connectivity.
5. **How can this be prevented?** Manage route tables through reviewed infrastructure-as-code changes and validate connectivity after network updates.

---

## 16. Apply Remediation

### Step 1 — Restore Internet Gateway Route

From WSL2:

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify the Route

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
VPC_CIDR         local
0.0.0.0/0        igw-xxxxxxxx
```

### Step 3 — Confirm Association

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

The dedicated Lab 09 subnet should remain associated.

---

## 17. Verify Recovery

### Test 1 — Reconnect Through SSH

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Expected: successful connection.

### Test 2 — Verify Outbound HTTPS

Inside EC2:

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: successful HTTP response.

### Test 3 — Verify Status Code

```bash
curl -4 -sS \
  -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  --max-time 15 \
  https://example.com
```

Expected: HTTP 200 when the target endpoint is healthy.

### Test 4 — Inspect Connectivity Logs

```bash
sudo journalctl \
  -u lab09-connectivity.service \
  --no-pager
```

Illustrative sequence:

```text
HTTPS SUCCESS
HTTPS SUCCESS
HTTPS FAILURE
HTTPS FAILURE
HTTPS SUCCESS
```

The actual log depends on when the test service ran relative to route removal and restoration.

### Test 5 — Verify DNS

```bash
getent ahostsv4 example.com
```

### Test 6 — Inspect Linux Routes

```bash
ip route
```

The guest operating system's default route may have remained unchanged throughout the outage.

This demonstrates that Linux routing and VPC routing are separate configuration layers.

Exit:

```bash
exit
```

### Test 7 — Verify EC2 Health

From WSL2:

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both status checks return `ok`.

### Before and After Comparison

| Component | Before Remediation | After Remediation |
|---|---|---|
| EC2 state | Running | Running |
| Public IPv4 | Assigned | Assigned |
| Internet gateway | Attached | Attached |
| Security group | Correct | Correct |
| Default internet route | Missing | Restored |
| SSH | Failed | Successful |
| Outbound HTTPS | Failed | Successful |
| DNS resolution | May still work | Works |
| Root cause | Missing route | Corrected |

---

## 18. Production Engineering Considerations

### Common Causes of EC2 Internet Connectivity Failure

- Missing default route
- Wrong route table association
- Internet gateway not attached
- Missing public IPv4 address
- Security group outbound restrictions
- Network ACL restrictions
- Incorrect Linux networking configuration
- DNS resolution failure
- NAT gateway misconfiguration for private subnets
- VPC endpoint or network appliance routing problems

### Public vs Private Subnets

| Public Subnet | Private Subnet |
|---|---|
| Default route commonly points to IGW | No direct IGW route for ordinary instance IPv4 egress |
| Instance can use public IPv4 | Instance commonly uses private IPv4 |
| Direct internet access possible | Outbound IPv4 internet access commonly uses NAT |
| Public-facing workloads possible | Internal workloads commonly deployed here |

An internet gateway route alone does not automatically make every instance publicly accessible. Public addressing and appropriate firewall configuration are also necessary.

### Troubleshooting Sequence

1. Verify EC2 state.
2. Inspect instance public and private IP addresses.
3. Identify the instance's subnet.
4. Determine the subnet's effective route table.
5. Check for the appropriate default route.
6. Verify gateway attachment.
7. Review security group outbound rules.
8. Inspect network ACLs.
9. Check Linux routing.
10. Verify DNS resolution.
11. Test HTTPS connectivity.
12. Confirm application recovery.

### Production Best Practices

- Use dedicated route tables when appropriate.
- Avoid changing shared network routes during experiments.
- Manage VPC networking with Terraform or CloudFormation.
- Review infrastructure changes before deployment.
- Monitor network configuration changes with AWS CloudTrail.
- Validate connectivity after route modifications.
- Use VPC Flow Logs when packet-level flow evidence is needed.
- Consider VPC Reachability Analyzer for supported network-path analysis.
- Maintain documented rollback procedures.

---

## 19. Related Connectivity Errors

| Symptom | Possible Cause |
|---|---|
| HTTPS timeout | Missing route, NACL, firewall, or connectivity issue |
| SSH timeout | Inbound/outbound path issue |
| DNS lookup failure | Resolver or DNS configuration |
| Connection refused | Destination is reachable but service is not accepting connections |
| HTTP 403 | Application authorization or access policy |
| Public IP but no internet | Missing route or other network configuration |
| Private EC2 no internet | Missing NAT or private egress path |
| EC2 healthy but API calls fail | Application, routing, DNS, or firewall |

---

## 20. Interview Questions and Answers

### Q1. Why might an EC2 instance have a public IP but no internet access?

Its subnet may lack an internet gateway default route, or another network control may block the traffic.

### Q2. What does `0.0.0.0/0` mean?

It represents all IPv4 destinations and is commonly used as the default route.

### Q3. What does an internet gateway do?

It provides an internet communication path for a VPC when routing and addressing are configured appropriately.

### Q4. What makes a subnet public?

A subnet is public when its route table includes a route to an internet gateway.

### Q5. Does a security group allow rule guarantee connectivity?

No. Routing, addressing, network ACLs, and operating-system configuration must also be correct.

### Q6. Why did SSH stop working after the default route was deleted?

The instance no longer had an internet gateway route needed for communication with the external SSH client.

### Q7. Can DNS work while internet connectivity is broken?

Yes. A VPC resolver may continue answering DNS queries even if the subnet cannot reach external IP addresses.

### Q8. What's the difference between a NAT gateway and an internet gateway?

An internet gateway enables internet connectivity for appropriately configured VPC resources. A NAT gateway commonly provides outbound IPv4 internet connectivity for instances in private subnets without exposing them to unsolicited inbound connections.

### Q9. How do you inspect VPC route tables using AWS CLI?

```bash
aws ec2 describe-route-tables
```

### Q10. How do you restore a missing internet gateway route?

```bash
aws ec2 create-route \
  --route-table-id ROUTE_TABLE_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id INTERNET_GATEWAY_ID
```

### Q11. Why was a dedicated route table used?

To isolate the troubleshooting experiment and prevent disruption to unrelated workloads.

### Q12. How would you explain this incident in an interview?

> I investigated an EC2 instance that was running but could not access the internet. I verified the instance's public IP, security group rules, and subnet configuration. Then I inspected its effective VPC route table and discovered that the default route to the internet gateway was missing. I restored the route using AWS CLI and verified that SSH and outbound HTTPS were working again. I used a dedicated subnet and route table to ensure the exercise did not affect other resources.

---

## 21. Cleanup

**Warning:** Verify all AWS resources before deleting them. The default VPC, its main route table, and its internet gateway must be preserved.

### Step 1 — Verify AWS Account

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Instance Tags

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the project tag is `EC2-Troubleshooting-Lab09`.

### Step 3 — Record Root Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify `DeleteOnTermination` is enabled for the root volume.

### Step 4 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Remove Security Group

Check network interface dependencies:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

If none remain:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Disassociate Dedicated Route Table

Confirm the association ID:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Associations' \
  --output json \
  --region "$AWS_REGION"
```

Disassociate the lab subnet:

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete Dedicated Route Table

Verify it is the tagged Lab 09 table and has no remaining explicit associations.

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Dedicated Subnet

Inspect remaining network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=subnet-id,Values=$SUBNET_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Once no dependencies remain and ownership is confirmed:

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete AWS SSH Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

Remove the dedicated local key:

```bash
rm -f "$KEY_FILE"
```

### Step 10 — Verify Root EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If the root volume was deleted, AWS reports `InvalidVolume.NotFound`.

If the volume remains in the `available` state, verify that it belongs exclusively to Lab 09 before deleting it.

### Cleanup Summary

| Resource | Action |
|---|---|
| Lab EC2 instance | Terminate |
| Lab root EBS volume | Verify deletion |
| Lab security group | Delete |
| Lab route table | Disassociate and delete |
| Lab subnet | Delete |
| Lab SSH key pair | Delete |
| Local private key | Delete |
| Default VPC | Preserve |
| Default VPC main route table | Preserve |
| Existing internet gateway | Preserve |

---

## 22. Repository Structure

```text
09-no-internet-access/
│
└── README.md
```

The lab is fully reproducible with AWS CLI and Linux commands documented in this README.

Do not commit credentials, SSH private keys, or temporary resource identifiers.

---

## 23. Lessons Learned

This lab demonstrated that an EC2 instance can remain healthy while losing public internet connectivity.

The simulated failure was caused by removing the default route from a dedicated VPC route table.

The investigation included EC2 configuration, subnet associations, security groups, internet gateway attachment, Linux routing, and HTTPS connectivity.

The remediation restored the missing internet gateway route.

The lab also demonstrated the importance of separating Linux operating-system routing from AWS VPC routing.

Using isolated network resources allowed the incident to be reproduced without modifying the default VPC's main route table.

---

## 24. Skills Demonstrated

- Amazon EC2 networking troubleshooting
- Amazon VPC
- Internet gateways
- Subnet creation and configuration
- Route table creation and association
- Default route management
- Public IPv4 networking
- AWS CLI v2
- Linux network diagnostics
- SSH troubleshooting
- HTTP and HTTPS testing
- DNS troubleshooting
- Root cause analysis
- Controlled fault injection
- Infrastructure remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-009 |
| Problem | EC2 No Internet Access |
| Root Cause | Missing default route |
| EC2 State | Running |
| Internet Gateway | Attached |
| Broken Route | `0.0.0.0/0` missing |
| Remediation | Restore IGW route |
| SSH After Recovery | Successful |
| HTTPS After Recovery | Successful |
| Security Group | Unchanged |
| Default VPC | Preserved |
| Cleanup | Dedicated resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** An EC2 instance needs correct addressing, routing, and firewall configuration to access the internet. When connectivity fails, inspect the subnet's effective route table and internet gateway before changing the operating system or security group.

# Lab 02 — Amazon EC2 SSH Connection Timeout

## Overview

This hands-on lab demonstrates how to troubleshoot an SSH connection timeout on an Amazon EC2 Linux instance caused by a missing inbound security group rule.

In this simulated production incident, an EC2 instance is running successfully and passing both AWS status checks. However, an engineer cannot connect to the instance using SSH.

The troubleshooting process involves investigating EC2 instance state, public IPv4 addressing, VPC networking, security group rules, SSH connectivity, and Linux services.

**Root Cause:** The security group does not permit inbound TCP traffic on port 22.

**Remediation:** Allow SSH access only from the engineer's trusted public IPv4 address using a `/32` CIDR.

**Workflow:** Establish Baseline → Reproduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-002 |
| AWS Services | Amazon EC2, Amazon VPC |
| Supporting Components | Security Groups, Internet Gateway |
| Difficulty | Beginner–Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Error | SSH Connection Timed Out |
| Protocol | TCP |
| Port | 22 |
| Root Cause | Missing inbound SSH rule |
| Remediation | Allow TCP 22 from trusted `/32` |
| Tools | AWS CLI v2, Linux, SSH, Bash |
| Client Environment | Ubuntu WSL2 |
| Expected Outcome | Successful SSH authentication |

---

## 1. Production Incident Scenario

### Incident Description

A Cloud Operations Engineer needs to access a production Linux EC2 instance for troubleshooting.

The AWS Console shows the instance as running, and both the system and instance status checks are healthy.

However, the engineer attempts to connect using SSH and receives a connection timeout.

### Reported Error

```text
ssh: connect to host <PUBLIC_IP> port 22:
Connection timed out
```

### Expected Behavior

An authorized engineer should establish an SSH connection to the EC2 instance using the correct private key and Linux username.

### Actual Behavior

The SSH client cannot establish a TCP connection to port 22.

### Potential Business Impact

- Engineers cannot perform administrative maintenance.
- Application troubleshooting is delayed.
- Incident response takes longer.
- System updates may be postponed.
- Recovery operations may be disrupted.

### Investigation Objective

Determine whether the SSH connection timeout is caused by the instance, network routing, security group, network ACL, or operating-system firewall.

---

## 2. Architecture

### Broken Architecture

```text
       Engineer — Ubuntu WSL2
                 |
                 | SSH TCP/22
                 v
             Internet
                 |
                 v
          Internet Gateway
                 |
                 v
         VPC Public Subnet
                 |
                 v
          Security Group
                 |
                 X
          TCP Port 22 Blocked
                 |
                 v
       Amazon EC2 Linux Instance
           State: Running
           Status Checks: OK
                 |
                 v
         SSH Connection Timeout
```

### Corrected Architecture

```text
       Engineer — Ubuntu WSL2
                 |
                 | SSH TCP/22
                 v
             Internet
                 |
                 v
          Internet Gateway
                 |
                 v
         VPC Public Subnet
                 |
                 v
          Security Group
                 |
                 | Allow TCP/22
                 | Source: CLIENT_PUBLIC_IP/32
                 v
       Amazon EC2 Linux Instance
                 |
                 v
           SSH Service
                 |
                 v
       Successful Authentication
```

---

## 3. Understanding SSH on Amazon EC2

SSH (Secure Shell) is a network protocol that provides encrypted remote access to Linux systems.

By default, SSH uses:

```text
Protocol: TCP
Port: 22
```

### Requirements for SSH Connectivity

For direct SSH access over the public internet, several components must be configured correctly.

| Component | Requirement |
|---|---|
| EC2 instance | Running |
| Status checks | Healthy |
| Public IPv4 | Assigned |
| Subnet routing | Route to internet gateway |
| Internet gateway | Attached to the VPC |
| Security group | TCP 22 allowed from client |
| Network ACL | Required inbound and outbound traffic allowed |
| SSH server | Running on the instance |
| Private key | Matches configured public key |
| Linux username | Correct for the AMI |
| Local network | Outbound SSH permitted |

A failure in any of these components can prevent successful access.

### Connection Timeout vs Permission Denied

| Error | Meaning |
|---|---|
| `Connection timed out` | TCP connection could not be established |
| `Connection refused` | Destination actively rejected the TCP connection |
| `Permission denied (publickey)` | SSH authentication failed |
| `Host key verification failed` | SSH host identity verification failed |

**Important:** A connection timeout generally indicates a reachability problem, but it does not automatically prove that the security group is responsible.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- SSH client
- Basic Linux command-line knowledge
- EC2 and VPC permissions
- Ability to create and delete an EC2 key pair
- Git and GitHub

### AWS Cost Considerations

This lab creates:

- One EC2 instance
- One EBS root volume
- One public IPv4 address
- One security group
- One EC2 key pair

EC2, EBS, and public IPv4 usage may generate AWS charges.

Delete the lab resources after completing the exercise.

### Verify AWS CLI

```bash
aws --version
```

### Verify AWS Identity

```bash
aws sts get-caller-identity
```

---

## 5. Configure the Lab Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)

export INSTANCE_NAME="cloud-lab02-ssh-instance"
export SG_NAME="cloud-lab02-ssh-sg"
export KEY_NAME="cloud-lab02-ssh-key"
```

### Step 2 — Identify the Default VPC

```bash
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$VPC_ID"
```

Expected format:

```text
vpc-xxxxxxxxxxxxxxxxx
```

This lab reuses the default VPC prepared in Lab 01.

### Step 3 — Check Supported Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Select a Supported Subnet

The following script selects a default subnet in an Availability Zone where `t3.micro` is offered.

```bash
export SUBNET_ID=$(python3 - <<'PY'
import json
import os
import subprocess

region = os.environ["AWS_REGION"]
vpc = os.environ["VPC_ID"]

def aws_json(args):
    output = subprocess.check_output(
        ["aws", "ec2", *args,
         "--region", region,
         "--output", "json"],
        text=True
    )
    return json.loads(output)

offerings = aws_json([
    "describe-instance-type-offerings",
    "--location-type", "availability-zone",
    "--filters", "Name=instance-type,Values=t3.micro"
])

zones = {
    item["Location"]
    for item in offerings["InstanceTypeOfferings"]
}

subnets = aws_json([
    "describe-subnets",
    "--filters", f"Name=vpc-id,Values={vpc}"
])

candidates = [
    subnet for subnet in subnets["Subnets"]
    if subnet["AvailabilityZone"] in zones
    and subnet.get("DefaultForAz", False)
]

if not candidates:
    raise SystemExit("No supported default subnet found")

selected = sorted(
    candidates,
    key=lambda s: s["AvailabilityZone"]
)[0]

print(selected["SubnetId"])
PY
)
```

Verify:

```bash
echo "$SUBNET_ID"
```

### Step 5 — Verify Internet Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Identify the route table effective for the selected subnet.

For a public subnet, confirm an active default IPv4 route:

```text
Destination: 0.0.0.0/0
Target: igw-xxxxxxxx
```

Also confirm that the internet gateway is attached to the VPC.

---

## 6. Create the SSH Key Pair

### Step 1 — Check for an Existing Key Pair

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new lab, `InvalidKeyPair.NotFound` is expected.

### Step 2 — Create a Private Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 3 — Configure Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab02-ssh-key.pem"
```

### Step 4 — Generate the Key Pair

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$KEY_FILE"
```

### Step 5 — Protect the Private Key

```bash
chmod 400 "$KEY_FILE"
```

Verify permissions:

```bash
ls -l "$KEY_FILE"
```

**Security:** Never upload your private SSH key to GitHub.

---

## 7. Create the Security Group

### Step 1 — Create a Dedicated Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab02 SSH connection timeout troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Verify Security Group

```bash
echo "$SG_ID"
```

### Step 3 — Inspect Inbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Why This Matters

A newly created security group has no inbound allow rules unless they are added.

The default outbound configuration typically allows traffic, but inbound SSH traffic remains blocked.

This missing TCP 22 rule is the intentional misconfiguration for the lab.

---

## 8. Launch the EC2 Instance

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab02-ssh-instance},{Key=Project,Value=EC2-Troubleshooting-Lab02}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Instance ID

```bash
echo "$INSTANCE_ID"
```

Expected format:

```text
i-xxxxxxxxxxxxxxxxx
```

### Step 4 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Wait for Health Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Inspect Status Checks

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
System: ok
Instance: ok
```

### Step 7 — Retrieve Public IP

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$PUBLIC_IP"
```

---

## 9. Reproduce the SSH Timeout

### Step 1 — Attempt SSH

```bash
ssh -o ConnectTimeout=8 \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Expected:

```text
ssh: connect to host <PUBLIC_IP> port 22:
Connection timed out
```

### Step 2 — Test TCP Port 22

```bash
timeout 8 bash -c \
  "echo > /dev/tcp/$PUBLIC_IP/22"
```

Expected: connection failure or timeout.

### Observation

The instance is healthy, but the network connection cannot reach the SSH server.

The missing security group rule is the intended cause.

---

## 10. Troubleshooting Investigation

### Check 1 — Verify Instance State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,Subnet:SubnetId,SecurityGroups:SecurityGroups}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 2 — Verify Health Checks

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

### Check 3 — Inspect Security Group Inbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Check 4 — Verify Network Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output json \
  --region "$AWS_REGION"
```

Ensure the subnet has a valid route to an internet gateway.

### Investigation Findings

| Check | Finding |
|---|---|
| EC2 state | Running |
| Instance health | OK |
| System health | OK |
| Public IP | Assigned |
| Internet gateway route | Present |
| SSH key | Available |
| Security group | Attached |
| Inbound TCP 22 | Missing |
| SSH connection | Timed out |
| Root cause | Security group blocks SSH |

---

## 11. Root Cause Analysis

### Root Cause

The EC2 security group does not contain an inbound rule allowing TCP port 22 from the engineer's public IPv4 address.

As a result, incoming SSH connection attempts are not permitted.

### Root Cause Flow

```text
Engineer Runs SSH
        |
        v
Public EC2 IPv4 Address
        |
        v
Internet Gateway
        |
        v
Security Group Evaluation
        |
        v
No TCP 22 Allow Rule
        |
        v
Traffic Not Permitted
        |
        v
SSH Connection Timeout
```

### Five Whys

1. **Why couldn't the engineer connect?** SSH timed out.
2. **Why did SSH time out?** TCP port 22 was unreachable.
3. **Why was TCP port 22 unreachable?** The security group did not allow inbound SSH.
4. **Why was the rule missing?** The security group was created without an inbound SSH rule.
5. **How can this be prevented?** Validate required network access and apply reviewed, least-privilege rules before operational access is needed.

---

## 12. Apply Remediation

### Step 1 — Identify Client Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Verify:

```bash
echo "$MY_IP"
```

If you are behind a VPN or corporate network, confirm this is the public source IP used by SSH.

### Step 2 — Authorize SSH From One IP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Explanation

| Setting | Value |
|---|---|
| Protocol | TCP |
| Port | 22 |
| Source | Client public IPv4 |
| CIDR | `/32` |
| Access | Single IPv4 address |

Using `/32` limits SSH access to the specified public IPv4 address.

### Step 3 — Verify the New Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected configuration:

```text
TCP 22
Source: CLIENT_PUBLIC_IP/32
```

---

## 13. Verify Successful SSH Access

### Step 1 — Retry SSH

```bash
ssh -o ConnectTimeout=10 \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Expected: an interactive Linux shell.

The initial connection may require host-key verification. In production, validate the host fingerprint against a trusted source before accepting it.

### Step 2 — Verify Username

Run inside EC2:

```bash
whoami
```

Expected:

```text
ec2-user
```

### Step 3 — Verify Operating System

```bash
cat /etc/os-release
```

Expected: Amazon Linux 2023.

### Step 4 — Verify SSH Service

```bash
sudo systemctl status sshd --no-pager
```

Expected:

```text
active (running)
```

### Step 5 — Exit

```bash
exit
```

This returns to the WSL2 terminal.

### Verification Summary

| Test | Before Fix | After Fix |
|---|---|---|
| Instance state | Running | Running |
| EC2 health checks | OK | OK |
| Public IPv4 | Assigned | Assigned |
| Security group TCP 22 | Blocked | Allowed from `/32` |
| TCP connectivity | Timed out | Successful |
| SSH session | Unavailable | Connected |
| Linux username | Not verified | Verified |
| SSH daemon | Not verified | Active |

---

## 14. Production Engineering Considerations

### Common Causes of SSH Connection Timeout

- Missing security group inbound SSH rule
- Incorrect client public IP
- No public IPv4 address
- Missing internet gateway route
- Restrictive network ACL
- Local or corporate firewall blocking port 22
- SSH daemon not listening
- Incorrect target address
- Instance-level firewall blocking SSH

### Recommended Troubleshooting Order

1. Confirm the instance is running.
2. Verify EC2 status checks.
3. Confirm the correct IP address.
4. Inspect subnet routing.
5. Check internet gateway connectivity.
6. Inspect security group inbound and outbound rules.
7. Inspect network ACL rules.
8. Test TCP port 22.
9. Verify the SSH service if host access is available.
10. Test SSH authentication.

### Security Best Practices

- Never expose SSH to the entire internet unnecessarily.
- Prefer trusted `/32` client addresses for direct administrative access.
- Use Systems Manager Session Manager when appropriate.
- Secure private keys using restrictive file permissions.
- Rotate and remove unused keys.
- Use dedicated security groups for different workloads.
- Remove temporary administrative access rules.
- Monitor security group configuration changes.

---

## 15. Related SSH Errors

| Error | Possible Cause |
|---|---|
| `Connection timed out` | Network reachability issue |
| `Connection refused` | Port closed or SSH daemon unavailable |
| `Permission denied (publickey)` | Authentication failure |
| `Host key verification failed` | SSH host identity mismatch |
| `UNPROTECTED PRIVATE KEY FILE` | Incorrect private-key permissions |
| `No route to host` | Network routing problem |
| `Network is unreachable` | Client routing problem |

---

## 16. Interview Questions and Answers

### Q1. What causes SSH connection timeouts on EC2?

Common causes include security group rules, network ACLs, routing, missing public IP addresses, and host-level firewalls.

### Q2. What port does SSH use?

TCP port 22 by default.

### Q3. What is the difference between a security group and a network ACL?

Security groups are stateful and are associated with network interfaces. Network ACLs are stateless and operate at the subnet level.

### Q4. Why is a public IPv4 address required for this lab?

The engineer connects directly from the public internet. The instance therefore needs a publicly reachable address and an appropriate internet gateway route.

### Q5. Why use a `/32` CIDR?

It permits traffic from exactly one IPv4 address instead of allowing an entire network range.

### Q6. Why might SSH fail even when EC2 status checks are healthy?

Status checks do not guarantee that an application or administrative port is reachable from a particular client.

### Q7. What is the default SSH username for Amazon Linux 2023?

`ec2-user`.

### Q8. Can SSH work without a public IPv4 address?

Yes. Alternatives include Systems Manager Session Manager, private network connectivity, and supported bastion or EC2 Instance Connect Endpoint architectures.

### Q9. How do you check security group inbound rules with AWS CLI?

Use `aws ec2 describe-security-groups` and inspect `IpPermissions`.

### Q10. How would you explain this incident in an interview?

> I investigated an SSH timeout on a healthy EC2 instance. I verified the instance state, public IPv4 address, subnet routing, and attached security group. I found that the security group had no inbound rule permitting TCP 22. I identified my public IPv4 address, added a restricted `/32` SSH rule, and successfully connected to the instance. I then verified the operating system and SSH daemon before cleaning up the lab resources.

---

## 17. Cleanup

**Warning:** Complete these steps only for resources created specifically for Lab 02.

### Step 1 — Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Step 2 — Verify the Instance

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the project tag:

```text
EC2-Troubleshooting-Lab02
```

### Step 3 — Terminate the Instance

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Wait for Termination

```bash
aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Network Interface Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Wait until no network interfaces reference the lab security group.

### Step 6 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

If a dependency error occurs, inspect the remaining associations rather than forcing deletion.

### Step 7 — Delete AWS Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 8 — Remove Local Private Key

```bash
rm -f "$KEY_FILE"
```

Only remove the dedicated Lab 02 key.

### Step 9 — Check Remaining EBS Volumes

Before termination, record the root volume ID if available.

For example:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

The root EBS volume normally uses `DeleteOnTermination=true`.

Verify that the dedicated volume has been removed, and inspect any unexpected leftover EBS volumes.

Do not delete unrelated resources.

### Step 10 — Confirm Instance Termination

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
terminated
```

Keep the default VPC and subnets for future EC2 labs.

---

## 18. Repository Structure

```text
02-ssh-connection-timeout/
│
└── README.md
```

The README contains all AWS CLI commands, troubleshooting procedures, and remediation steps.

SSH private keys and temporary execution artifacts must remain outside the public GitHub repository.

---

## 19. Lessons Learned

This lab demonstrated that a running EC2 instance with healthy status checks may still be unreachable over SSH.

The issue was caused by a missing inbound security group rule for TCP port 22.

The investigation required checking instance health, public IPv4 addressing, network routing, and security group configuration.

The remediation involved adding a restricted SSH rule allowing traffic only from the engineer's trusted public IPv4 address.

After applying the change, the SSH connection could be established and the Linux operating system and SSH daemon could be verified.

The key lesson is to troubleshoot SSH timeouts systematically and distinguish network connectivity failures from authentication problems.

---

## 20. Skills Demonstrated

- Amazon EC2 troubleshooting
- Amazon VPC networking
- Security groups
- Public IPv4 connectivity
- Internet gateway routing
- SSH troubleshooting
- Linux administration
- SSH key management
- AWS CLI v2
- Bash
- Least-privilege network access
- Root cause analysis
- Production incident remediation
- Resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-002 |
| Problem | SSH Connection Timeout |
| Instance State | Running |
| Root Cause | Missing TCP 22 inbound rule |
| Remediation | Allow trusted public IPv4 `/32` |
| TCP Connectivity | Restored |
| SSH Authentication | Successful |
| Linux Access | Verified |
| Security Group | Least-privilege SSH rule |
| Resource Cleanup | EC2 and lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When SSH times out on a running EC2 instance, verify networking before troubleshooting authentication. Inspect the public IP, route table, internet gateway, security group, network ACL, and SSH service, then apply the smallest secure remediation.

# Lab 13 — Amazon EC2 SSM Agent Connection Failure

## Overview

This hands-on lab demonstrates how to investigate and resolve an Amazon EC2 instance that cannot be accessed through AWS Systems Manager Session Manager.

Session Manager provides secure administrative access to EC2 instances without requiring inbound SSH port 22, an SSH key pair, or a bastion host.

In this simulated production incident, an EC2 instance is running normally and has the correct IAM instance profile. However, the SSM Agent service is intentionally stopped, causing the instance to lose its connection to AWS Systems Manager.

We investigate the instance's managed-node status, IAM permissions, agent service, networking requirements, and logs. Finally, we restore the service and verify Session Manager connectivity.

**Troubleshooting workflow:**

Healthy Baseline → Simulate Failure → Investigate → Root Cause Analysis → Restore Agent → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-013 |
| AWS Services | EC2, Systems Manager, IAM, VPC |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| AWS Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, Session Manager, systemd |
| Failure | SSM Agent stops responding |
| Managed-Node Status | `ConnectionLost` may appear |
| Root Cause | SSM Agent service stopped |
| Remediation | Restart `amazon-ssm-agent` |
| IAM Policy | `AmazonSSMManagedInstanceCore` |
| Administrative Access | Session Manager |
| SSH Port 22 | Not opened |
| Expected Outcome | Managed node returns to `Online` |

---

## 1. Production Incident Scenario

### Incident Description

A company manages Linux EC2 instances using AWS Systems Manager Session Manager.

Administrators use Session Manager to perform maintenance, inspect logs, and troubleshoot applications without opening SSH access to the instances.

One day, an administrator attempts to connect to an EC2 instance but receives an error.

The EC2 instance is running, and its EC2 status checks remain healthy.

However, Systems Manager cannot establish a session.

### Expected Behavior

The instance should appear in Systems Manager with the connection status:

```text
Online
```

An administrator should be able to connect using:

```bash
aws ssm start-session \
  --target INSTANCE_ID \
  --region us-east-1
```

### Simulated Failure

The SSM Agent service stops running.

Possible symptoms include:

```text
SSM Agent is not online
```

Or:

```text
TargetNotConnected
```

Systems Manager may eventually report:

```text
ConnectionLost
```

The exact errors and timing depend on when the service stops and when AWS updates the managed-node status.

### Potential Business Impact

- Loss of remote administrative access
- Delayed incident response
- Failed maintenance operations
- Interrupted automation
- Inability to run remote commands
- Reduced operational visibility
- Increased recovery time

### Investigation Objective

Identify why Session Manager cannot connect even though the underlying EC2 instance is still running.

---

## 2. Architecture

### Healthy Architecture

```text
                 Cloud Engineer
                       |
                       v
             AWS Systems Manager
                 Session Manager
                       |
                       v
              HTTPS Communication
                       |
                       v
                 Amazon EC2
                       |
             +---------+---------+
             |                   |
             v                   v
         IAM Role            SSM Agent
             |                   |
             v                   v
   AmazonSSMManagedInstanceCore  Running
             |                   |
             +---------+---------+
                       |
                       v
               Managed Node Online
                       |
                       v
              Session Established
```

### Broken Architecture

```text
               Cloud Engineer
                     |
                     v
              Session Manager
                     |
                     v
                 Amazon EC2
                     |
           +---------+---------+
           |                   |
           v                   v
       IAM Role            SSM Agent
       Correct              Stopped
           |                   |
           +---------+---------+
                     |
                     X
             SSM Connection Lost
                     |
                     v
           Session Manager Fails
```

### Recovery Architecture

```text
              SSM Connection Failure
                       |
                       v
             Investigate Instance
                       |
                       v
           Verify IAM and Network
                       |
                       v
             Inspect Agent State
                       |
                       v
             Restart SSM Agent
                       |
                       v
               Agent Reconnects
                       |
                       v
           Managed Node Status Online
                       |
                       v
            Session Manager Works
```

---

## 3. Understanding AWS Systems Manager

AWS Systems Manager helps manage and operate AWS resources.

It provides features for remote administration, automation, inventory, patch management, and operational troubleshooting.

### Important Components

| Component | Purpose |
|---|---|
| Systems Manager | AWS operations and management service |
| Session Manager | Interactive remote administration |
| SSM Agent | Software running on managed nodes |
| IAM role | Grants the agent necessary AWS permissions |
| Instance profile | Makes the IAM role available to EC2 |
| Managed node | Instance or machine registered with Systems Manager |
| `ssm` endpoint | Systems Manager service communication |
| `ssmmessages` endpoint | Session and communication channels |

### How Session Manager Works

1. The EC2 instance runs SSM Agent.
2. The instance obtains temporary credentials from its IAM role.
3. The agent establishes outbound HTTPS communication with Systems Manager endpoints.
4. AWS Systems Manager recognizes the instance as a managed node.
5. An authorized operator starts a Session Manager session.
6. The service and agent establish the interactive session.

### Why SSH Is Not Required

Session Manager uses agent-initiated outbound communication.

The EC2 security group does not need an inbound port 22 rule for Session Manager.

The IAM permissions of the managed instance and the human operator are separate.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 management permissions
- IAM role management permissions
- Systems Manager permissions
- Session Manager Console access or Session Manager plugin
- Git and GitHub

### Security Requirements

- Use a disposable EC2 instance.
- Create a dedicated IAM role.
- Attach `AmazonSSMManagedInstanceCore`.
- Require IMDSv2.
- Do not open SSH port 22.
- Do not configure permanent AWS credentials.
- Verify all resources before deletion.
- Schedule recovery before intentionally stopping SSM Agent.

### Cost Considerations

Possible charges include:

- EC2 compute
- EBS storage
- Public IPv4 usage
- Data transfer

This lab uses the existing default VPC and its internet gateway rather than creating additional networking services.

---

## 5. Prepare AWS Environment

All commands initially run from Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="EC2-Troubleshooting-Lab13"

export INSTANCE_NAME="cloud-lab13-ssm-instance"
export SG_NAME="cloud-lab13-ssm-sg"

export ROLE_NAME="cloud-lab13-ssm-role"
export PROFILE_NAME="cloud-lab13-ssm-profile"

export SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)
```

Verify the AWS account:

```bash
aws sts get-caller-identity
```

### Step 2 — Identify Default VPC

```bash
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

Stop if no default VPC is available.

### Step 3 — Select a Compatible Subnet

Check Availability Zones supporting `t3.micro`:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

List VPC subnets:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

Choose a compatible default subnet:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

Confirm that its effective route table supports outbound internet traffic through the existing internet gateway.

### Step 4 — Inspect VPC DNS Settings

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

These settings are inspected only. We do not modify the shared VPC.

---

## 6. Create the EC2 IAM Role

### Step 1 — Create Trust Policy

File: `ec2-trust-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEC2AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Create the file in WSL2:

```bash
cat > ec2-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEC2AssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

### Step 2 — Check for an Existing Role

```bash
aws iam get-role \
  --role-name "$ROLE_NAME"
```

For a new lab, `NoSuchEntity` is expected.

### Step 3 — Create the Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 4 — Attach the SSM Policy

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$SSM_POLICY_ARN"
```

### Step 5 — Verify Permissions

```bash
aws iam list-attached-role-policies \
  --role-name "$ROLE_NAME" \
  --output table
```

Expected:

```text
AmazonSSMManagedInstanceCore
```

This AWS-managed policy supplies permissions for core Systems Manager managed-node operations.

It does not automatically grant the person operating AWS CLI permission to start sessions.

---

## 7. Create IAM Instance Profile

### Step 1 — Check Existing Profile

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For a new lab, expect `NoSuchEntity`.

### Step 2 — Create the Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Attach Role to Profile

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

### Step 4 — Verify

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.{Name:InstanceProfileName,Roles:Roles[].RoleName}' \
  --output json
```

Expected: the dedicated Lab 13 role is included.

IAM configuration changes may take time to propagate.

---

## 8. Create a No-SSH Security Group

### Step 1 — Check Existing Group

```bash
aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

### Step 2 — Create Security Group

If the group name is unused:

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab13 Session Manager connectivity troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Inbound and Outbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected inbound configuration:

```json
[]
```

The newly created security group should permit outbound traffic unless its default egress rule has been modified.

**Important:** Do not add an inbound SSH rule.

SSM Agent initiates outbound communication over HTTPS.

---

## 9. Launch Amazon Linux EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Instance

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

### Step 3 — Launch EC2 With Instance Profile

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
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

### Configuration Explanation

The instance launches with:

- Amazon Linux 2023.
- IAM instance profile attached.
- IMDSv2 required.
- Public IPv4 for outbound internet access.
- No SSH key pair.
- No inbound security group rules.

The public IPv4 does not itself grant inbound access.

### Step 4 — Wait for Instance Readiness

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify EC2 Status Checks

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

---

## 10. Verify Systems Manager Registration

### Step 1 — Check Managed Node Information

From WSL2:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Instance:InstanceId,Status:PingStatus,AgentVersion:AgentVersion,Platform:PlatformName}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after the agent registers:

```text
Instance: i-xxxxxxxxxxxxxxxxx
Status: Online
```

The exact agent version varies.

### Step 2 — Verify the Instance Profile

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the Lab 13 instance profile ARN.

### Step 3 — Connect Using Session Manager

AWS Console procedure:

1. Open the EC2 Console.
2. Select the Lab 13 instance.
3. Choose **Connect**.
4. Select **Session Manager**.
5. Choose **Connect**.

Expected: an interactive Linux shell opens.

### Optional — AWS CLI Session Manager

The Session Manager plugin must be installed on the local computer.

Check:

```bash
session-manager-plugin --version
```

Connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

The operator must have the appropriate permissions to start sessions.

---

## 11. Establish Healthy SSM Agent Baseline

Run these commands inside the Session Manager shell.

### Check 1 — Verify Operating System

```bash
whoami
hostname
cat /etc/os-release
```

### Check 2 — Verify SSM Agent

```bash
sudo systemctl status amazon-ssm-agent --no-pager
```

Expected:

```text
Active: active (running)
```

### Check 3 — Inspect Agent Logs

```bash
sudo journalctl \
  -u amazon-ssm-agent \
  -n 30 \
  --no-pager
```

Check the SSM Agent log file:

```bash
sudo tail -n 30 \
  /var/log/amazon/ssm/amazon-ssm-agent.log
```

### Check 4 — Inspect AWS Identity

If AWS CLI is installed:

```bash
aws sts get-caller-identity
```

Expected: an assumed-role ARN containing the Lab 13 role name.

The Session Manager shell user and environment may differ from a normal `ec2-user` login, so verify the credential source if an unexpected identity appears.

### Check 5 — Verify DNS

```bash
getent ahostsv4 ssm.us-east-1.amazonaws.com
```

```bash
getent ahostsv4 ssmmessages.us-east-1.amazonaws.com
```

### Check 6 — Verify HTTPS Reachability

```bash
curl -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://ssm.us-east-1.amazonaws.com
```

```bash
curl -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://ssmmessages.us-east-1.amazonaws.com
```

An HTTP error response from an unauthenticated request can still demonstrate network reachability.

A DNS failure, connection timeout, or TLS error suggests a different problem.

### Healthy Baseline Findings

| Check | Expected Result |
|---|---|
| EC2 state | Running |
| Status checks | OK |
| Instance profile | Attached |
| Managed-node status | Online |
| SSM Agent | Running |
| STS role | Correct |
| Endpoint DNS | Working |
| HTTPS egress | Working |
| Session Manager | Connected |
| SSH port 22 | Not open |

---

## 12. Prepare the Controlled Agent Failure

Stopping SSM Agent will interrupt the current Session Manager connection.

Therefore, recovery must be prepared before the failure is introduced.

### Step 1 — Create Recovery Directory

Inside Session Manager:

```bash
sudo mkdir -p /opt/ec2-lab13
```

### Step 2 — Create the Recovery Script

File on EC2: `/opt/ec2-lab13/restore-ssm.sh`

```bash
#!/bin/bash

/usr/bin/systemctl start amazon-ssm-agent

/usr/bin/systemctl is-active \
  amazon-ssm-agent \
  > /opt/ec2-lab13/recovery-status.txt
```

Create it:

```bash
sudo tee /opt/ec2-lab13/restore-ssm.sh > /dev/null <<'EOF'
#!/bin/bash

/usr/bin/systemctl start amazon-ssm-agent

/usr/bin/systemctl is-active \
  amazon-ssm-agent \
  > /opt/ec2-lab13/recovery-status.txt
EOF
```

### Step 3 — Set Permissions

```bash
sudo chmod 700 /opt/ec2-lab13/restore-ssm.sh
```

### Step 4 — Schedule Automatic Recovery

```bash
sudo systemd-run \
  --unit=lab13-auto-recover \
  --on-active=5min \
  /opt/ec2-lab13/restore-ssm.sh
```

### Step 5 — Verify the Timer

```bash
systemctl list-timers --all | grep lab13
```

Do not intentionally stop the agent until the recovery timer has been verified.

**Important:** The recovery timer is a safeguard, not a guaranteed recovery method. If systemd or the recovery script fails, an approved out-of-band recovery method may be necessary.

---

## 13. Reproduce SSM Agent Connection Failure

### Step 1 — Schedule the Agent Stop

Inside Session Manager:

```bash
sudo systemd-run \
  --unit=lab13-stop-agent \
  --on-active=45s \
  /usr/bin/systemctl stop amazon-ssm-agent
```

### Step 2 — Verify Both Timers

```bash
systemctl list-timers --all | grep lab13
```

Expected:

```text
lab13-stop-agent.timer
lab13-auto-recover.timer
```

Actual systemd output may include additional timer details.

### Step 3 — Exit Session Manager

```bash
exit
```

The scheduled stop command will intentionally stop SSM Agent.

### Expected Behavior

- The SSM Agent stops.
- An existing Session Manager session may disconnect.
- New Session Manager connections fail while the agent is unavailable.
- The EC2 instance itself remains running.
- Systems Manager may eventually mark the node `ConnectionLost`.

The exact managed-node status update may be delayed.

---

## 14. Troubleshooting Investigation

Run these commands from WSL2.

### Check 1 — Inspect Managed-Node Status

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus,AgentVersion:AgentVersion,LastPing:LastPingDateTime}' \
  --output table \
  --region "$AWS_REGION"
```

Possible result:

```text
ConnectionLost
```

The status may still temporarily show `Online` even after the service stops.

### Check 2 — Attempt a Session

If the local Session Manager plugin is installed:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Possible failure:

```text
TargetNotConnected
```

### Check 3 — Verify EC2 State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Profile:IamInstanceProfile.Arn}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: `running`.

### Check 4 — Verify Status Checks

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both status checks remain `ok`.

### Check 5 — Verify Instance Profile Association

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query 'IamInstanceProfileAssociations[].{State:State,Profile:IamInstanceProfile.Arn}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: the intended instance profile remains attached.

### Check 6 — Verify IAM Policy

```bash
aws iam list-attached-role-policies \
  --role-name "$ROLE_NAME" \
  --output table
```

Expected:

```text
AmazonSSMManagedInstanceCore
```

### Investigation Summary

| Check | Expected Finding |
|---|---|
| EC2 instance | Running |
| Status checks | OK |
| IAM role | Attached |
| SSM managed policy | Attached |
| Inbound SSH | Not permitted |
| Managed-node status | May show ConnectionLost |
| Session Manager | Unavailable |
| SSM Agent | Intentionally stopped |
| Root cause | Agent service failure |

---

## 15. Root Cause Analysis

### Root Cause

The `amazon-ssm-agent` Linux service was intentionally stopped.

Because SSM Agent is responsible for maintaining the managed-node communication channels, stopping it prevents normal Session Manager connectivity.

### Technical Explanation

EC2 instance health and Systems Manager connectivity are separate conditions.

An EC2 instance may continue running successfully, while SSM Agent is stopped or unable to contact its service endpoints.

A healthy EC2 status check does not prove that SSM Agent is running.

### Root Cause Flow

```text
EC2 Instance Running
        |
        v
SSM Agent Stopped
        |
        v
Agent Communication Stops
        |
        v
Systems Manager Loses Connection
        |
        v
Managed Node May Become ConnectionLost
        |
        v
Session Manager Cannot Connect
```

### Five Whys

1. **Why couldn't Session Manager connect?** The managed agent wasn't available to establish the session.
2. **Why wasn't the agent available?** The service had been stopped.
3. **Why did AWS report a connection problem?** The agent couldn't maintain its Systems Manager communication.
4. **Why did EC2 remain healthy?** EC2 status checks are different from agent-level application health.
5. **How can this be prevented?** Monitor SSM connectivity, maintain the agent service, and implement appropriate operational recovery procedures.

---

## 16. Apply Remediation

### Step 1 — Allow the Scheduled Recovery to Execute

The Lab 13 recovery script is scheduled to start the SSM Agent after the controlled failure.

Its main action is:

```bash
sudo systemctl start amazon-ssm-agent
```

### Step 2 — Verify Managed Node Recovery

From WSL2:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{Instance:InstanceId,Status:PingStatus,LastPing:LastPingDateTime}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after reconnection:

```text
Online
```

### Step 3 — Reconnect Through Session Manager

From the AWS Console, use:

```text
EC2 → Instances → Connect → Session Manager
```

Or, with the local plugin:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify SSM Agent Service

Inside the recovered Session Manager session:

```bash
sudo systemctl is-active amazon-ssm-agent
```

Expected:

```text
active
```

Inspect the full status:

```bash
sudo systemctl status amazon-ssm-agent --no-pager
```

### Step 5 — Inspect Recovery Execution

```bash
sudo systemctl status lab13-auto-recover.service --no-pager
```

Check the recovery marker:

```bash
sudo cat /opt/ec2-lab13/recovery-status.txt
```

Expected if the recovery script executed successfully:

```text
active
```

### Step 6 — Inspect Logs

```bash
sudo journalctl \
  -u amazon-ssm-agent \
  -n 60 \
  --no-pager
```

Look for evidence of the agent stopping and starting.

### Step 7 — Verify Startup Configuration

```bash
sudo systemctl is-enabled amazon-ssm-agent
```

If the agent is intended to start automatically and is disabled:

```bash
sudo systemctl enable amazon-ssm-agent
```

### Step 8 — Verify IAM Identity

```bash
aws sts get-caller-identity
```

Confirm the expected EC2 role identity.

---

## 17. Final Verification

| Check | During Failure | After Recovery |
|---|---|---|
| EC2 state | Running | Running |
| EC2 status checks | Usually OK | OK |
| IAM instance profile | Attached | Attached |
| SSM Agent | Stopped | Running |
| Managed-node status | ConnectionLost possible | Online |
| Session Manager | Unavailable | Connected |
| SSM IAM policy | Attached | Attached |
| HTTPS egress | Available | Available |
| SSH port 22 | Closed | Closed |

### Success Criteria

The lab is considered resolved when:

- EC2 remains healthy.
- The correct instance profile is attached.
- The SSM Agent service is active.
- The managed node reports `Online`.
- A new Session Manager connection succeeds.
- Inbound SSH port 22 remains closed.
- The service stop and recovery are supported by actual logs or command output.

---

## 18. Other Common SSM Connection Problems

Although this lab deliberately stops the SSM Agent, real production failures can have multiple causes.

| Failure | Possible Cause | Investigation |
|---|---|---|
| Agent offline | Service stopped | `systemctl status` |
| TargetNotConnected | Agent or communication failure | Managed-node status |
| Instance absent from Systems Manager | Registration or configuration issue | IAM profile, agent, endpoints |
| AccessDenied starting session | Operator permissions | IAM user or role policy |
| Agent lacks permissions | Instance role problem | Attached policies |
| SSM endpoint unreachable | Routing, egress, DNS, or endpoint issue | Network tests |
| Agent missing | Custom AMI or package issue | Package and service checks |
| Agent unhealthy | Crash, corruption, or outdated version | Agent logs and version |

### Required Communication

Systems Manager managed nodes generally need HTTPS access to appropriate regional Systems Manager endpoints, including:

```text
ssm.us-east-1.amazonaws.com
ssmmessages.us-east-1.amazonaws.com
```

Legacy `ec2messages` communication can be relevant depending on region, agent version, and environment.

For private subnets, use appropriately configured VPC interface endpoints or approved outbound network access.

---

## 19. Production Engineering Best Practices

### Secure Remote Administration

- Prefer Session Manager where it meets security and operational requirements.
- Avoid exposing SSH to the public internet unnecessarily.
- Use least-privilege IAM roles.
- Separate instance permissions from operator permissions.
- Require IMDSv2.
- Keep SSM Agent updated.
- Monitor managed-node connectivity.
- Configure session logging and auditing when required.
- Use private endpoints for sensitive environments where appropriate.

### Troubleshooting Order

1. Verify EC2 state and status checks.
2. Check Systems Manager managed-node status.
3. Confirm the IAM instance profile.
4. Verify `AmazonSSMManagedInstanceCore`.
5. Check DNS and HTTPS endpoint connectivity.
6. Inspect SSM Agent service status when an authorized OS access path exists.
7. Read agent logs.
8. Identify the actual failure.
9. Apply the least disruptive remediation.
10. Verify a new Session Manager session.

### Important Production Lesson

An EC2 instance showing `running` does not guarantee that every management service inside the guest operating system is healthy.

Infrastructure health and application or agent health must be monitored separately.

---

## 20. Interview Questions and Answers

### Q1. What is AWS Systems Manager Session Manager?

Session Manager is an AWS capability that provides interactive access to supported managed nodes without requiring inbound SSH or RDP access.

### Q2. What is SSM Agent?

SSM Agent is software running on managed nodes that communicates with AWS Systems Manager and processes supported management operations.

### Q3. Why can an EC2 instance be running but appear offline in Systems Manager?

The SSM Agent might be stopped, lack IAM permissions, or be unable to reach Systems Manager endpoints.

### Q4. What IAM policy commonly provides core SSM Agent permissions?

```text
AmazonSSMManagedInstanceCore
```

### Q5. Does Session Manager require inbound SSH port 22?

No. It uses agent-initiated communication with AWS Systems Manager.

### Q6. How do you check SSM Agent status on Linux?

```bash
sudo systemctl status amazon-ssm-agent
```

### Q7. How do you restart SSM Agent?

```bash
sudo systemctl restart amazon-ssm-agent
```

### Q8. How do you check whether an instance is Online in Systems Manager?

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=INSTANCE_ID"
```

### Q9. What does `TargetNotConnected` mean?

It indicates that Systems Manager could not establish the requested connection to the target managed node. Investigation should include the agent, IAM, and network path.

### Q10. Can Session Manager work in a private subnet?

Yes. Appropriate VPC endpoints or another approved path to required Systems Manager endpoints can support Session Manager without public internet exposure.

### Q11. Does AmazonSSMManagedInstanceCore allow an IAM user to start sessions?

No. That policy grants permissions to the managed instance role. Operator authorization must be configured separately.

### Q12. How would you explain this incident in an interview?

> I investigated an EC2 instance that was running and passed its status checks but could not be accessed through AWS Systems Manager Session Manager. I verified the instance profile and SSM permissions, checked the managed-node connection status, and investigated the agent service. The root cause was a stopped SSM Agent. After restarting the service, I verified the managed node returned to Online status and established a new Session Manager connection. The exercise used no inbound SSH port or static credentials.

---

## 21. Cleanup

**Warning:** Delete only resources created for Lab 13.

### Step 1 — Verify AWS Identity

From WSL2:

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Instance Ownership

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project: EC2-Troubleshooting-Lab13
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check automatic deletion:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 4 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Confirm that it is the dedicated Lab 13 role.

### Step 6 — Detach AWS Managed Policy

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$SSM_POLICY_ARN"
```

### Step 7 — Verify Instance Profile Associations

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=iam-instance-profile.arn,Values=arn:aws:iam::${ACCOUNT_ID}:instance-profile/${PROFILE_NAME}" \
  --query 'IamInstanceProfileAssociations[].{Instance:InstanceId,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Ensure no active instance is using the profile.

### Step 8 — Remove the Role From the Profile

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

### Step 9 — Delete the Instance Profile

```bash
aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

### Step 10 — Delete IAM Role

```bash
aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 11 — Verify Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

If no dependencies remain:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If the volume was automatically deleted, AWS returns:

```text
InvalidVolume.NotFound
```

If a lab-owned EBS volume remains, confirm its ownership and attachment status before removing it.

Do not delete the default VPC, subnet, internet gateway, or shared IAM resources.

---

## 22. Repository Structure

```text
13-ssm-agent-connection-failure/
│
├── README.md
└── ec2-trust-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident and troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust relationship for the EC2 role |

The temporary recovery script runs on the disposable EC2 instance and is documented in this README.

The repository should not contain permanent AWS credentials, SSH private keys, or sensitive Session Manager logs.

---

## 23. Lessons Learned

This lab demonstrated how a healthy EC2 instance can lose its management connection when SSM Agent stops functioning.

The troubleshooting process involved checking the EC2 state, instance profile, IAM permissions, Systems Manager connectivity, Linux service status, and agent logs.

The simulation also demonstrated a safe fault-injection approach by scheduling automatic recovery before stopping the service.

After the agent restarted, the expected outcome was that the managed node returned to Online status and Session Manager became available again.

The exercise reinforced the value of secure remote administration without exposing inbound SSH access.

**Key lesson:** EC2 infrastructure health and Systems Manager agent health are separate. Both must be considered when investigating remote-management failures.

---

## 24. Skills Demonstrated

- Amazon EC2 troubleshooting
- AWS Systems Manager
- Session Manager administration
- SSM Agent troubleshooting
- IAM roles and instance profiles
- `AmazonSSMManagedInstanceCore`
- Linux systemd service management
- systemd timers
- AWS CLI v2
- IMDSv2
- Secure remote administration
- HTTPS endpoint troubleshooting
- Cloud incident investigation
- Root cause analysis
- Automatic recovery planning
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-013 |
| Problem | SSM Agent Connection Failure |
| Instance State | Running |
| Instance Profile | Attached |
| IAM Policy | AmazonSSMManagedInstanceCore |
| Simulated Root Cause | SSM Agent stopped |
| Session Manager During Failure | Unavailable |
| Remediation | Restart SSM Agent |
| Managed Node After Recovery | Online |
| Session Manager After Recovery | Working |
| Inbound SSH | Not required |
| Static AWS Credentials | Not required |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 instance is running but unavailable through Session Manager, investigate SSM Agent service status, IAM permissions, and the network path to Systems Manager. Restore the failed component, verify the managed node returns to Online, and confirm a new session can be established.

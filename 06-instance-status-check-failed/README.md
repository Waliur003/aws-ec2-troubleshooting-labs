# Lab 06 — Amazon EC2 Instance Status Check Failed

## Overview

This hands-on lab demonstrates how to investigate and recover from an Amazon EC2 instance-level reachability failure.

In this simulated production incident, an EC2 instance remains in the `running` state, but its operating-system networking becomes unavailable after the primary Linux network interface is administratively disabled.

The exercise uses AWS CLI, Amazon CloudWatch, Linux networking tools, SSH, and systemd to investigate the failure and restore connectivity.

**Root Cause:** Primary Linux network interface disabled.

**Remediation:** Restore the network interface or reboot the instance.

**Troubleshooting Workflow:**

Establish Baseline → Simulate Failure → Investigate → Root Cause Analysis → Recover → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-006 |
| AWS Services | EC2, CloudWatch, VPC |
| Primary Component | EC2 Instance Status Check |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Environment | Ubuntu Linux / WSL2 |
| Tools | AWS CLI v2, SSH, Bash, systemd |
| Simulated Failure | Primary Linux network interface disabled |
| Primary Symptom | Instance unreachable over SSH |
| Potential AWS Status | `InstanceStatus: impaired` |
| Recovery | Restore interface or reboot |
| Expected Result | Instance reachable; status checks OK |

**Important:** This lab reliably simulates a guest operating-system networking interruption. AWS status checks may or may not report an `impaired` state before the automatic recovery executes. Record the actual AWS status rather than assuming a particular result.

---

## 1. Production Incident Scenario

### Incident Description

An organization operates an EC2 instance hosting a business application.

The operations team discovers that the instance cannot be reached over the network.

The AWS Console shows that the instance is still running.

The team must determine whether the issue is caused by the AWS host infrastructure or the instance's guest operating system.

### Expected Behavior

```text
Instance State: running
System Status: ok
Instance Status: ok
SSH Connectivity: Successful
```

### Simulated Failure

```text
Instance State: running
Linux Network Interface: DOWN
SSH Connectivity: Unavailable
```

If the impairment is detected by EC2:

```text
System Status: ok
Instance Status: impaired
```

### Potential Business Impact

- Administrative SSH access unavailable
- Application network connectivity interrupted
- Failed application health checks
- Delayed maintenance or deployment
- Increased incident response time
- Possible application downtime

### Investigation Objective

Determine why the EC2 instance is unreachable, inspect its health signals, identify the operating-system networking problem, and restore normal operation.

---

## 2. Architecture

### Healthy Architecture

```text
            Cloud Engineer
              Ubuntu WSL2
                   |
                   | SSH TCP/22
                   v
                Internet
                   |
                   v
             Internet Gateway
                   |
                   v
              Public Subnet
                   |
                   v
             Security Group
              SSH Allowed
                   |
                   v
            Amazon EC2 Instance
                   |
                   v
           Linux Network Interface
                State: UP
                   |
                   v
             SSH Reachable

        System Status: OK
        Instance Status: OK
```

### Broken Architecture

```text
             Amazon EC2
             State: Running
                   |
                   v
          Amazon Linux 2023
                   |
                   v
         Primary Network Interface
                   |
                   X
             Interface DOWN
                   |
                   v
          Network Unreachable
                   |
                   v
           SSH Connection Fails

      Instance Status: May Be Impaired
```

### Recovery Architecture

```text
         Cloud Engineer / AWS CLI
                   |
                   v
        Network Recovery Procedure
                   |
          +--------+--------+
          |                 |
          v                 v
   systemd Timer        EC2 Reboot
          |                 |
          +--------+--------+
                   |
                   v
        Primary Interface Restored
                   |
                   v
          Network Connectivity
                   |
                   v
            SSH Successful
                   |
                   v
         EC2 Status Checks: OK
```

---

## 3. Understanding EC2 Status Checks

Amazon EC2 automatically performs status checks to detect problems that affect instances.

The main checks are system status and instance status.

### System Status Check

Monitors the infrastructure supporting the instance.

Examples of possible failures:

- Physical host hardware issues
- AWS infrastructure networking problems
- Power or host-level problems
- Underlying infrastructure faults

A failed system status check generally indicates an underlying AWS infrastructure issue.

### Instance Status Check

Monitors the software and network reachability of the instance.

Examples of possible failures:

- Incorrect Linux networking configuration
- Operating-system boot problems
- Kernel issues
- Memory exhaustion
- Filesystem problems
- Guest operating-system instability

A failed instance check can require operating-system troubleshooting or instance recovery.

### Status Check Comparison

| Check | Scope | Common Investigation |
|---|---|---|
| System | AWS host infrastructure | AWS infrastructure health and recovery |
| Instance | Guest operating system and reachability | OS networking, kernel, boot, resources |
| Attached EBS | Attached volume reachability and I/O | EBS volume health |

### Important EC2 Instance States

| State | Meaning |
|---|---|
| `pending` | Instance starting |
| `running` | Instance powered on |
| `stopping` | Instance shutting down |
| `stopped` | Instance stopped |
| `shutting-down` | Instance terminating |
| `terminated` | Instance permanently ended |

**Key concept:** An instance in `running` state is not necessarily healthy or reachable.

---

## 4. CloudWatch Status Check Metrics

Amazon CloudWatch exposes EC2 status-check metrics.

| Metric | Description |
|---|---|
| `StatusCheckFailed` | Overall status-check failure |
| `StatusCheckFailed_System` | AWS infrastructure status-check failure |
| `StatusCheckFailed_Instance` | Instance-level status-check failure |

### Metric Values

```text
0 = No failure recorded
1 = Failure recorded
```

These metrics can be used for monitoring, troubleshooting, and CloudWatch alarms.

Metrics are not necessarily published immediately. A short-lived network disruption may be recovered before a failed metric datapoint appears.

---

## 5. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- SSH client
- Bash
- Python 3
- Basic Linux networking knowledge
- EC2 and CloudWatch read permissions
- EC2 and VPC resource management permissions
- Git and GitHub

### Security Requirements

- Use a dedicated disposable instance.
- Never disable the network interface of a production server for testing.
- Restrict SSH access to a trusted public IP.
- Keep the private SSH key outside GitHub.
- Configure a recovery mechanism before disrupting networking.
- Confirm AWS account and instance tags before destructive commands.
- Remove test resources after completing the exercise.

### Cost Warning

EC2, EBS storage, public IPv4 addresses, and data transfer may incur charges.

---

## 6. Prepare the AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export INSTANCE_NAME="cloud-lab06-health-instance"
export SG_NAME="cloud-lab06-health-sg"
export KEY_NAME="cloud-lab06-health-key"
```

Verify your AWS account:

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
```

Verify:

```bash
echo "$VPC_ID"
```

### Step 3 — Identify a Supported Subnet

First list Availability Zones supporting `t3.micro`:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

List available default subnets:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

Select a default subnet located in a supported Availability Zone:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_YOUR_SUBNET_ID"
```

Replace the placeholder with your actual subnet ID.

Verify:

```bash
echo "$SUBNET_ID"
```

The selected subnet must have an effective route to an attached internet gateway for direct public SSH access.

---

## 7. Create SSH Credentials

### Step 1 — Prepare SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 2 — Configure Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab06-health-key.pem"
```

Before creating the key, verify that neither the local file nor the named AWS key pair already belongs to another workload.

```bash
test ! -e "$KEY_FILE" || echo "Key file already exists"
```

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new lab, `InvalidKeyPair.NotFound` is expected.

### Step 3 — Generate EC2 Key Pair

Only when both are unused:

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$KEY_FILE"
```

Protect it:

```bash
chmod 400 "$KEY_FILE"
```

Verify:

```bash
ls -l "$KEY_FILE"
```

Never upload the private key to GitHub.

---

## 8. Create the Security Group

### Step 1 — Get Client Public IP

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Verify:

```bash
echo "$MY_IP"
```

### Step 2 — Check for Existing Security Group

```bash
aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

Create only if the name is not already in use.

### Step 3 — Create Dedicated Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "EC2 Lab06 health check troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow SSH From Trusted IP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Step 5 — Verify

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected rule:

```text
Protocol: TCP
Port: 22
Source: CLIENT_PUBLIC_IP/32
```

---

## 9. Launch a Healthy EC2 Instance

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for Existing Lab Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate if an instance already exists for this lab.

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
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab06-health-instance},{Key=Project,Value=EC2-Troubleshooting-Lab06}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$INSTANCE_ID"
```

### Step 4 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Wait for Healthy Status Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Inspect Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{Instance:InstanceId,System:SystemStatus.Status,InstanceHealth:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
System: ok
InstanceHealth: ok
```

### Step 7 — Retrieve Public IPv4

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

## 10. Verify the Working Baseline

### Step 1 — Connect to EC2

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

For production systems, independently verify SSH host-key fingerprints before trusting a new host.

### Step 2 — Verify Linux Networking

Inside EC2:

```bash
hostname
```

```bash
ip -br addr
```

```bash
ip route
```

Expected: a primary network interface with an assigned private IPv4 address and a default route.

### Step 3 — Exit

```bash
exit
```

The baseline confirms that the instance was accessible before the failure simulation.

---

## 11. Introduce the Failure

**Warning:** The following commands intentionally interrupt network connectivity. Run them only on the isolated disposable instance.

### Step 1 — Connect to EC2

```bash
ssh \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

### Step 2 — Identify Primary Interface

Inside EC2:

```bash
ip -o -4 route show default
```

Example:

```text
default via 172.31.0.1 dev ens5
```

Extract the interface name:

```bash
export IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
```

Verify:

```bash
echo "$IFACE"
```

Inspect:

```bash
ip link show "$IFACE"
```

### Step 3 — Prepare Automatic Network Restoration

Locate the network-management command:

```bash
export IP_BIN=$(command -v ip)
```

Schedule a one-time recovery task:

```bash
sudo systemd-run \
  --unit=lab06-restore-network \
  --on-active=3min \
  "$IP_BIN" link set dev "$IFACE" up
```

Verify the timer:

```bash
systemctl list-timers --all | grep lab06
```

Do not introduce the failure unless the recovery timer is visible.

The timer provides an automatic recovery attempt. It does not guarantee complete recovery in every network configuration.

### Step 4 — Disable the Primary Network Interface

```bash
sudo ip link set dev "$IFACE" down
```

### Expected Result

- SSH becomes unresponsive or disconnects.
- The network interface is disabled.
- The EC2 instance may remain running.
- Instance reachability is interrupted.

This intentionally creates an operating-system networking failure.

---

## 12. Troubleshooting Investigation

Run the following AWS commands from Ubuntu WSL2.

### Check 1 — Inspect EC2 State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected during the network interruption:

```text
running
```

### Check 2 — Inspect Instance Status

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,InstanceHealth:InstanceStatus.Status,Details:InstanceStatus.Details}' \
  --output json \
  --region "$AWS_REGION"
```

Possible observation if AWS detects the disruption:

```json
[
  {
    "System": "ok",
    "InstanceHealth": "impaired",
    "Details": [
      {
        "Name": "reachability",
        "Status": "failed"
      }
    ]
  }
]
```

This JSON is illustrative, not a recorded output.

If AWS continues to report `ok`, the lab still demonstrates a guest network outage; it simply did not produce a confirmed EC2 instance-status failure during the observation period.

### Check 3 — Query CloudWatch Instance Status Metric

Set a time window:

```bash
export START_TIME=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
export END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

Retrieve metric data:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed_Instance \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 60 \
  --statistics Maximum \
  --region "$AWS_REGION"
```

Interpretation:

```text
Maximum = 0: No failure recorded
Maximum = 1: Failure recorded
```

An empty `Datapoints` array means no datapoints were returned for the requested period. It does not prove the instance was healthy.

### Check 4 — Compare System Status

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed_System \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 60 \
  --statistics Maximum \
  --region "$AWS_REGION"
```

Expected: no infrastructure failure recorded in this deliberately induced guest networking scenario.

### Check 5 — Retrieve EC2 Console Output

```bash
aws ec2 get-console-output \
  --instance-id "$INSTANCE_ID" \
  --latest \
  --query Output \
  --output text \
  --region "$AWS_REGION"
```

Console output may contain boot or kernel messages.

It may not include evidence of the manually disabled network interface.

### Investigation Summary

| Check | Expected or Possible Finding |
|---|---|
| EC2 state | Running |
| Linux interface | Disabled |
| SSH | Unreachable |
| AWS system status | Expected OK |
| AWS instance status | May become impaired |
| CloudWatch instance failure metric | May record 1 |
| Console output | May contain additional diagnostics |
| Primary cause | Linux network interface disabled |

---

## 13. Root Cause Analysis

### Root Cause

The primary network interface was administratively disabled inside the Amazon Linux operating system.

### Technical Explanation

The EC2 virtual machine continues to operate, but its guest operating system is unable to communicate normally through the disabled primary interface.

This can interrupt SSH, application traffic, and operating-system reachability.

If AWS detects the impairment during a status-check interval, it may report an instance-level reachability failure.

### Root Cause Flow

```text
EC2 Instance Running
         |
         v
Linux Network Interface Identified
         |
         v
ip link set dev INTERFACE down
         |
         v
Guest Networking Interrupted
         |
         v
SSH Connection Lost
         |
         v
Instance-Level Reachability Failure
         |
         v
Possible StatusCheckFailed_Instance
```

### Five Whys

1. **Why was the instance unreachable?** Its networking was interrupted.
2. **Why was networking interrupted?** The primary Linux interface was disabled.
3. **Why did that affect SSH?** SSH depends on network connectivity to the instance.
4. **Why could EC2 still show `running`?** Running state does not guarantee guest network reachability.
5. **How can this be prevented?** Use controlled network changes, tested configurations, monitoring, and recovery procedures.

---

## 14. Apply Remediation

### Recovery Method 1 — Automatic Interface Restoration

The systemd timer was configured before disabling networking.

It attempts to execute the equivalent of:

```bash
sudo ip link set dev "$IFACE" up
```

After the recovery task runs, test SSH from WSL2:

```bash
timeout 10 bash -c \
  "echo > /dev/tcp/$PUBLIC_IP/22"
```

Retry the connection:

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

If the connection succeeds, inspect:

```bash
ip -br link
```

```bash
ip route
```

Check the recovery service:

```bash
sudo systemctl status lab06-restore-network.service --no-pager
```

Exit:

```bash
exit
```

### Recovery Method 2 — EC2 Reboot

If the instance remains unreachable, reboot the dedicated lab instance:

```bash
aws ec2 reboot-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

The temporary `ip link` change normally does not persist across reboot.

Wait for healthy status checks:

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Reboot Considerations

- Reboot interrupts running workloads.
- Reboot normally preserves the instance's public IPv4 address.
- Reboot does not repair every type of network failure.
- Production systems require change-management and recovery procedures.

If reboot does not work, investigate instance console output and consider a stop/start operation where appropriate.

An EC2 stop/start can change a non-Elastic public IPv4 address.

---

## 15. Verify Successful Recovery

### Test 1 — Instance State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
running
```

### Test 2 — System and Instance Status

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

### Test 3 — SSH Connectivity

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP" \
  'hostname && ip -br link && ip route'
```

Expected:

- SSH connection succeeds.
- Hostname is displayed.
- Primary interface is enabled.
- Default network route exists.

### Test 4 — CloudWatch Metric

Query the instance status metric again using a time window that includes the recovery period.

A healthy datapoint is represented by:

```text
StatusCheckFailed_Instance = 0
```

A historical failed datapoint, if recorded, can remain visible after recovery.

### Verification Summary

| Test | During Failure | After Recovery |
|---|---|---|
| EC2 state | Running | Running |
| Linux interface | Down | Up |
| SSH connectivity | Failed | Successful |
| System status | Expected OK | OK |
| Instance status | Possibly impaired | OK |
| CloudWatch failure metric | Possibly 1 | 0 |
| Network route | Unavailable to the guest while interface down | Restored |

The incident is resolved when network reachability is restored, SSH access succeeds, and EC2 reports healthy status checks.

---

## 16. Production Engineering Considerations

### Common Causes of Instance Status Check Failures

- Incorrect operating-system network configuration
- Kernel panic
- Operating-system boot failure
- Memory exhaustion
- Filesystem corruption
- Incorrect system configuration
- Failed critical operating-system services

### Recommended Troubleshooting Order

1. Confirm the instance state.
2. Inspect system and instance status checks separately.
3. Identify the failing status-check category.
4. Review CloudWatch metrics.
5. Retrieve EC2 console output.
6. Investigate recent configuration changes.
7. Examine operating-system networking.
8. Inspect kernel and system logs where available.
9. Apply an appropriate recovery method.
10. Verify EC2 health and application connectivity.

### Useful Linux Commands

| Command | Purpose |
|---|---|
| `ip -br addr` | Display network addresses |
| `ip -br link` | Display interface states |
| `ip route` | Display routing table |
| `ip link show` | Inspect network interface |
| `journalctl` | Inspect systemd journal |
| `systemctl status` | Inspect service health |
| `ss -lntp` | Inspect listening TCP ports |
| `dmesg` | Inspect kernel messages |

### Prevention Strategies

- Avoid untested network changes.
- Use infrastructure-as-code for repeatable configuration.
- Monitor EC2 status-check metrics.
- Create appropriate recovery alarms.
- Maintain backups and snapshots.
- Use redundant instances for critical workloads.
- Document recovery procedures.
- Test networking changes in staging environments.

### Production Recovery

For high-availability applications, consider deploying multiple instances across Availability Zones behind a load balancer.

Replacing unhealthy instances through an Auto Scaling group can be more reliable than relying entirely on manual recovery.

---

## 17. Related EC2 Problems

| Symptom | Possible Cause |
|---|---|
| `SystemStatus: impaired` | AWS underlying infrastructure problem |
| `InstanceStatus: impaired` | Guest operating-system or reachability problem |
| SSH connection timed out | Network path or guest networking failure |
| SSH permission denied | Authentication failure |
| Instance stuck in pending | Launch or boot issue |
| HTTP application unavailable | Application or network problem |
| EBS status impaired | Volume reachability or I/O problem |

---

## 18. Interview Questions and Answers

### Q1. What is the difference between a system status check and an instance status check?

System status checks monitor AWS infrastructure. Instance status checks monitor guest operating-system and network reachability.

### Q2. Can an EC2 instance be running but unhealthy?

Yes. The running state does not guarantee successful OS boot, network reachability, or application availability.

### Q3. What does `StatusCheckFailed_Instance = 1` mean?

CloudWatch recorded an instance-level status-check failure during that metric period.

### Q4. What is a common cause of an instance status-check failure?

Operating-system networking misconfiguration, boot problems, kernel failures, or resource exhaustion.

### Q5. How can you troubleshoot an unreachable EC2 instance without SSH?

Use the EC2 API, status-check details, CloudWatch metrics, console output, and approved recovery access mechanisms.

### Q6. What happens when you disable the primary Linux network interface?

Network connectivity through that interface is interrupted, potentially disconnecting SSH and application traffic.

### Q7. Does rebooting an EC2 instance change its instance ID?

No. A reboot retains the same instance ID.

### Q8. What is the difference between reboot and stop/start?

Reboot restarts the guest OS on the instance. Stop/start stops and relaunches an EBS-backed instance and can move it to another underlying host. A non-Elastic public IPv4 address can change after stop/start.

### Q9. Why monitor both system and instance status checks?

They help identify whether a failure is related to AWS infrastructure or the guest operating system.

### Q10. How would you explain this incident in an interview?

> I investigated an EC2 instance that remained in the running state but became unreachable because its primary Linux network interface had been disabled. I verified the instance state, inspected AWS status-check details, and queried CloudWatch health metrics. I identified the guest networking change as the cause of the connectivity failure. I then restored the interface using a preconfigured recovery mechanism, with an EC2 reboot available as a fallback. Finally, I verified that both status checks returned to OK and SSH connectivity was restored.

---

## 19. Cleanup

**Warning:** Confirm that all resources belong to Lab 06 before performing destructive operations.

### Step 1 — Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Instance Tags

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project: EC2-Troubleshooting-Lab06
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify the root volume's deletion setting:

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
```

Wait:

```bash
aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Check Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Ensure no dependencies remain.

### Step 6 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete EC2 Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Local Private Key

```bash
rm -f "$KEY_FILE"
```

Only remove the key created specifically for Lab 06.

### Step 9 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If deleted, AWS returns:

```text
InvalidVolume.NotFound
```

If the volume remains in the `available` state, verify it belongs exclusively to Lab 06 before deleting it:

```bash
aws ec2 delete-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Confirm Termination

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

Keep the default VPC and subnets for future troubleshooting labs.

---

## 20. Repository Structure

```text
06-instance-status-check-failed/
│
└── README.md
```

The lab documents the full controlled failure, investigation, recovery, and cleanup using AWS CLI and Linux commands.

No application source files are required.

Do not commit SSH private keys, AWS credentials, or temporary resource metadata.

---

## 21. Lessons Learned

This lab demonstrated that an EC2 instance can remain in the `running` state while its guest operating system loses network connectivity.

The investigation covered EC2 status-check details, CloudWatch metrics, SSH connectivity, network interface configuration, and console diagnostics.

The recovery process included restoring the primary Linux network interface through a scheduled systemd task, with an EC2 reboot available as a fallback.

The exercise also demonstrated why status-check metrics and actual application connectivity must be interpreted together.

The key lesson is that EC2 power state, operating-system reachability, and application health are separate concerns.

---

## 22. Skills Demonstrated

- Amazon EC2 troubleshooting
- EC2 system and instance status checks
- Amazon CloudWatch metrics
- Linux network administration
- Network interface troubleshooting
- SSH connectivity diagnostics
- Linux systemd recovery
- AWS CLI v2
- Bash
- Incident investigation
- Root cause analysis
- Infrastructure recovery
- Production monitoring concepts
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-006 |
| Problem | EC2 Instance Reachability Failure |
| Simulated Root Cause | Primary Linux interface disabled |
| Instance State | Running |
| SSH During Failure | Unavailable |
| Instance Status Check | May report impaired |
| Remediation | Restore interface or reboot |
| Recovered System Status | OK |
| Recovered Instance Status | OK |
| SSH After Recovery | Successful |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 instance is running but unreachable, investigate its guest operating system and network configuration, review AWS status checks and CloudWatch metrics, and verify recovery using both infrastructure and connectivity tests.

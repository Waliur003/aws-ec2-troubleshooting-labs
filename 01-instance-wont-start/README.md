# Lab 01 — Amazon EC2 Instance Won't Start

## Overview

This hands-on lab demonstrates how to troubleshoot an Amazon EC2 instance that cannot start because its EBS root volume is detached.

An EC2 instance depends on its root volume to load the operating system. If the required root volume is missing, EC2 may reject the startup operation.

In this production-inspired incident, we create a working EC2 instance, stop it, deliberately detach its root EBS volume, reproduce the startup failure, investigate the missing attachment, and restore the original volume.

**Troubleshooting workflow:**

Establish Baseline → Simulate Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| AWS Service | Amazon EC2 |
| Supporting Service | Amazon EBS |
| Incident ID | INC-EC2-001 |
| Difficulty | Beginner–Intermediate |
| Error | Instance does not have a volume attached at root |
| Failed API | `StartInstances` |
| Root Cause | Detached EBS root volume |
| Remediation | Reattach the original root volume |
| Environment | Ubuntu Linux (WSL2) |
| Tools | AWS CLI v2, Bash |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Verification | Running state and EC2 status checks |

---

## 1. Production Incident Scenario

### Incident Description

A Cloud Operations team stops an EC2 instance for scheduled maintenance.

During the maintenance process, its EBS root volume becomes detached.

When the team attempts to restart the instance, the startup operation fails.

### Reported Error

```text
An error occurred (InvalidParameterValue)
when calling the StartInstances operation:

Instance does not have a volume attached at root
```

The exact AWS error code or message can vary.

### Expected Behavior

The EC2 instance should transition from:

```text
stopped → pending → running
```

Both EC2 status checks should eventually report `ok`.

### Actual Behavior

The instance cannot start because its required root EBS volume is missing.

### Potential Business Impact

- Application downtime
- Unavailable compute resources
- Delayed maintenance recovery
- Service disruption
- Increased recovery time

### Investigation Objective

Determine why EC2 cannot start and restore the original root volume without losing its data.

---

## 2. Architecture

### Working Environment

```text
Amazon EC2 Instance
        |
        | Root device: /dev/xvda
        v
Amazon EBS Root Volume
        |
        v
Operating System Available
        |
        v
Instance Running
        |
        v
Status Checks: OK
```

### Broken Environment

```text
Amazon EC2 Instance
        |
        | StartInstances
        v
Expected Root Device
        |
        X
Root EBS Volume Detached
        |
        v
Startup Failure
```

### Recovered Environment

```text
Cloud Engineer
        |
        | AttachVolume
        v
Original Root EBS Volume
        |
        | Correct Device Name
        v
Amazon EC2 Instance
        |
        | StartInstances
        v
Running
        |
        v
System Status: OK
Instance Status: OK
```

---

## 3. Understanding EC2 Instance States

Amazon EC2 instances transition through several states.

| State | Description |
|---|---|
| `pending` | Instance is preparing to start |
| `running` | Instance is running |
| `stopping` | Instance is shutting down |
| `stopped` | Instance is stopped |
| `shutting-down` | Instance is terminating |
| `terminated` | Instance has been terminated |

### Stopping vs Terminating

**Stop:** Shuts down an EBS-backed instance while retaining its EBS volumes, subject to their configuration and subsequent changes.

**Terminate:** Permanently ends the instance. Attached EBS volumes may be deleted depending on their `DeleteOnTermination` settings.

### Why the Root Volume Matters

The root EBS volume contains the operating system and files required for booting an EBS-backed EC2 instance.

A missing or incorrectly attached root volume can prevent successful startup.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- EC2 and EBS management permissions
- Access to a VPC and subnet
- Git and GitHub

### Security and Cost Considerations

- Use a dedicated disposable instance.
- Never detach a production root volume for testing.
- Do not enable unnecessary public access.
- Avoid opening SSH to `0.0.0.0/0`.
- Monitor EC2 and EBS costs.
- Terminate the test instance after completion.
- Verify whether the EBS root volume was deleted.

### Configure AWS Variables

```bash
export AWS_REGION="us-east-1"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

export INSTANCE_NAME="cloud-lab01-instance"
```

Verify AWS credentials:

```bash
aws sts get-caller-identity
```

---

## 5. Identify the EC2 Environment

### Step 1 — Retrieve the Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query 'Parameter.Value' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$AMI_ID"
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

If the output is `None`, the Region does not have a default VPC.

For an authorized sandbox account without a default VPC, one option is:

```bash
aws ec2 create-default-vpc \
  --region "$AWS_REGION"
```

Re-run the VPC lookup after creation.

**Important:** The default VPC is account infrastructure, not a temporary EC2 instance resource. Do not delete it during this lab's cleanup.

### Step 3 — Identify the Default Subnets

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Verify Instance Type Availability

Not every instance type is supported in every Availability Zone.

Check where `t3.micro` is offered:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Select a Supported Subnet

For this lab, choose an existing default subnet from a supported Availability Zone.

For example:

```bash
export SUBNET_ID=$(aws ec2 describe-subnets \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=default-for-az,Values=true" \
  --query "Subnets[?AvailabilityZone=='us-east-1a' || AvailabilityZone=='us-east-1b' || AvailabilityZone=='us-east-1c' || AvailabilityZone=='us-east-1d' || AvailabilityZone=='us-east-1f'] | [0].SubnetId" \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$SUBNET_ID"
```

This example reflects the supported-zone alternatives reported during the exercise. For another account or Region, use the actual output of `describe-instance-type-offerings`.

### Step 6 — Identify the Default Security Group

```bash
export SG_ID=$(aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=default" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$SG_ID"
```

---

## 6. Launch the EC2 Instance

### Step 1 — Check for an Existing Lab Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate if a test instance already exists.

### Step 2 — Launch the Instance

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --no-associate-public-ip-address \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab01-instance},{Key=Project,Value=EC2-Troubleshooting-Lab01}]' \
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

Verify:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone}' \
  --output table \
  --region "$AWS_REGION"
```

Expected state: `running`.

---

## 7. Verify the Working Baseline

### Step 1 — Wait for Status Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Inspect Status Checks

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{Instance:InstanceId,InstanceStatus:InstanceStatus.Status,SystemStatus:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
InstanceStatus: ok
SystemStatus: ok
```

### Step 3 — Identify the Root Device

```bash
export ROOT_DEVICE=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].RootDeviceName' \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$ROOT_DEVICE"
```

Typical value:

```text
/dev/xvda
```

### Step 4 — Identify the Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE}'].Ebs.VolumeId | [0]" \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$ROOT_VOLUME_ID"
```

### Step 5 — Inspect Volume Attachment

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{Volume:VolumeId,State:State,Device:Attachments[0].Device,AttachmentState:Attachments[0].State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: in-use
AttachmentState: attached
```

### Step 6 — Record Lab Identifiers

```bash
printf 'INSTANCE_ID=%s\nROOT_VOLUME_ID=%s\nROOT_DEVICE=%s\nAWS_REGION=%s\n' \
  "$INSTANCE_ID" "$ROOT_VOLUME_ID" "$ROOT_DEVICE" "$AWS_REGION" \
  > lab-resources.txt
```

Keep `lab-resources.txt` locally. It is not required in the public repository.

---

## 8. Introduce the Startup Failure

**Warning:** The following actions affect the operating-system volume. Perform them only on a disposable EC2 instance created for this lab.

### Step 1 — Verify the Instance Tag

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the project tag is:

```text
EC2-Troubleshooting-Lab01
```

### Step 2 — Stop the Instance

```bash
aws ec2 stop-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Wait for Stopped State

```bash
aws ec2 wait instance-stopped \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
stopped
```

### Step 4 — Detach the Root EBS Volume

Only after confirming the instance is stopped:

```bash
aws ec2 detach-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Wait for Volume Availability

```bash
aws ec2 wait volume-available \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Volume Is Detached

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{Volume:VolumeId,State:State,Attachments:Attachments}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
State: available
Attachments: []
```

The volume still exists, but it is no longer attached to the EC2 instance.

---

## 9. Reproduce the Failure

Attempt to start the EC2 instance:

```bash
aws ec2 start-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Expected Error

```text
An error occurred (InvalidParameterValue)
when calling the StartInstances operation:

Instance does not have a volume attached at root
```

The exact response may differ.

### Why Startup Fails

The instance expects its operating-system volume at the configured root device.

Because that volume has been detached, the required root attachment is missing.

---

## 10. Troubleshooting Investigation

### Check 1 — Inspect Instance State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{Instance:InstanceId,State:State.Name,Reason:StateReason}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 2 — Inspect Root Device Mapping

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{RootDevice:RootDeviceName,Mappings:BlockDeviceMappings}' \
  --output json \
  --region "$AWS_REGION"
```

### Check 3 — Inspect EBS Volume

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{Volume:VolumeId,State:State,AZ:AvailabilityZone,Attachments:Attachments}' \
  --output json \
  --region "$AWS_REGION"
```

Expected finding:

```text
Volume state: available
No active attachment
```

### Investigation Findings

| Component | Working Baseline | Failed Environment |
|---|---|---|
| EC2 state | Running | Stopped |
| Root device | Configured | Missing attachment |
| EBS volume | In use | Available |
| Attachment | Attached | Detached |
| StartInstances | Successful | Rejected |
| Primary cause | None | Missing root EBS attachment |

---

## 11. Root Cause Analysis

### Root Cause

The EC2 instance cannot start because its EBS root volume was detached while the instance was stopped.

### Technical Explanation

An EBS-backed EC2 instance requires its operating-system root volume to be attached under the correct device name.

If this attachment is missing, EC2 cannot complete the normal startup operation.

### Root Cause Flow

```text
EC2 Instance Running
         |
         v
Instance Stopped
         |
         v
Root EBS Volume Detached
         |
         v
StartInstances Requested
         |
         v
Root Volume Attachment Missing
         |
         v
Startup Rejected
```

### Five Whys

1. **Why did the EC2 instance fail to start?** Its required root volume was not attached.
2. **Why was the root volume missing?** It had been detached during the simulated maintenance operation.
3. **Why did the missing attachment matter?** The instance needs its operating-system root volume to start.
4. **Why wasn't the issue resolved by repeating StartInstances?** Restarting cannot restore a missing EBS attachment.
5. **How can this be prevented?** Validate root volume attachments before restarting instances after storage maintenance.

---

## 12. Apply Remediation

### Step 1 — Verify Resource IDs

```bash
echo "$INSTANCE_ID"
echo "$ROOT_VOLUME_ID"
echo "$ROOT_DEVICE"
```

Confirm the volume belongs to the intended instance and remains in the correct Availability Zone.

### Step 2 — Reattach the Root Volume

```bash
aws ec2 attach-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device "$ROOT_DEVICE" \
  --region "$AWS_REGION"
```

**Important:** Use the original root device name recorded before the failure.

### Step 3 — Wait for Attachment

```bash
aws ec2 wait volume-in-use \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Attachment

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{Volume:VolumeId,State:State,Instance:Attachments[0].InstanceId,Device:Attachments[0].Device,AttachmentState:Attachments[0].State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: in-use
AttachmentState: attached
Device: Original root device
```

### Step 5 — Restart the Instance

```bash
aws ec2 start-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

---

## 13. Verify Successful Recovery

### Test 1 — Check Instance State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{Instance:InstanceId,State:State.Name,RootDevice:RootDeviceName}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: running
```

### Test 2 — Verify Status Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Then:

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{InstanceStatus:InstanceStatus.Status,SystemStatus:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
InstanceStatus: ok
SystemStatus: ok
```

### Test 3 — Verify Root Attachment

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{State:State,Device:Attachments[0].Device,Instance:Attachments[0].InstanceId}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: in-use
```

### Verification Summary

| Test | Before Fix | After Fix |
|---|---|---|
| Root EBS attachment | Missing | Attached |
| Volume state | Available | In use |
| StartInstances | Rejected | Successful |
| Instance state | Stopped | Running |
| System status | Not applicable while stopped | OK |
| Instance status | Not applicable while stopped | OK |

**Recovery is successful when the original root volume is attached and the instance starts with healthy status checks.**

---

## 14. Additional EC2 Launch Troubleshooting

During environment setup, the `t3.micro` instance type was unavailable in the initially selected Availability Zone.

### Encountered Error

```text
Unsupported:

Your requested instance type (t3.micro)
is not supported in Availability Zone (us-east-1e).
```

### Investigation

Use:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Remediation

Select a subnet in an Availability Zone that supports the requested instance type.

### Lesson Learned

An EC2 launch can fail even when the AMI and instance type are individually valid if the chosen Availability Zone does not offer that instance type.

This is a separate issue from the root EBS volume failure simulated in the main lab.

---

## 15. Production Engineering Considerations

### Incident Triage

When an EC2 instance does not start, investigate:

- Current instance state
- `StartInstances` error
- Instance state reason
- Root device configuration
- EBS volume existence
- EBS attachment status
- Availability Zone alignment
- EBS encryption and KMS permissions
- EBS volume health
- EC2 service events
- Instance limits and capacity

### Useful AWS CLI Commands

| Command | Purpose |
|---|---|
| `describe-instances` | Inspect instance state and root mapping |
| `describe-instance-status` | Check instance health |
| `describe-volumes` | Inspect EBS volume state |
| `describe-volume-status` | Inspect EBS volume health |
| `stop-instances` | Stop an instance |
| `detach-volume` | Detach an EBS volume |
| `attach-volume` | Attach an EBS volume |
| `start-instances` | Start an instance |
| `wait instance-status-ok` | Wait for healthy status checks |

### Production Safety

Never detach a root volume from a production instance without an approved maintenance procedure and recovery plan.

For important systems, consider:

- EBS snapshots
- Verified backups
- Maintenance windows
- Documented recovery procedures
- Instance monitoring
- Change approval
- Least-privilege IAM permissions

---

## 16. Prevention Strategies

### Monitor EBS Attachments

Track unexpected volume attachment changes through appropriate AWS monitoring and audit controls.

### Use Change Management

Require review and approval for storage maintenance activities.

### Take Recovery Snapshots

Create appropriate EBS snapshots before high-risk storage operations.

### Record Root Device Names

Maintain accurate documentation of root-volume attachments.

### Avoid Unnecessary Manual Detachment

Use automation and approved workflows wherever possible.

### Verify Recovery

After maintenance, check instance state, status checks, and application functionality.

---

## 17. Related EC2 Errors

| Error or Symptom | Possible Cause |
|---|---|
| Root volume not attached | Missing EBS root attachment |
| Unsupported instance type | Instance type unavailable in selected AZ |
| InsufficientInstanceCapacity | Insufficient capacity |
| UnauthorizedOperation | Missing EC2 or IAM permission |
| VolumeInUse | Volume already attached |
| InvalidVolume.NotFound | Incorrect or deleted volume ID |
| Instance status check failed | OS or instance-level problem |
| System status check failed | Underlying AWS infrastructure issue |

---

## 18. Interview Questions and Answers

### Q1. Why might an EC2 instance fail to start?

Possible causes include missing root volumes, unsupported configurations, insufficient capacity, authorization problems, and other AWS resource issues.

### Q2. What is an EC2 root volume?

It is the storage volume containing the operating system used to boot an EBS-backed instance.

### Q3. Can you detach the root EBS volume?

Yes, from a stopped EBS-backed instance, subject to applicable AWS restrictions.

### Q4. Why must you use the original root device name?

The EC2 instance expects its boot volume to be attached using the configured root device mapping.

### Q5. What is the difference between an EBS volume in `available` and `in-use` states?

`available` indicates the volume is not attached. `in-use` indicates it has an attachment.

### Q6. What is the difference between EC2 system and instance status checks?

System checks monitor underlying infrastructure. Instance checks monitor instance-level reachability.

### Q7. What does `InvalidVolume.NotFound` mean?

The specified EBS volume ID cannot be found in the requested account and Region, or the volume has been deleted.

### Q8. Why might `t3.micro` fail to launch in one Availability Zone?

The instance type may not be offered in that Availability Zone for the account.

### Q9. What should you verify after reattaching a root volume?

Check the attachment status, device mapping, instance state, and EC2 health checks.

### Q10. How would you explain this incident in an interview?

> An EC2 instance failed to start after a maintenance operation. I inspected the instance state and root device mapping using AWS CLI. Then I examined the associated EBS volume and found that it was detached. I confirmed the original device name, reattached the volume to the stopped instance, and restarted EC2. Finally, I verified that the instance reached the running state and both status checks passed.

---

## 19. Cleanup

**Warning:** These actions permanently remove the disposable EC2 lab instance and may remove its root EBS volume.

### Step 1 — Verify AWS Account and Instance

```bash
aws sts get-caller-identity

echo "$INSTANCE_ID"
echo "$ROOT_VOLUME_ID"
```

### Step 2 — Inspect DeleteOnTermination

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE}'].Ebs.DeleteOnTermination | [0]" \
  --output text \
  --region "$AWS_REGION"
```

If `true`, the root volume is configured for deletion upon instance termination.

Do not assume a manually reattached volume is always configured for automatic deletion.

### Step 3 — Terminate Instance

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

### Step 5 — Inspect Root EBS Volume

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Possible results:

- `InvalidVolume.NotFound` — the volume was deleted.
- `available` — the volume still exists.

### Step 6 — Delete Remaining Lab Volume

If the root volume remains `available` and you have verified it belongs exclusively to this exercise:

```bash
aws ec2 delete-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Do not attempt to delete an EBS volume attached to another instance.

### Step 7 — Confirm Cleanup

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

Verify the EBS volume no longer exists.

### Step 8 — Remove Local Temporary Metadata

```bash
rm -f lab-resources.txt
```

Keep the default VPC and default subnets for future labs.

---

## 20. Repository Structure

```text
01-instance-wont-start/
│
└── README.md
```

All commands needed for the exercise are documented in this README.

No AWS credentials, instance identifiers, or temporary resource metadata should be committed.

---

## 21. Lessons Learned

This lab demonstrated how an Amazon EC2 instance can fail to start when its EBS root volume is detached.

The investigation involved inspecting EC2 instance states, identifying root device mappings, examining EBS volume attachments, and reproducing the startup failure.

The recovery process required attaching the original root volume to the correct instance and device name, restarting EC2, and verifying the instance's health checks.

The lab also introduced a separate EC2 launch issue involving instance-type Availability Zone compatibility.

The key lesson is to investigate EC2 dependencies instead of repeatedly attempting to start a failing instance without understanding the error.

---

## 22. Skills Demonstrated

- Amazon EC2 troubleshooting
- Amazon EBS
- EC2 instance lifecycle management
- Root volume identification
- EBS attachment diagnostics
- AWS CLI v2
- Linux Bash
- EC2 status checks
- Availability Zone troubleshooting
- Root cause analysis
- Infrastructure recovery
- AWS resource cleanup
- Production incident documentation

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-001 |
| AWS Services | EC2 + EBS |
| Primary Failure | Missing root EBS attachment |
| Root Cause | Detached operating-system volume |
| Remediation | Reattach original root volume |
| Instance Startup | Successful |
| Instance Status Check | OK |
| System Status Check | OK |
| Resource Cleanup | Instance terminated, EBS removed |
| Expected Lab Status | Resolved |

**Key Takeaway:** When an EC2 instance fails to start, investigate its instance state, root device mapping, EBS attachments, and AWS error message. Restore the missing dependency and verify recovery before closing the incident.

# Lab 07 — Amazon EC2 EBS Root Volume Full

## Overview

This hands-on lab demonstrates how to troubleshoot high root filesystem utilization on an Amazon EC2 Linux instance.

An EC2 instance uses its EBS root volume to store operating-system files, application data, logs, and other information. When available filesystem space becomes low, applications may fail to write files, logging may stop, and services may become unstable.

In this simulated production incident, we launch an Amazon Linux 2023 instance with a 12-GiB root EBS volume, create a controlled disk-pressure condition, investigate storage utilization, identify the cause, and implement two recovery methods.

**Recovery Method A:** Remove a known disposable file to recover disk space.

**Recovery Method B:** Increase EBS volume size from 12 GiB to 16 GiB, then expand the Linux partition and filesystem.

The lab follows a production-style troubleshooting process:

Baseline → Simulate Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-007 |
| AWS Services | Amazon EC2, Amazon EBS |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Initial EBS Volume | 12 GiB |
| Expanded EBS Volume | 16 GiB (optional) |
| Volume Type | gp3 |
| Filesystem | XFS or ext4, verified on instance |
| Problem | High root filesystem utilization |
| Simulated Cause | Large temporary file |
| Recovery A | Remove temporary file |
| Recovery B | Expand EBS and filesystem |
| Tools | AWS CLI v2, SSH, Bash, Linux utilities |
| Environment | Ubuntu WSL2 |

**Important:** This exercise simulates elevated storage utilization rather than guaranteeing a completely full filesystem or an actual `ENOSPC` error. The allocation is deliberately bounded to preserve operating-system functionality.

---

## 1. Production Incident Scenario

### Incident Description

A company operates a Linux EC2 instance supporting an application.

The monitoring team detects high root filesystem utilization.

The infrastructure team must investigate the storage issue before the instance runs out of available disk space.

### Observed Symptom

```text
EC2 State: running
EBS Root Volume: 12 GiB
Root Filesystem: High Utilization
Available Space: Reduced
```

### Potential Error if the Filesystem Becomes Full

```text
No space left on device
```

This message is a possible production symptom, not an error that the lab intentionally forces.

### Expected Behavior

The root filesystem should have sufficient free space for operating-system and application operations.

### Potential Business Impact

- Application write failures
- Failed deployments
- Logging interruptions
- Database write failures
- Failed temporary-file creation
- Service crashes
- Increased latency
- Application downtime

### Investigation Objective

Determine which files or directories consume the available storage and recover sufficient disk capacity without damaging important operating-system or application data.

---

## 2. Architecture

### Healthy Environment

```text
             Amazon EC2
           Amazon Linux 2023
                   |
                   v
           Root EBS Volume
                12 GiB
                   |
                   v
           Linux Filesystem
                   |
                   v
            Free Space
                   |
                   v
          Applications Running
```

### Simulated Disk Pressure

```text
             Amazon EC2
                   |
                   v
          EBS Root Volume
               12 GiB
                   |
                   v
          Linux Filesystem /
                   |
                   v
       /var/tmp/ec2-lab07/
           disk-pressure.bin
                   |
                   v
          High Disk Utilization
                   |
                   v
        Reduced Free Disk Space
```

### Recovery Architecture

```text
           High Disk Utilization
                    |
           +--------+--------+
           |                 |
           v                 v
    Remove Large File   Increase EBS Size
           |                 |
           v                 v
      Free Space       12 GiB → 16 GiB
                             |
                             v
                       Grow Partition
                             |
                             v
                       Grow Filesystem
           |                 |
           +--------+--------+
                    |
                    v
             Verify Capacity
                    |
                    v
              Storage Healthy
```

---

## 3. Understanding EBS Storage

Amazon Elastic Block Store (EBS) provides block-level storage for EC2 instances.

EBS volumes can be attached to supported EC2 instances and used as operating-system or application storage.

### Important EBS Concepts

| Concept | Explanation |
|---|---|
| EBS volume | Persistent block storage |
| Root volume | Stores the instance operating system |
| gp3 | General-purpose SSD volume type |
| Volume size | Provisioned block storage capacity |
| Partition | Logical division of a block device |
| Filesystem | Organizes files within storage |
| Mount point | Directory where a filesystem is accessible |
| Snapshot | Point-in-time EBS backup |
| Elastic Volumes | Allows supported volume modifications |

### EBS Volume vs Filesystem

These are different storage layers.

```text
EBS Volume
    |
    v
Block Device
    |
    v
Partition
    |
    v
Filesystem
    |
    v
Mounted Directory (/)
```

Increasing EBS capacity does not necessarily increase the mounted filesystem's usable space.

The partition and filesystem may need to be expanded separately.

### Important Linux Storage Commands

| Command | Purpose |
|---|---|
| `df -h` | Filesystem capacity and utilization |
| `df -i` | Inode utilization |
| `du -h` | Directory and file disk usage |
| `lsblk` | Block devices and partitions |
| `findmnt` | Filesystem source and mount details |
| `find` | Locate files |
| `journalctl` | Inspect system logs |
| `fallocate` | Allocate filesystem space |
| `growpart` | Extend a partition |
| `xfs_growfs` | Grow an XFS filesystem |
| `resize2fs` | Resize an ext-family filesystem |

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- OpenSSH client
- EC2 and EBS permissions
- Linux filesystem administration knowledge
- Git and GitHub

### Security and Safety Requirements

- Use a disposable EC2 instance.
- Never intentionally fill a production root filesystem.
- Maintain reserve disk capacity during testing.
- Do not delete unknown application files.
- Keep SSH access restricted to a trusted source.
- Keep private SSH keys outside GitHub.
- Verify resource identifiers before EBS modifications.
- Create a snapshot or verified backup before resizing important production volumes.
- Delete lab resources after the exercise.

### AWS Costs

The following may generate charges:

- EC2 instance
- gp3 EBS root volume
- Public IPv4 address
- Data transfer
- Optional snapshots

Increasing EBS capacity can increase storage charges.

---

## 5. Prepare the AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export INSTANCE_NAME="cloud-lab07-ebs-instance"
export SG_NAME="cloud-lab07-ebs-sg"
export KEY_NAME="cloud-lab07-ebs-key"
```

Verify AWS identity:

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

Expected: a valid `vpc-...` ID.

### Step 3 — Check Instance Type Availability

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Identify Default Subnets

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

Select a default subnet in a supported Availability Zone:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_YOUR_ID"
```

Replace the placeholder with a real subnet ID.

Verify the subnet has appropriate internet gateway routing for direct SSH access.

---

## 6. Create SSH Credentials

### Step 1 — Prepare SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 2 — Configure Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab07-ebs-key.pem"
```

Verify this path is unused.

Check whether the AWS key pair already exists:

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new lab, `InvalidKeyPair.NotFound` is expected.

### Step 3 — Create the Key Pair

Only if the key pair and local file do not already exist:

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$KEY_FILE"
```

### Step 4 — Secure the Private Key

```bash
chmod 400 "$KEY_FILE"
```

Verify:

```bash
ls -l "$KEY_FILE"
```

Never upload the private key to the repository.

---

## 7. Create the Security Group

### Step 1 — Retrieve Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')

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

Create only if no group exists with that name.

### Step 3 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab07 EBS root filesystem troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow SSH From Client

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: TCP
Port: 22
Source: CLIENT_PUBLIC_IP/32
```

---

## 8. Launch EC2 With a 12-GiB Root Volume

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Identify AMI Root Device

```bash
export ROOT_DEVICE=$(aws ec2 describe-images \
  --image-ids "$AMI_ID" \
  --query 'Images[0].RootDeviceName' \
  --output text \
  --region "$AWS_REGION")

echo "$ROOT_DEVICE"
```

### Step 3 — Check for an Existing Lab Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not launch a duplicate instance.

### Step 4 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --block-device-mappings \
    "DeviceName=$ROOT_DEVICE,Ebs={VolumeSize=12,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab07-ebs-instance},{Key=Project,Value=EC2-Troubleshooting-Lab07}]' \
    'ResourceType=volume,Tags=[{Key=Project,Value=EC2-Troubleshooting-Lab07}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

If launch fails, investigate the actual AWS error before modifying instance type, encryption, or account configuration.

### Step 5 — Wait for Readiness

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Identify Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE}'].Ebs.VolumeId | [0]" \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{Volume:VolumeId,SizeGiB:Size,Type:VolumeType,State:State,Encrypted:Encrypted}' \
  --output table \
  --region "$AWS_REGION"
```

Expected root EBS size: 12 GiB.

### Step 7 — Retrieve Public IPv4

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

### Step 8 — Connect to EC2

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

For production instances, verify SSH host-key fingerprints through a trusted source.

---

## 9. Establish the Storage Baseline

The following commands are executed inside EC2.

### Check 1 — Root Filesystem Utilization

```bash
df -hT /
```

Example:

```text
Filesystem       Type  Size  Used  Avail  Use% Mounted on
/dev/nvme0n1p1   xfs    12G  2.5G   9.5G   21% /
```

Values vary by AMI and filesystem configuration.

### Check 2 — Block Devices

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

### Check 3 — Inode Utilization

```bash
df -ih /
```

### Check 4 — Directory Utilization

```bash
sudo du -xhd1 /var /home /opt 2>/dev/null
```

### Check 5 — System Logs

```bash
sudo journalctl --disk-usage
```

```bash
sudo du -xhd1 /var/log 2>/dev/null
```

### Baseline Findings

| Component | Expected Condition |
|---|---|
| EC2 instance | Running |
| EBS root volume | 12 GiB |
| Root filesystem | Mounted |
| Available capacity | Sufficient |
| Disk utilization | Below simulated alert threshold |
| Inodes | Available |
| SSH connectivity | Working |

---

## 10. Simulate High Root Filesystem Utilization

### Step 1 — Create Test Directory

```bash
sudo mkdir -p /var/tmp/ec2-lab07
```

Only files created inside this dedicated directory will be removed during remediation.

### Step 2 — Calculate Safe Disk Allocation

```bash
read FS_SIZE FS_USED FS_AVAIL <<< \
  "$(df -B1 --output=size,used,avail / | tail -n 1)"

TARGET_USED=$(( FS_SIZE * 85 / 100 ))
MIN_FREE=$(( 1536 * 1024 * 1024 ))

TARGET_ALLOC=$(( TARGET_USED - FS_USED ))
SAFE_ALLOC=$(( FS_AVAIL - MIN_FREE ))

ALLOC_BYTES=$(( TARGET_ALLOC < SAFE_ALLOC ? TARGET_ALLOC : SAFE_ALLOC ))

printf 'Filesystem size: %s bytes\n' "$FS_SIZE"
printf 'Current used:    %s bytes\n' "$FS_USED"
printf 'Available:       %s bytes\n' "$FS_AVAIL"
printf 'Test allocation: %s bytes\n' "$ALLOC_BYTES"
```

### Explanation

The script targets approximately 85% utilization while reserving at least 1.5 GiB of reported available space.

The calculated value is limited by whichever condition is more restrictive.

### Step 3 — Verify Allocation

```bash
test "$ALLOC_BYTES" -gt 0 &&
  echo "Allocation size is valid"
```

If the value is not positive, stop the simulation.

### Step 4 — Create Disk-Pressure File

```bash
sudo fallocate \
  -l "$ALLOC_BYTES" \
  /var/tmp/ec2-lab07/disk-pressure.bin
```

This allocates storage blocks for the temporary lab file.

### Step 5 — Verify File Size

```bash
sudo du -h /var/tmp/ec2-lab07/disk-pressure.bin
```

### Step 6 — Check Root Utilization

```bash
df -hT /
```

Expected: substantially higher utilization, generally around the configured target if enough capacity was available.

**Safety:** Do not create additional files merely to force 100% utilization.

---

## 11. Troubleshooting Investigation

### Check 1 — Verify Filesystem Space

```bash
df -h /
```

### Check 2 — Identify Large Directories

```bash
sudo du -xhd1 /var /home /opt 2>/dev/null
```

### Check 3 — Inspect Temporary Storage

```bash
sudo du -xhd2 /var/tmp 2>/dev/null
```

### Check 4 — Identify Large Lab Files

```bash
sudo find /var/tmp/ec2-lab07 \
  -type f -printf '%s %p\n' | sort -nr
```

### Check 5 — Inspect File Details

```bash
sudo ls -lh /var/tmp/ec2-lab07/
```

### Check 6 — Inspect Failed Services

```bash
sudo systemctl --failed
```

### Check 7 — Review System Warnings

```bash
sudo journalctl -p warning -n 30 --no-pager
```

### Check 8 — Inspect Inodes

```bash
df -ih /
```

### Investigation Summary

| Check | Finding |
|---|---|
| Instance | Running |
| Root volume | 12 GiB |
| Root utilization | Elevated |
| Temporary directory | Large |
| Largest identified file | `disk-pressure.bin` |
| Inodes | May remain healthy |
| Application errors | Not guaranteed |
| Simulated root cause | Test file consuming disk space |

### Important Observation

High disk utilization does not always cause an immediate application failure.

An operating system may continue operating at 85% usage.

The purpose of this lab is to identify and recover from disk pressure before it causes a complete outage.

---

## 12. Root Cause Analysis

### Root Cause

A large temporary file under `/var/tmp/ec2-lab07/` consumes a substantial portion of the available root filesystem capacity.

### Technical Explanation

The root filesystem has finite capacity.

As files consume storage blocks, the amount of available free space decreases.

When capacity becomes insufficient, applications may fail to write new data.

### Root Cause Flow

```text
EC2 Instance Running
         |
         v
Root EBS Volume: 12 GiB
         |
         v
Temporary File Created
         |
         v
Filesystem Blocks Allocated
         |
         v
Available Space Decreases
         |
         v
High Root Filesystem Utilization
```

### Five Whys

1. **Why was root filesystem utilization high?** A large temporary file consumed storage blocks.
2. **Why did that affect available capacity?** The temporary file was stored on the root filesystem.
3. **Why did the condition matter?** Applications and the operating system require free space for normal writes.
4. **Why was the issue identifiable?** Linux `df`, `du`, and `find` exposed filesystem utilization and file sizes.
5. **How can it be prevented?** Monitor filesystem usage, enforce retention policies, and provision adequate capacity.

---

## 13. Remediation A — Recover Disk Space

### Step 1 — Verify the File

```bash
sudo ls -lh /var/tmp/ec2-lab07/disk-pressure.bin
```

Confirm that this is the file created during the exercise.

### Step 2 — Remove the Known Test File

```bash
sudo rm -f /var/tmp/ec2-lab07/disk-pressure.bin
```

### Step 3 — Remove Empty Directory

```bash
sudo rmdir /var/tmp/ec2-lab07
```

### Step 4 — Verify Recovery

```bash
df -hT /
```

Expected: filesystem utilization decreases and available space increases.

### Step 5 — Check Temporary Directory Usage

```bash
sudo du -xhd1 /var/tmp 2>/dev/null
```

### Recovery Result

| Check | Before Cleanup | After Cleanup |
|---|---|---|
| Root utilization | High | Reduced |
| Temporary test file | Present | Deleted |
| Free space | Reduced | Increased |
| Root filesystem | Mounted | Mounted |
| Instance | Running | Running |

### Production Safety

Do not indiscriminately delete logs, application directories, database files, or filesystem contents.

If a deleted file remains open by a process, its disk space may remain allocated until the file descriptor is closed.

Where available, `lsof +L1` can help identify deleted but still-open files.

---

## 14. Remediation B — Expand the EBS Root Volume

This optional method demonstrates storage expansion when deleting files is not sufficient.

### Objective

Increase the EBS root volume from 12 GiB to 16 GiB.

### Important Considerations

- EBS volume expansion can increase storage costs.
- EBS volumes cannot be directly reduced to a smaller size.
- EBS resizing may require a partition expansion.
- The filesystem may need a separate expansion.
- Production volumes should have an appropriate snapshot or verified backup before resizing.
- Confirm the EBS volume ID before executing any modification.

### Step 1 — Identify Root Filesystem

Inside EC2:

```bash
findmnt -no SOURCE,FSTYPE,TARGET /
```

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

Record the filesystem type, partition name, and parent disk.

Exit the instance:

```bash
exit
```

### Step 2 — Inspect EBS Volume From WSL2

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{ID:VolumeId,SizeGiB:Size,Type:VolumeType,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
SizeGiB: 12
Type: gp3
```

### Step 3 — Verify Resource Tags

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[0].Tags' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the volume belongs to `EC2-Troubleshooting-Lab07`.

### Step 4 — Modify EBS Volume

```bash
aws ec2 modify-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --size 16 \
  --region "$AWS_REGION"
```

### Step 5 — Monitor Modification

```bash
aws ec2 describe-volumes-modifications \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'VolumesModifications[].{Volume:VolumeId,OriginalGiB:OriginalSize,TargetGiB:TargetSize,State:ModificationState,Progress:Progress}' \
  --output table \
  --region "$AWS_REGION"
```

Possible states:

```text
modifying
optimizing
completed
```

Wait until the operation reaches `optimizing` or `completed` before extending the filesystem.

### Step 6 — Reconnect to EC2

```bash
ssh \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

### Step 7 — Compare Device and Filesystem Sizes

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

```bash
df -hT /
```

The EBS-backed block device may now show 16 GiB while the partition or filesystem remains smaller.

### Step 8 — Identify Root Partition and Parent Disk

```bash
export ROOT_PART=$(findmnt -no SOURCE /)

export ROOT_DISK_NAME=$(lsblk -no PKNAME "$ROOT_PART" | head -n 1)

export ROOT_PART_NUM=$(lsblk -no PARTN "$ROOT_PART" | head -n 1)

export ROOT_DISK="/dev/$ROOT_DISK_NAME"
```

Verify:

```bash
echo "Root partition: $ROOT_PART"
echo "Parent disk:    $ROOT_DISK"
echo "Partition no:   $ROOT_PART_NUM"
```

Example for a Nitro-based EC2 instance:

```text
Root partition: /dev/nvme0n1p1
Parent disk: /dev/nvme0n1
Partition no: 1
```

The actual device name may differ.

### Step 9 — Expand Root Partition

Inspect the partition layout first:

```bash
lsblk
```

If the partition is smaller than the expanded EBS disk and the root filesystem uses a normal partition:

```bash
sudo growpart "$ROOT_DISK" "$ROOT_PART_NUM"
```

Do not apply these commands blindly to LVM, encrypted device-mapper layers, or unsupported filesystem layouts.

If `growpart` reports `NOCHANGE`, inspect the partition size and layout rather than repeatedly running modification commands.

### Step 10 — Identify Filesystem Type

```bash
findmnt -no FSTYPE /
```

### Step 11 — Expand Filesystem

For XFS:

```bash
sudo xfs_growfs /
```

For ext4:

```bash
sudo resize2fs "$ROOT_PART"
```

**Run only the command matching the actual filesystem type.**

### Step 12 — Verify Expanded Capacity

```bash
df -hT /
```

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

Expected: approximately 16 GiB of root storage, accounting for filesystem overhead and layout.

### Expansion Summary

| Layer | Before | After |
|---|---|---|
| EBS Volume | 12 GiB | 16 GiB |
| Parent Block Device | 12 GiB | 16 GiB |
| Root Partition | Smaller capacity | Expanded |
| Root Filesystem | Initial capacity | Expanded |
| Additional Provisioned Capacity | — | 4 GiB |

---

## 15. Verify Final Recovery

### Test 1 — Filesystem Capacity

Inside EC2:

```bash
df -hT /
```

### Test 2 — Inode Availability

```bash
df -ih /
```

### Test 3 — Block Device Layout

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
```

### Test 4 — System Services

```bash
sudo systemctl --failed
```

A clean result means systemd is not currently reporting failed units, although application-specific verification may still be required.

Exit:

```bash
exit
```

### Test 5 — EC2 Health Checks

From WSL2:

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

### Test 6 — AWS EBS Capacity

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --query 'Volumes[].{ID:VolumeId,SizeGiB:Size,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

If the optional resize was completed, expected EBS volume size is 16 GiB.

---

## 16. Production Engineering Considerations

### Common Causes of Root Filesystem Exhaustion

- Excessive application logging
- Large temporary files
- Unremoved software packages
- Application caches
- Docker container logs and layers
- Database files
- Failed log rotation
- Backup files stored locally
- Unbounded application output
- Unexpected data growth

### Recommended Troubleshooting Order

1. Check root filesystem usage with `df -h`.
2. Check inode exhaustion using `df -i`.
3. Identify large directories with `du`.
4. Identify large files with `find`.
5. Review recent application changes.
6. Inspect logging and retention behavior.
7. Verify which files can be safely removed.
8. Recover temporary storage when appropriate.
9. Increase EBS capacity if necessary.
10. Expand the partition and filesystem.
11. Verify services and application health.
12. Configure monitoring to prevent recurrence.

### Production Monitoring

Linux filesystem usage is not directly represented by the standard EC2 CPU or status-check metrics.

To monitor root filesystem utilization centrally, consider the Amazon CloudWatch Agent and its disk utilization metrics.

Example monitoring thresholds:

| Utilization | Example Operational Response |
|---|---|
| Below 70% | Normal monitoring |
| 70–80% | Review growth trend |
| 80–90% | Investigate and plan remediation |
| Above 90% | High-priority capacity investigation |
| Near 100% | Risk of write failures and service disruption |

These are illustrative thresholds. Production thresholds should reflect workload behavior and available capacity.

### Prevention Strategies

- Configure disk-space monitoring.
- Implement log rotation.
- Apply retention policies.
- Clean temporary files safely.
- Monitor application storage growth.
- Separate critical application data from operating-system storage when appropriate.
- Use automated infrastructure provisioning.
- Maintain verified backup and recovery procedures.
- Review storage capacity during deployment planning.

---

## 17. Related Storage Errors

| Error or Symptom | Possible Cause |
|---|---|
| `No space left on device` | Disk space or inode exhaustion |
| Filesystem nearly full | Excessive storage consumption |
| `Permission denied` | Filesystem permissions |
| Read-only filesystem | Filesystem or storage problem |
| `growpart: NOCHANGE` | Partition already expanded or unsuitable layout |
| `Bad magic number` | Wrong filesystem tool or target |
| EBS modification in progress | Elastic Volumes operation not completed |
| Disk size differs from filesystem size | Partition/filesystem not expanded |

---

## 18. Interview Questions and Answers

### Q1. How do you check disk usage in Linux?

Use `df -h` to inspect filesystem capacity and utilization.

### Q2. How do you find directories consuming the most space?

Use `du`, for example `sudo du -xhd1 /var`.

### Q3. What is the difference between `df` and `du`?

`df` reports filesystem-wide capacity and usage. `du` measures storage used by files and directories.

### Q4. Can a filesystem run out of space even if `df -h` shows available capacity?

Yes. It can run out of inodes. Check `df -i`.

### Q5. What does `No space left on device` mean?

A write failed because the filesystem could not allocate required space or inodes, among other possible filesystem allocation limits.

### Q6. How can you increase an EBS volume?

Use the AWS Console, `ModifyVolume` API, or AWS CLI `aws ec2 modify-volume`.

### Q7. Does EBS expansion automatically increase Linux filesystem size?

Not always. Partition and filesystem expansion may be necessary.

### Q8. How do you extend an XFS filesystem?

Use `xfs_growfs` on the mounted filesystem.

### Q9. How do you extend an ext4 filesystem?

Use `resize2fs` on the correct filesystem device.

### Q10. Why is it dangerous to delete unknown files from `/var/log`?

Logs may be needed for troubleshooting, security investigations, auditing, and application operations. Deleting active log files can also fail to recover space immediately if processes still hold them open.

### Q11. Can you shrink an EBS volume after increasing its size?

You cannot directly reduce an EBS volume's provisioned size. Reducing capacity generally requires migration to a smaller, correctly prepared volume.

### Q12. How would you explain this incident in an interview?

> I investigated high root filesystem utilization on an EC2 instance. First, I used `df -h` and `df -i` to inspect storage and inode usage. Then I used `du` and `find` to identify large directories and files. I found that a temporary file was consuming significant root filesystem capacity. I removed the known disposable file and verified that free space increased. I also practiced expanding the EBS root volume using AWS CLI, `growpart`, and the appropriate filesystem utility. Finally, I checked EC2 status, filesystem capacity, and system services to confirm recovery.

---

## 19. Cleanup

**Warning:** Perform these steps only on the dedicated Lab 07 resources.

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
Project: EC2-Troubleshooting-Lab07
```

### Step 3 — Verify Root Volume Configuration

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='${ROOT_DEVICE}'].Ebs.DeleteOnTermination | [0]" \
  --output text \
  --region "$AWS_REGION"
```

Expected: `True` for the root volume configured in this lab.

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

### Step 5 — Verify EBS Deletion

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If AWS returns `InvalidVolume.NotFound`, the volume was removed.

If the dedicated lab volume remains `available`, confirm its ownership and lack of attachments before deleting it:

```bash
aws ec2 delete-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Do not remove unrelated EBS volumes.

### Step 6 — Check Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Ensure no network interface still references the group.

### Step 7 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete AWS SSH Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 9 — Remove Local Private Key

```bash
rm -f "$KEY_FILE"
```

Only remove the key created for Lab 07.

### Step 10 — Verify Cleanup

Confirm:

- EC2 instance terminated.
- Dedicated EBS root volume deleted.
- Security group deleted.
- AWS key pair deleted.
- Local private key deleted.
- Default VPC and subnets preserved.

---

## 20. Repository Structure

```text
07-ebs-root-volume-full/
│
└── README.md
```

All provisioning, troubleshooting, recovery, and cleanup commands are included in this README.

The temporary disk-pressure file is created only inside the EC2 instance and should not be stored in GitHub.

Do not commit private keys, AWS credentials, or temporary resource identifiers.

---

## 21. Lessons Learned

This lab demonstrated how to investigate elevated root filesystem utilization on an EBS-backed EC2 instance.

The investigation involved checking filesystem capacity, inode usage, block devices, directory sizes, and system logs.

The simulated problem was caused by a large temporary file consuming root filesystem storage.

The first recovery method removed the known disposable file and restored free space.

The second recovery method demonstrated how EBS volumes can be expanded, followed by partition and filesystem resizing.

The key lesson is that storage troubleshooting requires understanding several layers: the EBS volume, underlying block device, partition, filesystem, and application files.

A larger EBS volume does not automatically guarantee that the mounted filesystem can use the additional capacity.

---

## 22. Skills Demonstrated

- Amazon EC2 troubleshooting
- Amazon EBS administration
- gp3 EBS volume management
- Linux filesystem troubleshooting
- Disk capacity analysis
- Inode troubleshooting
- Linux block-device inspection
- EBS Elastic Volumes
- Root partition expansion
- XFS filesystem expansion
- ext4 filesystem expansion
- Bash scripting
- AWS CLI v2
- SSH administration
- Root cause analysis
- Production storage recovery
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-007 |
| Problem | High Root Filesystem Utilization |
| Simulated Root Cause | Large temporary file |
| Initial EBS Size | 12 GiB |
| Disk Pressure | Approximately 85% target |
| Remediation A | Remove temporary file |
| Remediation B | EBS resize and filesystem expansion |
| Optional Final EBS Size | 16 GiB |
| Filesystem Space | Recovered or expanded |
| EC2 Status Checks | OK |
| Resource Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 root filesystem is nearly full, use Linux tools to identify the source of disk consumption, recover space safely, and expand EBS capacity only when needed. Always verify the filesystem itself reflects the new capacity after an EBS resize.

# Lab 15 — Amazon EC2 Launch Failure

## Overview

This hands-on lab demonstrates how to investigate and resolve common Amazon EC2 instance launch failures using AWS CLI.

Launching an EC2 instance requires several AWS resources and configurations to work together correctly, including the Amazon Machine Image (AMI), instance type, subnet, security group, IAM permissions, and available infrastructure capacity.

An invalid configuration can cause the `RunInstances` API operation to fail before an instance is created.

In this lab, we reproduce three common EC2 launch failures, investigate IAM authorization and capacity-related issues, and successfully launch a healthy EC2 instance using a corrected configuration.

**Troubleshooting workflow:**

Prepare → Reproduce Failure → Investigate → Identify Root Cause → Remediate → Launch Successfully → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-015 |
| AWS Service | Amazon EC2 |
| Related Services | VPC, IAM, Systems Manager Parameter Store |
| Difficulty | Intermediate–Advanced |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| AWS Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, Git |
| Primary API | `ec2:RunInstances` |
| Scenario A | Invalid AMI |
| Scenario B | Missing EC2 key pair |
| Scenario C | Invalid subnet |
| Scenario D | IAM permission validation |
| Scenario E | Instance type and capacity investigation |
| Remediation | Correct launch parameters |
| Expected Outcome | EC2 running with healthy status checks |

---

## 1. Production Incident Scenario

### Incident Description

A company's cloud engineering team needs to deploy a new EC2 instance for an application environment.

During deployment, the `RunInstances` API request repeatedly fails.

The cloud engineer discovers several configuration problems involving incorrect AWS resource identifiers.

The deployment cannot proceed until the invalid configurations are identified and corrected.

### Expected Behavior

The AWS CLI should successfully create the EC2 instance.

```bash
aws ec2 run-instances \
  --image-id VALID_AMI_ID \
  --instance-type t3.micro \
  --subnet-id VALID_SUBNET_ID \
  --security-group-ids VALID_SECURITY_GROUP_ID
```

After launching, the instance should reach:

```text
State: running
SystemStatus: ok
InstanceStatus: ok
```

### Failure Scenarios

| Scenario | AWS Error | Root Cause |
|---|---|---|
| A | `InvalidAMIID.NotFound` | AMI ID invalid or unavailable |
| B | `InvalidKeyPair.NotFound` | Requested key pair doesn't exist |
| C | `InvalidSubnetID.NotFound` | Subnet ID invalid |
| D | `UnauthorizedOperation` | IAM permissions insufficient |
| E | `InsufficientInstanceCapacity` | Requested capacity unavailable |

The lab intentionally reproduces scenarios A, B, and C.

IAM permissions are checked using `--dry-run`. Capacity constraints are investigated without deliberately requesting excessive resources.

### Business Impact

EC2 launch failures can cause:

- Delayed application deployments
- Failed infrastructure provisioning
- CI/CD pipeline failures
- Slower environment creation
- Unavailable replacement instances
- Increased operational workload
- Failure to meet deployment deadlines

### Investigation Objective

Identify the exact launch failure, validate AWS resource configurations, correct the underlying issue, and verify successful EC2 deployment.

---

## 2. Architecture

### EC2 Launch Workflow

```text
                  Cloud Engineer
                        |
                        v
                     AWS CLI
                        |
                        v
                 EC2 RunInstances
                        |
                        v
               Launch Validation
                        |
          +-------------+-------------+
          |             |             |
          v             v             v
       AMI Check    Network Check   IAM Check
          |             |             |
          +-------------+-------------+
                        |
                        v
               Instance Type Check
                        |
                        v
                 Capacity Check
                        |
               +--------+--------+
               |                 |
               v                 v
          Validation          Validation
            Failed            Passed
               |                 |
               v                 v
           API Error         EC2 Launch
                                 |
                                 v
                          Instance Running
                                 |
                                 v
                         Status Checks OK
```

### Broken Launch Configuration

```text
               EC2 Launch Request
                       |
          +------------+------------+
          |            |            |
          v            v            v
      Invalid AMI   Missing Key   Invalid Subnet
          |            |            |
          X            X            X
          |            |            |
          +------------+------------+
                       |
                       v
                  Launch Failed
```

### Corrected Architecture

```text
                  AWS CLI
                     |
                     v
              EC2 RunInstances
                     |
            +--------+--------+
            |        |        |
            v        v        v
        Valid AMI  Valid SG  Valid Subnet
            |        |        |
            +--------+--------+
                     |
                     v
            Compatible Instance
                     |
                     v
             Authorized Request
                     |
                     v
            EC2 Instance Running
                     |
                     v
              Status Checks OK
```

---

## 3. Understanding EC2 Launch Requirements

Before creating an EC2 instance, AWS evaluates several launch parameters.

### Amazon Machine Image

An AMI contains the software and configuration required to launch an EC2 instance.

It includes the operating system and associated launch configuration.

AMI IDs are specific to AWS Regions.

### Instance Type

The instance type determines the virtual hardware available to the EC2 instance, including vCPU, memory, and networking capabilities.

### Subnet

A subnet determines the instance's network placement within a VPC and Availability Zone.

The subnet must have sufficient available private IP addresses.

### Security Group

A security group controls inbound and outbound traffic associated with EC2 network interfaces.

The security group must belong to the intended VPC.

### IAM Permissions

The principal launching the instance must have sufficient permissions for the requested EC2 resources and configuration.

If an IAM instance profile is specified, `iam:PassRole` may also be required.

### Infrastructure Capacity

AWS must have sufficient available capacity to satisfy the requested instance type and placement.

An instance type being offered in an Availability Zone does not guarantee available capacity at any given moment.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 management permissions
- VPC read permissions
- SSM public parameter read access
- Git and GitHub

### Security Requirements

- Use a disposable EC2 instance.
- Restrict launch tests to a known AWS account and Region.
- Do not attach unnecessary IAM permissions.
- Do not create public SSH access.
- Avoid generating unnecessary resources.
- Confirm resources before deleting them.
- Do not delete shared networking infrastructure.

### Cost Considerations

The intentionally invalid launch requests should fail before creating EC2 instances.

The final successful launch may incur EC2 compute and EBS storage charges.

---

## 5. Prepare AWS Environment

Run all commands in Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="EC2-Troubleshooting-Lab15"

export INSTANCE_NAME="cloud-lab15-launch-instance"
export SG_NAME="cloud-lab15-launch-sg"

export INSTANCE_TYPE="t3.micro"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)
```

Verify identity:

```bash
aws sts get-caller-identity
```

Check AWS CLI:

```bash
aws --version
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

If no default VPC exists, use an authorized lab VPC and adjust the networking setup.

### Step 3 — Verify Instance Type Offerings

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Identify a Compatible Subnet

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz,FreeIPs:AvailableIpAddressCount}' \
  --output table \
  --region "$AWS_REGION"
```

Choose a subnet with free IP addresses in a supported Availability Zone.

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

Verify:

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,VPC:VpcId,AZ:AvailabilityZone,AvailableIPs:AvailableIpAddressCount}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$AMI_ID"
```

### Step 6 — Validate AMI

```bash
aws ec2 describe-images \
  --image-ids "$AMI_ID" \
  --query 'Images[].{ID:ImageId,State:State,Architecture:Architecture,Name:Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: available
Architecture: x86_64
```

---

## 6. Create a Dedicated Security Group

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

Only create it if the name is unused.

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab15 EC2 launch troubleshooting" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=$SG_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Configuration

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{ID:GroupId,VPC:VpcId,Inbound:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected inbound rules:

```json
[]
```

No inbound SSH access is required.

---

## 7. Scenario A — Invalid AMI

### Step 1 — Define an Invalid AMI

```bash
export BAD_AMI_ID="ami-00000000000000000"
```

### Step 2 — Check the AMI

```bash
aws ec2 describe-images \
  --image-ids "$BAD_AMI_ID" \
  --region "$AWS_REGION"
```

Expected: the image is not found.

Confirm that the identifier is invalid before attempting the launch test.

### Step 3 — Attempt EC2 Launch

```bash
aws ec2 run-instances \
  --image-id "$BAD_AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --count 1 \
  --region "$AWS_REGION"
```

Expected error:

```text
An error occurred (InvalidAMIID.NotFound)
when calling the RunInstances operation
```

### Root Cause

The EC2 API request references an AMI that is not available in the requested Region.

### Remediation

Use the validated Amazon Linux 2023 AMI.

Verify it again:

```bash
aws ec2 describe-images \
  --image-ids "$AMI_ID" \
  --query 'Images[].{ID:ImageId,State:State,Architecture:Architecture}' \
  --output table \
  --region "$AWS_REGION"
```

### Production Lesson

Avoid hardcoding outdated AMI IDs.

Where possible, retrieve approved AMIs through SSM public parameters or an organizational image catalog.

---

## 8. Scenario B — Missing Key Pair

### Step 1 — Generate a Nonexistent Key Name

```bash
export BAD_KEY_NAME="cloud-lab15-missing-key-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
```

### Step 2 — Verify the Key Does Not Exist

```bash
aws ec2 describe-key-pairs \
  --key-names "$BAD_KEY_NAME" \
  --region "$AWS_REGION"
```

Expected:

```text
InvalidKeyPair.NotFound
```

### Step 3 — Attempt EC2 Launch

```bash
aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$BAD_KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --count 1 \
  --region "$AWS_REGION"
```

Expected:

```text
An error occurred (InvalidKeyPair.NotFound)
when calling the RunInstances operation
```

### Root Cause

The launch configuration references an EC2 key pair that does not exist in the selected Region.

### Remediation

Possible solutions:

- Use an existing authorized key pair.
- Create a dedicated key pair.
- Remove the key-pair parameter when SSH access is unnecessary.

For this lab, we omit the key pair from the corrected launch command.

### Production Lesson

EC2 instances do not always require SSH key pairs.

Other approved administrative access methods, including Systems Manager Session Manager when properly configured, can reduce dependence on SSH.

---

## 9. Scenario C — Invalid Subnet

### Step 1 — Define Invalid Subnet

```bash
export BAD_SUBNET_ID="subnet-00000000000000000"
```

### Step 2 — Verify It Does Not Exist

```bash
aws ec2 describe-subnets \
  --subnet-ids "$BAD_SUBNET_ID" \
  --region "$AWS_REGION"
```

Expected:

```text
InvalidSubnetID.NotFound
```

### Step 3 — Attempt EC2 Launch

```bash
aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$BAD_SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --count 1 \
  --region "$AWS_REGION"
```

Expected:

```text
An error occurred (InvalidSubnetID.NotFound)
when calling the RunInstances operation
```

### Root Cause

The subnet ID is invalid or unavailable in the requested account and Region.

### Step 4 — Validate Correct Subnet

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[].{ID:SubnetId,VPC:VpcId,AZ:AvailabilityZone,FreeIPs:AvailableIpAddressCount}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Check Security Group VPC

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[].{ID:GroupId,VPC:VpcId}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm that the security group and subnet belong to the same VPC.

### Remediation

Use a valid subnet within the intended VPC and a compatible Availability Zone.

### Production Lesson

VPC networking resources must be validated together.

An existing subnet is not necessarily compatible with every instance type or security group.

---

## 10. Scenario D — IAM Permission Validation

### Step 1 — Use EC2 Dry Run

```bash
aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --count 1 \
  --dry-run \
  --region "$AWS_REGION"
```

The request intentionally does not create an instance.

### Possible Result A — DryRunOperation

```text
An error occurred (DryRunOperation)
when calling the RunInstances operation:
Request would have succeeded, but DryRun flag is set.
```

Meaning: the permission check succeeded.

### Possible Result B — UnauthorizedOperation

```text
An error occurred (UnauthorizedOperation)
when calling the RunInstances operation:
You are not authorized to perform this operation.
```

Meaning: an applicable IAM authorization check failed.

### Step 2 — Identify AWS Caller

```bash
aws sts get-caller-identity
```

### Step 3 — Understand Required Permissions

Possible IAM requirements include:

```text
ec2:RunInstances
ec2:DescribeImages
ec2:DescribeSubnets
ec2:DescribeSecurityGroups
```

The required authorizations depend on the workflow, requested resources, and configuration.

When attaching an IAM instance profile, the caller may additionally require:

```text
iam:PassRole
```

### Optional — Decode Authorization Failure

If AWS provides an encoded authorization message and the operator has permission to decode it:

```bash
aws sts decode-authorization-message \
  --encoded-message "PASTE_ACTUAL_MESSAGE" \
  --query DecodedMessage \
  --output text
```

Do not grant excessive permissions simply to make a deployment work.

### Important Lesson

A successful `DryRunOperation` response verifies the authorization check, not availability of EC2 capacity or every runtime launch condition.

---

## 11. Scenario E — Instance Type and Capacity Investigation

### Step 1 — Inspect Instance Type

```bash
aws ec2 describe-instance-types \
  --instance-types "$INSTANCE_TYPE" \
  --query 'InstanceTypes[].{Type:InstanceType,Architecture:ProcessorInfo.SupportedArchitectures,VCpu:VCpuInfo.DefaultVCpus}' \
  --output json \
  --region "$AWS_REGION"
```

### Step 2 — Inspect Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Check Selected Subnet AZ

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].AvailabilityZone' \
  --output text \
  --region "$AWS_REGION"
```

Confirm that the selected instance type is offered in the selected Availability Zone.

### Step 4 — Check Subnet IP Capacity

```bash
aws ec2 describe-subnets \
  --subnet-ids "$SUBNET_ID" \
  --query 'Subnets[0].{Subnet:SubnetId,AvailableIPs:AvailableIpAddressCount,AZ:AvailabilityZone}' \
  --output table \
  --region "$AWS_REGION"
```

The subnet must have available private IPv4 addresses.

### Understanding InsufficientInstanceCapacity

Possible AWS error:

```text
InsufficientInstanceCapacity:
We currently do not have sufficient capacity
in the Availability Zone you requested.
```

This means the requested capacity cannot currently be fulfilled.

### Production Remediation

Possible strategies include:

- Trying a different compatible instance type.
- Selecting another Availability Zone.
- Retrying after a temporary shortage.
- Reducing the number of requested instances.
- Planning capacity reservations for predictable workloads.

**Note:** This lab does not intentionally generate a real capacity shortage.

---

## 12. Final Remediation — Launch a Healthy EC2 Instance

### Step 1 — Check for Existing Lab Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not launch a duplicate instance.

### Step 2 — Create an Idempotency Token

```bash
export CLIENT_TOKEN="lab15-$(python3 -c 'import uuid; print(uuid.uuid4())')"
```

Verify:

```bash
echo "$CLIENT_TOKEN"
```

The token helps prevent duplicate launches when an identical request is retried.

Retain the same token if retrying the exact same launch request.

### Step 3 — Launch EC2 Using Correct Parameters

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --client-token "$CLIENT_TOKEN" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

This launch uses:

- Verified Amazon Linux AMI.
- Compatible instance type.
- Valid subnet.
- Valid security group.
- IMDSv2 required.
- No SSH key pair.
- No unnecessary instance profile.
- Idempotency token.

### Step 4 — Verify Instance ID

```bash
echo "$INSTANCE_ID"
```

Expected:

```text
i-xxxxxxxxxxxxxxxxx
```

If no instance ID is returned, inspect the request failure and existing Lab 15 instances before retrying.

### Step 5 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Wait for Healthy Status Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Verify Launch Configuration

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,AMI:ImageId,InstanceType:InstanceType,Subnet:SubnetId,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: running
InstanceType: t3.micro
PrivateIP: assigned
```

### Step 8 — Verify Status Checks

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{ID:InstanceId,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
System: ok
Instance: ok
```

### Expected Remediation Result

The corrected launch should successfully create the EC2 instance and pass its health checks.

---

## 13. Root Cause Analysis

### Scenario A — Invalid AMI

The EC2 launch request referenced an AMI that was unavailable in the selected Region.

**Fix:** Retrieve and validate the correct AMI.

### Scenario B — Missing Key Pair

The request specified a key pair that did not exist.

**Fix:** Use a valid key pair or omit the key-pair parameter.

### Scenario C — Invalid Subnet

The request referenced a nonexistent subnet.

**Fix:** Select a valid subnet with compatible networking configuration.

### Scenario D — IAM Authorization

A launch can fail when the caller lacks the necessary EC2 permissions.

**Fix:** Identify the specific denied action and update permissions according to least-privilege principles.

### Scenario E — Capacity Constraints

An EC2 launch can fail when the requested instance capacity is unavailable.

**Fix:** Use alternative capacity, instance types, or Availability Zones.

### Root Cause Summary

| Failure | Root Cause | Remediation |
|---|---|---|
| Invalid AMI | Incorrect AMI ID | Validate AMI |
| Missing key pair | Key pair unavailable | Correct or omit key |
| Invalid subnet | Wrong subnet ID | Select valid subnet |
| UnauthorizedOperation | IAM denial | Correct authorization |
| Insufficient capacity | Capacity unavailable | Adjust placement or instance type |

### Five Whys — Invalid AMI Example

1. **Why did the instance fail to launch?** The API rejected the request.
2. **Why did AWS reject it?** The AMI was invalid.
3. **Why was the AMI invalid?** The deployment configuration referenced an unavailable image.
4. **Why wasn't it detected earlier?** The AMI wasn't validated before deployment.
5. **How can recurrence be prevented?** Use approved AMI discovery and deployment validation.

---

## 14. Final Verification

| Check | Initial Failure | Final Deployment |
|---|---|---|
| AMI | Invalid | Available |
| Key pair | Missing in test | Omitted |
| Subnet | Invalid in test | Valid |
| Security group | Valid | Valid |
| Instance type | Investigated | Compatible |
| IAM authorization | Validated via dry run | Authorized |
| EC2 instance | Not created by invalid requests | Running |
| System status | N/A | OK |
| Instance status | N/A | OK |

### Success Criteria

The lab is successfully completed when:

- The expected launch errors are reproduced.
- Their root causes are understood.
- The valid AMI and subnet are verified.
- IAM authorization is checked.
- The corrected EC2 launch succeeds.
- The instance passes EC2 status checks.
- Temporary resources are cleaned up.

---

## 15. Production Engineering Best Practices

### Configuration Validation

- Validate AMI IDs before launching.
- Ensure AMI architecture matches the instance type.
- Use approved AMI catalogs or SSM parameters.
- Validate subnet and security group VPC relationships.
- Check Availability Zone instance type offerings.
- Confirm subnet IP availability.
- Use `--dry-run` for authorization checks.

### IAM Security

- Follow least-privilege principles.
- Avoid granting unnecessary administrative permissions.
- Review permissions boundaries and organizational SCPs.
- Restrict `iam:PassRole` to approved roles.
- Use CloudTrail to investigate failed authorization and API events where available.

### Deployment Reliability

- Use idempotency tokens for retries.
- Avoid blindly repeating failed launches.
- Plan for capacity shortages.
- Review EC2 service quotas.
- Consider multiple Availability Zones.
- Validate infrastructure through CI/CD before production deployment.

### Infrastructure as Code

Terraform or CloudFormation can reduce human configuration mistakes.

Recommended automated checks include:

- AMI availability
- Instance architecture compatibility
- VPC resource consistency
- IAM permissions
- Required subnet capacity
- Resource tagging
- Deployment parameter validation

---

## 16. Interview Questions and Answers

### Q1. What are common causes of EC2 launch failures?

Invalid AMIs, missing key pairs, invalid subnets, insufficient IAM permissions, incompatible instance types, quota restrictions, and unavailable capacity.

### Q2. What is `InvalidAMIID.NotFound`?

It indicates that the specified AMI is not available in the request context.

### Q3. What is `InvalidKeyPair.NotFound`?

The requested EC2 key pair does not exist in the selected Region.

### Q4. What is `InvalidSubnetID.NotFound`?

The requested subnet cannot be found in the current account and Region context.

### Q5. What does `UnauthorizedOperation` mean?

The caller does not have permission to perform an operation under the applicable authorization policies.

### Q6. What is `DryRunOperation`?

It indicates that an AWS dry-run authorization check succeeded without performing the requested operation.

### Q7. Does DryRunOperation guarantee successful launch?

No. Capacity, quotas, and other launch-time requirements can still prevent deployment.

### Q8. What causes InsufficientInstanceCapacity?

AWS cannot currently fulfill the requested EC2 capacity for the specified placement.

### Q9. What is the difference between capacity errors and quota errors?

Capacity errors reflect available AWS infrastructure. Quota errors reflect account-specific limits.

### Q10. Why must a security group and subnet belong to the same VPC?

An EC2 network interface can only use security groups associated with its VPC.

### Q11. Why use a client token when launching EC2?

It makes eligible repeated launch requests idempotent and helps prevent accidental duplicate instances.

### Q12. Can EC2 launch without an SSH key?

Yes. EC2 doesn't require an SSH key pair for every launch configuration.

### Q13. What is the first step when RunInstances fails?

Read the precise AWS error code and identify which input or authorization check failed.

### Q14. How would you explain this lab in an interview?

> I created an AWS EC2 troubleshooting lab focused on launch failures. I intentionally reproduced invalid AMI, missing key pair, and invalid subnet errors using AWS CLI. For each failure, I investigated the AWS API response, identified the configuration problem, and validated the correct resource. I also used EC2 DryRun to check IAM authorization and inspected instance type availability and subnet capacity. Finally, I launched a correctly configured EC2 instance, verified its status checks, and cleaned up the resources. The lab helped me understand how to diagnose deployment failures systematically.

---

## 17. Cleanup

**Warning:** Verify ownership before deleting AWS resources.

### Step 1 — Verify AWS Account

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Instance Tags

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project = EC2-Troubleshooting-Lab15
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify automatic deletion:

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

### Step 5 — Verify Security Group Ownership

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{ID:GroupId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm it belongs to Lab 15.

### Step 6 — Check Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

If no interfaces remain:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Expected after the root volume has been automatically removed:

```text
InvalidVolume.NotFound
```

If the EBS volume still exists, verify its ownership and attachment state before deleting it.

### Step 8 — Confirm No Active Lab Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: no active Lab 15 instances.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Final EC2 instance | Terminated |
| Root EBS volume | Deleted |
| Dedicated security group | Deleted |
| Invalid AMI reference | No resource created |
| Missing key pair reference | No resource created |
| Invalid subnet reference | No resource created |
| Default VPC | Preserved |
| Default subnet | Preserved |
| Shared AWS resources | Unchanged |

---

## 18. Repository Structure

```text
15-ec2-launch-failure/
│
└── README.md
```

All AWS CLI commands, failure simulations, investigation procedures, remediation steps, and cleanup instructions are documented in this file.

No application source code is required.

---

## 19. Lessons Learned

This lab demonstrated how EC2 launch failures can result from invalid resource identifiers, configuration mismatches, IAM authorization restrictions, and infrastructure capacity limitations.

The investigation emphasized the importance of reading AWS error codes before changing configurations.

The intentionally invalid AMI, key pair, and subnet requests helped demonstrate how AWS validates launch parameters.

The successful deployment demonstrated how validating AWS resources and correcting launch settings can restore the provisioning workflow.

The exercise also reinforced important cloud engineering practices such as least-privilege access, idempotency, infrastructure validation, and resource cleanup.

**Key lesson:** Most EC2 launch errors should be diagnosed by identifying the precise failed validation rather than repeatedly attempting the same deployment without investigating the error.

---

## 20. Skills Demonstrated

- Amazon EC2 troubleshooting
- EC2 RunInstances API
- AMI validation
- EC2 key pair management
- VPC and subnet validation
- Security group configuration
- IAM authorization troubleshooting
- EC2 DryRun
- Instance type compatibility checks
- Availability Zone investigation
- EC2 capacity troubleshooting
- Deployment idempotency
- AWS CLI v2
- Linux Bash
- Root cause analysis
- Cloud deployment remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-015 |
| Problem | EC2 Launch Failure |
| Invalid AMI | Diagnosed |
| Missing Key Pair | Diagnosed |
| Invalid Subnet | Diagnosed |
| IAM Authorization | Validated |
| Capacity Availability | Investigated |
| Corrected Launch | Successful |
| Instance State | Running |
| System Status | OK |
| Instance Status | OK |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Successful EC2 deployment requires valid resource identifiers, compatible network settings, sufficient IAM permissions, and available infrastructure capacity. Systematic validation and AWS CLI diagnostics help cloud engineers resolve launch failures safely and efficiently.

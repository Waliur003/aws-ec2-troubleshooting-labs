# Lab 10 — Amazon EC2 Cannot Access S3

## Overview

This hands-on troubleshooting lab demonstrates how to investigate and resolve an Amazon EC2 instance that cannot download objects from a private Amazon S3 bucket.

The simulated production incident involves an EC2 instance running Amazon Linux 2023 with an IAM role attached through an instance profile.

The instance has working network connectivity and valid temporary AWS credentials. However, an application receives an `AccessDenied` error while trying to read an S3 object.

The root cause is a missing `s3:GetObject` permission in the EC2 role's identity-based IAM policy.

We will reproduce the failure, examine the IAM permissions, restore least-privilege access, verify recovery, and remove the lab resources.

**Troubleshooting workflow:**

Working Baseline → Introduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-010 |
| AWS Services | EC2, S3, IAM, VPC |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| AWS Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Primary Error | `AccessDenied` |
| Failed Operation | `s3:GetObject` |
| Root Cause | Missing IAM object-read permission |
| Remediation | Restore least-privilege IAM policy |
| Authentication | EC2 instance profile |
| Encryption | SSE-S3 |
| Security | S3 Block Public Access |
| Tools | AWS CLI v2, Bash, SSH, JSON |

---

## 1. Production Incident Scenario

### Incident Description

A company runs an application on Amazon EC2 that downloads configuration files from a private Amazon S3 bucket.

The application requires read access to objects stored under the `app/` prefix.

The EC2 instance is running normally, the network is functioning, and the correct IAM instance profile is attached.

However, attempts to download configuration files from S3 fail.

### Reported Error

```text
An error occurred (AccessDenied)
when calling the GetObject operation:
Access Denied
```

### Expected Behavior

The instance should download:

```text
s3://LAB_BUCKET_NAME/app/config.txt
```

Expected file content:

```text
application=cloud-security-lab
environment=development
incident=INC-EC2-010
status=healthy
```

### Actual Behavior

The instance can list objects under the permitted prefix, but it cannot download them.

### Potential Business Impact

- Application initialization failures
- Missing configuration files
- Interrupted data processing
- Failed application deployments
- Broken automated workflows
- Increased operational troubleshooting time

### Investigation Objective

Determine whether the problem is caused by IAM authorization, the EC2 instance profile, S3 bucket configuration, or network connectivity.

---

## 2. Architecture

### Working Architecture

```text
            Amazon EC2
          Amazon Linux 2023
                 |
                 v
          Instance Profile
                 |
                 v
             IAM Role
                 |
       +---------+---------+
       |                   |
       v                   v
 s3:ListBucket         s3:GetObject
       |                   |
       +---------+---------+
                 |
                 v
          Private S3 Bucket
                 |
                 v
           app/config.txt
                 |
                 v
         Download Successful
```

### Broken Architecture

```text
            Amazon EC2
                 |
                 v
           Instance Profile
                 |
                 v
              IAM Role
                 |
          s3:ListBucket
              ALLOWED
                 |
          s3:GetObject
              MISSING
                 |
                 v
           Amazon S3
                 |
                 X
            AccessDenied
```

### Corrected Architecture

```text
           Amazon EC2
                |
                v
          IAM Role Updated
                |
                v
       Least-Privilege Policy
                |
          s3:GetObject
                |
                v
          S3 Object ARN
                |
                v
         Download Successful
```

---

## 3. Understanding EC2 IAM Roles

An EC2 instance can access AWS services through an IAM role attached using an instance profile.

The AWS SDK and AWS CLI can automatically retrieve temporary credentials associated with that role.

This avoids manually storing long-lived access keys on the instance.

### Important IAM Components

| Component | Purpose |
|---|---|
| IAM role | Defines an AWS identity with permissions |
| Trust policy | Specifies which principal can assume the role |
| Permissions policy | Specifies allowed or denied actions |
| Instance profile | Connects an IAM role to an EC2 instance |
| Temporary credentials | Enable authenticated AWS API requests |
| STS | Supports temporary security credentials |

### Authentication vs Authorization

**Authentication:** Which AWS identity is making the request?

**Authorization:** Is that identity permitted to perform the requested operation?

An EC2 instance can authenticate successfully using its instance profile but still receive `AccessDenied` if its IAM permissions are insufficient.

---

## 4. Understanding S3 Permissions

S3 uses separate permissions for bucket-level and object-level operations.

| Permission | Resource | Purpose |
|---|---|---|
| `s3:ListBucket` | Bucket ARN | List objects |
| `s3:GetObject` | Object ARN | Read or download objects |
| `s3:PutObject` | Object ARN | Upload objects |
| `s3:DeleteObject` | Object ARN | Delete objects |

### Bucket ARN

```text
arn:aws:s3:::LAB_BUCKET_NAME
```

### Object ARN

```text
arn:aws:s3:::LAB_BUCKET_NAME/app/*
```

The object ARN grants access to objects in the application prefix when paired with the appropriate action.

### Least-Privilege Principle

An application that only needs to read configuration files should not receive unnecessary permissions to write, delete, or administer unrelated S3 resources.

This lab uses a policy restricted to one bucket and one object prefix.

---

## 5. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- SSH client
- Python 3
- EC2 permissions
- IAM role and instance profile permissions
- S3 bucket management permissions
- Git and GitHub

### Security Requirements

- Use a private S3 bucket.
- Enable S3 Block Public Access.
- Use SSE-S3 for the test object.
- Use IAM roles rather than hardcoded AWS credentials.
- Restrict SSH to a trusted client IP.
- Keep private keys outside GitHub.
- Use a dedicated IAM role and instance profile.
- Remove all disposable lab resources after completion.

### Cost Considerations

This lab may generate charges for EC2 compute, EBS storage, public IPv4 usage, S3 storage, and API requests.

---

## 6. Prepare the Environment

### Step 1 — Create Lab Variables

From Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

export PROJECT_TAG="EC2-Troubleshooting-Lab10"

export INSTANCE_NAME="cloud-lab10-s3-instance"
export SG_NAME="cloud-lab10-s3-sg"
export KEY_NAME="cloud-lab10-s3-key"

export ROLE_NAME="cloud-lab10-ec2-s3-role"
export PROFILE_NAME="cloud-lab10-ec2-s3-profile"
export POLICY_NAME="cloud-lab10-s3-read-policy"

export OBJECT_KEY="app/config.txt"
```

Verify AWS identity:

```bash
aws sts get-caller-identity
```

### Step 2 — Generate Bucket Name

```bash
export BUCKET_NAME="cloud-lab10-s3-${ACCOUNT_ID}-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"

echo "$BUCKET_NAME"
```

S3 bucket names must be unique across the applicable AWS partition.

---

## 7. Create a Private S3 Bucket

### Step 1 — Create Bucket

```bash
aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION"
```

For `us-east-1`, no location constraint is needed in this request.

### Step 2 — Verify Ownership

```bash
aws s3api head-bucket \
  --bucket "$BUCKET_NAME" \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Block Public Access

```bash
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Configure SSE-S3

```bash
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' \
  --region "$AWS_REGION"
```

### Step 5 — Create Test Configuration File

Create `config.txt`:

```text
application=cloud-security-lab
environment=development
incident=INC-EC2-010
status=healthy
```

### Step 6 — Upload Test Object

```bash
aws s3api put-object \
  --bucket "$BUCKET_NAME" \
  --key "$OBJECT_KEY" \
  --body config.txt \
  --server-side-encryption AES256 \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Verify Object

```bash
aws s3api head-object \
  --bucket "$BUCKET_NAME" \
  --key "$OBJECT_KEY" \
  --region "$AWS_REGION"
```

**Important:** Successful S3 access from WSL2 does not prove that the EC2 instance's IAM role has access. These are separate identities.

---

## 8. Create an EC2 IAM Role

### Step 1 — Create Trust Policy

File: `ec2-trust-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 2 — Create IAM Role

Verify that the role name is unused before creating it:

```bash
aws iam get-role \
  --role-name "$ROLE_NAME"
```

For a new lab, `NoSuchEntity` is expected.

Create:

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Create Least-Privilege Policy

File: `s3-read-policy.json`

Replace `LAB_BUCKET_NAME` with the actual bucket created for the lab.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListApplicationPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::LAB_BUCKET_NAME",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "app/",
            "app/*"
          ]
        }
      }
    },
    {
      "Sid": "ReadApplicationObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::LAB_BUCKET_NAME/app/*"
    }
  ]
}
```

To generate the actual policy automatically from the WSL2 bucket variable:

```bash
cat > s3-read-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListApplicationPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["app/", "app/*"]
        }
      }
    },
    {
      "Sid": "ReadApplicationObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/app/*"
    }
  ]
}
EOF
```

### Step 4 — Attach Inline Policy

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://s3-read-policy.json
```

### Step 5 — Verify Policy

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME"
```

---

## 9. Create IAM Instance Profile

### Step 1 — Create Instance Profile

Confirm the profile name is unused.

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For a fresh lab, `NoSuchEntity` is expected.

Create:

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 2 — Add Role to Profile

```bash
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

### Step 3 — Verify Instance Profile

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

IAM changes can require a short propagation period before EC2 can use the profile.

---

## 10. Configure EC2 Networking

### Step 1 — Identify Default VPC

```bash
export VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query 'Vpcs[0].VpcId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Select Compatible Subnet

Find a default subnet in an Availability Zone that supports `t3.micro`.

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

Set the verified subnet:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

Confirm it has a route to an attached internet gateway.

### Step 3 — Create SSH Key Pair

```bash
mkdir -p ~/.ssh/aws-ec2-labs
chmod 700 ~/.ssh ~/.ssh/aws-ec2-labs

export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab10-s3-key.pem"
```

Before creating the key, confirm the local filename and AWS key-pair name are unused.

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

### Step 4 — Create Security Group

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Confirm the dedicated group does not already exist, then create it:

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab10 EC2 S3 permissions troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Allow SSH from the trusted IP:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

Verify outbound HTTPS connectivity is permitted by the security group.

---

## 11. Launch EC2 With Instance Profile

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check for Existing Lab Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text \
  --region "$AWS_REGION"
```

Do not create a duplicate.

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options \
    "HttpTokens=required,HttpEndpoint=enabled" \
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

### Step 5 — Verify Instance Profile

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile' \
  --output json \
  --region "$AWS_REGION"
```

### Step 6 — Retrieve Public IPv4

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — SSH Into EC2

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

For production access, verify the SSH host-key fingerprint through a trusted source.

---

## 12. Establish the Working Baseline

The following commands execute inside EC2.

### Step 1 — Check AWS CLI

```bash
aws --version
```

### Step 2 — Verify IAM Identity

```bash
aws sts get-caller-identity
```

Expected assumed-role ARN format:

```text
arn:aws:sts::ACCOUNT_ID:assumed-role/cloud-lab10-ec2-s3-role/SESSION_NAME
```

The session name can vary.

### Step 3 — Load Lab Variables

From WSL2, transfer the nonsensitive bucket name and object key to the EC2 shell environment as described in the hands-on exercise.

On EC2:

```bash
source ~/lab10-env.sh
```

Verify:

```bash
echo "$BUCKET_NAME"
echo "$OBJECT_KEY"
```

### Step 4 — List S3 Objects

```bash
aws s3api list-objects-v2 \
  --bucket "$BUCKET_NAME" \
  --prefix "app/" \
  --query 'Contents[].Key' \
  --output table \
  --region "$AWS_DEFAULT_REGION"
```

Expected:

```text
app/config.txt
```

### Step 5 — Download Configuration

```bash
aws s3api get-object \
  --bucket "$BUCKET_NAME" \
  --key "$OBJECT_KEY" \
  /tmp/lab10-config.txt \
  --region "$AWS_DEFAULT_REGION"
```

### Step 6 — Verify File

```bash
cat /tmp/lab10-config.txt
```

Expected:

```text
application=cloud-security-lab
environment=development
incident=INC-EC2-010
status=healthy
```

### Baseline Findings

| Check | Expected Result |
|---|---|
| EC2 status | Running |
| Instance profile | Attached |
| STS identity | Correct role |
| Network connectivity | Working |
| S3 bucket | Private |
| S3 listing | Successful |
| Object download | Successful |

---

## 13. Introduce IAM Permission Failure

Return to WSL2 to modify the dedicated role policy.

### Step 1 — Create Broken Policy

File: `broken-s3-policy.json`

Replace `LAB_BUCKET_NAME` with the actual lab bucket name.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListApplicationPrefixOnly",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::LAB_BUCKET_NAME",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "app/",
            "app/*"
          ]
        }
      }
    }
  ]
}
```

For a functional copy using the bucket variable:

```bash
cat > broken-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListApplicationPrefixOnly",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["app/", "app/*"]
        }
      }
    }
  ]
}
EOF
```

### Intentional Misconfiguration

The broken policy still grants `s3:ListBucket`, but it no longer grants `s3:GetObject`.

### Step 2 — Replace the Inline Policy

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://broken-s3-policy.json
```

### Step 3 — Verify Policy

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --query PolicyDocument \
  --output json
```

Expected: `s3:GetObject` is absent.

IAM permission changes may take time to propagate.

---

## 14. Reproduce the S3 AccessDenied Error

Connect to EC2 and load the lab variables:

```bash
source ~/lab10-env.sh
```

### Step 1 — Verify Role Identity

```bash
aws sts get-caller-identity
```

The instance should still use the intended Lab 10 role.

### Step 2 — Verify Object Listing

```bash
aws s3api list-objects-v2 \
  --bucket "$BUCKET_NAME" \
  --prefix "app/" \
  --query 'Contents[].Key' \
  --output table \
  --region "$AWS_DEFAULT_REGION"
```

Expected: listing succeeds.

### Step 3 — Attempt Object Download

```bash
aws s3api get-object \
  --bucket "$BUCKET_NAME" \
  --key "$OBJECT_KEY" \
  /tmp/lab10-denied.txt \
  --region "$AWS_DEFAULT_REGION"
```

Expected after policy propagation:

```text
An error occurred (AccessDenied)
when calling the GetObject operation
```

If it succeeds immediately after the policy change, allow for IAM propagation and retry.

### Observation

The instance has valid AWS credentials and can list the bucket prefix, but it cannot read the object.

This distinguishes missing object permissions from missing instance credentials.

---

## 15. Troubleshooting Investigation

### Check 1 — EC2 Instance Profile

From WSL2:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile' \
  --output json \
  --region "$AWS_REGION"
```

### Check 2 — Role Identity

Inside EC2:

```bash
aws sts get-caller-identity
```

### Check 3 — S3 DNS Resolution

```bash
getent ahostsv4 "s3.${AWS_DEFAULT_REGION}.amazonaws.com"
```

### Check 4 — HTTPS Connectivity

```bash
curl -I \
  --connect-timeout 5 \
  --max-time 10 \
  "https://s3.${AWS_DEFAULT_REGION}.amazonaws.com/"
```

An HTTP response from S3 indicates that the network can reach the endpoint. An unauthenticated request may return HTTP 403.

### Check 5 — IAM Inline Policy

From WSL2:

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --query PolicyDocument \
  --output json
```

### Check 6 — Compare Permissions

| Permission | Broken Policy | Working Policy |
|---|---|---|
| `s3:ListBucket` | Allowed | Allowed |
| `s3:GetObject` | Missing | Allowed |
| `s3:PutObject` | Not granted | Not granted |
| `s3:DeleteObject` | Not granted | Not granted |

### Investigation Findings

| Check | Finding |
|---|---|
| EC2 running | Yes |
| Instance profile attached | Yes |
| IAM role assumed | Yes |
| S3 DNS | Working |
| HTTPS connectivity | Working |
| S3 ListBucket | Successful |
| S3 GetObject | AccessDenied |
| Root cause | Missing object-read permission |

---

## 16. Root Cause Analysis

### Root Cause

The EC2 role's inline IAM policy does not contain the `s3:GetObject` action required to download objects.

### Technical Explanation

An S3 download request requires the appropriate object-level permission.

The IAM role continues to grant `s3:ListBucket`, so the application can discover object names.

However, object listing and object reading are separate operations.

Without the necessary `s3:GetObject` permission, the download request is denied.

### Root Cause Flow

```text
EC2 Application
      |
      v
Instance Profile Credentials
      |
      v
IAM Role Authenticated
      |
      v
S3 GetObject Request
      |
      v
IAM Authorization Evaluation
      |
      v
No Matching GetObject Allow
      |
      v
AccessDenied
```

### Five Whys

1. **Why couldn't EC2 download the object?** The S3 API denied the request.
2. **Why was the request denied?** The role lacked `s3:GetObject`.
3. **Why was the permission missing?** The role's inline policy was replaced with a list-only policy.
4. **Why did S3 listing still work?** The `s3:ListBucket` permission remained.
5. **How can this be prevented?** Validate IAM policies, apply least privilege carefully, and test required operations after permission changes.

---

## 17. Apply Remediation

### Step 1 — Restore the Original Policy

From WSL2:

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://s3-read-policy.json
```

### Step 2 — Verify Permissions

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --query PolicyDocument \
  --output json
```

Confirm the policy includes:

```text
s3:ListBucket
s3:GetObject
```

The resources should remain restricted to the Lab 10 bucket and the `app/` prefix.

### Step 3 — Retry From EC2

Inside EC2:

```bash
source ~/lab10-env.sh
```

Download:

```bash
aws s3api get-object \
  --bucket "$BUCKET_NAME" \
  --key "$OBJECT_KEY" \
  /tmp/lab10-recovered.txt \
  --region "$AWS_DEFAULT_REGION"
```

### Step 4 — Verify File Content

```bash
cat /tmp/lab10-recovered.txt
```

Expected:

```text
application=cloud-security-lab
environment=development
incident=INC-EC2-010
status=healthy
```

### Step 5 — Verify Incident Identifier

```bash
grep "INC-EC2-010" /tmp/lab10-recovered.txt
```

If IAM propagation has not completed, retry after the new policy becomes effective.

---

## 18. Verification Summary

| Check | Before Fix | After Fix |
|---|---|---|
| EC2 state | Running | Running |
| IAM role attached | Yes | Yes |
| STS identity | Correct | Correct |
| S3 network connectivity | Working | Working |
| ListBucket | Successful | Successful |
| GetObject | AccessDenied | Successful |
| Bucket public access | Blocked | Blocked |
| Hardcoded credentials | None | None |
| Access scope | Incorrect | Least privilege restored |

The incident is resolved when the application can download the intended object using the EC2 instance role without granting excessive permissions.

---

## 19. Advanced Troubleshooting Scenarios

### Scenario A — No Credentials

Possible error:

```text
Unable to locate credentials
```

Investigate:

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Check whether the instance profile is attached and whether the application is using the correct credential provider.

### Scenario B — ListBucket Denied

Possible error:

```text
AccessDenied when calling ListObjectsV2
```

Investigate bucket-level `s3:ListBucket` authorization.

### Scenario C — GetObject Denied

Possible error:

```text
AccessDenied when calling GetObject
```

Investigate object-level permissions, bucket policies, explicit denies, and encryption requirements.

### Scenario D — S3 Endpoint Unreachable

Possible error:

```text
Could not connect to the endpoint URL
```

Investigate:

- Subnet routing
- Internet or NAT gateway
- Security group egress
- Network ACLs
- DNS resolution
- S3 VPC endpoint configuration

### Scenario E — SSE-KMS Permissions

For objects encrypted using AWS KMS keys, additional KMS permissions may be necessary.

This lab uses SSE-S3 to avoid mixing KMS permissions into the primary failure.

### Additional Authorization Controls

Even when an identity-based policy allows `s3:GetObject`, access can still be denied by other applicable controls, including explicit denies, SCPs, permissions boundaries, resource policies, and VPC endpoint policies.

---

## 20. Production Engineering Considerations

### Recommended Investigation Sequence

1. Identify the failed AWS API operation.
2. Read the exact error message.
3. Verify instance profile association.
4. Confirm the role identity with STS.
5. Check network connectivity.
6. Inspect the role's IAM policies.
7. Verify the action and resource ARN.
8. Review applicable bucket and organization policies.
9. Check KMS permissions if applicable.
10. Apply the smallest required permission change.
11. Retest the original operation.
12. Document the root cause and remediation.

### Security Best Practices

- Use IAM roles for EC2 workloads.
- Avoid static AWS credentials.
- Restrict S3 permissions to required actions and resources.
- Block public access unless explicitly required.
- Encrypt S3 objects.
- Review permissions before deployment.
- Test authorization after IAM changes.
- Use CloudTrail and relevant access logs for investigation when configured.
- Avoid granting `s3:*` on `*` to solve access problems.
- Use infrastructure as code for repeatable IAM configuration.

---

## 21. Interview Questions and Answers

### Q1. What is an EC2 instance profile?

An instance profile is the mechanism used to associate an IAM role with an EC2 instance.

### Q2. Why should EC2 use IAM roles instead of access keys?

IAM roles provide temporary credentials and reduce the need to distribute or store long-lived credentials.

### Q3. What is the difference between `s3:ListBucket` and `s3:GetObject`?

`ListBucket` permits listing objects in a bucket. `GetObject` permits reading objects.

### Q4. Can an instance list S3 objects but fail to download them?

Yes. It may have `s3:ListBucket` but lack `s3:GetObject`.

### Q5. What does AccessDenied indicate?

The AWS service rejected the operation during authorization. The cause may involve identity-based permissions, resource policies, explicit denies, or other authorization controls.

### Q6. What command verifies the EC2 AWS identity?

```bash
aws sts get-caller-identity
```

### Q7. Does an EC2 instance need an IAM role to access S3?

It needs valid AWS credentials with the necessary permissions. An instance profile role is the recommended approach for applications running on EC2.

### Q8. How can S3 be accessed privately from a VPC?

A suitable S3 VPC endpoint can provide access without using public internet egress, depending on the VPC configuration and endpoint type.

### Q9. Why is least privilege important?

It limits the actions a workload can perform and reduces the impact of accidental misuse or compromise.

### Q10. How would you troubleshoot EC2 S3 AccessDenied?

> I would first verify the IAM instance profile and use STS to confirm the role identity. Then I would determine whether the failure is a connectivity error or an authorization response. I would inspect the required S3 action and the corresponding bucket or object ARN, along with relevant bucket policies and other access controls. After identifying the missing permission, I would restore the minimum required access and verify the original request.

### Q11. Why did this lab use SSE-S3 instead of SSE-KMS?

SSE-S3 allowed the exercise to focus on S3 authorization without introducing additional KMS access requirements.

### Q12. What is the key lesson from this incident?

Successful authentication and working network connectivity do not guarantee that an AWS API operation is authorized.

---

## 22. Cleanup

**Warning:** Only delete resources created specifically for Lab 10.

### Step 1 — Verify AWS Account

```bash
aws sts get-caller-identity
```

### Step 2 — Verify EC2 Ownership

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the project tag:

```text
EC2-Troubleshooting-Lab10
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Verify the volume's `DeleteOnTermination` setting.

### Step 4 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify S3 Bucket Contents

```bash
aws s3api list-objects-v2 \
  --bucket "$BUCKET_NAME" \
  --query 'Contents[].Key' \
  --output table \
  --region "$AWS_REGION"
```

Confirm that the bucket belongs exclusively to Lab 10.

### Step 6 — Delete Test Object

```bash
aws s3api delete-object \
  --bucket "$BUCKET_NAME" \
  --key "$OBJECT_KEY" \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete S3 Bucket

```bash
aws s3api delete-bucket \
  --bucket "$BUCKET_NAME" \
  --expected-bucket-owner "$ACCOUNT_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Inline IAM Policy

```bash
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME"
```

### Step 9 — Remove Role From Instance Profile

Confirm that the profile is not used by another active instance.

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

### Step 10 — Delete Instance Profile

```bash
aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

### Step 11 — Delete IAM Role

```bash
aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 12 — Delete Security Group

Verify no network interfaces reference the group:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Then:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete AWS SSH Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Local Private Key

```bash
rm -f "$KEY_FILE"
```

### Step 15 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If the volume no longer exists, AWS returns `InvalidVolume.NotFound`.

If it remains available, verify it is exclusively a Lab 10 volume before removing it.

### Cleanup Summary

| Resource | Expected Action |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| S3 object | Deleted |
| S3 bucket | Deleted |
| Inline IAM policy | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Security group | Deleted |
| AWS SSH key | Deleted |
| Local private key | Deleted |
| Default VPC | Preserved |

---

## 23. Repository Structure

```text
10-ec2-cannot-access-s3/
│
├── README.md
├── config.txt
├── ec2-trust-policy.json
├── s3-read-policy.json
└── broken-s3-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident documentation |
| `config.txt` | Test S3 object content |
| `ec2-trust-policy.json` | EC2 IAM role trust relationship |
| `s3-read-policy.json` | Working S3 read policy |
| `broken-s3-policy.json` | Intentionally incorrect policy |

**Note:** The example policy files contain the actual lab bucket ARN after generation. They are not credential files, but review them before publication. For a reusable public repository, you can replace the generated bucket name with a documented placeholder.

Never commit private keys or AWS credentials.

---

## 24. Lessons Learned

This lab demonstrated that an EC2 instance can have valid IAM role credentials and working S3 connectivity but still receive an authorization error.

The simulated failure was caused by removing `s3:GetObject` from the IAM role's inline policy.

The investigation included verifying the EC2 instance profile, identifying the assumed IAM role, testing S3 connectivity, comparing bucket-level and object-level permissions, and examining the failed operation.

The remediation restored object-read permission scoped to the required S3 prefix.

The key lesson is to distinguish authentication, authorization, and network connectivity before modifying AWS permissions.

---

## 25. Skills Demonstrated

- Amazon EC2 troubleshooting
- Amazon S3 authorization
- AWS IAM roles
- EC2 instance profiles
- IAM trust policies
- Identity-based IAM policies
- Least-privilege permission design
- AWS STS identity verification
- S3 ListBucket and GetObject permissions
- AWS CLI v2
- JSON policy configuration
- AccessDenied troubleshooting
- AWS credential-provider concepts
- Root cause analysis
- Production incident documentation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-010 |
| Problem | EC2 Cannot Download S3 Object |
| EC2 State | Running |
| IAM Instance Profile | Attached |
| AWS Identity | Correct assumed role |
| Root Cause | Missing `s3:GetObject` |
| ListBucket | Successful |
| GetObject Before Fix | AccessDenied |
| Remediation | Restore read permission |
| GetObject After Fix | Successful |
| Public S3 Access | Blocked |
| Static AWS Credentials | Not required |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 application receives S3 AccessDenied, confirm the role identity, inspect the exact S3 action and resource ARN, and restore only the permissions the application requires. Avoid solving authorization problems by granting broad access.

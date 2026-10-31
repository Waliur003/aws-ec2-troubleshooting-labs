# Lab 11 — Amazon EC2 Instance Profile Permission Error

## Overview

This hands-on lab demonstrates how to troubleshoot IAM credential and authorization problems on an Amazon EC2 instance.

An application running on EC2 needs AWS credentials and the appropriate IAM permissions to access AWS services. When the EC2 instance profile is missing or the attached IAM role does not allow the required API operation, AWS CLI commands and applications can fail.

In this lab, we reproduce two production-style incidents:

- **Scenario A — Missing Instance Profile:** The EC2 instance cannot obtain AWS credentials.
- **Scenario B — Insufficient IAM Permissions:** The instance has valid role credentials but receives an authorization error when calling the EC2 API.

We investigate both failures, implement appropriate fixes, verify successful API operations, and remove the temporary AWS resources.

**Troubleshooting workflow:**

Baseline → Reproduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-011 |
| AWS Services | EC2, IAM, STS, VPC |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, SSH, JSON |
| Scenario A | Missing IAM instance profile |
| Scenario B | Missing `ec2:DescribeInstances` |
| Authentication | Temporary IAM role credentials |
| Metadata Service | IMDSv2 |
| Remediation | Attach profile and correct IAM policy |
| Expected Outcome | Authorized EC2 API request succeeds |

---

## 1. Production Incident Scenario

A company operates an EC2 instance that runs infrastructure monitoring scripts.

These scripts need to call the AWS EC2 API to retrieve information about instances.

The engineering team encounters two different issues.

### Scenario A — Missing IAM Credentials

The monitoring script fails with:

```text
Unable to locate credentials.
You can configure credentials by running "aws configure".
```

Investigation shows that the EC2 instance has no IAM instance profile attached.

### Scenario B — Insufficient IAM Permissions

After an instance profile is attached, the script starts receiving temporary IAM credentials.

However, calling `DescribeInstances` fails with:

```text
An error occurred (UnauthorizedOperation)
when calling the DescribeInstances operation:
You are not authorized to perform this operation.
```

The role allows `ec2:DescribeRegions` but not `ec2:DescribeInstances`.

### Business Impact

- Failed infrastructure monitoring
- Broken AWS automation scripts
- Interrupted operational workflows
- Missing inventory information
- Application initialization failures
- Delayed deployments
- Increased incident response time

### Investigation Objective

Determine whether the failure is caused by missing credentials, incorrect instance profile attachment, or insufficient IAM permissions.

---

## 2. Architecture

### Scenario A — Missing Instance Profile

```text
              Amazon EC2
            Amazon Linux 2023
                    |
                    v
              AWS CLI / SDK
                    |
                    v
             Credential Chain
                    |
                    v
           No Instance Profile
                    |
                    v
        No IAM Role Credentials
                    |
                    X
          Unable to Locate
             Credentials
```

### Scenario B — Permission Error

```text
              Amazon EC2
                    |
                    v
             Instance Profile
                    |
                    v
                IAM Role
                    |
           +--------+--------+
           |                 |
           v                 v
   DescribeRegions     DescribeInstances
        Allowed             Missing
           |                 |
           v                 X
        Success       UnauthorizedOperation
```

### Corrected Architecture

```text
              Amazon EC2
                    |
                    v
            EC2 Instance Profile
                    |
                    v
                IAM Role
                    |
                    v
          Temporary Credentials
                    |
                    v
          IAM Permissions Policy
                    |
           +--------+--------+
           |                 |
           v                 v
     DescribeRegions   DescribeInstances
           |                 |
           +--------+--------+
                    |
                    v
           AWS EC2 API Success
```

---

## 3. Understanding IAM Roles and Instance Profiles

### IAM Role

An IAM role is an AWS identity with permission policies that determine which actions can be performed.

Unlike an IAM user, an IAM role is normally assumed to obtain temporary credentials.

### Trust Policy

The trust policy identifies the principal allowed to assume the role.

For an EC2 instance role, the service principal is:

```text
ec2.amazonaws.com
```

### Permissions Policy

A permissions policy defines the actions an assumed role is allowed to perform.

Example:

```json
{
  "Effect": "Allow",
  "Action": "ec2:DescribeInstances",
  "Resource": "*"
}
```

### Instance Profile

An instance profile is the AWS resource used to associate an IAM role with an EC2 instance.

A profile can be associated when launching an instance or attached to an existing running instance.

### Instance Metadata Service (IMDS)

EC2 provides access to instance-specific metadata through a link-local metadata service.

For an instance with an IAM role, temporary role credentials are available through its instance metadata endpoint.

The AWS CLI and SDK credential providers can retrieve these credentials automatically.

### Authentication vs Authorization

| Authentication | Authorization |
|---|---|
| Identifies the AWS caller | Determines allowed operations |
| Uses credentials | Evaluates policies |
| Can be investigated with STS | Requires checking IAM actions and resource scopes |
| Failure example: no credentials | Failure example: UnauthorizedOperation |

**Important:** Successful authentication does not guarantee permission to call a particular AWS API.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- SSH client
- Python 3
- IAM management permissions
- EC2 management permissions
- Git and GitHub

### Security Requirements

- Use a disposable EC2 instance.
- Create a dedicated IAM role and instance profile.
- Restrict SSH to your trusted public IPv4 address.
- Require IMDSv2.
- Avoid permanent AWS access keys on EC2.
- Apply minimum required IAM permissions.
- Verify AWS account and resource tags before cleanup.
- Do not modify roles used by other workloads.

### AWS Costs

The lab may incur EC2, EBS, public IPv4, and data-transfer charges.

IAM roles and instance profiles do not have separate usage fees.

---

## 5. Prepare AWS Environment

Run these commands from Ubuntu WSL2.

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="EC2-Troubleshooting-Lab11"

export INSTANCE_NAME="cloud-lab11-iam-instance"
export SG_NAME="cloud-lab11-iam-sg"
export KEY_NAME="cloud-lab11-iam-key"

export ROLE_NAME="cloud-lab11-ec2-role"
export PROFILE_NAME="cloud-lab11-instance-profile"
export POLICY_NAME="cloud-lab11-describe-policy"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account \
  --output text)
```

Verify:

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

Stop if no valid default VPC is found.

### Step 3 — Find a Compatible Subnet

List Availability Zones that support `t3.micro`:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

List default subnets:

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

Select an appropriate subnet:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

Ensure the subnet supports internet routing for SSH and outbound AWS API connectivity.

---

## 6. Create SSH Credentials

### Step 1 — Prepare SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs
chmod 700 ~/.ssh ~/.ssh/aws-ec2-labs
```

### Step 2 — Configure Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab11-iam-key.pem"
```

Check whether the local key already exists:

```bash
test ! -e "$KEY_FILE" || echo "Existing local key detected"
```

Check AWS:

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new lab, AWS returns `InvalidKeyPair.NotFound`.

### Step 3 — Create Key Pair

Only if both the local file and AWS key-pair name are unused:

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

## 7. Configure Security Group

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

### Step 3 — Create Security Group

Only if the name is unused:

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "EC2 Lab11 instance profile troubleshooting" \
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

Verify that the security group permits outbound HTTPS, which is normally enabled by default on a newly created group.

---

## 8. Launch EC2 Without an IAM Role

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate.

### Step 3 — Launch Instance

The command deliberately omits the instance profile.

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
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

### Step 4 — Verify Instance Health

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Missing Profile

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
null
```

### Step 6 — Retrieve Public IPv4

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Connect to EC2

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

For production access, independently verify the server's SSH host-key fingerprint.

---

## 9. Scenario A — Reproduce Missing Credentials

Execute these commands inside EC2.

### Check 1 — Verify AWS CLI

```bash
aws --version
```

### Check 2 — Attempt STS Identity Lookup

```bash
aws sts get-caller-identity
```

Expected:

```text
Unable to locate credentials.
You can configure credentials by running "aws configure".
```

The exact message can vary by AWS CLI version.

### Check 3 — Inspect Credential Environment

```bash
env | grep '^AWS_' || true
```

Check for shared credential configuration:

```bash
ls -la ~/.aws 2>/dev/null || true
```

Do not print AWS secrets.

### Check 4 — Investigate IMDSv2

Generate a metadata token:

```bash
TOKEN=$(curl -fsS \
  --connect-timeout 2 \
  --max-time 5 \
  -X PUT \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)
```

Check the IAM role metadata path:

```bash
curl -sS \
  -o /tmp/lab11-role-response \
  -w "HTTP Status: %{http_code}\n" \
  -H "X-aws-ec2-metadata-token: $TOKEN" \
  --connect-timeout 2 \
  --max-time 5 \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

Expected: IAM role metadata is unavailable, commonly indicated by HTTP 404.

Remove the response file:

```bash
rm -f /tmp/lab11-role-response
unset TOKEN
```

### Scenario A Findings

| Check | Expected Result |
|---|---|
| EC2 running | Yes |
| SSH | Working |
| Internet connectivity | Working |
| Instance profile | Missing |
| Temporary role credentials | Unavailable |
| STS request | Failed |
| Root cause | No IAM instance profile |

Exit:

```bash
exit
```

---

## 10. Create the IAM Trust Policy

File: `ec2-trust-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowEC2ToAssumeRole",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Explanation

The trust policy allows the EC2 service to assume the role.

It does not authorize the role to access every AWS service.

### Create the Role

From WSL2, first verify that the role name is unused:

```bash
aws iam get-role \
  --role-name "$ROLE_NAME"
```

For a new role, `NoSuchEntity` is expected.

Then create:

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

---

## 11. Create an Intentionally Limited IAM Policy

File: `limited-ec2-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowDescribeRegionsOnly",
      "Effect": "Allow",
      "Action": "ec2:DescribeRegions",
      "Resource": "*"
    }
  ]
}
```

### Explanation

This policy permits:

```text
ec2:DescribeRegions
```

It does not permit:

```text
ec2:DescribeInstances
```

This allows us to demonstrate the difference between successful authentication and insufficient authorization.

### Attach the Policy

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://limited-ec2-policy.json
```

Verify:

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME"
```

---

## 12. Create the Instance Profile

### Step 1 — Check Existing Profile

```bash
aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For a new profile, `NoSuchEntity` is expected.

### Step 2 — Create Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Add IAM Role

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

Expected: the profile contains `cloud-lab11-ec2-role`.

IAM changes may require a short propagation period.

---

## 13. Remediate Scenario A — Attach the Instance Profile

### Step 1 — Inspect Existing Associations

From WSL2:

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query 'IamInstanceProfileAssociations[].{ID:AssociationId,State:State,Profile:IamInstanceProfile.Arn}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: no active instance profile association.

### Step 2 — Attach the Profile

```bash
aws ec2 associate-iam-instance-profile \
  --instance-id "$INSTANCE_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --region "$AWS_REGION"
```

The operator executing this command must have the appropriate `ec2:AssociateIamInstanceProfile` and `iam:PassRole` permissions.

### Step 3 — Verify Association

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query 'IamInstanceProfileAssociations[].{ID:AssociationId,State:State,Profile:IamInstanceProfile.Arn}' \
  --output table \
  --region "$AWS_REGION"
```

Expected state:

```text
associated
```

### Step 4 — Verify From EC2

Reconnect:

```bash
ssh \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Run:

```bash
aws sts get-caller-identity
```

Expected ARN pattern:

```text
arn:aws:sts::ACCOUNT_ID:assumed-role/cloud-lab11-ec2-role/SESSION_NAME
```

The session name may vary.

### Check IMDSv2 Role Name

```bash
TOKEN=$(curl -fsS -X PUT \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
  http://169.254.169.254/latest/api/token)

curl -fsS \
  -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/

unset TOKEN
```

Expected:

```text
cloud-lab11-ec2-role
```

Do not retrieve or expose the actual metadata credentials.

### Scenario A Recovery

The instance can now obtain AWS credentials automatically through its IAM instance profile.

---

## 14. Scenario B — Reproduce an Authorization Failure

The instance now has credentials, but its IAM role has only one EC2 API permission.

### Step 1 — Test Allowed Operation

Inside EC2:

```bash
aws ec2 describe-regions \
  --region us-east-1 \
  --query 'Regions[0:3].RegionName' \
  --output table
```

Expected: successful response, assuming no additional policy restriction.

### Step 2 — Test Unauthorized Operation

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --max-results 5
```

Expected:

```text
An error occurred (UnauthorizedOperation)
when calling the DescribeInstances operation:
You are not authorized to perform this operation.
```

### Technical Explanation

The role's policy allows `DescribeRegions` but does not allow `DescribeInstances`.

The AWS CLI successfully authenticates using the role's temporary credentials.

The EC2 service then denies the requested action because no applicable permission grants it.

### Investigation Results

| Check | Expected Result |
|---|---|
| Instance profile | Attached |
| STS identity | Successful |
| IMDSv2 role name | Available |
| DescribeRegions | Successful |
| DescribeInstances | UnauthorizedOperation |
| Root cause | Missing IAM action |

Exit EC2:

```bash
exit
```

---

## 15. Root Cause Analysis

### Scenario A — Missing Profile

**Root Cause:** The EC2 instance was launched without an IAM instance profile, so its application could not obtain temporary role credentials.

### Scenario B — Missing Permission

**Root Cause:** The attached IAM role had a valid trust relationship and working credentials but lacked `ec2:DescribeInstances`.

### Combined Root Cause Flow

```text
EC2 AWS API Request
        |
        v
Credential Discovery
        |
        +-- No Instance Profile
        |         |
        |         v
        |    No Credentials
        |         |
        |         v
        |    Request Cannot Authenticate
        |
        +-- Instance Profile Attached
                  |
                  v
           Temporary Credentials
                  |
                  v
          IAM Policy Evaluation
                  |
          +-------+-------+
          |               |
          v               v
     Action Allowed   Action Missing
          |               |
          v               v
       Success     UnauthorizedOperation
```

### Five Whys — Scenario B

1. **Why did the EC2 API call fail?** The service rejected the operation.
2. **Why was the operation rejected?** The role lacked `ec2:DescribeInstances`.
3. **Why was the permission absent?** The attached policy allowed only `DescribeRegions`.
4. **Why were credentials still valid?** Authentication and authorization are separate.
5. **How can this be prevented?** Review IAM actions, test required APIs, and manage policies through controlled infrastructure changes.

---

## 16. Remediate Scenario B — Correct the IAM Policy

File: `fixed-ec2-policy.json`

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLabEC2ReadOnlyAPIs",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions",
        "ec2:DescribeInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

### Why Resource Is `*`

The `DescribeRegions` and `DescribeInstances` actions do not support resource-level scoping in ordinary IAM identity policies.

Using `Resource: "*"` with only these specific read-only actions does not grant permission to launch, modify, or terminate EC2 instances.

### Step 1 — Replace the Inline Policy

From WSL2:

```bash
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document file://fixed-ec2-policy.json
```

### Step 2 — Verify Policy

```bash
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --query PolicyDocument \
  --output json
```

Verify both actions are present:

```text
ec2:DescribeRegions
ec2:DescribeInstances
```

### Step 3 — Verify From EC2

Connect:

```bash
ssh \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Verify identity:

```bash
aws sts get-caller-identity
```

Retry the previously denied API operation:

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --max-results 5 \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table
```

Expected: successful response.

If AWS still denies the operation immediately after updating the policy, allow for IAM propagation and check for additional permission restrictions.

Exit:

```bash
exit
```

---

## 17. Final Verification

| Test | Before Remediation | After Remediation |
|---|---|---|
| EC2 instance state | Running | Running |
| Instance profile | Missing initially | Attached |
| STS credentials | Unavailable initially | Available |
| IAM role | Not attached initially | Attached |
| DescribeRegions | Allowed after profile attachment | Allowed |
| DescribeInstances | UnauthorizedOperation | Successful |
| IMDSv2 | Enabled | Enabled |
| Static access keys | Not required | Not required |
| EC2 status checks | OK | OK |

### Success Criteria

The incident is considered resolved when:

- EC2 has the intended instance profile.
- `aws sts get-caller-identity` returns the correct assumed role.
- `DescribeRegions` succeeds.
- `DescribeInstances` succeeds.
- No static AWS credentials were stored on EC2.
- EC2 status checks remain healthy.

---

## 18. Production Engineering Considerations

### Common IAM Instance Profile Problems

| Error | Possible Cause | Investigation |
|---|---|---|
| Unable to locate credentials | Missing profile or credential provider issue | EC2 association, IMDS |
| UnauthorizedOperation | Missing EC2 permission | IAM policy |
| AccessDenied | Authorization restriction | Policies and resource scope |
| Wrong assumed role | Incorrect profile or credential precedence | STS identity |
| Invalid instance profile | Missing or unpropagated profile | IAM instance profile |
| PassRole denied | Operator lacks delegation permission | `iam:PassRole` |
| Metadata request fails | IMDS configuration or connectivity issue | Metadata options and IMDSv2 |

### Recommended Troubleshooting Order

1. Identify the exact AWS API error.
2. Check the instance profile association.
3. Verify credentials with STS.
4. Inspect IMDSv2 configuration.
5. Confirm the IAM role and trust policy.
6. Identify the required API action.
7. Inspect identity-based permissions.
8. Check for explicit denies and other permission controls.
9. Apply minimum necessary permissions.
10. Retry the original API call.
11. Document the fix and prevention measures.

### Security Best Practices

- Use instance profiles instead of hardcoded credentials.
- Require IMDSv2 where supported.
- Restrict IAM permissions to required operations.
- Avoid AdministratorAccess for ordinary EC2 workloads.
- Limit `iam:PassRole` to approved roles.
- Use AWS CloudTrail to investigate IAM configuration changes.
- Manage IAM roles with Terraform or CloudFormation.
- Use short-lived credentials.
- Review IAM policies before deployment.
- Verify AWS identity before troubleshooting authorization.

### Important Production Lesson

An IAM policy with the correct actions cannot solve a missing-credentials problem if the application has no way to obtain the role credentials.

Likewise, attaching an instance profile cannot solve every authorization error if the role's permissions are insufficient.

Always identify which failure category applies first.

---

## 19. Interview Questions and Answers

### Q1. What is an EC2 instance profile?

An instance profile is an AWS resource used to attach an IAM role to an EC2 instance.

### Q2. What is the difference between an IAM role and an instance profile?

An IAM role defines an identity and permissions. An instance profile provides the mechanism for EC2 to use that role.

### Q3. Why would EC2 report Unable to locate credentials?

The application may not have a usable credential provider, such as an attached IAM role, or credentials may not be accessible through its configuration.

### Q4. What command verifies the AWS identity used by EC2?

```bash
aws sts get-caller-identity
```

### Q5. What is the difference between authentication and authorization?

Authentication establishes the caller's identity. Authorization determines whether that identity can perform an action.

### Q6. Can EC2 have valid credentials but still receive UnauthorizedOperation?

Yes. The IAM role may lack the required API permission.

### Q7. What does `iam:PassRole` do?

It authorizes an IAM principal to pass an IAM role to a supported AWS service, subject to the applicable policies and conditions.

### Q8. What is IMDSv2?

IMDSv2 is the token-based version of the EC2 Instance Metadata Service.

### Q9. Why should AWS access keys not be stored permanently on EC2?

Long-lived credentials create additional security and rotation risks. Instance profiles provide temporary credentials automatically.

### Q10. How do you inspect EC2 instance profile associations?

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=INSTANCE_ID"
```

### Q11. Does attaching a role automatically authorize every AWS API call?

No. The role's permission policies and other applicable policy controls determine what the caller can do.

### Q12. How would you explain this lab in an interview?

> I investigated two EC2 IAM failures. First, an instance could not call AWS APIs because it had no instance profile, so temporary credentials were unavailable. I created a dedicated IAM role and instance profile, attached it to the running EC2 instance, and verified the assumed role using AWS STS. Next, I reproduced an authorization error by allowing DescribeRegions but excluding DescribeInstances. I identified the missing IAM action, updated the policy with the required read-only permission, and verified that the original EC2 API request succeeded. I completed the lab without storing permanent AWS access keys.

---

## 20. Cleanup

**Warning:** Delete only resources created for Lab 11. Verify resource tags, names, and AWS account before destructive operations.

### Step 1 — Verify AWS Identity

From WSL2:

```bash
aws sts get-caller-identity
```

### Step 2 — Verify EC2 Ownership

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project: EC2-Troubleshooting-Lab11
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check root-volume automatic deletion:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 4 — Terminate the EC2 Instance

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

### Step 5 — Verify IAM Role Ownership

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"
```

Confirm the role belongs to Lab 11.

### Step 6 — Delete Inline Policy

```bash
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME"
```

### Step 7 — Verify Instance Profile Is Not in Use

```bash
aws ec2 describe-iam-instance-profile-associations \
  --filters "Name=iam-instance-profile.arn,Values=arn:aws:iam::${ACCOUNT_ID}:instance-profile/${PROFILE_NAME}" \
  --query 'IamInstanceProfileAssociations[].{Instance:InstanceId,State:State}' \
  --output table \
  --region "$AWS_REGION"
```

Do not delete a profile that is still actively used by another instance.

### Step 8 — Remove Role From Profile

```bash
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

### Step 9 — Delete Profile

```bash
aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

### Step 10 — Delete IAM Role

```bash
aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 11 — Check Security Group Dependencies

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

### Step 12 — Delete SSH Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

Remove the local private key:

```bash
rm -f "$KEY_FILE"
```

### Step 13 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Expected after automatic deletion:

```text
InvalidVolume.NotFound
```

If the EBS volume remains, verify its ownership and attachment status before removing it.

### Cleanup Summary

| Resource | Expected Action |
|---|---|
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| IAM inline policy | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Security group | Deleted |
| EC2 key pair | Deleted |
| Local SSH key | Deleted |
| Default VPC | Preserved |
| Default subnet | Preserved |

---

## 21. Repository Structure

```text
11-instance-profile-permission-error/
│
├── README.md
├── ec2-trust-policy.json
├── limited-ec2-policy.json
└── fixed-ec2-policy.json
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete troubleshooting documentation |
| `ec2-trust-policy.json` | Trust relationship for EC2 |
| `limited-ec2-policy.json` | Intentionally insufficient policy |
| `fixed-ec2-policy.json` | Corrected IAM permissions policy |

These policy files provide reusable examples for IAM troubleshooting.

Do not upload AWS credentials or SSH private keys.

---

## 22. Lessons Learned

This lab demonstrated two different AWS IAM problems that can affect applications running on EC2.

The first problem occurred because the instance had no IAM instance profile and therefore could not obtain the expected temporary AWS credentials.

The second problem occurred after the instance profile was attached. The role credentials worked, but the IAM policy did not authorize the `DescribeInstances` API operation.

The remediation involved attaching the dedicated instance profile and updating the IAM role's policy to allow the required read-only action.

The exercise reinforced the importance of verifying AWS identity before changing authorization policies.

**The key lesson is to distinguish credential discovery failures from IAM permission failures and apply the smallest necessary fix.**

---

## 23. Skills Demonstrated

- Amazon EC2 troubleshooting
- AWS Identity and Access Management
- EC2 instance profiles
- IAM role trust policies
- IAM permissions policies
- AWS STS
- Temporary AWS credentials
- IMDSv2
- Authentication troubleshooting
- Authorization troubleshooting
- AWS CLI v2
- IAM least-privilege design
- Linux administration
- AWS API diagnostics
- Root cause analysis
- Production incident response
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-011 |
| Initial Problem | Missing IAM credentials |
| Secondary Problem | Unauthorized EC2 API operation |
| Root Cause A | Missing instance profile |
| Root Cause B | Missing `ec2:DescribeInstances` permission |
| Authentication Fix | Attach instance profile |
| Authorization Fix | Update role permissions |
| STS Verification | Successful |
| DescribeRegions | Successful |
| DescribeInstances | Successful after fix |
| Permanent AWS Keys | Not required |
| EC2 Health | OK |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 instance cannot access AWS APIs, first identify the credentials it is using. Then inspect the IAM permissions required for the failed operation. A correct instance profile and a least-privilege policy are both necessary for secure, reliable AWS automation.

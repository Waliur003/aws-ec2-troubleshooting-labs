# Lab 03 — Amazon EC2 SSH Permission Denied (`publickey`)

## Overview

This hands-on lab demonstrates how to troubleshoot an SSH authentication failure on an Amazon EC2 Linux instance.

The simulated production incident involves an EC2 instance that is running successfully, passing both AWS status checks, and accepting TCP connections on port 22. However, an engineer cannot log in because the private SSH key being used does not match the public key authorized on the instance.

The exercise focuses on distinguishing authentication failures from network connectivity problems.

**Root Cause:** Incorrect SSH private key.

**Remediation:** Use the matching private key with the correct Linux username.

**Troubleshooting workflow:**

Establish Baseline → Reproduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-003 |
| AWS Services | Amazon EC2, Amazon VPC |
| Supporting Components | EC2 Key Pairs, Security Groups |
| Difficulty | Beginner–Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Error | `Permission denied (publickey)` |
| Protocol | SSH / TCP 22 |
| Root Cause | Incorrect SSH private key |
| Remediation | Use correct private key |
| Environment | Ubuntu Linux / WSL2 |
| Tools | AWS CLI v2, Bash, OpenSSH |
| Verification | Successful Linux SSH login |

---

## 1. Production Incident Scenario

### Incident Description

A Cloud Operations Engineer needs to access a Linux EC2 instance for routine administration.

The instance is running, its EC2 status checks are healthy, and the security group permits SSH connections from the engineer's public IPv4 address.

However, the engineer attempts to connect and receives an authentication error.

### Reported Error

```text
ec2-user@PUBLIC_IP: Permission denied (publickey).
```

### Expected Behavior

The engineer should authenticate using the private SSH key corresponding to the public key authorized for the `ec2-user` account.

### Actual Behavior

The SSH server rejects the presented identity because the wrong private key is being used.

### Potential Business Impact

- Administrative access unavailable
- Delayed troubleshooting and maintenance
- Increased incident response time
- Failed automation relying on SSH
- Disruption to deployment or operational workflows

### Investigation Objective

Determine why authentication fails even though TCP port 22 is reachable.

---

## 2. Architecture

### Broken Architecture

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
               TCP 22 Allowed
                  |
                  v
           Amazon EC2 Instance
                  |
                  v
             SSH Server
                  |
                  v
        Incorrect Private Key
                  |
                  X
       Public Key Authentication
                  |
                  v
       Permission denied (publickey)
```

### Corrected Architecture

```text
            Cloud Engineer
             Ubuntu WSL2
                  |
                  | Correct Private Key
                  v
           Amazon EC2 Instance
                  |
                  v
             SSH Server
                  |
                  v
        Authorized Public Key
                  |
                  v
            Key Verification
                  |
                  v
        Authentication Successful
                  |
                  v
          Amazon Linux Shell
```

---

## 3. Understanding SSH Authentication

SSH stands for Secure Shell. It provides encrypted remote access to computers and servers.

Amazon EC2 Linux instances commonly use SSH public-key authentication.

### How Public-Key Authentication Works

1. An SSH key pair contains a private key and a public key.
2. The public key is authorized for a Linux user on the server.
3. The SSH client presents the corresponding public-key identity and proves possession of the private key.
4. The SSH server checks whether that public key is authorized.
5. Authentication succeeds only when the user and key are accepted.

The private key must remain on the client and should never be shared.

### Important SSH Components

| Component | Purpose |
|---|---|
| SSH client | Starts the connection |
| SSH server | Accepts SSH connections |
| TCP port 22 | Default SSH port |
| Private key | Authenticates the client |
| Public key | Trusted identity on the server |
| `authorized_keys` | Stores authorized public keys |
| Linux username | Determines which user account is accessed |
| Security group | Controls permitted network traffic |

### SSH Error Comparison

| Error | Interpretation |
|---|---|
| `Connection timed out` | Network connectivity problem |
| `Connection refused` | TCP port actively rejected |
| `Permission denied (publickey)` | Public-key authentication failure |
| `Host key verification failed` | Server identity verification problem |
| `UNPROTECTED PRIVATE KEY FILE` | Local private-key permissions are too open |

This lab specifically investigates public-key authentication.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- OpenSSH client
- Basic Linux knowledge
- EC2 and VPC permissions
- Permission to create EC2 key pairs
- Git and GitHub

### Security Requirements

- Use a dedicated disposable EC2 instance.
- Restrict SSH access to your public IP.
- Do not commit private SSH keys.
- Do not share private-key material.
- Avoid modifying production authorized keys.
- Use least-privilege AWS permissions.
- Remove lab resources after completion.

### Cost Considerations

This lab creates:

- One EC2 instance
- One EBS root volume
- One public IPv4 address
- One security group
- One AWS EC2 key pair

These resources may incur charges.

---

## 5. Prepare the AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

export INSTANCE_NAME="cloud-lab03-ssh-instance"
export SG_NAME="cloud-lab03-ssh-sg"
export KEY_NAME="cloud-lab03-correct-key"
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
```

Verify:

```bash
echo "$VPC_ID"
```

### Step 4 — Check Supported Instance Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 5 — Select a Compatible Subnet

```bash
export SUBNET_ID=$(python3 - <<'PY'
import json
import os
import subprocess

region = os.environ["AWS_REGION"]
vpc = os.environ["VPC_ID"]

def aws_json(args):
    result = subprocess.check_output(
        ["aws", "ec2", *args, "--region", region, "--output", "json"],
        text=True
    )
    return json.loads(result)

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
    raise SystemExit("No compatible default subnet found")

print(
    sorted(candidates, key=lambda s: s["AvailabilityZone"])[0]["SubnetId"]
)
PY
)
```

Verify:

```bash
echo "$SUBNET_ID"
```

The subnet must have appropriate internet routing for direct public SSH access.

---

## 6. Create SSH Key Pairs

Two SSH keys are used in this exercise.

**Correct key:** Registered with EC2 at launch.

**Incorrect key:** Generated locally and deliberately used to produce an authentication failure.

### Step 1 — Prepare SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 2 — Configure Key Paths

```bash
export CORRECT_KEY="$HOME/.ssh/aws-ec2-labs/cloud-lab03-correct.pem"

export WRONG_KEY="$HOME/.ssh/aws-ec2-labs/cloud-lab03-wrong.pem"
```

Verify neither path contains an existing key that must be preserved.

### Step 3 — Create Correct EC2 Key Pair

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$CORRECT_KEY"
```

Protect the file:

```bash
chmod 400 "$CORRECT_KEY"
```

### Step 4 — Generate Incorrect Local Key

```bash
ssh-keygen \
  -t ed25519 \
  -f "$WRONG_KEY" \
  -N "" \
  -C "ec2-lab03-wrong-key"
```

Secure it:

```bash
chmod 400 "$WRONG_KEY"
```

### Step 5 — Compare Public-Key Fingerprints

Correct key:

```bash
ssh-keygen -y -f "$CORRECT_KEY" | ssh-keygen -lf -
```

Incorrect key:

```bash
ssh-keygen -y -f "$WRONG_KEY" | ssh-keygen -lf -
```

The fingerprints should differ.

**Important:** Never print private-key contents or upload `.pem` files to GitHub.

---

## 7. Configure Security Group

### Step 1 — Create Dedicated Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "EC2 Lab 03 SSH authentication troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$SG_ID"
```

### Step 2 — Identify Client Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Verify:

```bash
echo "$MY_IP"
```

### Step 3 — Allow SSH From Trusted IP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Inbound Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Protocol: TCP
Port: 22
Source: YOUR_PUBLIC_IP/32
```

### Security Explanation

The `/32` CIDR allows SSH traffic from one specified IPv4 address.

It prevents the lab from unnecessarily exposing SSH to every public IPv4 address.

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

### Step 2 — Launch Using the Correct Key Pair

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab03-ssh-instance},{Key=Project,Value=EC2-Troubleshooting-Lab03}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Instance Health

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Check both status checks:

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

### Step 5 — Retrieve Public IP

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

## 9. Reproduce SSH Authentication Failure

### Step 1 — Verify TCP Port 22

```bash
timeout 10 bash -c \
  "echo > /dev/tcp/$PUBLIC_IP/22"
```

A successful connection normally exits without output.

This confirms TCP reachability before testing authentication.

### Step 2 — Connect Using the Wrong Key

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$WRONG_KEY" \
  ec2-user@"$PUBLIC_IP"
```

### Expected Error

```text
ec2-user@PUBLIC_IP: Permission denied (publickey).
```

### Observation

The EC2 instance is reachable, but SSH authentication fails.

The SSH client's private key does not correspond to the public key authorized for the `ec2-user` account.

---

## 10. Troubleshooting Investigation

### Check 1 — Inspect SSH Verbose Output

```bash
ssh -vvv \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$WRONG_KEY" \
  ec2-user@"$PUBLIC_IP"
```

Relevant output may contain:

```text
Offering public key
Authentications that can continue: publickey
No more authentication methods to try
Permission denied (publickey)
```

### What This Indicates

The SSH client attempted public-key authentication, but the server did not accept the offered identity.

### Check 2 — Verify EC2 Key Pair Association

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{Instance:InstanceId,KeyPair:KeyName,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
KeyPair: cloud-lab03-correct-key
```

### Check 3 — Compare Local Public Keys

```bash
ssh-keygen -y -f "$CORRECT_KEY" | ssh-keygen -lf -
```

```bash
ssh-keygen -y -f "$WRONG_KEY" | ssh-keygen -lf -
```

Expected: different fingerprints.

### Check 4 — Verify the Linux Username

Common default usernames:

| AMI | Username |
|---|---|
| Amazon Linux 2023 | `ec2-user` |
| Amazon Linux 2 | `ec2-user` |
| Ubuntu | `ubuntu` |
| Debian | `admin` |
| RHEL | `ec2-user` |

Default usernames depend on the AMI.

Our instance uses Amazon Linux 2023, so the appropriate default username is `ec2-user`.

### Check 5 — Inspect Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Confirm that TCP port 22 is allowed from the trusted client IP.

### Investigation Summary

| Check | Finding |
|---|---|
| EC2 running | Yes |
| Instance health | OK |
| System health | OK |
| Public IPv4 | Assigned |
| TCP 22 | Reachable |
| Security group | Correct |
| Linux username | `ec2-user` |
| EC2 key association | Correct key pair |
| Presented private key | Wrong key |
| SSH authentication | Rejected |
| Root cause | SSH identity mismatch |

---

## 11. Root Cause Analysis

### Root Cause

The engineer attempted to authenticate using a private SSH key that did not match the public key trusted by the EC2 instance.

### Root Cause Flow

```text
Engineer Starts SSH
         |
         v
TCP Connection Established
         |
         v
SSH Authentication Begins
         |
         v
Incorrect Private Key Offered
         |
         v
Server Checks Authorized Public Keys
         |
         v
No Matching Authorized Identity
         |
         v
Permission denied (publickey)
```

### Five Whys

1. **Why couldn't the engineer log in?** SSH authentication was rejected.
2. **Why was authentication rejected?** The offered key was not authorized.
3. **Why was the wrong key offered?** The SSH command referenced an unrelated private key.
4. **Why did the server reject that identity?** Its matching public key was not installed for the target Linux user.
5. **How can the issue be prevented?** Maintain reliable key-pair records, verify usernames, and use explicit SSH identity configuration.

---

## 12. Apply Remediation

### Step 1 — Verify Correct Key Permissions

```bash
chmod 400 "$CORRECT_KEY"
```

Check:

```bash
ls -l "$CORRECT_KEY"
```

### Step 2 — Connect Using Correct Private Key

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$CORRECT_KEY" \
  ec2-user@"$PUBLIC_IP"
```

Expected: successful SSH login.

### Why This Works

The private key now corresponds to the public key authorized on the EC2 instance.

The SSH server can validate the client's proof of private-key possession and allow access.

### Step 3 — Verify Login

Inside the EC2 instance:

```bash
whoami
```

Expected:

```text
ec2-user
```

### Step 4 — Verify Operating System

```bash
cat /etc/os-release
```

Expected: Amazon Linux 2023.

### Step 5 — Verify SSH Service

```bash
sudo systemctl status sshd --no-pager
```

Expected:

```text
active (running)
```

### Step 6 — Verify Authorized Key Permissions

```bash
stat -c '%a %n' ~/.ssh ~/.ssh/authorized_keys
```

Typical secure values:

```text
700 /home/ec2-user/.ssh
600 /home/ec2-user/.ssh/authorized_keys
```

### Step 7 — Exit

```bash
exit
```

---

## 13. Recovery Verification

| Test | Before Fix | After Fix |
|---|---|---|
| EC2 running | Yes | Yes |
| TCP port 22 | Reachable | Reachable |
| Security group | Correct | Correct |
| Linux username | Correct | Correct |
| Private key | Wrong | Correct |
| Authentication | Rejected | Accepted |
| SSH shell | Unavailable | Available |
| SSH daemon | Not inspected | Verified |

### Recovery Criteria

The incident is resolved when:

- The correct private key is used.
- The correct Linux username is specified.
- The SSH server accepts the authentication.
- The engineer can access the Linux shell.
- No unnecessary network exposure is introduced.

---

## 14. Production Engineering Considerations

### Common Causes of `Permission denied (publickey)`

- Incorrect private key
- Incorrect Linux username
- Public key missing from `authorized_keys`
- Incorrect `authorized_keys` permissions
- Incorrect `.ssh` directory permissions
- SSH client offering the wrong identity
- SSH agent configuration problems
- SSH server configuration restrictions
- Account-level SSH access restrictions

### Recommended Troubleshooting Order

1. Confirm the instance is running.
2. Verify TCP port 22 is reachable.
3. Check the Linux username.
4. Confirm the EC2 key pair association.
5. Inspect the private key file.
6. Run SSH with `-vvv`.
7. Check which public key is being offered.
8. Compare public-key fingerprints.
9. Review `authorized_keys` when authorized access is available.
10. Retry with the correct credentials.

### Security Recommendations

- Keep private keys outside source repositories.
- Use restricted private-key file permissions.
- Avoid sharing SSH private keys between engineers.
- Prefer short-lived access and centralized access management where practical.
- Use AWS Systems Manager Session Manager when appropriate.
- Remove unused key pairs.
- Audit SSH access.
- Restrict security group rules to trusted networks.

---

## 15. Related SSH Errors

| Error | Possible Cause |
|---|---|
| `Permission denied (publickey)` | Key or username authentication issue |
| `Connection timed out` | Network reachability problem |
| `Connection refused` | SSH port rejected or daemon unavailable |
| `Host key verification failed` | Server identity mismatch |
| `UNPROTECTED PRIVATE KEY FILE` | Private key permissions too broad |
| `Too many authentication failures` | Excessive identities offered by SSH client |
| `No such identity` | Incorrect private-key file path |

---

## 16. Interview Questions and Answers

### Q1. What does `Permission denied (publickey)` mean?

The SSH server did not accept any of the public-key identities presented for the requested Linux user.

### Q2. How is it different from an SSH timeout?

A timeout typically occurs before SSH authentication because the connection cannot be established. A public-key denial occurs after SSH communication reaches authentication.

### Q3. What is the default SSH username for Amazon Linux 2023?

`ec2-user`.

### Q4. What does `ssh -vvv` do?

It enables highly verbose SSH debugging output to help inspect connection and authentication behavior.

### Q5. What does `IdentitiesOnly=yes` do?

It limits SSH authentication to configured or explicitly specified identities rather than trying unrelated agent identities.

### Q6. Why should the private key have restricted permissions?

To prevent unauthorized local users from reading or using it. OpenSSH may reject keys with overly permissive file permissions.

### Q7. What is `authorized_keys`?

A file listing public keys authorized to authenticate to a Linux user account.

### Q8. Can you recover access if the correct private key is lost?

Potentially, through authorized recovery mechanisms such as EC2 Instance Connect, Systems Manager Session Manager, or offline root-volume repair, depending on instance configuration and access.

### Q9. Should SSH port 22 be open to the entire internet?

Generally no. Administrative access should be restricted to trusted sources or provided through safer access mechanisms.

### Q10. How would you explain this incident in an interview?

> I investigated an SSH authentication failure on a healthy EC2 instance. I first verified that TCP port 22 was reachable, which ruled out the initial network connection problem. Then I checked the instance's configured key pair, confirmed the Linux username, and used `ssh -vvv` to inspect the offered identity. I found that the SSH client was using an incorrect private key. After switching to the correct key, authentication succeeded. I verified shell access, the operating system, and the SSH service.

---

## 17. Cleanup

**Warning:** These steps permanently remove resources created for the isolated Lab 03 environment.

### Step 1 — Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Lab Instance

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the project tag:

```text
EC2-Troubleshooting-Lab03
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check deletion settings:

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

### Step 5 — Verify Network Interface Cleanup

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Confirm no network interfaces depend on the security group.

### Step 6 — Delete Lab Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete AWS Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 8 — Delete Local Lab Keys

```bash
rm -f "$CORRECT_KEY"
rm -f "$WRONG_KEY"
rm -f "${WRONG_KEY}.pub"
```

Only remove the keys generated for this lab.

### Step 9 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If the volume has been automatically deleted, AWS should return `InvalidVolume.NotFound`.

If the dedicated test volume remains and is `available`, confirm its identity before deleting:

```bash
aws ec2 delete-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Do not delete any unrelated EBS volume.

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

Keep the default VPC and subnets for future EC2 troubleshooting labs.

---

## 18. Repository Structure

```text
03-ssh-permission-denied/
│
└── README.md
```

All commands needed to reproduce and investigate the authentication failure are documented in this README.

Private SSH keys and temporary AWS resource identifiers should not be included in the public repository.

---

## 19. Lessons Learned

This lab demonstrated how SSH authentication can fail even when the EC2 instance is running, network routing is correct, and port 22 is accessible.

The root cause was an incorrect SSH private key.

The investigation involved inspecting SSH verbose logs, reviewing the EC2 key-pair association, comparing public-key fingerprints, and verifying the Linux username.

The remediation involved using the correct private key with restrictive file permissions.

The lab reinforced the importance of separating network connectivity troubleshooting from authentication troubleshooting.

---

## 20. Skills Demonstrated

- Amazon EC2
- SSH public-key authentication
- Linux SSH administration
- EC2 key pairs
- OpenSSH debugging
- AWS CLI v2
- Security groups
- Public IPv4 networking
- Private-key file permissions
- Authorized public keys
- Root cause analysis
- Least-privilege security
- Production incident remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-003 |
| Problem | SSH Permission Denied |
| Instance State | Running |
| Network Connectivity | Working |
| Root Cause | Incorrect private SSH key |
| Remediation | Use matching private key |
| SSH Authentication | Successful |
| Linux Access | Verified |
| Security Group | Restricted to trusted `/32` |
| Resource Cleanup | EC2 and temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When SSH reports `Permission denied (publickey)`, first confirm network connectivity, then investigate the Linux username, EC2 key-pair association, private-key identity, SSH debug logs, and authorized public keys.

# Lab 05 — Amazon EC2 User Data Script Failure

## Overview

This lab demonstrates how to troubleshoot a failed Amazon EC2 user-data script using AWS CLI, Linux, cloud-init, and systemd.

The simulated production incident involves an Amazon Linux 2023 instance that launches successfully but fails to configure its web application during startup.

Although the instance reaches the `running` state and passes EC2 health checks, its HTTP application remains unavailable.

The failure occurs because the user-data script contains an invalid Linux command:

```bash
mkdirr -p /opt/ec2-lab05/www
```

Because the script uses `set -e`, this command causes execution to stop before the application and systemd service are created.

The goal is to investigate the failure, identify the incorrect command, repair the application, and verify that the corrected script works on a newly launched instance.

**Troubleshooting workflow:**

Baseline → Failure Simulation → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-005 |
| AWS Services | Amazon EC2, Amazon VPC |
| Primary Technology | EC2 User Data / cloud-init |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| AWS Region | `us-east-1` |
| Application | Python HTTP Server |
| Application Port | TCP 80 |
| Error | `mkdirr: command not found` |
| Root Cause | Incorrect command in user-data script |
| Remediation | Correct script and redeploy application |
| Tools | AWS CLI v2, Bash, SSH, systemd, curl |
| Environment | Ubuntu WSL2 |
| Verification | HTTP 200 OK |

---

## 1. Production Incident Scenario

### Incident Description

A company's infrastructure team deploys an EC2 instance to host a web application.

The application should be installed automatically through an EC2 user-data script during the first boot.

After deployment, the operations team discovers that the EC2 instance is healthy but the application does not respond on port 80.

### Reported Symptoms

```text
EC2 Instance: Running
System Status Check: OK
Instance Status Check: OK

Application: Unavailable
HTTP Port: 80
Application Service: Not Running

User Data: Failed
```

### Expected Behavior

The user-data script should:

1. Create the application directory.
2. Generate the application HTML file.
3. Configure a systemd service.
4. Start the HTTP server.
5. Make the application accessible.

Expected HTTP response:

```text
HTTP/1.0 200 OK
```

### Actual Behavior

The startup script terminates before creating the web application.

### Potential Business Impact

- Failed application deployment
- Unhealthy application targets
- Service downtime
- Failed automated provisioning
- Delayed infrastructure releases
- Increased operational workload

### Investigation Objective

Determine whether the issue is related to EC2 infrastructure, networking, application configuration, or initialization failure.

---

## 2. Architecture

### Broken Architecture

```text
        AWS EC2 RunInstances
                 |
                 v
       Amazon Linux 2023
                 |
                 v
             cloud-init
                 |
                 v
       broken-user-data.sh
                 |
                 v
        mkdirr -p /opt/...
                 |
                 X
          Command Not Found
                 |
                 v
           Script Exits
                 |
                 v
       Web Service Not Created
                 |
                 v
        Application Unavailable
```

### Corrected Architecture

```text
        Amazon EC2 Instance
                 |
                 v
        Corrected Bash Script
                 |
                 v
        Create App Directory
                 |
                 v
        Generate index.html
                 |
                 v
       Create systemd Service
                 |
                 v
         Start HTTP Server
                 |
                 v
        HTTP Port 80 Listening
                 |
                 v
             HTTP 200 OK
```

---

## 3. Understanding EC2 User Data

EC2 user data allows engineers to provide scripts or configuration instructions that are processed during instance initialization.

Common use cases include:

- Installing packages
- Configuring Linux services
- Deploying applications
- Creating directories
- Writing configuration files
- Running startup automation

On Amazon Linux, cloud-init normally processes user-data shell scripts during the initial instance boot.

### Important Components

| Component | Purpose |
|---|---|
| EC2 user data | Supplies bootstrap instructions |
| cloud-init | Processes instance initialization |
| `/var/log/cloud-init.log` | Records cloud-init execution details |
| `/var/log/cloud-init-output.log` | Records script output and errors |
| systemd | Manages Linux services |
| `set -e` | Exits when an unhandled command fails |
| `set -u` | Treats undefined shell variables as errors |
| `set -x` | Prints executed commands for debugging |
| `pipefail` | Propagates failures from shell pipelines |

### Important Behavior

A standard EC2 user-data shell script usually executes during the initial boot only.

Stopping and starting an existing EC2 instance does not automatically rerun the original user-data script.

For production recovery, engineers may repair an existing instance or replace it with a new instance using corrected configuration.

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- OpenSSH client
- Python 3
- curl
- Basic Linux administration
- EC2 and VPC permissions
- Git and GitHub

### Security Requirements

- Use disposable EC2 resources.
- Restrict SSH and HTTP to a trusted client IP.
- Never commit private SSH keys.
- Require IMDSv2 where supported.
- Avoid storing credentials in user-data scripts.
- Do not modify production instances.
- Remove temporary resources after testing.

### Cost Considerations

The exercise may incur charges for EC2 instances, EBS volumes, public IPv4 addresses, and data transfer.

The optional replacement-instance test creates an additional billable instance.

---

## 5. Prepare the AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

export INSTANCE_NAME="cloud-lab05-userdata-instance"
export SG_NAME="cloud-lab05-userdata-sg"
export KEY_NAME="cloud-lab05-ssh-key"
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

Expected: a valid VPC ID.

### Step 4 — Select a Compatible Default Subnet

Select a subnet in an Availability Zone supporting `t3.micro`.

```bash
export SUBNET_ID=$(python3 - <<'PY'
import json
import os
import subprocess

region = os.environ["AWS_REGION"]
vpc = os.environ["VPC_ID"]

def get(args):
    return json.loads(subprocess.check_output(
        [
            "aws", "ec2", *args,
            "--region", region,
            "--output", "json"
        ],
        text=True
    ))

offerings = get([
    "describe-instance-type-offerings",
    "--location-type", "availability-zone",
    "--filters", "Name=instance-type,Values=t3.micro"
])

zones = {
    item["Location"]
    for item in offerings["InstanceTypeOfferings"]
}

subnets = get([
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

print(sorted(
    candidates,
    key=lambda item: item["AvailabilityZone"]
)[0]["SubnetId"])
PY
)
```

Verify:

```bash
echo "$SUBNET_ID"
```

The subnet must have appropriate internet routing for SSH and HTTP access.

---

## 6. Create SSH Access

### Step 1 — Create Local SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 2 — Set Private Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab05-key.pem"
```

Check that neither the AWS key pair nor the local private-key file already belongs to another workload.

### Step 3 — Generate EC2 Key Pair

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$KEY_FILE"
```

### Step 4 — Protect Private Key

```bash
chmod 400 "$KEY_FILE"
```

Verify:

```bash
ls -l "$KEY_FILE"
```

Never commit this private key.

---

## 7. Configure Networking

### Step 1 — Identify Client Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')

echo "$MY_IP"
```

### Step 2 — Create Security Group

Check whether the lab security group already exists before creating it.

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab05 EC2 user data troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Allow SSH

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 22 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Step 4 — Allow HTTP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
TCP 22 — CLIENT_IP/32
TCP 80 — CLIENT_IP/32
```

This keeps the lab's network configuration correct so that troubleshooting can focus on user-data execution.

---

## 8. Introduce the Broken User-Data Script

### Step 1 — Create `broken-user-data.sh`

```bash
cat > broken-user-data.sh <<'EOF'
#!/bin/bash
set -euxo pipefail

echo "INC-EC2-005: Beginning application bootstrap"

mkdir -p /opt/ec2-lab05

# INTENTIONAL ERROR
mkdirr -p /opt/ec2-lab05/www

cat > /opt/ec2-lab05/www/index.html <<'HTML'
<!DOCTYPE html>
<html>
<body>
  <h1>EC2 Lab 05 - Application Running</h1>
  <p>Incident: INC-EC2-005</p>
  <p>Status: Healthy</p>
</body>
</html>
HTML

cat > /etc/systemd/system/ec2-lab05-web.service <<'SERVICE'
[Unit]
Description=EC2 Lab05 HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /opt/ec2-lab05/www
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now ec2-lab05-web.service

echo "INC-EC2-005: Bootstrap complete"
EOF
```

### Step 2 — Identify the Deliberate Error

Incorrect:

```bash
mkdirr -p /opt/ec2-lab05/www
```

Correct:

```bash
mkdir -p /opt/ec2-lab05/www
```

Because `mkdirr` is not a valid command and Bash is running with `set -e`, execution stops before completing the application deployment.

### Expected Consequences

- Application directory remains incomplete.
- HTML file is not created.
- systemd service is not registered.
- HTTP server is not started.
- Application remains unavailable.

---

## 9. Launch the Broken EC2 Instance

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

Do not create duplicate lab instances.

### Step 3 — Launch with Broken User Data

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --user-data file://broken-user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab05-userdata-instance},{Key=Project,Value=EC2-Troubleshooting-Lab05}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify EC2 Status Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

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

**Important:** Healthy EC2 status checks do not guarantee that cloud-init or application deployment completed successfully.

### Step 6 — Retrieve Public IPv4

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")

echo "$PUBLIC_IP"
```

---

## 10. Reproduce the Application Failure

### Step 1 — Test HTTP Access

From Ubuntu WSL2:

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PUBLIC_IP/"
```

Expected: a connection failure because the HTTP service is not listening.

A typical response is:

```text
curl: (7) Failed to connect to PUBLIC_IP port 80
```

### Step 2 — Verify Inbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Confirm TCP ports 22 and 80 are allowed from the client address.

### Observation

The application is unavailable even though:

- EC2 is running.
- Status checks are healthy.
- The security group allows HTTP.
- The instance has a public IPv4 address.

The evidence suggests that the problem may be inside the operating system or application initialization process.

---

## 11. Troubleshooting Investigation

### Step 1 — Connect to EC2

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Verify the SSH host-key identity through a trusted source before accepting it in a production environment.

The following commands run **inside the EC2 instance**.

### Step 2 — Check cloud-init Status

```bash
sudo cloud-init status --long
```

Expected: an error state or details indicating that user-data execution failed.

### Step 3 — Inspect the User-Data Output Log

```bash
sudo tail -n 80 /var/log/cloud-init-output.log
```

Look for:

```text
mkdirr: command not found
```

The exact wording may include a line number.

### Step 4 — Search for Errors

```bash
sudo grep -n -E \
  'mkdirr|command not found|Failed|ERROR' \
  /var/log/cloud-init-output.log
```

### Step 5 — Inspect cloud-init Operational Logs

```bash
sudo tail -n 60 /var/log/cloud-init.log
```

### Step 6 — Verify Application Files

```bash
ls -la /opt/ec2-lab05/
```

The `www` directory should not have been created by the failed script.

### Step 7 — Check the systemd Service

```bash
sudo systemctl status ec2-lab05-web.service --no-pager
```

Expected: the service is not found or is not running.

### Step 8 — Check the Listening Port

```bash
sudo ss -lntp | grep ':80'
```

Expected: no listener on port 80.

### Step 9 — Test Local HTTP

```bash
curl -I --connect-timeout 3 http://127.0.0.1/
```

Expected: failed connection.

### Investigation Findings

| Check | Finding |
|---|---|
| EC2 instance | Running |
| EC2 health checks | OK |
| TCP 80 security group rule | Allowed |
| SSH access | Working |
| cloud-init | Failed |
| cloud-init output | `mkdirr: command not found` |
| Application directory | Incomplete |
| systemd service | Missing |
| HTTP listener | Missing |
| Root cause | User-data command typo |

---

## 12. Root Cause Analysis

### Root Cause

The user-data script contains an invalid command:

```bash
mkdirr -p /opt/ec2-lab05/www
```

The intended Linux command is `mkdir`.

Because the script uses `set -e`, Bash exits when the unhandled command fails.

As a result, the script never creates the web application or starts the HTTP service.

### Root Cause Flow

```text
EC2 Instance Starts
        |
        v
cloud-init Executes User Data
        |
        v
Application Directory Created
        |
        v
mkdirr Command Executed
        |
        v
Command Not Found
        |
        v
Bash Exits
        |
        v
Application Service Not Created
        |
        v
HTTP Request Fails
```

### Five Whys

1. **Why was the application unavailable?** The HTTP service was not running.
2. **Why was the HTTP service not running?** The initialization script stopped before creating it.
3. **Why did the script stop?** An invalid command returned an error.
4. **Why did one failed command terminate the script?** The script used `set -e`.
5. **How can this be prevented?** Use script validation, automated deployment tests, and application-level readiness checks.

---

## 13. Apply Remediation

### Step 1 — Create Corrected Script

Return to Ubuntu WSL2 and create `fixed-user-data.sh`:

```bash
cat > fixed-user-data.sh <<'EOF'
#!/bin/bash
set -euxo pipefail

echo "INC-EC2-005: Starting corrected bootstrap"

mkdir -p /opt/ec2-lab05/www

cat > /opt/ec2-lab05/www/index.html <<'HTML'
<!DOCTYPE html>
<html>
<body>
  <h1>EC2 Lab 05 - Application Running</h1>
  <p>Incident: INC-EC2-005</p>
  <p>Status: Recovered</p>
</body>
</html>
HTML

cat > /etc/systemd/system/ec2-lab05-web.service <<'SERVICE'
[Unit]
Description=EC2 Lab05 HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /opt/ec2-lab05/www
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now ec2-lab05-web.service

echo "INC-EC2-005: Corrected bootstrap completed"
EOF
```

### Step 2 — Validate Bash Syntax

```bash
bash -n fixed-user-data.sh
```

Expected: no syntax errors.

**Note:** Bash syntax validation does not catch every runtime error. The broken `mkdirr` command is syntactically valid shell text but fails during execution.

### Step 3 — Copy Script to EC2

```bash
scp \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  fixed-user-data.sh \
  ec2-user@"$PUBLIC_IP":/home/ec2-user/fixed-user-data.sh
```

### Step 4 — Connect to EC2

```bash
ssh \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

### Step 5 — Run Corrected Deployment

Inside EC2:

```bash
sudo bash /home/ec2-user/fixed-user-data.sh
```

Expected final message:

```text
INC-EC2-005: Corrected bootstrap completed
```

### Step 6 — Verify systemd

```bash
sudo systemctl status ec2-lab05-web.service --no-pager
```

Expected:

```text
active (running)
```

### Step 7 — Verify Port 80

```bash
sudo ss -lntp | grep ':80'
```

Expected: Python HTTP server listening.

### Step 8 — Test Local HTTP

```bash
curl -I http://127.0.0.1/
```

Expected:

```text
HTTP/1.0 200 OK
```

Exit the EC2 instance:

```bash
exit
```

---

## 14. Verify Application Recovery

### Test 1 — External HTTP Request

From WSL2:

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PUBLIC_IP/"
```

Expected content:

```html
<h1>EC2 Lab 05 - Application Running</h1>
<p>Incident: INC-EC2-005</p>
<p>Status: Recovered</p>
```

### Test 2 — HTTP Status Code

```bash
curl -sS \
  -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  "http://$PUBLIC_IP/"
```

Expected:

```text
HTTP Status: 200
```

### Test 3 — Verify Application Content

```bash
curl -fsS "http://$PUBLIC_IP/" |
  grep -E 'INC-EC2-005|Recovered'
```

### Verification Summary

| Check | Before Fix | After Fix |
|---|---|---|
| EC2 running | Yes | Yes |
| EC2 status checks | OK | OK |
| Original user-data execution | Failed | Historical failure remains |
| Corrected deployment | Not applied | Successful |
| Web application files | Missing | Created |
| systemd service | Missing | Running |
| TCP port 80 listener | Missing | Present |
| Local HTTP | Failed | 200 |
| External HTTP | Failed | 200 |

### Important Distinction

Executing the corrected script manually repairs the application on the existing instance.

It does not mean that the original cloud-init execution succeeded.

The initial failure remains useful forensic evidence.

---

## 15. Optional — Verify Immutable Deployment

Instead of repairing an existing instance, a production deployment may replace it with a newly configured instance.

To verify that the fixed script runs successfully as user data, launch a separate disposable instance with `fixed-user-data.sh`.

### Launch Replacement Instance

```bash
export FIXED_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --user-data file://fixed-user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab05-fixed-instance},{Key=Project,Value=EC2-Troubleshooting-Lab05}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Wait for Instance Health

```bash
aws ec2 wait instance-running \
  --instance-ids "$FIXED_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$FIXED_INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Retrieve Public IPv4

```bash
export FIXED_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$FIXED_INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

### Verify the Application

```bash
curl -fsS "http://$FIXED_PUBLIC_IP/"
```

Expected: the recovered application page.

### Production Lesson

Testing a corrected user-data script on a fresh instance validates the startup automation itself.

This is stronger than testing only a manual repair.

---

## 16. Production Engineering Considerations

### Common User-Data Failure Causes

- Misspelled Linux commands
- Missing packages
- Incorrect package manager
- Invalid file paths
- Insufficient filesystem permissions
- Network connectivity problems
- Broken package repositories
- Invalid configuration files
- Failed systemd services
- Application dependency errors
- Scripts that assume unavailable environment variables

### Recommended Troubleshooting Order

1. Verify EC2 state.
2. Check EC2 status checks.
3. Confirm application network access.
4. Inspect cloud-init status.
5. Review cloud-init output logs.
6. Identify the first failing command.
7. Check application files and dependencies.
8. Inspect systemd services.
9. Correct the initialization script.
10. Verify the service locally.
11. Verify external connectivity.
12. Test the corrected script on a clean instance.

### Prevention Strategies

**Script Validation**

Use tools such as `bash -n` and ShellCheck to identify syntax and common scripting problems.

**Infrastructure Testing**

Test initialization scripts in disposable environments before production deployment.

**Idempotency**

Design provisioning scripts so they can be rerun safely when appropriate.

**Observability**

Collect startup logs and application-level health signals.

**Immutable Infrastructure**

Prefer replacing failed instances with correctly configured instances where the deployment architecture supports it.

**Least Privilege**

Avoid embedding credentials or giving bootstrap scripts unnecessary permissions.

---

## 17. Related Errors and Symptoms

| Error or Symptom | Possible Cause |
|---|---|
| `command not found` | Invalid command or missing package |
| `Permission denied` | Filesystem or execution permission issue |
| `No such file or directory` | Missing path |
| `cloud-init status: error` | Initialization stage failed |
| HTTP connection refused | No process listening |
| HTTP timeout | Network filtering or reachability |
| systemd unit not found | Service file not created |
| systemd service failed | Invalid service configuration or application error |
| HTTP 500 | Application-side failure |

---

## 18. Interview Questions and Answers

### Q1. What is EC2 user data?

User data provides initialization instructions that an instance can process during startup.

### Q2. What is cloud-init?

cloud-init is a Linux initialization system commonly used to configure cloud instances.

### Q3. Where do you check EC2 user-data errors?

Common locations include `/var/log/cloud-init-output.log` and `/var/log/cloud-init.log`.

### Q4. What does `set -e` do?

It causes Bash to exit when an unhandled command fails, subject to the command context and Bash's exceptions.

### Q5. Why did the script fail in this lab?

It attempted to execute `mkdirr`, an invalid Linux command.

### Q6. Does an EC2 instance passing status checks mean user data succeeded?

No. EC2 infrastructure and reachability checks do not prove application initialization completed.

### Q7. Does a normal EC2 reboot rerun user data?

A standard user-data shell script normally runs on first boot. Rebooting does not automatically rerun it.

### Q8. How can you inspect a failed systemd service?

Use `systemctl status` and `journalctl -u` for the service.

### Q9. What is the advantage of immutable infrastructure?

Failed instances can be replaced with new, correctly configured instances instead of relying on manual changes to existing systems.

### Q10. How would you explain this incident in an interview?

> I investigated an EC2 application deployment that failed even though the instance was running and healthy. I verified the security group and network configuration, then connected to the instance and inspected cloud-init logs. I found a command-not-found error caused by a typo in the user-data script. I corrected the script, deployed the application, and verified the systemd service and HTTP response. I also tested the corrected script on a fresh instance to confirm that automated initialization worked.

---

## 19. Cleanup

**Warning:** These steps permanently remove resources created for Lab 05.

### Step 1 — Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Step 2 — Record Original Root Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Inspect its `DeleteOnTermination` setting before termination.

### Step 3 — Terminate Original Instance

Verify its project tag is `EC2-Troubleshooting-Lab05`, then run:

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Terminate Optional Replacement

Only if you launched the optional replacement:

```bash
aws ec2 terminate-instances \
  --instance-ids "$FIXED_INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$FIXED_INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inspect the replacement's root volume before and after termination as well.

### Step 5 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Expected if deleted:

```text
InvalidVolume.NotFound
```

If a dedicated lab root volume remains `available`, confirm its identity before deleting it with `aws ec2 delete-volume`.

Do not delete unrelated volumes.

### Step 6 — Check Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Confirm no network interfaces still use the group.

### Step 7 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete AWS Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 9 — Remove Local Private Key

```bash
rm -f "$KEY_FILE"
```

Only remove the dedicated Lab 05 key.

### Step 10 — Confirm Cleanup

Verify that:

- Both lab instances are terminated, if the optional one was created.
- Their EBS root volumes are deleted.
- The dedicated security group is deleted.
- The AWS lab key pair is deleted.
- The private key is removed.
- The default VPC and subnets remain intact.

---

## 20. Repository Structure

```text
05-user-data-script-failure/
│
├── README.md
├── broken-user-data.sh
└── fixed-user-data.sh
```

Both scripts are included to demonstrate the incorrect configuration and corrected implementation.

Do not commit AWS credentials, SSH private keys, or sensitive instance metadata.

---

## 21. Lessons Learned

This lab demonstrated that an EC2 instance can start successfully while its initialization script fails.

The simulated failure was caused by an invalid Linux command inside the user-data script.

The investigation involved examining cloud-init logs, validating application files, checking the systemd service, and testing HTTP connectivity.

The remediation corrected the invalid command and restored the application.

The optional replacement-instance test demonstrated how to validate corrected user data through a fresh deployment.

The key lesson is to investigate application initialization separately from EC2 infrastructure health.

---

## 22. Skills Demonstrated

- Amazon EC2 troubleshooting
- EC2 user data
- cloud-init
- Linux Bash
- Shell script debugging
- systemd service management
- AWS CLI v2
- SSH administration
- HTTP diagnostics
- Application deployment
- Linux log analysis
- Root cause analysis
- Deployment recovery
- Immutable infrastructure concepts
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-005 |
| Problem | EC2 User Data Script Failure |
| EC2 State | Running |
| Root Cause | `mkdirr` command typo |
| Initial User Data | Failed |
| Remediation | Corrected bootstrap script |
| systemd Service | Running |
| Application Port | 80 |
| HTTP Response | 200 OK |
| Fresh Instance Validation | Optional |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 instance is healthy but its application is unavailable, inspect cloud-init logs, identify the failed initialization step, verify Linux services, and validate the corrected deployment on a clean instance.

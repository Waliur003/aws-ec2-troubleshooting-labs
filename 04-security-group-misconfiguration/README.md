# Lab 04 — Amazon EC2 Security Group Misconfiguration

## Overview

This hands-on lab demonstrates how to troubleshoot an EC2-hosted web application that is unreachable from the internet because of an incorrect security group configuration.

The simulated production incident involves an Amazon Linux 2023 EC2 instance running a Python HTTP web server on TCP port 80.

Although the instance is healthy, the application cannot be accessed because the attached security group does not allow inbound HTTP traffic.

The objective is to reproduce the incident, investigate the network configuration, identify the root cause, apply a least-privilege security group rule, and verify application recovery.

**Troubleshooting workflow:**

Baseline → Introduce Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-004 |
| AWS Services | Amazon EC2, Amazon VPC |
| Primary Component | EC2 Security Group |
| Difficulty | Beginner–Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Application | Python HTTP Server |
| Application Port | TCP 80 |
| Error | HTTP Connection Timeout |
| Root Cause | Missing inbound TCP 80 rule |
| Remediation | Allow TCP 80 from trusted `/32` |
| Tools | AWS CLI v2, Bash, curl, Python |
| Environment | Ubuntu Linux / WSL2 |
| Expected Result | HTTP 200 OK |

---

## 1. Production Incident Scenario

### Incident Description

A company hosts an internal web application on an Amazon EC2 instance.

The Cloud Operations team reports that the EC2 instance is running and passing its AWS status checks, but users cannot access the website.

The application is deployed during instance initialization using an EC2 user data script.

A network investigation reveals that the security group associated with the EC2 instance does not allow inbound HTTP connections.

### Reported Error

```text
curl: (28) Failed to connect to PUBLIC_IP port 80:
Connection timed out
```

### Expected Behavior

An authorized client should access the application at:

```text
http://EC2_PUBLIC_IP/
```

The application should return:

```text
HTTP 200 OK
```

### Actual Behavior

HTTP connection attempts time out before reaching the application.

### Potential Business Impact

- Website unavailable to authorized users
- Application downtime
- Failed application health checks
- Interrupted business workflows
- Increased incident response time
- Potential service-level objective violations

### Investigation Objective

Determine whether the failure is caused by the EC2 instance, application service, subnet routing, security group, network ACL, or operating-system firewall.

---

## 2. Architecture

### Broken Architecture

```text
            Client / Ubuntu WSL2
                     |
                     | HTTP Request
                     | TCP Port 80
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
                     |
                     X
              TCP 80 BLOCKED
                     |
                     v
             Amazon EC2 Instance
              Amazon Linux 2023
                     |
                     v
             Python HTTP Server
              Listening on :80

Result: HTTP Connection Timeout
```

### Corrected Architecture

```text
            Client / Ubuntu WSL2
                     |
                     | HTTP Request
                     | TCP Port 80
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
                     |
                     | Allow TCP 80
                     | Source: CLIENT_IP/32
                     v
             Amazon EC2 Instance
              Amazon Linux 2023
                     |
                     v
             Python HTTP Server
                     |
                     v
                 index.html
                     |
                     v
                 HTTP 200 OK
```

---

## 3. Understanding EC2 Security Groups

A security group is a virtual firewall that controls inbound and outbound traffic for resources associated with it, including EC2 network interfaces.

Security groups contain allow rules rather than explicit deny rules.

Traffic that does not match an applicable allow rule is not permitted.

### Important Security Group Concepts

| Concept | Explanation |
|---|---|
| Inbound rules | Control incoming connections |
| Outbound rules | Control outgoing connections |
| Protocol | TCP, UDP, ICMP, or other supported protocols |
| Port | Specifies the allowed application port |
| Source CIDR | Identifies permitted incoming IP addresses |
| Stateful | Response traffic for allowed connections is automatically permitted |
| Default inbound rules | A newly created security group has no inbound allow rules |
| Default outbound rules | New security groups normally permit outbound traffic |

### Common Application Ports

| Port | Protocol | Service |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 3306 | TCP | MySQL |
| 5432 | TCP | PostgreSQL |
| 8080 | TCP | Alternate HTTP |

This lab focuses on port 80.

### Security Group vs Network ACL

| Security Group | Network ACL |
|---|---|
| Stateful | Stateless |
| Associated with network interfaces | Associated with subnets |
| Allow rules only | Allow and deny rules |
| Evaluates applicable rules together | Evaluates rules in numbered order |
| Return traffic automatically permitted | Return traffic must satisfy ACL rules |

---

## 4. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- Python 3
- curl
- EC2 and VPC management permissions
- Git and GitHub

### Security Requirements

- Use a dedicated disposable EC2 instance.
- Keep the security group restricted to the trusted test client.
- Do not expose SSH unnecessarily.
- Do not store AWS credentials in user data.
- Use IMDSv2.
- Do not modify production network policies.
- Delete temporary AWS resources after completing the exercise.

### Cost Warning

This lab can generate charges for:

- EC2 instance usage
- EBS root volume storage
- Public IPv4 usage
- Data transfer

Review AWS costs and complete cleanup after testing.

---

## 5. Prepare the AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

export INSTANCE_NAME="cloud-lab04-web-instance"

export SG_NAME="cloud-lab04-web-sg"
```

Verify identity:

```bash
aws sts get-caller-identity
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

Do not proceed if the result is `None`.

### Step 3 — Select a Supported Subnet

Select a default subnet in an Availability Zone supporting `t3.micro`.

```bash
export SUBNET_ID=$(python3 - <<'PY'
import json
import os
import subprocess

region = os.environ["AWS_REGION"]
vpc = os.environ["VPC_ID"]

def aws_json(args):
    output = subprocess.check_output(
        [
            "aws", "ec2", *args,
            "--region", region,
            "--output", "json"
        ],
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
    subnet
    for subnet in subnets["Subnets"]
    if subnet["AvailabilityZone"] in zones
    and subnet.get("DefaultForAz", False)
]

if not candidates:
    raise SystemExit("No compatible default subnet found")

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

### Step 4 — Verify Public Subnet Routing

Inspect the VPC route tables:

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Routes:Routes,Associations:Associations}' \
  --output json \
  --region "$AWS_REGION"
```

Determine which route table is effective for the selected subnet.

For direct internet access, confirm an active IPv4 default route:

```text
Destination: 0.0.0.0/0
Target: igw-xxxxxxxx
```

Also verify that the internet gateway is attached to the VPC.

---

## 6. Create the Security Group

### Step 1 — Identify Client Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Verify:

```bash
echo "$MY_IP"
```

### Step 2 — Check for Existing Group

```bash
aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

Create the group only if the name is not already in use.

### Step 3 — Create Dedicated Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "EC2 Lab04 HTTP security group troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

Verify:

```bash
echo "$SG_ID"
```

### Step 4 — Inspect Inbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Intentional Misconfiguration

No inbound rule allows HTTP on TCP port 80.

This creates the network restriction that will prevent external access to the web server.

---

## 7. Deploy the HTTP Application

### Step 1 — Create User Data Script

Create `user-data.sh`:

```bash
cat > user-data.sh <<'EOF'
#!/bin/bash
set -euxo pipefail

mkdir -p /opt/ec2-lab04

cat > /opt/ec2-lab04/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
  <title>EC2 Security Group Lab</title>
</head>
<body>
  <h1>EC2 Lab 04 - Web Server Running</h1>
  <p>Status: Healthy</p>
  <p>Incident: INC-EC2-004</p>
</body>
</html>
HTML

cat > /etc/systemd/system/ec2-lab04-web.service <<'SERVICE'
[Unit]
Description=EC2 Lab04 Python HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /opt/ec2-lab04
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now ec2-lab04-web.service
EOF
```

### What the Script Does

1. Creates the application directory.
2. Generates a basic HTML webpage.
3. Creates a systemd service.
4. Starts Python's HTTP server on port 80.
5. Configures the service to start automatically.

### Production Note

The Python HTTP server is intended for education and testing.

It runs as root in this example to bind the privileged HTTP port. Production services should use an appropriately hardened application server and a least-privilege service identity.

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

Verify:

```bash
echo "$AMI_ID"
```

### Step 2 — Check for an Existing Lab Instance

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=$INSTANCE_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

Do not create a duplicate if an existing lab instance is still active.

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --user-data file://user-data.sh \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab04-web-instance},{Key=Project,Value=EC2-Troubleshooting-Lab04}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Verify Instance ID

```bash
echo "$INSTANCE_ID"
```

Expected format:

```text
i-xxxxxxxxxxxxxxxxx
```

### Step 5 — Wait for Running State

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Status Checks

```bash
aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inspect:

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

## 9. Reproduce the HTTP Failure

### Step 1 — Attempt HTTP Access

From Ubuntu WSL2:

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PUBLIC_IP/"
```

Expected:

```text
curl: (28) Failed to connect
Connection timed out
```

### Step 2 — Test TCP Port 80

```bash
timeout 5 bash -c \
  "echo > /dev/tcp/$PUBLIC_IP/80"
```

Expected: timeout or failed connection.

### Observation

The EC2 instance is running, but external HTTP traffic is blocked because the security group has no inbound port 80 permission.

The timeout does not by itself establish whether the web server is healthy.

---

## 10. Troubleshooting Investigation

### Check 1 — Verify EC2 State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PublicIP:PublicIpAddress,Subnet:SubnetId,Groups:SecurityGroups}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

- State is `running`.
- Public IPv4 exists.
- Correct subnet is attached.
- Dedicated security group is attached.

### Check 2 — Verify EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both checks report `ok`.

### Check 3 — Inspect Inbound Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Check 4 — Review Application Startup Output

```bash
aws ec2 get-console-output \
  --instance-id "$INSTANCE_ID" \
  --latest \
  --query Output \
  --output text \
  --region "$AWS_REGION"
```

Look for cloud-init or user-data errors.

Console output may be delayed and does not always include enough information to establish application health.

### Check 5 — Verify Network Routing

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --output json \
  --region "$AWS_REGION"
```

Confirm the subnet has an active route to an internet gateway.

### Investigation Findings

| Check | Finding |
|---|---|
| EC2 state | Running |
| System status | OK |
| Instance status | OK |
| Public IPv4 | Assigned |
| Internet gateway route | Expected to be present |
| Web server deployment | Configured through user data |
| Security group inbound rules | Empty |
| TCP 80 allowed | No |
| External HTTP request | Timeout |
| Confirmed network misconfiguration | Missing inbound TCP 80 rule |

---

## 11. Root Cause Analysis

### Root Cause

The EC2 instance's security group does not contain an inbound rule permitting HTTP connections on TCP port 80 from the test client's public IPv4 address.

### Technical Explanation

Security groups enforce allow rules for network traffic.

When an inbound connection does not match an authorized rule, the traffic is not permitted.

The client therefore cannot establish an HTTP connection to the instance.

### Root Cause Flow

```text
Client Sends HTTP Request
           |
           v
EC2 Public IPv4 Address
           |
           v
Internet Gateway
           |
           v
Security Group Evaluation
           |
           v
No Inbound TCP 80 Rule
           |
           v
Traffic Not Permitted
           |
           v
HTTP Connection Timeout
```

### Five Whys

1. **Why was the website inaccessible?** The client's HTTP request timed out.
2. **Why did the request time out?** The inbound connection was not permitted.
3. **Why was the connection blocked?** The security group had no TCP 80 allow rule.
4. **Why was the rule missing?** The lab security group was deliberately created without inbound HTTP access.
5. **How can this be prevented?** Validate required application ports and source ranges before deployment and monitor network configuration changes.

---

## 12. Apply Least-Privilege Remediation

### Step 1 — Confirm the Client IP

```bash
echo "$MY_IP"
```

If the client's public IP has changed, retrieve it again:

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

### Step 2 — Allow HTTP From One IP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "${MY_IP}/32" \
  --region "$AWS_REGION"
```

### Explanation

| Setting | Value |
|---|---|
| Protocol | TCP |
| Port | 80 |
| Source | Test client's public IPv4 |
| CIDR | `/32` |
| Permission | Inbound HTTP from one IPv4 address |

### Step 3 — Verify the Rule

```bash
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
TCP port 80
Source: CLIENT_PUBLIC_IP/32
```

### Security Benefit

The lab does not need unrestricted public access.

Using `/32` permits testing from the intended client while preventing unnecessary exposure to other public IPv4 addresses.

---

## 13. Verify Application Recovery

### Test 1 — Retry HTTP Request

```bash
curl -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PUBLIC_IP/"
```

Expected page content:

```html
<h1>EC2 Lab 04 - Web Server Running</h1>
<p>Status: Healthy</p>
<p>Incident: INC-EC2-004</p>
```

### Test 2 — Verify HTTP Status Code

```bash
curl -sS \
  -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PUBLIC_IP/"
```

Expected:

```text
HTTP Status: 200
```

### Test 3 — Verify Response Headers

```bash
curl -I \
  --connect-timeout 5 \
  --max-time 10 \
  "http://$PUBLIC_IP/"
```

Expected:

```text
HTTP/1.0 200 OK
```

### Test 4 — Verify Incident Identifier

```bash
curl -fsS "http://$PUBLIC_IP/" |
  grep "INC-EC2-004"
```

Expected:

```html
<p>Incident: INC-EC2-004</p>
```

### If HTTP Still Fails

A successful security group update does not guarantee the application is running.

Investigate user-data completion and the HTTP service using an authorized instance-access method.

Useful commands inside the instance include:

```bash
sudo systemctl status ec2-lab04-web.service --no-pager
```

```bash
sudo journalctl -u ec2-lab04-web.service -n 50 --no-pager
```

```bash
sudo ss -lntp
```

```bash
curl -I http://127.0.0.1/
```

Also inspect:

```bash
sudo tail -n 100 /var/log/cloud-init-output.log
```

These checks help distinguish an application problem from a security group problem.

### Verification Summary

| Test | Before Fix | After Fix |
|---|---|---|
| EC2 running | Yes | Yes |
| Status checks | OK | OK |
| Public IPv4 | Present | Present |
| TCP 80 inbound | Blocked | Allowed from `/32` |
| External HTTP request | Timeout | Successful |
| HTTP status | No response | 200 |
| Application content | Unavailable | Verified |
| Security group scope | No HTTP access | Trusted client only |

---

## 14. Production Engineering Considerations

### Common Causes of HTTP Unavailability

- Missing security group inbound rule
- Incorrect application port
- Incorrect public IPv4 address
- Missing internet gateway route
- Restrictive network ACL
- Host-level firewall blocking traffic
- Web service not running
- Application listening only on localhost
- Failed EC2 user-data script
- Incorrect web server configuration

### Recommended Troubleshooting Sequence

1. Confirm EC2 is running.
2. Check instance and system status.
3. Identify the correct destination IP.
4. Verify the application is listening on the expected port.
5. Inspect security group inbound rules.
6. Verify subnet routing.
7. Inspect network ACL rules.
8. Check host-level firewall rules.
9. Review application and system logs.
10. Retry the original HTTP request.

### Production Security Recommendations

- Use least-privilege inbound rules.
- Prefer HTTPS for real applications.
- Terminate TLS through a suitable load balancer or application server.
- Avoid exposing administrative ports unnecessarily.
- Use dedicated security groups by workload.
- Review changes through infrastructure-as-code workflows.
- Monitor security group modifications with appropriate AWS services.
- Keep operating systems and application dependencies updated.

---

## 15. Related Errors and Symptoms

| Symptom | Possible Cause |
|---|---|
| Connection timed out | Security group, network ACL, routing, or firewall |
| Connection refused | Service unavailable or port not listening |
| HTTP 403 | Application authorization issue |
| HTTP 404 | Requested resource not found |
| HTTP 500 | Server-side application error |
| HTTP 502 | Gateway or upstream response issue |
| HTTP 503 | Service unavailable |
| HTTP 200 | Successful HTTP response |

---

## 16. Interview Questions and Answers

### Q1. What is an EC2 security group?

A stateful virtual firewall that controls permitted inbound and outbound traffic for associated resources.

### Q2. Why did the application time out?

Its security group did not allow inbound TCP port 80 traffic from the client.

### Q3. What is the difference between a security group and a network ACL?

Security groups are stateful and allow-only. Network ACLs are stateless and support both allow and deny rules.

### Q4. Why use `/32` instead of `0.0.0.0/0`?

A `/32` CIDR allows one IPv4 address and reduces unnecessary exposure.

### Q5. Can an EC2 instance be healthy while its application is inaccessible?

Yes. EC2 status checks do not prove that a specific application port is reachable from an external client.

### Q6. What port does HTTP use by default?

TCP port 80.

### Q7. What port does HTTPS use by default?

TCP port 443.

### Q8. Why might HTTP fail after correcting the security group?

The application may not be running, may be listening on the wrong interface, or may be blocked by another network control.

### Q9. What command can verify an HTTP response?

`curl -I` for headers or `curl -v` for detailed connection and response information.

### Q10. How would you explain this incident in an interview?

> I investigated an EC2-hosted web application that was unreachable even though the instance was running and healthy. I verified the public IP, instance configuration, and security group rules. I found that TCP port 80 was not permitted inbound. I added a restricted HTTP rule allowing traffic from the authorized client's public IPv4 address, then used curl to verify that the application returned HTTP 200 and its expected content. I also reviewed the instance startup configuration to distinguish network access from application health.

---

## 17. Cleanup

**Warning:** Perform these actions only for the isolated Lab 04 resources.

### Step 1 — Record Root Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check deletion configuration:

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' \
  --output text \
  --region "$AWS_REGION"
```

### Step 2 — Verify AWS Account

```bash
aws sts get-caller-identity
```

### Step 3 — Verify Instance Tags

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project: EC2-Troubleshooting-Lab04
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

### Step 5 — Verify Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Confirm that no network interface references the lab security group.

### Step 6 — Delete Security Group

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

If a dependency error occurs, investigate the remaining references and retry later.

### Step 7 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If AWS returns `InvalidVolume.NotFound`, the volume was deleted.

If the dedicated volume remains in the `available` state, verify that it belongs to this lab and delete it:

```bash
aws ec2 delete-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Do not delete unrelated volumes.

### Step 8 — Verify Instance Termination

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

Keep the default VPC and its subnets for future labs.

---

## 18. Repository Structure

```text
04-security-group-misconfiguration/
│
├── README.md
└── user-data.sh
```

The user-data script creates the sample web application and systemd service.

The README documents the entire incident response and remediation process.

Do not commit credentials, production addresses, or temporary AWS identifiers.

---

## 19. Lessons Learned

This lab demonstrated that an EC2 instance can be healthy while its hosted application is unreachable.

The simulated failure was caused by a missing security group inbound rule for HTTP traffic.

The investigation focused on EC2 state, application deployment, public IPv4 configuration, VPC networking, and security group permissions.

The remediation allowed TCP port 80 only from the authorized test client.

Successful recovery was verified using HTTP status codes and expected application content.

The key lesson is to separate infrastructure health, application health, and network connectivity when investigating EC2 application failures.

---

## 20. Skills Demonstrated

- Amazon EC2 troubleshooting
- Amazon VPC networking
- Security group configuration
- HTTP connectivity troubleshooting
- Linux web server deployment
- EC2 user data
- systemd services
- AWS CLI v2
- Bash
- curl
- Public IPv4 routing
- Least-privilege network access
- Root cause analysis
- Production incident documentation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-004 |
| Application | Python HTTP Server |
| Problem | HTTP connection timeout |
| Root Cause | Missing inbound TCP 80 rule |
| Remediation | Allow TCP 80 from trusted `/32` |
| EC2 State | Running |
| HTTP Response | 200 OK |
| Application Content | Verified |
| Security Group | Restricted to trusted client |
| Cleanup | EC2 and temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2-hosted application is unreachable, verify the application, network path, security group, route table, and firewall. A healthy EC2 instance does not automatically mean the application is accessible.

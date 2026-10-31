# Lab 12 — Amazon EC2 DNS Resolution Failure

## Overview

This hands-on lab demonstrates how to troubleshoot DNS resolution failures on an Amazon EC2 instance running Amazon Linux 2023.

DNS is responsible for translating domain names into IP addresses. Applications rely on DNS to communicate with external APIs, databases, package repositories, and other services.

In this simulated production incident, an EC2 instance has working network connectivity but cannot resolve domain names because its operating system is configured to use an unreachable DNS server.

We will investigate the Linux DNS configuration, reproduce the failure, identify the root cause, restore the correct resolver settings, and verify connectivity.

The experiment uses temporary, instance-local DNS changes rather than modifying shared VPC DNS settings.

**Troubleshooting workflow:**

Healthy Baseline → Simulate Failure → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-012 |
| AWS Services | EC2, VPC, Route 53 VPC Resolver |
| Difficulty | Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, SSH, Bash, curl |
| Linux Diagnostics | `getent`, `resolvectl`, `ip`, `journalctl` |
| Problem | DNS Resolution Failure |
| Simulated Cause | Incorrect DNS server |
| Incorrect Resolver | `192.0.2.53` |
| AWS VPC Resolver | `169.254.169.253` |
| Remediation | Revert temporary DNS override |
| Expected Outcome | Successful DNS and HTTPS requests |

---

## 1. Production Incident Scenario

### Incident Description

A company hosts an application on Amazon EC2 that communicates with an external API.

The application has been working normally, but users suddenly report connection errors.

The EC2 instance remains in the `running` state, and its network interface and default route appear healthy.

However, requests using domain names fail.

### Expected Behavior

The instance should resolve public domain names.

```bash
getent ahostsv4 example.com
```

Expected: one or more IPv4 addresses.

An HTTPS request should also succeed:

```bash
curl -I https://example.com
```

### Simulated Failure

The application fails to resolve its destination hostname.

Possible error:

```text
curl: (6) Could not resolve host: example.com
```

Depending on the resolver and timeout settings, the command might instead report a DNS resolution timeout.

### Potential Business Impact

- Application API failures
- Failed software updates
- Unavailable external integrations
- Interrupted automated jobs
- Failed package installations
- Service degradation
- Delayed application deployments

### Investigation Objective

Identify whether the connectivity issue is caused by DNS resolution, network routing, operating-system configuration, or VPC-level DNS settings.

---

## 2. Architecture

### Healthy Architecture

```text
             EC2 Application
                    |
                    v
             Domain Name Query
                    |
                    v
             Linux Resolver
                    |
                    v
           Amazon VPC Resolver
             169.254.169.253
                    |
                    v
               DNS Answer
                    |
                    v
             Resolved IP
                    |
                    v
            HTTPS Connection
                    |
                    v
              Application OK
```

### Broken Architecture

```text
             EC2 Application
                    |
                    v
             Domain Name Query
                    |
                    v
             Linux Resolver
                    |
                    v
          Incorrect DNS Server
               192.0.2.53
                    |
                    X
             DNS Lookup Fails
                    |
                    v
          Application Connection
                 Fails
```

### Recovery Architecture

```text
          DNS Resolution Failure
                    |
                    v
         Inspect Resolver Settings
                    |
                    v
          Identify Incorrect DNS
                    |
                    v
        Remove Temporary Override
                    |
                    v
        Restore Working DNS Server
                    |
                    v
           Verify DNS Resolution
                    |
                    v
            Verify HTTPS Access
                    |
                    v
              Incident Resolved
```

---

## 3. Understanding DNS

DNS stands for Domain Name System.

It translates human-readable domain names into IP addresses.

Example:

```text
example.com → IPv4 address
```

Applications can then use the returned IP address to establish network connections.

### Important DNS Concepts

| Concept | Explanation |
|---|---|
| DNS | Domain Name System |
| A record | Maps a hostname to an IPv4 address |
| AAAA record | Maps a hostname to an IPv6 address |
| Recursive resolver | Resolves DNS queries on behalf of clients |
| DNS cache | Stores previously resolved answers |
| `/etc/resolv.conf` | Linux resolver configuration interface |
| systemd-resolved | Linux DNS resolution service |
| VPC Resolver | AWS-provided DNS resolver within a VPC |
| DHCP options | Configuration that can supply DNS servers to instances |

### DNS Resolution vs Network Connectivity

DNS resolution and packet routing are separate operations.

A machine can have working IP connectivity while DNS lookups fail.

For example:

```text
Network Connectivity: Working
DNS Server: Incorrect
Hostname Resolution: Failed
```

This distinction helps engineers avoid unnecessary changes to security groups or VPC route tables.

---

## 4. Amazon VPC DNS Resolver

AWS provides a DNS resolver for VPC resources.

The Amazon-provided DNS server can be reached using the link-local IPv4 address:

```text
169.254.169.253
```

It can also be reached using the primary IPv4 CIDR block's network address plus two.

### AWS DNS Settings

| Setting | Purpose |
|---|---|
| `enableDnsSupport` | Controls support for DNS resolution through Amazon-provided DNS |
| `enableDnsHostnames` | Controls DNS hostname assignment for supported VPC instances |
| DHCP options | Can provide DNS servers and domain settings |
| Route 53 Resolver | Performs DNS resolution within the VPC |

This lab does not modify VPC-wide DNS attributes or DHCP options.

All intentional DNS changes are confined to the disposable EC2 instance.

---

## 5. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- SSH client
- Bash
- Amazon Linux 2023
- EC2 and VPC read permissions
- Git and GitHub

### Security and Safety Requirements

- Use a disposable EC2 instance.
- Do not modify the default VPC's shared DNS settings.
- Do not change shared DHCP options.
- Restrict SSH to a trusted public IP.
- Never upload private SSH keys to GitHub.
- Verify resolver implementation before changing settings.
- Schedule a recovery mechanism before intentionally breaking DNS.
- Preserve the default VPC and its existing networking resources.

### AWS Costs

Possible charges include EC2 compute, EBS storage, public IPv4 usage, and data transfer.

---

## 6. Prepare the AWS Environment

### Step 1 — Configure Variables

From WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="EC2-Troubleshooting-Lab12"

export INSTANCE_NAME="cloud-lab12-dns-instance"
export SG_NAME="cloud-lab12-dns-sg"
export KEY_NAME="cloud-lab12-dns-key"
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

Stop if no default VPC is available.

### Step 3 — Inspect VPC DNS Support

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

Expected:

```text
EnableDnsSupport: true
```

Inspect DNS hostnames:

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

For a typical default VPC, both settings are enabled.

### Step 4 — Select a Compatible Subnet

List supported Availability Zones:

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

Choose a compatible subnet with appropriate internet gateway routing:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

Replace the placeholder with a verified subnet ID.

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
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab12-dns-key.pem"
```

Check for an existing local key:

```bash
test ! -e "$KEY_FILE" || echo "Existing key detected"
```

Check AWS:

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new lab, `InvalidKeyPair.NotFound` is expected.

### Step 3 — Create Key Pair

Only if the AWS name and local path are unused:

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

Never commit `.pem` files.

---

## 8. Create Security Group

### Step 1 — Retrieve Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Verify:

```bash
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

If no existing group uses this name:

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab12 EC2 DNS troubleshooting" \
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

Verify the group allows outbound HTTPS.

---

## 9. Launch EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Lab Instances

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

### Step 3 — Launch Instance

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

### Step 5 — Retrieve Public IPv4

```bash
export PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Connect Over SSH

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

For production systems, independently verify the SSH host-key fingerprint.

---

## 10. Establish Healthy DNS Baseline

Run the following commands inside EC2.

### Check 1 — Inspect Network Interface

```bash
ip -br addr
```

### Check 2 — Identify Primary Interface

```bash
export IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')

echo "$IFACE"
```

The interface may be named `ens5` or another valid device name.

### Check 3 — Inspect Linux Routing

```bash
ip route
```

Expected: a valid default route.

### Check 4 — Inspect Resolver Configuration

```bash
cat /etc/resolv.conf
```

Inspect the file location:

```bash
ls -l /etc/resolv.conf

readlink -f /etc/resolv.conf
```

### Check 5 — Inspect systemd-resolved

```bash
systemctl is-active systemd-resolved
```

```bash
resolvectl status
```

If systemd-resolved is not active or the operating system does not use it for application lookups, do not use the interface override procedure below.

### Check 6 — Test DNS Resolution

```bash
getent ahostsv4 example.com
```

Expected: IPv4 addresses are returned.

### Check 7 — Test HTTPS by Domain

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: a successful HTTP response.

### Check 8 — Test Connectivity by IP

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://1.1.1.1
```

This test helps distinguish basic internet connectivity from hostname resolution. A failed request alone is not conclusive because the endpoint or TLS behavior can also affect the result.

### Baseline Findings

| Check | Expected Condition |
|---|---|
| EC2 | Running |
| Status checks | OK |
| Network interface | Up |
| Default route | Present |
| DNS resolver | Working |
| Domain lookup | Successful |
| HTTPS by hostname | Successful |
| Direct IP connectivity | Working |

---

## 11. Prepare Safe DNS Failure Simulation

**Important:** The intentional DNS modification is suitable only if `systemd-resolved` is active and the applications being tested use its resolution path.

Some Amazon Linux 2023 configurations use NetworkManager-managed resolver files or a different name-resolution setup.

Never assume that a `resolvectl` override will affect all applications on every AMI.

### Step 1 — Verify DNS Service

```bash
systemctl is-active systemd-resolved
```

```bash
resolvectl status
```

Verify that `/etc/resolv.conf` and the system's name-service configuration actually direct normal host lookups through this service.

### Step 2 — Record Baseline

```bash
sudo mkdir -p /var/tmp/ec2-lab12
```

```bash
resolvectl status | sudo tee \
  /var/tmp/ec2-lab12/dns-baseline.txt
```

Inspect the interface's current DNS configuration:

```bash
resolvectl dns "$IFACE"
```

### Step 3 — Schedule Automatic Recovery

Before applying the incorrect DNS settings, create a temporary systemd timer.

```bash
export RESOLVECTL_BIN=$(command -v resolvectl)
```

```bash
sudo systemd-run \
  --unit=lab12-auto-restore-dns \
  --on-active=3min \
  "$RESOLVECTL_BIN" revert "$IFACE"
```

Verify:

```bash
systemctl list-timers --all | grep lab12
```

The timer is intended to revert temporary interface settings after three minutes.

**Safety:** A recovery timer is a precaution, not a guarantee. Keep SSH access available and be prepared to revert the settings manually.

---

## 12. Introduce DNS Resolution Failure

### Step 1 — Configure Incorrect DNS Server

```bash
sudo resolvectl dns "$IFACE" 192.0.2.53
```

The address `192.0.2.53` belongs to a documentation-only IPv4 range.

It is used here to simulate an unreachable DNS server.

### Step 2 — Route DNS Queries Through the Interface

```bash
sudo resolvectl domain "$IFACE" '~.'
```

### Step 3 — Flush DNS Cache

```bash
sudo resolvectl flush-caches
```

### Step 4 — Verify Incorrect Configuration

```bash
resolvectl status "$IFACE"
```

Expected: `192.0.2.53` is listed as the interface DNS server.

### Step 5 — Test DNS Resolution

```bash
getent ahostsv4 www.iana.org
```

Expected if the override is effective: resolution fails or times out.

### Step 6 — Test HTTPS

```bash
curl -4 \
  --connect-timeout 3 \
  --max-time 8 \
  https://www.iana.org/ \
  -o /dev/null
```

Possible output:

```text
curl: (6) Could not resolve host: www.iana.org
```

### Important Observation

The DNS failure may not reproduce if another active resolver, cached result, or fallback DNS server handles the lookup.

Do not report a successful failure simulation unless the lookup actually fails.

This lab deliberately avoids replacing `/etc/resolv.conf` or disabling shared AWS DNS settings.

---

## 13. Troubleshooting Investigation

### Check 1 — Test Hostname Resolution

```bash
getent ahostsv4 example.com
```

### Check 2 — Test Direct IP Connectivity

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://1.1.1.1
```

If hostname resolution fails while known-IP connectivity succeeds, DNS becomes the leading suspect.

### Check 3 — Inspect Resolver Settings

```bash
resolvectl dns "$IFACE"
```

### Check 4 — Inspect Detailed Resolver State

```bash
resolvectl status "$IFACE"
```

### Check 5 — Verify Network Routing

```bash
ip route
```

### Check 6 — Inspect DNS Service

```bash
systemctl status systemd-resolved --no-pager
```

### Check 7 — Review DNS Logs

```bash
sudo journalctl \
  -u systemd-resolved \
  -n 50 \
  --no-pager
```

### Check 8 — Inspect Operating-System Resolver File

```bash
cat /etc/resolv.conf
```

If it shows `127.0.0.53`, that may be a valid local DNS stub. The actual upstream server should be investigated through `resolvectl`.

### Investigation Summary

| Check | Expected Finding |
|---|---|
| Instance state | Running |
| Network interface | Up |
| Default route | Present |
| Incorrect DNS server | `192.0.2.53` |
| Domain lookup | Fails if override is effective |
| HTTPS by hostname | Fails |
| IP-based connectivity | Can remain functional |
| Root cause | Incorrect DNS configuration |

---

## 14. Root Cause Analysis

### Root Cause

The Linux resolver was temporarily configured to send DNS queries to an unreachable DNS server.

### Technical Explanation

When an application requests a domain name, the operating system consults its configured DNS resolver.

If the resolver attempts to contact a nonresponsive DNS server, the hostname lookup may time out or fail.

Even with a valid Linux default route and a correctly configured VPC, the application can fail because it cannot obtain the destination IP address.

### Root Cause Flow

```text
EC2 Application
       |
       v
DNS Lookup Request
       |
       v
Linux DNS Resolver
       |
       v
Incorrect DNS Server
192.0.2.53
       |
       X
No Usable DNS Answer
       |
       v
Hostname Resolution Fails
       |
       v
Application Request Fails
```

### Five Whys

1. **Why did the application fail to connect?** The hostname could not be resolved.
2. **Why did DNS resolution fail?** The resolver used an unreachable DNS server.
3. **Why was that server configured?** An incorrect interface-level DNS override was applied.
4. **Why did networking otherwise remain functional?** DNS resolution and IP routing are separate components.
5. **How can this be prevented?** Use managed resolver configuration, monitor DNS failures, and validate changes before production deployment.

---

## 15. Apply Remediation

### Step 1 — Revert Incorrect DNS Configuration

Inside EC2:

```bash
sudo resolvectl revert "$IFACE"
```

This removes the temporary interface-level settings established through `resolvectl`.

### Step 2 — Flush DNS Cache

```bash
sudo resolvectl flush-caches
```

### Step 3 — Inspect Resolver State

```bash
resolvectl status
```

Confirm that the temporary `192.0.2.53` override is no longer effective.

The interface should return to its normal working DNS configuration.

If a valid DNS server is not restored, investigate DHCP and the system's actual network manager rather than blindly overwriting `/etc/resolv.conf`.

### Step 4 — Verify DNS Resolution

```bash
getent ahostsv4 example.com
```

Expected: a valid IPv4 response.

### Step 5 — Verify Another Domain

```bash
getent ahostsv4 www.amazon.com
```

Expected: successful lookup.

### Step 6 — Test HTTPS

```bash
curl -4 -I \
  --connect-timeout 5 \
  --max-time 10 \
  https://example.com
```

Expected: a successful HTTP response.

### Step 7 — Verify HTTP Status

```bash
curl -4 -sS \
  -o /dev/null \
  -w "HTTP Status: %{http_code}\n" \
  --connect-timeout 5 \
  --max-time 15 \
  https://example.com
```

Expected when the endpoint is available:

```text
HTTP Status: 200
```

### Step 8 — Stop Pending Recovery Timer

If DNS has already been restored manually and the timer has not fired:

```bash
sudo systemctl stop lab12-auto-restore-dns.timer
```

Confirm DNS remains operational.

---

## 16. Verify Recovery

### Test 1 — DNS Resolver

```bash
resolvectl status
```

### Test 2 — Domain Resolution

```bash
getent ahostsv4 example.com
```

### Test 3 — HTTPS Connectivity

```bash
curl -4 -I \
  --max-time 10 \
  https://example.com
```

### Test 4 — Linux Network Routes

```bash
ip route
```

### Test 5 — DNS Service Health

```bash
systemctl is-active systemd-resolved
```

### Recovery Comparison

| Check | During Failure | After Recovery |
|---|---|---|
| EC2 state | Running | Running |
| SSH | Usually working | Working |
| Network interface | Up | Up |
| Default route | Present | Present |
| DNS configuration | Incorrect override | Normal resolver restored |
| DNS lookup | Failure possible | Successful |
| HTTPS by hostname | Fails when DNS is broken | Successful |
| IP connectivity | Remains available | Available |
| Status checks | Usually OK | OK |

### Recovery Success Criteria

The incident is resolved when the instance can resolve domain names and connect to the required external service without relying on an incorrect DNS override.

---

## 17. Inspect AWS VPC DNS Configuration

From WSL2, first exit the EC2 instance:

```bash
exit
```

### Check 1 — VPC DNS Support

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsSupport \
  --region "$AWS_REGION"
```

### Check 2 — VPC DNS Hostnames

```bash
aws ec2 describe-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --attribute enableDnsHostnames \
  --region "$AWS_REGION"
```

### Check 3 — DHCP Options

```bash
export DHCP_OPTIONS_ID=$(aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].DhcpOptionsId' \
  --output text \
  --region "$AWS_REGION")
```

Inspect:

```bash
aws ec2 describe-dhcp-options \
  --dhcp-options-ids "$DHCP_OPTIONS_ID" \
  --query 'DhcpOptions[].DhcpConfigurations' \
  --output json \
  --region "$AWS_REGION"
```

For a typical default VPC, DNS server configuration commonly uses `AmazonProvidedDNS`.

**Important:** These shared settings are inspected only. Do not change the default VPC or DHCP options during this lab.

---

## 18. Production Engineering Considerations

### Common Causes of DNS Failure

- Incorrect DNS server
- Unreachable custom DNS resolver
- Misconfigured DHCP options
- Disabled VPC DNS support
- Incorrect operating-system resolver configuration
- Failed local DNS service
- Stale DNS cache
- Incorrect private hosted zone configuration
- Broken conditional forwarding rules
- Incorrect application DNS configuration

### Recommended Troubleshooting Sequence

1. Confirm EC2 is running.
2. Check the network interface and default route.
3. Test direct IP connectivity.
4. Test domain name resolution.
5. Inspect `/etc/resolv.conf`.
6. Identify the active DNS resolver service.
7. Inspect configured DNS servers.
8. Review resolver logs.
9. Check VPC DNS attributes.
10. Inspect DHCP options when relevant.
11. Restore the correct resolver configuration.
12. Verify DNS resolution and application connectivity.

### Production Best Practices

- Prefer managed DNS configuration.
- Avoid manually overwriting resolver files without understanding the operating system's network manager.
- Verify DNS changes after deployments.
- Monitor application DNS failures.
- Use Amazon-provided DNS where appropriate.
- Document custom DNS forwarders.
- Keep recovery procedures available.
- Avoid modifying VPC-wide settings to troubleshoot a single instance unless the shared configuration is proven faulty.
- Use infrastructure as code to manage VPC settings consistently.

### Important Production Lesson

A Linux server may have a healthy network interface and valid routing while still failing to resolve domain names.

Always distinguish DNS resolution failures from IP connectivity failures before changing firewalls, security groups, or route tables.

---

## 19. Related DNS and Connectivity Errors

| Symptom | Possible Cause |
|---|---|
| `Could not resolve host` | DNS lookup failure |
| `Temporary failure in name resolution` | Resolver or upstream DNS problem |
| DNS timeout | Unreachable or nonresponsive resolver |
| `Connection timed out` | Network routing, firewall, or endpoint issue |
| HTTP 403 | Application authorization, not necessarily DNS |
| Direct IP works but domain fails | Likely DNS problem |
| Domain resolves but HTTPS fails | TLS, routing, firewall, or application issue |
| DNS works intermittently | Resolver instability, caching, or network problems |

---

## 20. Interview Questions and Answers

### Q1. What is DNS?

DNS translates domain names into IP addresses so applications can connect to network services.

### Q2. How do you troubleshoot DNS failure on EC2?

Check the network, test direct IP connectivity, inspect resolver configuration, test DNS queries, and verify VPC DNS settings.

### Q3. What does `/etc/resolv.conf` do?

It exposes DNS resolver configuration used by Linux name-resolution components, depending on the operating system.

### Q4. What is the Amazon VPC DNS resolver IP?

```text
169.254.169.253
```

### Q5. What does `enableDnsSupport` control?

It controls whether the VPC supports DNS resolution through the Amazon-provided DNS server.

### Q6. What does `enableDnsHostnames` control?

It controls DNS hostname assignment behavior for supported instances in the VPC.

### Q7. Can an EC2 instance have internet connectivity but broken DNS?

Yes. IP routing can work while hostname lookups fail.

### Q8. What command tests DNS through normal Linux name resolution?

```bash
getent ahostsv4 example.com
```

### Q9. What does `resolvectl` do?

It inspects and manages DNS resolution information when systemd-resolved is in use.

### Q10. Why should you avoid directly replacing `/etc/resolv.conf`?

The file may be managed automatically by a network service, and manually replacing it can disrupt the system's intended DNS configuration.

### Q11. How can you distinguish DNS and routing problems?

Test resolution using a hostname and compare it with a connection to a known IP address. Also inspect routing and resolver configuration.

### Q12. How would you explain this incident in an interview?

> I investigated an EC2 instance that could reach network destinations by IP address but could not resolve domain names. I verified the instance's network interface, routing, and DNS configuration. Then I used Linux commands such as getent, resolvectl, and journalctl to identify an incorrect DNS server. I reverted the temporary DNS override and verified that hostname resolution and outbound HTTPS worked again. I also inspected VPC DNS support and DHCP options to confirm the shared AWS networking configuration was healthy.

---

## 21. Cleanup

**Warning:** Delete only resources created for Lab 12.

### Step 1 — Verify AWS Identity

From WSL2:

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Lab Instance Tags

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project: EC2-Troubleshooting-Lab12
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check automatic root-volume deletion:

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

If no dependencies remain:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Delete AWS SSH Key Pair

```bash
aws ec2 delete-key-pair \
  --key-name "$KEY_NAME" \
  --region "$AWS_REGION"
```

### Step 7 — Remove Local SSH Key

```bash
rm -f "$KEY_FILE"
```

Only remove the Lab 12 private key.

### Step 8 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Expected after successful automatic deletion:

```text
InvalidVolume.NotFound
```

If the volume remains, verify its ownership and attachment status before removing it.

### Cleanup Summary

| Resource | Expected Action |
|---|---|
| Lab EC2 instance | Terminated |
| Root EBS volume | Deleted |
| Lab security group | Deleted |
| AWS SSH key pair | Deleted |
| Local SSH private key | Deleted |
| Default VPC | Preserved |
| VPC DNS support | Unchanged |
| DHCP options | Unchanged |
| Route tables | Unchanged |

---

## 22. Repository Structure

```text
12-ec2-dns-resolution-failure/
│
└── README.md
```

All AWS CLI, Linux diagnostic, fault simulation, recovery, and cleanup steps are documented in this file.

No separate application code is required.

Never commit private keys, AWS credentials, or sensitive instance information.

---

## 23. Lessons Learned

This lab demonstrated how an EC2 instance can experience DNS resolution failures even when its network interface and routing remain functional.

The investigation involved checking Linux network settings, resolver configuration, domain name lookups, and operating-system logs.

The simulated failure used an incorrect DNS server configured through a temporary interface-level override.

The remediation involved reverting the override and restoring normal DNS resolution.

The lab also reinforced the importance of verifying the actual resolver implementation before changing Linux DNS settings.

**The key lesson is that hostname resolution and network connectivity are separate problems and should be investigated independently.**

---

## 24. Skills Demonstrated

- Amazon EC2 troubleshooting
- Amazon VPC networking
- Route 53 VPC Resolver concepts
- Linux DNS administration
- systemd-resolved diagnostics
- DNS resolution troubleshooting
- `/etc/resolv.conf` inspection
- Linux network routing
- Bash commands
- AWS CLI v2
- IMDS-independent network diagnostics
- Controlled fault simulation
- Automatic recovery safeguards
- Root cause analysis
- Incident remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-012 |
| Problem | DNS Resolution Failure |
| Simulated Root Cause | Incorrect DNS server |
| Test DNS Server | `192.0.2.53` |
| AWS VPC Resolver | `169.254.169.253` |
| Failure Evidence | Failed hostname lookup, if override effective |
| Remediation | Revert resolver override |
| DNS After Fix | Working |
| HTTPS After Fix | Working |
| VPC Configuration | Preserved |
| EC2 Health | OK |
| Cleanup | Lab resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When an EC2 instance cannot resolve a hostname, verify the active Linux resolver and DNS configuration before modifying VPC routes, security groups, or other network components. Restore the correct resolver and validate both DNS and application connectivity.

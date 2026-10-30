# AWS EC2 Troubleshooting Labs

## Overview

This repository contains 15 hands-on Amazon EC2 troubleshooting labs designed to simulate common real-world cloud infrastructure incidents.

Each lab follows a production-style incident response process to help Cloud Engineers and Cloud Security Engineers understand why EC2 instances fail and how to investigate, remediate, and verify the problem using AWS CLI, Linux, and AWS troubleshooting tools.

The labs progress from beginner-friendly instance problems to advanced networking, storage, IAM, monitoring, and recovery scenarios.

**Goal:** Develop practical AWS troubleshooting skills through realistic incidents rather than memorizing solutions.

---

## Technologies Used

- Amazon EC2
- Amazon EBS
- Amazon VPC
- AWS IAM
- AWS Systems Manager
- Amazon CloudWatch
- AWS CLI v2
- Ubuntu Linux / WSL2
- Bash
- SSH
- Linux system administration

---

## Troubleshooting Methodology

Every lab follows the same workflow:

**1. Establish Baseline**

Create a working AWS environment and verify its expected behavior.

**2. Introduce Failure**

Deliberately simulate a misconfiguration or operational failure in an isolated sandbox.

**3. Investigate**

Use AWS CLI, Linux commands, instance metadata, logs, metrics, and relevant AWS tools to gather evidence.

**4. Identify Root Cause**

Determine exactly which configuration, permission, resource, or system component caused the incident.

**5. Apply Remediation**

Restore functionality with the smallest appropriate change.

**6. Verify Recovery**

Repeat the original failed operation and confirm the system behaves correctly.

**7. Cleanup**

Remove lab resources to avoid unnecessary AWS charges.

---

## Repository Structure

```text
aws-ec2-troubleshooting-labs/
│
├── README.md
│
├── 01-instance-wont-start/
├── 02-ssh-connection-timeout/
├── 03-ssh-permission-denied/
├── 04-security-group-misconfiguration/
├── 05-user-data-script-failure/
├── 06-instance-status-check-failed/
├── 07-ebs-root-volume-full/
├── 08-high-cpu-utilization/
├── 09-no-internet-access/
├── 10-ec2-cannot-access-s3/
├── 11-instance-profile-permission-error/
├── 12-ec2-dns-resolution-failure/
├── 13-ssm-agent-connection-failure/
├── 14-instance-auto-recovery-failure/
└── 15-ec2-launch-failure/
```

Lab directories are introduced progressively as the exercises are completed.

---

## Lab Roadmap

| Lab | Incident | Difficulty |
|---|---|---|
| 01 | EC2 Instance Won't Start | Beginner |
| 02 | SSH Connection Timeout | Beginner |
| 03 | SSH Permission Denied | Beginner |
| 04 | Security Group Misconfiguration | Beginner |
| 05 | EC2 User Data Script Failure | Intermediate |
| 06 | EC2 Status Check Failed | Intermediate |
| 07 | EBS Root Volume Full | Intermediate |
| 08 | High CPU Utilization | Intermediate |
| 09 | EC2 Instance Has No Internet Access | Intermediate |
| 10 | EC2 Cannot Access Amazon S3 | Intermediate |
| 11 | EC2 Instance Profile Permission Error | Intermediate |
| 12 | EC2 DNS Resolution Failure | Advanced |
| 13 | SSM Agent Connection Failure | Advanced |
| 14 | EC2 Automatic Recovery Failure | Advanced |
| 15 | EC2 Instance Launch Failure | Advanced |

---

## Lab Descriptions

### Lab 01 — EC2 Instance Won't Start

**Incident:** An EC2 instance cannot transition into the running state.

**Skills:** EC2 state transitions, instance diagnostics, AWS CLI, instance lifecycle troubleshooting.

### Lab 02 — SSH Connection Timeout

**Incident:** An engineer cannot connect to a running Linux EC2 instance.

**Skills:** SSH connectivity, security groups, network routing, public IP addresses, TCP port 22.

### Lab 03 — SSH Permission Denied

**Incident:** SSH reaches the instance but rejects authentication.

**Skills:** SSH key pairs, Linux usernames, private-key permissions, authentication troubleshooting.

### Lab 04 — Security Group Misconfiguration

**Incident:** Application traffic is blocked because of incorrect security group rules.

**Skills:** Inbound and outbound rules, ports, CIDR ranges, least-privilege networking.

### Lab 05 — User Data Script Failure

**Incident:** An EC2 instance launches successfully, but the initialization script fails.

**Skills:** EC2 user data, cloud-init, Linux logs, startup automation.

### Lab 06 — Instance Status Check Failed

**Incident:** An instance reports failed health checks.

**Skills:** System status checks, instance status checks, EC2 monitoring, recovery decisions.

### Lab 07 — EBS Root Volume Full

**Incident:** A Linux instance runs out of disk space and applications fail.

**Skills:** Linux disk troubleshooting, EBS volumes, filesystem usage, storage expansion.

### Lab 08 — High CPU Utilization

**Incident:** An application experiences poor performance because the instance CPU is heavily utilized.

**Skills:** CloudWatch metrics, Linux process monitoring, performance analysis.

### Lab 09 — No Internet Access

**Incident:** An EC2 instance cannot reach external services.

**Skills:** Route tables, internet gateways, NAT gateways, subnet configuration, DNS.

### Lab 10 — EC2 Cannot Access Amazon S3

**Incident:** An EC2-hosted application fails to communicate with Amazon S3.

**Skills:** S3 connectivity, IAM permissions, VPC endpoints, network troubleshooting.

### Lab 11 — Instance Profile Permission Error

**Incident:** Applications running on EC2 receive AWS authorization errors.

**Skills:** Instance profiles, IAM roles, temporary credentials, least-privilege permissions.

### Lab 12 — DNS Resolution Failure

**Incident:** An EC2 instance cannot resolve required hostnames.

**Skills:** DNS, AmazonProvidedDNS, VPC DNS settings, Linux resolver troubleshooting.

### Lab 13 — SSM Agent Connection Failure

**Incident:** An EC2 instance does not appear as a connected Systems Manager managed node.

**Skills:** SSM Agent, instance profiles, VPC endpoints, connectivity diagnostics.

### Lab 14 — Instance Auto-Recovery Failure

**Incident:** An EC2 instance experiences an infrastructure-related failure and automated recovery does not occur as expected.

**Skills:** CloudWatch alarms, EC2 automatic recovery, recovery prerequisites, health monitoring.

### Lab 15 — EC2 Launch Failure

**Incident:** An instance launch request fails because of a configuration, capacity, quota, or resource restriction.

**Skills:** EC2 launch diagnostics, AMI validation, instance types, quotas, capacity, subnet requirements.

---

## Prerequisites

To complete these labs, you should have:

- An AWS account with appropriate sandbox permissions
- AWS CLI v2 installed and configured
- Ubuntu Linux / WSL2
- Basic Linux command-line knowledge
- Basic understanding of networking
- Familiarity with EC2 instances, IAM, and security groups
- Git and GitHub

### Verify AWS CLI

```bash
aws --version
```

### Verify AWS Identity

```bash
aws sts get-caller-identity
```

### Configure Default Region

```bash
export AWS_REGION="us-east-1"
```

Some exercises may require a different Region or additional services.

---

## Security Best Practices

All labs are designed around safe, isolated environments.

- Use dedicated test resources.
- Do not modify production instances.
- Never commit SSH private keys or AWS credentials.
- Limit SSH exposure to trusted source IP addresses.
- Use least-privilege IAM permissions.
- Prefer Systems Manager Session Manager when appropriate.
- Keep EBS encryption enabled when available.
- Avoid disabling security controls unnecessarily.
- Verify the current AWS account before deleting resources.
- Remove temporary instances, volumes, and other billable resources after each exercise.

**Important:** An EC2 instance in a public subnet is not automatically accessible from the internet. Routing, IP addressing, security group rules, and operating-system configuration also matter.

---

## AWS Cost Management

Some labs create billable AWS resources, including:

- EC2 instances
- EBS volumes and snapshots
- Public IPv4 addresses
- NAT gateways
- CloudWatch resources
- Other supporting infrastructure

Use small instance types when suitable, inspect estimated costs before starting, and delete resources when finished.

An AWS Free Tier entitlement should not be assumed to cover every exercise.

---

## Evidence and Verification

Each lab documents the investigation and expected recovery evidence.

Depending on the scenario, verification may include:

- EC2 instance state
- Instance status checks
- SSH connectivity
- Linux process status
- Disk usage and filesystem health
- Application logs
- Network reachability
- IAM authorization results
- CloudWatch metrics
- Successful AWS CLI responses

Expected outputs are examples. Actual results depend on the account and environment.

---

## Troubleshooting Documentation Standards

Each individual lab README includes:

1. Incident overview
2. Production scenario
3. Architecture
4. Prerequisites
5. Resource configuration
6. Failure simulation
7. Troubleshooting commands
8. Investigation findings
9. Root cause analysis
10. Remediation
11. Recovery verification
12. Prevention and security recommendations
13. Cleanup
14. Interview questions and answers
15. Lessons learned

---

## Learning Outcomes

After completing this repository, the learner should be able to:

- Diagnose EC2 instance state problems.
- Troubleshoot SSH connectivity and authentication.
- Investigate security group and network failures.
- Analyze EC2 initialization and Linux system logs.
- Resolve common EBS storage problems.
- Investigate CPU and instance performance.
- Troubleshoot IAM instance-profile permissions.
- Diagnose DNS and Systems Manager connectivity.
- Understand automatic recovery limitations.
- Investigate EC2 launch failures.
- Document AWS incidents using a structured approach.

---

## Target Roles

These labs are relevant to:

- Cloud Engineer
- Junior Cloud Engineer
- Cloud Operations Engineer
- Cloud Security Engineer
- DevOps Engineer
- Infrastructure Engineer
- Platform Engineer
- Site Reliability Engineer

---

## Project Philosophy

**Break It → Investigate It → Fix It → Verify It → Document It**

These exercises are intentionally designed to develop hands-on troubleshooting skills.

The focus is not just making AWS resources work, but understanding why they fail, identifying the root cause, and applying safe, repeatable solutions.

## Status

**Curriculum:** 15 planned labs

**Starting Point:** Lab 01 — EC2 Instance Won't Start

Labs will be added progressively as they are completed.

---

## Disclaimer

This repository is intended for educational purposes.

All failures should be simulated in authorized sandbox environments. AWS services may incur charges. Always verify the resources and account before executing destructive commands.

**Built for practical Cloud Engineering and Cloud Security Engineering preparation.**

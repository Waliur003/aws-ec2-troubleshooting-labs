# Lab 08 — Amazon EC2 High CPU Utilization

## Overview

This hands-on lab demonstrates how to troubleshoot high CPU utilization on an Amazon EC2 Linux instance using AWS CLI, Amazon CloudWatch, and Linux performance-monitoring tools.

In this simulated production incident, an EC2 instance experiences elevated CPU usage because a Python workload continuously performs CPU-intensive calculations.

The goal is to identify the process responsible for the CPU spike, investigate system performance, review CloudWatch metrics, safely stop the problematic workload, and verify recovery.

The exercise also introduces CPU credit behavior on burstable Amazon EC2 T3 instances.

**Root Cause:** CPU-intensive Python worker processes.

**Remediation:** Identify and terminate the controlled CPU workload.

**Troubleshooting Workflow:**

Baseline → Generate CPU Load → Investigate → Root Cause Analysis → Remediate → Verify → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-008 |
| AWS Services | EC2, CloudWatch, VPC |
| Difficulty | Beginner–Intermediate |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| vCPUs | 2 |
| CPU Credit Mode | Standard |
| Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Python, Bash, SSH |
| Linux Diagnostics | `top`, `ps`, `uptime`, `vmstat` |
| Primary Metric | `CPUUtilization` |
| Supporting Metrics | `CPUCreditBalance`, `CPUCreditUsage` |
| Root Cause | CPU-intensive Python workload |
| Remediation | Stop identified workload |
| Expected Outcome | CPU usage returns toward baseline |

---

## 1. Production Incident Scenario

### Incident Description

A Cloud Operations team receives reports that an application hosted on Amazon EC2 is responding slowly.

The instance remains in the `running` state and passes its EC2 status checks. However, system performance has degraded.

CloudWatch monitoring indicates elevated CPU utilization.

The engineer must determine which workload is consuming CPU and whether the behavior is expected or caused by an inefficient process.

### Expected Behavior

The instance should have sufficient CPU capacity to handle its normal workloads.

### Simulated Behavior

Two Python worker processes perform repeated calculations, consuming available CPU capacity.

### Potential Business Impact

- Increased application response time
- Reduced throughput
- CPU resource contention
- Delayed background jobs
- Increased request latency
- CPU credit exhaustion
- Possible CPU throttling
- Performance-related alerts

### Investigation Objective

Identify the CPU-intensive workload, determine its effect on the instance, stop it safely, and verify that CPU utilization decreases.

---

## 2. Architecture

### Healthy Environment

```text
          Amazon EC2 Instance
               t3.micro
                  |
                  v
          Amazon Linux 2023
                  |
                  v
           Normal Processes
                  |
                  v
             Low CPU Usage
                  |
                  v
          Application Healthy
```

### High CPU Environment

```text
          Amazon EC2 Instance
               t3.micro
                  |
                  v
             Linux OS
                  |
                  v
            cpu-load.py
                  |
           +------+------+
           |             |
           v             v
       Worker 1       Worker 2
           |             |
           +------+------+
                  |
                  v
        CPU-Intensive Calculations
                  |
                  v
           High CPU Usage
                  |
                  v
       Potential Performance Impact
```

### Recovery Architecture

```text
           Cloud Engineer
                  |
                  v
           Linux Diagnostics
             top / ps
                  |
                  v
        Identify CPU Workload
                  |
                  v
        Stop Lab Python Process
                  |
                  v
         CPU Activity Decreases
                  |
                  v
         Verify with CloudWatch
                  |
                  v
           Performance Restored
```

---

## 3. Understanding CPU Utilization

CPU utilization measures the percentage of available CPU processing capacity being used by the instance.

### Important Linux CPU Concepts

| Concept | Explanation |
|---|---|
| CPU | Central Processing Unit |
| vCPU | Virtual processor allocated to EC2 |
| CPU utilization | Percentage of available CPU capacity in use |
| User CPU | CPU time spent executing user processes |
| System CPU | CPU time spent executing kernel operations |
| Idle CPU | Time when the CPU is not executing work |
| Load average | Average number of runnable or uninterruptible tasks |
| Process ID | Identifier assigned to a running process |

### Important Linux Commands

| Command | Purpose |
|---|---|
| `top` | Interactive process and CPU monitoring |
| `ps` | Display process information |
| `uptime` | Show system uptime and load averages |
| `vmstat` | Display CPU and system activity |
| `nproc` | Show available processing units |
| `lscpu` | Display processor information |
| `pgrep` | Find matching processes |
| `kill` | Send signals to processes |

### CPU Utilization vs Load Average

CPU utilization reports processor usage.

Load average reports the average number of tasks that are runnable or waiting in uninterruptible sleep.

For example, a load average near 2 on an instance with two vCPUs may indicate that approximately two tasks are competing for or using processing resources.

Load average is not a CPU percentage.

---

## 4. Understanding T3 CPU Credits

Amazon EC2 T3 instances use a burstable CPU performance model.

These instances have baseline CPU performance and can temporarily burst above that baseline using CPU credits.

### CPU Credit

One CPU credit represents one vCPU running at 100% utilization for one minute.

### CPU Credit Metrics

| Metric | Description |
|---|---|
| `CPUCreditBalance` | Available accrued CPU credits |
| `CPUCreditUsage` | CPU credits consumed |
| `CPUSurplusCreditBalance` | Surplus credits accumulated in Unlimited mode |
| `CPUSurplusCreditsCharged` | Surplus credits charged in Unlimited mode |

### Standard vs Unlimited

| Standard | Unlimited |
|---|---|
| Uses accrued CPU credits | Can sustain bursting beyond accrued credits |
| Performance limited when credits are exhausted | May incur surplus CPU credit charges |
| Suitable for bounded learning exercises | Requires cost awareness |

This lab explicitly uses Standard mode to avoid Unlimited-mode surplus credit charges.

**Important:** High CPU utilization is not automatically an incident. The engineer must determine whether the activity is expected and whether it negatively affects workload performance.

---

## 5. Prerequisites

Required:

- AWS account
- AWS CLI v2
- Ubuntu Linux / WSL2
- SSH client
- Python 3
- Bash
- EC2 and CloudWatch permissions
- Git and GitHub

### Security Requirements

- Use a dedicated disposable EC2 instance.
- Restrict SSH access to a trusted public IPv4 address.
- Keep SSH private keys outside GitHub.
- Limit CPU workload duration.
- Do not run load tests on production systems.
- Terminate only processes belonging to this lab.
- Verify resource tags before cleanup.

### Cost Considerations

Possible charges include:

- EC2 compute
- EBS storage
- Public IPv4 usage
- Data transfer

The example uses `t3.micro` with Standard CPU credit mode.

---

## 6. Prepare AWS Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"

export INSTANCE_NAME="cloud-lab08-cpu-instance"
export SG_NAME="cloud-lab08-cpu-sg"
export KEY_NAME="cloud-lab08-cpu-key"
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

### Step 3 — Identify Supported Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

### Step 4 — Identify Subnets

```bash
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,Default:DefaultForAz}' \
  --output table \
  --region "$AWS_REGION"
```

Choose a default subnet in a supported Availability Zone:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

Replace this placeholder with a real subnet ID from your account.

Verify public internet routing before launching.

---

## 7. Create SSH Credentials

### Step 1 — Create SSH Directory

```bash
mkdir -p ~/.ssh/aws-ec2-labs

chmod 700 ~/.ssh
chmod 700 ~/.ssh/aws-ec2-labs
```

### Step 2 — Configure Private Key Path

```bash
export KEY_FILE="$HOME/.ssh/aws-ec2-labs/cloud-lab08-cpu-key.pem"
```

Check that the local file does not exist:

```bash
test ! -e "$KEY_FILE" || echo "Key file already exists"
```

Check AWS:

```bash
aws ec2 describe-key-pairs \
  --key-names "$KEY_NAME" \
  --region "$AWS_REGION"
```

For a new key pair, AWS returns `InvalidKeyPair.NotFound`.

### Step 3 — Generate the Key Pair

Only when the key pair name and local path are unused:

```bash
umask 077

aws ec2 create-key-pair \
  --key-name "$KEY_NAME" \
  --key-type rsa \
  --query KeyMaterial \
  --output text \
  --region "$AWS_REGION" > "$KEY_FILE"
```

### Step 4 — Secure the Key

```bash
chmod 400 "$KEY_FILE"
```

Verify:

```bash
ls -l "$KEY_FILE"
```

Never commit `.pem` files.

---

## 8. Configure Security Group

### Step 1 — Retrieve Public IPv4

```bash
export MY_IP=$(curl -4 -fsS \
  https://checkip.amazonaws.com | tr -d '\r\n')
```

Verify:

```bash
echo "$MY_IP"
```

### Step 2 — Check for an Existing Group

```bash
aws ec2 describe-security-groups \
  --filters \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[].GroupId' \
  --output text \
  --region "$AWS_REGION"
```

Create only if the group does not already exist.

### Step 3 — Create Security Group

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab08 EC2 CPU troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow SSH From Trusted IP

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

## 9. Launch EC2 Instance

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

Do not launch duplicates.

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --credit-specification "CpuCredits=standard" \
  --key-name "$KEY_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    'ResourceType=instance,Tags=[{Key=Name,Value=cloud-lab08-cpu-instance},{Key=Project,Value=EC2-Troubleshooting-Lab08}]' \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Verify CPU Credit Mode

```bash
aws ec2 describe-instance-credit-specifications \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Expected:

```text
CpuCredits: standard
```

### Step 5 — Wait for Readiness

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Health

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

### Step 8 — Connect to EC2

```bash
ssh \
  -o ConnectTimeout=10 \
  -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=accept-new \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

Verify the SSH host fingerprint through a trusted source for production access.

---

## 10. Establish CPU Baseline

Execute the following commands inside EC2.

### Check 1 — Available Processors

```bash
nproc
```

Expected for `t3.micro`:

```text
2
```

### Check 2 — CPU Information

```bash
lscpu
```

### Check 3 — Current CPU Activity

```bash
top
```

Press `q` to exit.

### Check 4 — Load Average

```bash
uptime
```

Example:

```text
load average: 0.02, 0.04, 0.01
```

### Check 5 — Top CPU Processes

```bash
ps -eo pid,ppid,user,%cpu,%mem,stat,comm \
  --sort=-%cpu | head -n 12
```

### Baseline Findings

| Component | Expected Condition |
|---|---|
| EC2 instance | Running |
| Status checks | OK |
| vCPUs | 2 |
| CPU utilization | Relatively low |
| Load average | Relatively low |
| CPU-intensive test processes | Absent |

Record actual baseline values before introducing the workload.

---

## 11. Create the CPU-Intensive Workload

Return to Ubuntu WSL2:

```bash
exit
```

### Step 1 — Create `cpu-load.py`

```python
#!/usr/bin/env python3

import multiprocessing as mp
import os
import time

DURATION_SECONDS = 360
WORKERS = min(os.cpu_count() or 1, 2)


def cpu_worker(deadline):
    value = 1

    while time.monotonic() < deadline:
        value = ((value * 1103515245) + 12345) & 0x7FFFFFFF


def main():
    deadline = time.monotonic() + DURATION_SECONDS
    processes = []

    print(
        f"INC-EC2-008: Starting {WORKERS} CPU workers",
        flush=True
    )

    try:
        for _ in range(WORKERS):
            process = mp.Process(
                target=cpu_worker,
                args=(deadline,)
            )
            process.start()
            processes.append(process)

        for process in processes:
            process.join()

    except KeyboardInterrupt:
        print("Interrupted; stopping CPU workers", flush=True)

    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()

        for process in processes:
            process.join(timeout=5)

        print(
            "INC-EC2-008: CPU workload stopped",
            flush=True
        )


if __name__ == "__main__":
    main()
```

### Script Explanation

The script uses Python's multiprocessing module to create CPU-intensive worker processes.

Each worker continuously performs mathematical calculations until the deadline expires.

The number of workers is limited to two.

The workload has a six-minute execution deadline.

The parent process attempts to stop remaining worker processes before exiting.

### Safety Controls

- Maximum two CPU workers
- Six-minute internal deadline
- External Linux timeout
- Dedicated lab process
- No intentionally large output files
- No production workloads affected

---

## 12. Upload and Start the Workload

### Step 1 — Upload Script

From WSL2:

```bash
scp \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  cpu-load.py \
  ec2-user@"$PUBLIC_IP":/home/ec2-user/cpu-load.py
```

### Step 2 — Connect

```bash
ssh \
  -o IdentitiesOnly=yes \
  -i "$KEY_FILE" \
  ec2-user@"$PUBLIC_IP"
```

### Step 3 — Start CPU Load

Inside EC2:

```bash
nohup timeout --signal=TERM --kill-after=10s 390s \
  python3 /home/ec2-user/cpu-load.py \
  > /home/ec2-user/lab08-cpu.log 2>&1 < /dev/null &

echo $! > /home/ec2-user/lab08-cpu.pid
```

### Step 4 — Record Process ID

```bash
cat /home/ec2-user/lab08-cpu.pid
```

### Step 5 — Inspect Log

```bash
cat /home/ec2-user/lab08-cpu.log
```

Expected beginning:

```text
INC-EC2-008: Starting 2 CPU workers
```

**Note:** On a burstable instance, actual CPU throughput depends on available CPU credits.

---

## 13. Troubleshooting Investigation

### Check 1 — Monitor CPU With top

```bash
top
```

Look for Python processes consuming CPU.

Press `q` to exit.

### Check 2 — Identify High CPU Processes

```bash
ps -eo pid,ppid,user,%cpu,%mem,stat,comm,args \
  --sort=-%cpu | head -n 12
```

Expected: one or more Python worker processes with elevated CPU usage.

### Check 3 — Inspect Parent Process

```bash
export LOAD_PID=$(cat /home/ec2-user/lab08-cpu.pid)

ps -p "$LOAD_PID" \
  -o pid,ppid,%cpu,%mem,etime,args
```

The PID saved by the shell refers to the outer `timeout` process. The Python parent and workers are its descendants.

### Check 4 — Inspect Process Hierarchy

```bash
ps -eo pid,ppid,%cpu,comm,args --forest |
  grep -E 'timeout|cpu-load.py'
```

Verify the processes belong to the controlled Lab 08 workload.

### Check 5 — Inspect Load Average

```bash
uptime
```

An elevated load average may indicate increased competition for CPU resources.

### Check 6 — Inspect CPU Statistics

```bash
vmstat 1 5
```

Relevant fields:

| Field | Meaning |
|---|---|
| `r` | Runnable tasks |
| `us` | User-space CPU time |
| `sy` | Kernel-space CPU time |
| `id` | Idle CPU time |
| `wa` | I/O wait |

During the CPU-intensive workload, expect user CPU activity to increase and idle time to decrease.

### Investigation Summary

| Check | Expected Finding |
|---|---|
| EC2 state | Running |
| Status checks | Usually OK |
| CPU activity | Elevated |
| Python worker processes | Active |
| Load average | Increased |
| CPU credits | May decrease |
| Memory consumption | Not primary bottleneck |
| Root cause | CPU-intensive Python workload |

---

## 14. CloudWatch Investigation

Amazon CloudWatch provides EC2 performance metrics.

Unlike Linux process tools, standard EC2 CloudWatch CPU metrics do not identify the specific process consuming CPU.

### Step 1 — Set Monitoring Window

From a separate WSL2 terminal:

```bash
export AWS_REGION="us-east-1"

export INSTANCE_ID="REPLACE_WITH_LAB08_INSTANCE_ID"

export START_TIME=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

export END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

Replace the placeholder with the actual EC2 instance ID.

### Step 2 — Query CPUUtilization

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Average Maximum \
  --region "$AWS_REGION"
```

### Metric Interpretation

| Statistic | Meaning |
|---|---|
| Average | Mean CPU utilization during the period |
| Maximum | Highest published CPU utilization statistic during the period |

With basic EC2 monitoring, metrics are typically available at five-minute resolution.

A short test might not produce a clearly elevated CloudWatch datapoint due to collection intervals, publication delays, or T3 CPU credit behavior.

### Step 3 — Inspect CPUCreditBalance

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUCreditBalance \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Average \
  --region "$AWS_REGION"
```

### Step 4 — Inspect CPUCreditUsage

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUCreditUsage \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 300 \
  --statistics Sum \
  --region "$AWS_REGION"
```

### CloudWatch Findings

| Metric | Expected Behavior |
|---|---|
| CPUUtilization | May increase |
| CPUCreditBalance | May decrease |
| CPUCreditUsage | May increase |
| StatusCheckFailed_Instance | Usually remains 0 |

Record actual metric values rather than assuming the test generated a particular measurement.

---

## 15. Root Cause Analysis

### Root Cause

The elevated CPU activity was caused by Python worker processes performing continuous calculations.

### Technical Explanation

CPU-bound programs consume processor time while performing calculations.

When multiple CPU-intensive tasks run simultaneously on a small EC2 instance, they compete for available processing resources.

This can reduce the CPU capacity available to other workloads.

### Root Cause Flow

```text
Python CPU Script Started
           |
           v
Two Worker Processes Created
           |
           v
Repeated Mathematical Calculations
           |
           v
Increased CPU Demand
           |
           v
Higher CPU Utilization
           |
           v
Potential Resource Contention
```

### Five Whys

1. **Why was CPU usage elevated?** Python processes consumed CPU time.
2. **Why were the processes consuming CPU?** They continuously performed calculations.
3. **Why did this affect the instance?** The workload used a significant portion of the available vCPU capacity.
4. **Why was it identifiable?** Linux process-monitoring tools revealed the busy processes.
5. **How can it be prevented?** Monitor performance, limit background workloads, and implement appropriate application resource controls.

---

## 16. Apply Remediation

### Step 1 — Identify the Lab Process

Inside EC2:

```bash
export LOAD_PID=$(cat /home/ec2-user/lab08-cpu.pid)
```

Inspect:

```bash
ps -p "$LOAD_PID" -o pid,ppid,args
```

### Step 2 — Inspect the Process Tree

```bash
ps -eo pid,ppid,args --forest |
  grep -E 'timeout|cpu-load.py'
```

Confirm the processes belong to Lab 08.

### Step 3 — Stop the Workload

If the workload is still running:

```bash
kill -TERM "$LOAD_PID"
```

The external `timeout` process should forward the termination signal to the Python workload.

If the test has already reached its time limit, no termination is required.

### Step 4 — Verify Termination

```bash
pgrep -af 'cpu-load.py' || true
```

Expected: no running Lab 08 CPU worker processes.

If any remain, confirm their identity before stopping them individually.

**Safety:** Do not use broad commands such as `killall python3`, which could disrupt unrelated applications.

---

## 17. Verify Recovery

### Test 1 — Inspect CPU Activity

```bash
top
```

Expected: reduced CPU activity and increased idle time after the workload stops.

### Test 2 — Inspect Processes

```bash
ps -eo pid,ppid,user,%cpu,%mem,comm \
  --sort=-%cpu | head -n 12
```

### Test 3 — Inspect System Statistics

```bash
vmstat 1 5
```

### Test 4 — Inspect Workload Logs

```bash
cat /home/ec2-user/lab08-cpu.log
```

The log may include:

```text
INC-EC2-008: CPU workload stopped
```

If an external timeout terminated the program, the final Python message may not appear.

### Test 5 — Verify EC2 Health

Exit EC2 and run:

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

### Test 6 — Compare CloudWatch CPU Usage

Query CPUUtilization again after the workload stops.

Look for CPU activity returning toward its baseline.

CloudWatch data may lag behind the current Linux process state.

### Verification Summary

| Check | During Load | After Recovery |
|---|---|---|
| EC2 state | Running | Running |
| Python workers | Active | Stopped |
| Linux CPU utilization | Elevated | Reduced |
| CPU idle time | Lower | Higher |
| Load average | Increased | Gradually decreases |
| CloudWatch CPUUtilization | May increase | Trends toward baseline |
| CPUCreditBalance | May decrease | Can recover over time |
| EC2 status checks | Usually OK | OK |

---

## 18. Production Engineering Considerations

### Common Causes of High CPU on EC2

- CPU-intensive application code
- Inefficient loops
- High request traffic
- Background jobs
- Scheduled tasks
- Excessive process concurrency
- Application bugs
- Data processing workloads
- Container CPU contention
- CPU credit exhaustion on burstable instances

### Recommended Troubleshooting Sequence

1. Inspect CloudWatch CPU utilization.
2. Determine when the spike began.
3. Check T-series CPU credit metrics if applicable.
4. Connect to the instance using an authorized method.
5. Use `top` and `ps` to identify CPU-intensive processes.
6. Review recent deployments and scheduled jobs.
7. Examine application performance and logs.
8. Determine whether the load is expected.
9. Apply the least disruptive remediation.
10. Verify CPU, latency, errors, and application health.

### Production Remediation Options

**Stop a faulty process:** Suitable when a confirmed malfunctioning process causes the spike.

**Optimize application code:** Reduce unnecessary computations or inefficient algorithms.

**Scale vertically:** Use a larger EC2 instance when greater processing capacity is required.

**Scale horizontally:** Add application instances behind a load balancer when the architecture supports it.

**Use Auto Scaling:** Adjust the number of instances based on application demand.

**Review burstable instance selection:** Consider whether sustained workloads should use an instance family designed for consistent CPU performance.

### Monitoring Recommendations

Consider CloudWatch alarms for sustained CPU utilization and appropriate CPU credit thresholds.

Example alert levels:

| CPU Utilization | Example Response |
|---|---|
| Below 50% | Routine monitoring |
| 50–70% | Review workload trend |
| 70–85% | Investigate sustained demand |
| Above 85% | Evaluate performance and capacity |
| Near 100% | Investigate possible saturation |

These thresholds are illustrative. Actual alerting should reflect workload requirements and service-level objectives.

---

## 19. Related EC2 Performance Issues

| Symptom | Possible Cause |
|---|---|
| High CPU utilization | CPU-intensive processes |
| High load average | Runnable or blocked tasks |
| Low CPUCreditBalance | Sustained bursting on T-series |
| High memory utilization | Memory-intensive workload |
| High I/O wait | Storage bottleneck |
| Application latency | CPU, memory, network, or storage contention |
| EC2 status check impaired | Guest or infrastructure problem, depending on check |
| High CPU with healthy status checks | Instance reachable despite resource pressure |

---

## 20. Interview Questions and Answers

### Q1. How do you troubleshoot high CPU usage on EC2?

First inspect CloudWatch CPU metrics. Then use Linux process tools such as `top` and `ps` to identify the workload consuming CPU.

### Q2. What is the difference between CPU utilization and load average?

CPU utilization measures processor activity. Load average reflects tasks that are runnable or waiting in uninterruptible sleep.

### Q3. What command shows the highest CPU-consuming processes?

```bash
ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head
```

### Q4. What is a CPU credit?

A CPU credit represents one vCPU running at full utilization for one minute, or equivalent CPU usage.

### Q5. What happens when a T3 Standard instance runs out of CPU credits?

Its ability to sustain CPU usage above its baseline becomes limited until more credits are available.

### Q6. What does CloudWatch CPUUtilization measure?

The percentage of allocated EC2 CPU capacity in use.

### Q7. Can an EC2 instance have high CPU but healthy status checks?

Yes. High CPU does not automatically cause a status-check failure.

### Q8. Why should you avoid killing every Python process?

Other Python processes may support unrelated applications or system tasks.

### Q9. What is the difference between scaling vertically and horizontally?

Vertical scaling increases the capacity of an individual instance. Horizontal scaling adds more instances to distribute the workload.

### Q10. How can high CPU be prevented?

Use monitoring, efficient application code, workload controls, suitable instance sizing, and appropriate scaling mechanisms.

### Q11. Why is CloudWatch alone insufficient for identifying a high CPU process?

Standard EC2 CPU metrics show instance-level activity, not the identity of each Linux process.

### Q12. How would you explain this incident in an interview?

> I investigated high CPU utilization on an EC2 instance. I first established a CPU baseline and reviewed CloudWatch CPU metrics. Then I used Linux tools such as top, ps, and vmstat to identify CPU-intensive Python worker processes. I also reviewed CPU credit metrics because the instance was a burstable T3 instance. After confirming that the test workload was responsible, I stopped the specific process and verified that CPU activity decreased. Finally, I confirmed the instance remained healthy and removed all temporary AWS resources.

---

## 21. Cleanup

**Warning:** Perform these steps only for the dedicated Lab 08 resources.

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

Confirm:

```text
Project: EC2-Troubleshooting-Lab08
```

### Step 3 — Record Root EBS Volume

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text \
  --region "$AWS_REGION")
```

Check deletion behavior:

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

### Step 5 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

If AWS returns `InvalidVolume.NotFound`, the root volume has been deleted.

If it remains `available`, verify it belongs exclusively to Lab 08 and has no attachments before deleting it:

```bash
aws ec2 delete-volume \
  --volume-id "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Check Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

Confirm no network interface still references the group.

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

### Step 9 — Remove Local SSH Private Key

```bash
rm -f "$KEY_FILE"
```

Only delete the private key created for Lab 08.

### Step 10 — Confirm Cleanup

Verify that:

- The EC2 instance is terminated.
- The dedicated root EBS volume is deleted.
- The security group is deleted.
- The AWS key pair is deleted.
- The local private key is removed.
- The default VPC and subnets remain intact.

---

## 22. Repository Structure

```text
08-high-cpu-utilization/
│
├── README.md
└── cpu-load.py
```

The Python script generates a controlled CPU-intensive workload.

The README documents the incident scenario, reproduction, investigation, root cause, remediation, verification, and cleanup.

Do not commit credentials, private keys, or sensitive AWS resource identifiers.

---

## 23. Lessons Learned

This lab demonstrated how to investigate elevated CPU utilization on an Amazon EC2 instance.

The investigation involved Linux process monitoring, system load analysis, CloudWatch CPU metrics, and CPU credit monitoring.

The simulated issue was caused by a CPU-intensive Python workload running multiple worker processes.

The remediation involved identifying and stopping the specific workload.

The lab also demonstrated that high CPU utilization does not necessarily mean an EC2 instance has failed its status checks.

The key lesson is to determine which process is consuming CPU and whether the activity represents expected demand or an actual performance problem before taking corrective action.

---

## 24. Skills Demonstrated

- Amazon EC2 performance troubleshooting
- Amazon CloudWatch
- EC2 CPUUtilization monitoring
- T3 CPU credit analysis
- Linux process management
- CPU performance diagnostics
- Python multiprocessing
- Bash scripting
- SSH administration
- AWS CLI v2
- Linux system monitoring
- Root cause analysis
- Production incident response
- Safe process remediation
- EC2 resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-008 |
| Problem | High CPU Utilization |
| Simulated Root Cause | CPU-intensive Python workload |
| Instance Type | t3.micro |
| CPU Credit Mode | Standard |
| CPU Workers | Maximum 2 |
| Workload Duration | Maximum 6 minutes internally |
| Detection | Linux tools and CloudWatch |
| Remediation | Stop controlled workload |
| CPU After Recovery | Returns toward baseline |
| EC2 Status Checks | OK |
| Cleanup | All temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** When EC2 CPU utilization is high, use CloudWatch to identify performance trends and Linux tools to identify the responsible processes. Verify the cause before taking action, and confirm system performance after remediation.

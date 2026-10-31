# Lab 14 — Amazon EC2 Instance Auto Recovery Failure

## Overview

This lab demonstrates how to troubleshoot and remediate incorrect Amazon EC2 automatic recovery configurations.

EC2 automatic recovery helps restore eligible instances affected by underlying AWS infrastructure problems. However, recovery protection may be disabled, a CloudWatch recovery alarm may be misconfigured, or an actual recovery attempt may fail because of AWS infrastructure conditions.

We will investigate two simulated configuration problems:

1. **Simplified automatic recovery disabled** on an eligible EC2 instance.
2. **CloudWatch recovery alarm missing its recovery action**, preventing the alarm from initiating an EC2 recovery.

We will restore the configuration, test alarm state transitions safely, verify the recovery settings, and clean up all disposable resources.

**Important:** This lab does not deliberately cause a real infrastructure failure or verify a successful instance migration. It tests configuration and monitoring behavior.

**Workflow:**

Provision → Diagnose → Remediate → Simulate Alarm State → Verify Protection → Cleanup

---

## Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-EC2-014 |
| AWS Services | EC2, CloudWatch, AWS Health, VPC |
| Difficulty | Intermediate–Advanced |
| Operating System | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Region | `us-east-1` |
| Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash |
| Scenario A | Simplified recovery disabled |
| Scenario B | CloudWatch recovery action missing |
| Monitored Metric | `StatusCheckFailed_System` |
| Recovery Action | `arn:aws:automate:us-east-1:ec2:recover` |
| Remediation | Restore recovery settings and alarm action |
| Fault Injection | Configuration-level only |
| Expected Outcome | Recovery mechanisms correctly configured |

---

## 1. Production Incident Scenario

### Incident Description

A company's application runs on an Amazon EC2 instance.

The operations team expects the instance to recover automatically when eligible underlying AWS host infrastructure experiences an impairment.

During a configuration audit, the cloud engineer discovers that automatic recovery protection is incomplete.

Two issues are identified:

- Simplified automatic recovery is disabled.
- A CloudWatch alarm monitors system status failures but has no EC2 recovery action.

The instance is currently healthy, but its recovery configuration does not meet the intended operational requirements.

### Expected Behavior

The instance should have simplified recovery configured to:

```text
default
```

The CloudWatch alarm should monitor:

```text
AWS/EC2
StatusCheckFailed_System
```

And invoke:

```text
arn:aws:automate:us-east-1:ec2:recover
```

when a qualifying alarm condition occurs.

### Actual Misconfiguration

**Scenario A:**

```text
MaintenanceOptions.AutoRecovery = disabled
```

**Scenario B:**

```text
AlarmActions = []
ActionsEnabled = false
```

### Potential Business Impact

- Prolonged instance unavailability during infrastructure incidents
- Delayed recovery from host impairments
- Reduced application availability
- Increased manual operational intervention
- Extended incident response time
- Failure to meet recovery expectations

### Investigation Objective

Identify missing recovery protection and restore appropriate automatic recovery configuration without introducing a real EC2 outage.

---

## 2. Recovery Architecture

### Simplified Automatic Recovery

```text
               Amazon EC2
                    |
                    v
          AWS Infrastructure Health
                    |
                    v
           System Status Checks
                    |
                    v
         Supported Host Impairment
                    |
                    v
       AWS Simplified Auto Recovery
                    |
                    v
         Recovery Attempt by AWS
                    |
                    v
         Instance Availability
```

### CloudWatch Action-Based Recovery

```text
                Amazon EC2
                     |
                     v
          StatusCheckFailed_System
                     |
                     v
             CloudWatch Alarm
                     |
                +----+----+
                |         |
                v         v
          No Action     Recover Action
                |         |
                X         v
          No Recovery   EC2 Recovery
          Initiation    Attempt
```

### Remediation Architecture

```text
        EC2 Recovery Configuration
                    |
                    v
           Diagnose Protection
                    |
          +---------+---------+
          |                   |
          v                   v
   Simplified Recovery   CloudWatch Alarm
      Disabled           Missing Action
          |                   |
          v                   v
    Restore Default      Add Recover ARN
          |                   |
          +---------+---------+
                    |
                    v
            Verify Configuration
                    |
                    v
             Protection Ready
```

The final state demonstrates configured recovery protection, not proof that an actual host migration will succeed.

---

## 3. Understanding EC2 Recovery

### Simplified Automatic Recovery

Simplified automatic recovery is an AWS-managed capability that attempts to recover eligible EC2 instances from supported underlying infrastructure impairments.

It is enabled by default for supported instances unless disabled.

The relevant configuration values are:

| Value | Meaning |
|---|---|
| `default` | Use simplified recovery when supported |
| `disabled` | Disable simplified recovery |

The `default` setting does not make an unsupported instance eligible.

### CloudWatch Action-Based Recovery

CloudWatch action-based recovery uses a metric alarm that monitors an EC2 instance's system status checks.

When the system failure condition is met and the recovery action is enabled, CloudWatch can initiate an EC2 recovery attempt.

### Status Check Metrics

| Metric | Meaning |
|---|---|
| `StatusCheckFailed_System` | Underlying AWS infrastructure or host impairment |
| `StatusCheckFailed_Instance` | Guest operating-system or instance-level problem |
| `StatusCheckFailed` | Aggregate status-check failure |

The EC2 recover action uses the system status check metric.

### Recovery Limitations

Automatic recovery is not guaranteed in every situation.

Recovery can be affected by instance eligibility, AWS service events, capacity availability, and recovery-attempt limits.

Automatic recovery also does not replace a highly available architecture using multiple instances and Availability Zones.

---

## 4. Prerequisites and Safety

Required:

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 management permissions
- CloudWatch alarm management permissions
- EC2 and CloudWatch read permissions
- Git and GitHub

### Safety Requirements

- Use a disposable EC2 instance.
- Confirm the chosen instance type supports recovery.
- Do not cause an actual host or system failure.
- Keep CloudWatch alarm actions disabled during the simulated state transition.
- Never force the alarm into `ALARM` after enabling the recovery action.
- Verify resources using IDs and tags before deletion.
- Preserve the default VPC and shared networking infrastructure.

### Cost Considerations

The exercise may incur EC2, EBS, CloudWatch alarm, and other applicable charges.

We do not create a NAT gateway, load balancer, or additional VPC.

---

## 5. Prepare the AWS Environment

Run the commands in Ubuntu WSL2.

### Step 1 — Create Lab Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="EC2-Troubleshooting-Lab14"

export INSTANCE_NAME="cloud-lab14-recovery-instance"
export SG_NAME="cloud-lab14-recovery-sg"

export ALARM_NAME="cloud-lab14-system-recovery-alarm"

export RECOVERY_ARN="arn:aws:automate:${AWS_REGION}:ec2:recover"
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

### Step 3 — Identify Compatible Subnet

Check instance-type availability:

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

Choose a compatible subnet:

```bash
export SUBNET_ID="subnet-REPLACE_WITH_ACTUAL_ID"
```

No public IPv4, SSH key, or guest login is required for this exercise.

### Step 4 — Verify Recovery Support

```bash
aws ec2 describe-instance-types \
  --instance-types t3.micro \
  --query 'InstanceTypes[].{Type:InstanceType,AutoRecovery:AutoRecoverySupported}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm that the instance type supports automatic recovery before launching it.

---

## 6. Create Security Group

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

### Step 2 — Create Dedicated Group

Only if the group name is unused:

```bash
export SG_ID=$(aws ec2 create-security-group \
  --group-name "$SG_NAME" \
  --description "Lab14 EC2 auto recovery troubleshooting" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Inbound Rules

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

No inbound rules are required.

---

## 7. Launch EC2 With Recovery Disabled

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Lab Instance

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

### Step 3 — Launch EC2

**Important:** Use the lowercase value `disabled`. AWS CLI enum values are case-sensitive in this request.

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --maintenance-options "AutoRecovery=disabled" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=false" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 5 — Wait for Instance Readiness

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Inspect EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both status checks return `ok`.

---

## 8. Scenario A — Diagnose Disabled Simplified Recovery

### Step 1 — Inspect Recovery Setting

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Recovery:MaintenanceOptions.AutoRecovery}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Recovery: disabled
State: running
```

### Scenario A Finding

The instance is running but simplified automatic recovery is disabled.

This does not indicate that the host is currently unhealthy. It indicates that the intended simplified recovery protection is not enabled.

### Step 2 — Restore Simplified Recovery

```bash
aws ec2 modify-instance-maintenance-options \
  --instance-id "$INSTANCE_ID" \
  --auto-recovery default \
  --region "$AWS_REGION"
```

### Step 3 — Verify Remediation

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].MaintenanceOptions.AutoRecovery' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
default
```

**Scenario A expected result:** Simplified automatic recovery is configured to use its supported default behavior.

---

## 9. Inspect CloudWatch Status Metrics

### Step 1 — Set Metric Query Window

```bash
export START_TIME=$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
export END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

### Step 2 — Inspect System Status

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed_System \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 60 \
  --statistics Maximum \
  --output json \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Instance Status

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed_Instance \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 60 \
  --statistics Maximum \
  --output json \
  --region "$AWS_REGION"
```

### Metric Interpretation

| Value | Meaning |
|---|---|
| `0` | Status check passed |
| `1` | Status check failed |
| No datapoints | No available observations in selected window |

The instance should normally remain healthy during this lab.

---

## 10. Scenario B — Create a Misconfigured CloudWatch Alarm

### Step 1 — Check Existing Alarm

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

Do not overwrite an unrelated alarm.

### Step 2 — Create a Broken Alarm

We intentionally create an alarm without an EC2 recovery action.

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab14 simulated missing EC2 recovery action" \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed_System \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --threshold 0.5 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --no-actions-enabled \
  --tags "Key=Project,Value=$PROJECT_TAG" \
  --region "$AWS_REGION"
```

### Step 3 — Verify the Misconfiguration

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Name:AlarmName,Metric:MetricName,ActionsEnabled:ActionsEnabled,Actions:AlarmActions,State:StateValue}' \
  --output json \
  --region "$AWS_REGION"
```

Expected important fields:

```json
{
  "Metric": "StatusCheckFailed_System",
  "ActionsEnabled": false,
  "Actions": []
}
```

### Scenario B Finding

The CloudWatch alarm monitors the required system status metric but has no recovery action.

Additionally, alarm actions are disabled.

This alarm is not configured to initiate EC2 recovery.

---

## 11. Root Cause Analysis

### Root Cause A

Simplified automatic recovery was explicitly disabled.

### Root Cause B

The CloudWatch alarm had no configured EC2 recovery action, and its actions were disabled.

### Technical Explanation

CloudWatch alarms evaluate metrics and transition between alarm states.

A metric alarm does not automatically perform an EC2 recovery operation merely because it monitors an EC2 status check.

The recovery action must be explicitly configured, and alarm actions must be enabled for the recovery action to execute.

### Root Cause Flow

```text
EC2 System Status Failure
             |
             v
       CloudWatch Metric
             |
             v
         Alarm Evaluation
             |
             v
       Alarm State = ALARM
             |
       +-----+-----+
       |           |
       v           v
 Missing Action  Recover Action
       |           |
       X           v
 No Recovery     EC2 Recovery
 Initiation      Request
```

### Five Whys

1. **Why was automatic recovery protection incomplete?** Recovery configuration was disabled or missing.
2. **Why was simplified recovery unavailable?** The maintenance option was set to `disabled`.
3. **Why couldn't the CloudWatch alarm initiate recovery?** It had no recovery action configured.
4. **Why wasn't merely monitoring the metric sufficient?** Metric evaluation and recovery-action execution are separate features.
5. **How can this be prevented?** Manage recovery settings through infrastructure as code and validate alarm actions and configuration during deployment.

---

## 12. Remediate the CloudWatch Alarm

### Step 1 — Update the Recovery Alarm

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "Lab14 EC2 system status recovery alarm" \
  --namespace AWS/EC2 \
  --metric-name StatusCheckFailed_System \
  --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
  --statistic Maximum \
  --period 60 \
  --evaluation-periods 2 \
  --datapoints-to-alarm 2 \
  --threshold 0.5 \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data missing \
  --alarm-actions "$RECOVERY_ARN" \
  --no-actions-enabled \
  --region "$AWS_REGION"
```

The recovery action is now configured, but actions remain disabled for the controlled state-transition test.

### Step 2 — Verify Alarm Action

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Metric:MetricName,ActionsEnabled:ActionsEnabled,AlarmActions:AlarmActions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
{
  "Metric": "StatusCheckFailed_System",
  "ActionsEnabled": false,
  "AlarmActions": [
    "arn:aws:automate:us-east-1:ec2:recover"
  ]
}
```

---

## 13. Safely Test the CloudWatch Alarm

### Safety Requirement

Before simulating an alarm state change, confirm that CloudWatch alarm actions are disabled.

Forcing a recovery alarm into `ALARM` while actions are enabled may invoke the configured recovery action.

### Step 1 — Verify Actions Disabled

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[0].ActionsEnabled' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
False
```

**Do not proceed if this returns `True`.**

### Step 2 — Set Simulated ALARM State

```bash
aws cloudwatch set-alarm-state \
  --alarm-name "$ALARM_NAME" \
  --state-value ALARM \
  --state-reason "Lab14 controlled simulation with actions disabled" \
  --region "$AWS_REGION"
```

### Step 3 — Inspect Alarm State

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{State:StateValue,Reason:StateReason,ActionsEnabled:ActionsEnabled}' \
  --output table \
  --region "$AWS_REGION"
```

Expected shortly after setting the state:

```text
State: ALARM
ActionsEnabled: False
```

CloudWatch can return the alarm to `OK` when actual healthy metrics are reevaluated.

### Step 4 — Restore OK State

```bash
aws cloudwatch set-alarm-state \
  --alarm-name "$ALARM_NAME" \
  --state-value OK \
  --state-reason "Lab14 simulated alarm test completed" \
  --region "$AWS_REGION"
```

### Step 5 — Verify EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both checks remain `ok`.

### Test Limitations

This test demonstrates a CloudWatch alarm-state transition with actions disabled.

It does not validate the recover action's execution, an AWS system status failure, or the host migration process.

A real infrastructure recovery cannot be reliably reproduced through ordinary customer-facing EC2 APIs.

---

## 14. Enable the Recovery Action

### Step 1 — Verify the Alarm Configuration

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Metric:MetricName,Dimensions:Dimensions,Actions:AlarmActions,State:StateValue}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the alarm:

- Monitors `StatusCheckFailed_System`.
- References the intended Lab 14 instance ID.
- Has the correct EC2 recover action.
- Is not currently indicating a genuine infrastructure failure.

### Step 2 — Enable Actions

```bash
aws cloudwatch enable-alarm-actions \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 3 — Verify

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,ActionsEnabled:ActionsEnabled,Actions:AlarmActions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
ActionsEnabled: true
AlarmActions: arn:aws:automate:us-east-1:ec2:recover
```

**Warning:** Do not use `set-alarm-state` to force another ALARM transition after enabling actions.

---

## 15. Verify Both Recovery Mechanisms

### Simplified Recovery

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Instance:InstanceId,State:State.Name,Recovery:MaintenanceOptions.AutoRecovery}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
State: running
Recovery: default
```

### CloudWatch Recovery

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].{Metric:MetricName,State:StateValue,ActionsEnabled:ActionsEnabled,AlarmActions:AlarmActions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Metric: StatusCheckFailed_System
ActionsEnabled: true
Recovery ARN: arn:aws:automate:us-east-1:ec2:recover
```

### Before and After Comparison

| Component | Before Fix | After Fix |
|---|---|---|
| EC2 running | Yes | Yes |
| System status check | OK | OK |
| Simplified recovery | Disabled | Default |
| CloudWatch recovery metric | Correct | Correct |
| Alarm recovery action | Missing | Configured |
| Alarm actions | Disabled | Enabled |
| Actual host failure | Not simulated | Not simulated |
| Actual recovery migration | Not tested | Not tested |

### Success Criteria

The configuration portion of the incident is considered resolved when the simplified recovery setting is `default`, the CloudWatch alarm uses `StatusCheckFailed_System`, and its EC2 recovery action is configured and enabled.

---

## 16. Troubleshooting Real Recovery Failures

Correct recovery configuration does not guarantee that recovery will always succeed.

### Common Recovery Failure Causes

| Cause | Explanation | Recommended Investigation |
|---|---|---|
| Simplified recovery disabled | Recovery protection not enabled | Inspect maintenance options |
| Alarm missing action | CloudWatch cannot invoke recovery | Inspect AlarmActions |
| Alarm actions disabled | Configured actions do not run | Check ActionsEnabled |
| Wrong metric | Alarm monitors wrong failure type | Verify metric |
| Instance unsupported | Instance fails eligibility requirements | Check EC2 documentation |
| Insufficient capacity | No suitable replacement capacity | Inspect AWS Health |
| AWS service event | Recovery can be restricted | Review service events |
| Recovery limit reached | Allowed attempts exhausted | Review recovery history |

### AWS Health Events

Simplified recovery:

```text
AWS_EC2_SIMPLIFIED_AUTO_RECOVERY_SUCCESS
AWS_EC2_SIMPLIFIED_AUTO_RECOVERY_FAILURE
```

CloudWatch action-based recovery:

```text
AWS_EC2_INSTANCE_AUTO_RECOVERY_SUCCESS
AWS_EC2_INSTANCE_AUTO_RECOVERY_FAILURE
```

These events can provide evidence of actual recovery attempts and outcomes.

They are not expected in this lab because no real underlying host failure was introduced.

---

## 17. Production Engineering Best Practices

### Recovery Configuration

- Enable simplified automatic recovery for eligible workloads where appropriate.
- Configure CloudWatch recovery alarms when additional operational control is required.
- Use the correct system status metric.
- Verify recovery alarm actions after deployment.
- Review instance recovery eligibility.
- Monitor AWS Health events.
- Document application restart behavior.
- Understand that RAM data is lost during recovery.
- Do not rely solely on single-instance recovery for critical services.

### High Availability

Automatic recovery is useful, but it is not equivalent to Multi-AZ redundancy.

For production workloads requiring higher availability, consider:

- Multiple EC2 instances.
- Application Load Balancers.
- Auto Scaling groups.
- Multi-AZ architecture.
- Health-based replacement.
- Backups and tested disaster recovery.
- Infrastructure as code.

### Monitoring and Operations

- Use CloudWatch for status-check monitoring.
- Maintain alarm ownership and operational documentation.
- Review alarms and actions during change management.
- Monitor actual recovery success and failure events.
- Investigate persistent status check failures.
- Use AWS Health and AWS Support when needed.

---

## 18. Interview Questions and Answers

### Q1. What is EC2 automatic recovery?

It is an AWS capability designed to recover eligible EC2 instances from supported underlying infrastructure problems.

### Q2. What is simplified automatic recovery?

It is an AWS-managed recovery mechanism that operates for eligible instances when the required conditions are satisfied.

### Q3. What is CloudWatch action-based recovery?

It uses a CloudWatch alarm and an EC2 recovery action to initiate recovery when qualifying system status check failures occur.

### Q4. Which metric is used for CloudWatch recovery?

```text
StatusCheckFailed_System
```

### Q5. What is the difference between system and instance status checks?

System checks assess underlying AWS infrastructure. Instance checks detect failures affecting the guest instance.

### Q6. What is the EC2 recovery action ARN?

```text
arn:aws:automate:REGION:ec2:recover
```

### Q7. Can automatic recovery be tested end to end using AWS CLI?

No. Ordinary customer-facing APIs cannot reproduce an actual underlying EC2 system status check failure.

### Q8. What happens during successful EC2 recovery?

AWS attempts to restore the instance on suitable host infrastructure. The process involves a reboot, and in-memory data is lost.

### Q9. Why might automatic recovery fail?

Capacity constraints, ineligible configurations, AWS service events, and recovery-attempt limits are possible causes.

### Q10. Does automatic recovery replace Multi-AZ architecture?

No. Automatic recovery addresses eligible individual instance failures. Multi-AZ designs provide broader redundancy.

### Q11. How do you check simplified recovery configuration?

```bash
aws ec2 describe-instances \
  --instance-ids INSTANCE_ID \
  --query 'Reservations[0].Instances[0].MaintenanceOptions.AutoRecovery'
```

### Q12. How would you explain this lab in an interview?

> I investigated an EC2 recovery configuration issue involving two problems. First, simplified automatic recovery was disabled, so I restored its default behavior. Then I examined a CloudWatch alarm monitoring system status checks and found that it lacked the EC2 recover action. I corrected the alarm, safely tested its state transition with actions disabled, and enabled the recovery action after verifying instance health. I also reviewed recovery eligibility and AWS Health failure events. The exercise validated the recovery configuration without causing an actual infrastructure outage.

---

## 19. Cleanup

**Warning:** Verify the AWS account, instance tags, and CloudWatch alarm ownership before deleting resources.

### Step 1 — Verify Account

```bash
aws sts get-caller-identity
```

### Step 2 — Verify Instance Ownership

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{ID:InstanceId,State:State.Name,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm:

```text
Project: EC2-Troubleshooting-Lab14
```

### Step 3 — Verify Alarm Tag

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity \
  --query Account --output text)

aws cloudwatch list-tags-for-resource \
  --resource-arn "arn:aws:cloudwatch:${AWS_REGION}:${ACCOUNT_ID}:alarm:${ALARM_NAME}" \
  --region "$AWS_REGION"
```

Confirm the alarm belongs exclusively to Lab 14.

### Step 4 — Disable CloudWatch Alarm Actions

```bash
aws cloudwatch disable-alarm-actions \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

### Step 5 — Delete the Alarm

```bash
aws cloudwatch delete-alarms \
  --alarm-names "$ALARM_NAME" \
  --region "$AWS_REGION"
```

Verify deletion:

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$ALARM_NAME" \
  --query 'MetricAlarms[].AlarmName' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Step 6 — Record Root EBS Volume

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

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Check Security Group Dependencies

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=group-id,Values=$SG_ID" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' \
  --output text \
  --region "$AWS_REGION"
```

When no dependencies remain:

```bash
aws ec2 delete-security-group \
  --group-id "$SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify EBS Cleanup

```bash
aws ec2 describe-volumes \
  --volume-ids "$ROOT_VOLUME_ID" \
  --region "$AWS_REGION"
```

Expected after deletion:

```text
InvalidVolume.NotFound
```

If a lab-owned volume remains, confirm its ownership and attachment status before deleting it.

### Cleanup Summary

| Resource | Expected Action |
|---|---|
| CloudWatch alarm | Deleted |
| EC2 instance | Terminated |
| Root EBS volume | Deleted |
| Dedicated security group | Deleted |
| Default VPC | Preserved |
| Default subnet | Preserved |
| Shared infrastructure | Unchanged |

---

## 20. Repository Structure

```text
14-instance-auto-recovery-failure/
│
└── README.md
```

No application code or EC2 guest access is required.

All investigation, remediation, and verification commands are performed using AWS CLI.

Do not commit AWS credentials, confidential resource information, or private keys.

---

## 21. Lessons Learned

This lab demonstrated how an EC2 instance can be healthy while its recovery configuration is incomplete.

The first misconfiguration involved simplified automatic recovery being disabled.

The second involved a CloudWatch alarm that monitored the correct system status metric but did not have an EC2 recovery action.

The remediation restored simplified recovery to its default behavior and configured the CloudWatch alarm with the correct recovery action.

The exercise also demonstrated the importance of testing alarm behavior safely without invoking recovery against a healthy instance.

Finally, it emphasized that properly configured recovery mechanisms do not eliminate the need for Multi-AZ availability, monitoring, and operational recovery planning.

---

## 22. Skills Demonstrated

- Amazon EC2 recovery configuration
- Simplified automatic recovery
- CloudWatch action-based recovery
- EC2 system status checks
- CloudWatch metrics
- CloudWatch metric alarms
- EC2 recovery action ARN configuration
- AWS CLI v2
- Alarm state testing
- AWS Health event investigation
- Root cause analysis
- Recovery planning
- Operational safety
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-EC2-014 |
| Problem | Automatic recovery protection misconfigured |
| Root Cause A | Simplified recovery disabled |
| Root Cause B | Missing CloudWatch recovery action |
| Simplified Recovery After Fix | `default` |
| Recovery Metric | `StatusCheckFailed_System` |
| Recovery Alarm Action | Configured |
| Alarm Actions After Fix | Enabled |
| EC2 System Status | Healthy |
| Actual Infrastructure Failure | Not simulated |
| Actual Host Migration | Not tested |
| Cleanup | Lab resources removed |
| Expected Configuration Status | Resolved |

**Key Takeaway:** EC2 automatic recovery depends on instance eligibility and correctly configured recovery mechanisms. Monitor the correct system status metric, validate recovery actions, and remember that configuration verification cannot guarantee success during a real infrastructure failure.

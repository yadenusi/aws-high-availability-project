# Troubleshooting

Start with the logs. Every instance ships its bootstrap, nginx and app logs to CloudWatch Logs under `/ecommerce-ha-dev/web/`, so you rarely need to log in. When you do, use Session Manager:

```bash
aws ssm start-session --target <instance-id>
sudo tail -n 100 /var/log/storefront-bootstrap.log
sudo journalctl -u storefront -n 100 --no-pager
sudo /opt/storefront/venv/bin/python /opt/storefront/manage.py check
```

## Issues named in the brief

### 1. Instances fail to register with the ALB, or stay unhealthy

| Check | How |
|---|---|
| Did the bootstrap finish? | Log group `/ecommerce-ha-dev/web/user-data`: look for `[bootstrap] complete`. A failed `dnf` or `pip` step usually means no outbound route: check the NAT gateway and the app route table |
| Is the app listening? | `curl -s localhost/health` on the instance should return `{"status":"ok"...}` |
| Security groups | The app SG must allow port 80 from the ALB SG (`aws_vpc_security_group_ingress_rule.app_from_alb`) |
| Correct subnets | The ASG uses the **app** subnets; the ALB uses the **public** subnets |
| Health check settings | Path `/health`, matcher `200`. The target group's *Targets* tab shows the reason code (for example `Target.Timeout` or `Target.ResponseCodeMismatch`) |
| Grace period | New instances need about 2 to 3 minutes. The ASG waits 300 seconds before acting on ELB health |

### 2. Auto Scaling does not scale as expected

| Check | How |
|---|---|
| Policies exist | `aws autoscaling describe-policies --auto-scaling-group-name <asg>` should show both target tracking policies |
| Alarms created by the policies | CloudWatch *Alarms*: search for `TargetTracking-<asg>`. They are managed by Auto Scaling; do not edit them |
| Metrics arriving | EC2 CPU for the ASG dimension needs detailed monitoring (enabled in the launch template). `RequestCountPerTarget` needs traffic through the ALB |
| At max already | Desired capacity equals `asg_max_size`? Raise it in tfvars |
| Cooldown and warmup | Scale in is deliberately slow (about 15 minutes) to avoid flapping |
| Load test not reaching the origin | `/api/products` is cached at the edge; the CPU is driven by `/api/load` and the home page |

### 3. Database failover takes longer than expected

| Check | How |
|---|---|
| Multi-AZ enabled | `aws rds describe-db-instances --db-instance-identifier <primary> --query 'DBInstances[0].MultiAZ'` returns `true` |
| DNS caching | The app reconnects per request and resolves the writer endpoint each time. Long lived connection pools must respect the 5 second TTL |
| Timeouts | PyMySQL uses a 3 second connect timeout, so the app reports 503 quickly instead of hanging |
| Pending maintenance | Failover during a maintenance action can take longer. Check the RDS *Maintenance and backups* tab |
| Expectations | 60 to 120 seconds is normal for RDS MySQL Multi-AZ instances. Aurora or RDS Proxy is the answer if that is too slow |

## Other issues

| Symptom | Cause and fix |
|---|---|
| `terraform init` fails with an access denied error on the state bucket | Run the `bootstrap/` stack first and use `-backend-config=backend.hcl`. Check your AWS profile |
| `terraform apply` fails creating the ALB with `Access Denied for bucket` | The ALB checks log bucket permissions at creation. Re-run apply; the bucket policy is applied first through `depends_on` |
| Secret already scheduled for deletion | You redeployed within the recovery window. Keep `secret_recovery_window_days = 0` for the lab, or run `aws secretsmanager delete-secret --secret-id <name> --force-delete-without-recovery` |
| SNS emails never arrive | Confirm both subscription emails (one for us-east-2 and one for us-east-1). Check spam |
| CloudFront returns the maintenance page | The origin returned 502, 503 or 504. Check target health and the `alb-elb-5xx` alarm |
| CloudFront still serves old static files | `aws cloudfront create-invalidation --distribution-id <id> --paths '/static/*'` |
| Redis errors in the app log after a secret change | Changing the AUTH token needs a rolling restart: start an instance refresh on the ASG |
| `terraform destroy` hangs on the replica or the primary | RDS deletes take 5 to 10 minutes each. If deletion protection was turned on, set it to false and apply first |

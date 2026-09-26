# Test Plan and Results

Each test states what it proves, how to run it, what should happen, and what evidence to keep. Save everything in `evidence/` (screenshots as PNG, command output as text or JSON). Record the actual results in the tables at the end.

Before starting: the stack has been applied, both SNS subscription emails are confirmed, and `./scripts/verify.sh` passes.

---

## T1. Functional baseline

**Proves:** the whole request path works: CloudFront, ALB, EC2, Redis, the replica, the primary and S3.

**Run**
```bash
./scripts/verify.sh | tee evidence/t1-verify.txt
```
Then open the `storefront_url` output in a browser. Refresh several times and place two orders.

**Expected**
- Every verify check passes.
- The header pills change between instances and AZs as you refresh.
- The catalog source shows `replica` on the first load and `cache` after that.
- Orders appear in *Recent orders*, labelled with the instance and AZ that wrote them.
- `curl -I http://<alb_dns_name>/` returns 403.

**Evidence:** `t1-verify.txt`; screenshots of the storefront from two different AZs; the direct ALB 403.

---

## T2. Load and Auto Scaling

**Proves:** the platform absorbs a traffic spike by scaling out, and scales back in afterwards.

**Run**
```bash
# Terminal 1
./scripts/load-test/run-jmeter.sh                 # 200 users, 5 min ramp, 20 min total
# Terminal 2 (optional): watch capacity
watch -n 15 "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $(terraform output -raw asg_name) \
  --query 'AutoScalingGroups[0].[DesiredCapacity,length(Instances)]' --output text"
```

**Expected**
- Web tier CPU climbs above the 50% target, and desired capacity rises from 2 toward 6 within about 5 minutes.
- New instances pass health checks and start taking traffic. Error rate stays under 1%.
- The SNS email shows `EC2 Instance Launch Successful` events.
- About 15 minutes after the test ends, the group scales back to 2.

**Evidence:** the JMeter HTML report (`scripts/load-test/results/<run>/report/index.html`) with screenshots of the summary and response time graphs; dashboard screenshots during the peak; the ASG *Activity* tab; the launch notification emails.

---

## T3. Loss of an Availability Zone (web tier)

**Proves:** the store keeps serving when every instance in one AZ disappears, and capacity self-heals.

**Run**
```bash
# Terminal 1
./scripts/watch-availability.sh
# Terminal 2
./scripts/chaos/run-fis.sh az
```
Stop the watcher with Ctrl+C about 5 minutes after the experiment completes.

**Expected**
- Requests keep succeeding, served from the other AZ. At most a handful of failed requests while the ALB drains the terminated targets.
- The `alb-unhealthy-hosts` alarm may fire, then return to OK.
- The ASG launches replacements (spread back across both AZs) within about 5 minutes.

**Evidence:** the watcher CSV and its summary; the FIS JSON from `evidence/`; the ASG activity table printed by the script; the dashboard's healthy host graph.

---

## T4. Database failover (RDS Multi-AZ)

**Proves:** writes recover automatically after the primary fails, and reads stay available throughout.

**Run**
```bash
# Terminal 1
./scripts/watch-availability.sh
# Terminal 2
./scripts/chaos/run-fis.sh rds
```

**Expected**
- Writes (`POST /api/orders`) return 503 for about 60 to 120 seconds, then recover without any intervention.
- Reads (`/api/catalog`) keep returning 200, served from Redis or the replica.
- RDS events show `Multi-AZ instance failover started` and `completed`, and an SNS email arrives.
- `aws rds describe-db-instances` shows the primary is now in the other AZ.

**Evidence:** the watcher CSV (compute write downtime as last failure minus first failure); the RDS events table; the failover email; before and after screenshots of the primary's AZ.

---

## T5. Cache failover (ElastiCache)

**Proves:** a cache node failure does not take the store down; the app degrades gracefully to the database.

**Run**
```bash
# Terminal 1
./scripts/watch-availability.sh
# Terminal 2
./scripts/chaos/redis-failover.sh
```

**Expected**
- Reads stay at 200. The `source` column switches from `cache` to `replica` for a short window, then returns to `cache`.
- The node roles printed after the test show the former replica is now the primary.

**Evidence:** the watcher CSV; the role before and after output saved in `evidence/`; the ElastiCache events table.

---

## T6. Security checks

| Check | Command | Expected |
|---|---|---|
| ALB cannot be reached directly | `curl -s -o /dev/null -w '%{http_code}\n' http://$(terraform output -raw alb_dns_name)/` | `403` |
| Header forgery is blocked | `curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Origin-Verify: guess' http://$(terraform output -raw alb_dns_name)/` | `403` |
| Instances have no public IP | `aws ec2 describe-instances --filters Name=tag:aws:autoscaling:groupName,Values=$(terraform output -raw asg_name) --query 'Reservations[].Instances[].PublicIpAddress'` | empty list |
| IMDSv2 is enforced | same command, query `Instances[].MetadataOptions.HttpTokens` | all `required` |
| Database is private | `aws rds describe-db-instances --query 'DBInstances[].PubliclyAccessible'` | all `false` |
| Shell access without SSH | `aws ssm start-session --target <instance-id>` | a session opens; no key pair exists |
| Security headers | `curl -sI $(terraform output -raw storefront_url) \| grep -i -E 'strict-transport\|x-frame\|x-content-type'` | all three present |

---

## Results (fill in after each run)

| Test | Date | Result | Key numbers | Evidence files |
|---|---|---|---|---|
| T1 Functional | | | | |
| T2 Load and scaling | | | Peak users: , Peak instances: , p95 latency: , Error %: | |
| T3 AZ loss | | | Failed requests: , Time to full capacity: | |
| T4 RDS failover | | | Write downtime (s): , Read failures: | |
| T5 Redis failover | | | Read failures: , Failover duration (s): | |
| T6 Security | | | | |

### Observations and lessons learned

_Write what surprised you, what you tuned, and what you would change for production._

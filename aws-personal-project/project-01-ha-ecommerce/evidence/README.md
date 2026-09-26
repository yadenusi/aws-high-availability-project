# Evidence

Screenshots and command output that prove each test in [../docs/testing.md](../docs/testing.md). Scripts write their CSV and JSON files here automatically.

Suggested file names:

| Test | Files |
|---|---|
| T1 | `t1-verify.txt`, `t1-storefront-az-a.png`, `t1-storefront-az-b.png`, `t1-alb-direct-403.png` |
| T2 | `jmeter-statistics-*.json`, `t2-jmeter-summary.png`, `t2-dashboard-peak.png`, `t2-asg-activity.png`, `t2-scaling-email.png` |
| T3 | `availability-*.csv`, `fis-az_web_tier_loss-*.json`, `t3-healthy-hosts.png` |
| T4 | `availability-*.csv`, `fis-rds_force_failover-*.json`, `t4-rds-events.png`, `t4-failover-email.png` |
| T5 | `availability-*.csv`, `redis-failover-*.txt`, `t5-elasticache-events.png` |
| T6 | `t6-security-checks.txt` |

Before committing, check that no screenshot shows secrets, access keys or your full account ID.

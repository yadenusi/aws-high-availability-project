#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Post-deployment verification. Run from the project folder after apply:
#   ./scripts/verify.sh
# Prints PASS / FAIL per check and exits non-zero if anything failed.
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

out() { terraform output -raw "$1"; }

URL=$(out storefront_url)
ALB=$(out alb_dns_name)
ASG=$(out asg_name)
TG=$(out target_group_arn)
REGION=$(out aws_region)
PRIMARY=$(terraform output -json db_instance_ids | jq -r .primary)
REPLICA=$(terraform output -json db_instance_ids | jq -r .replica)
REDIS=$(out redis_replication_group_id)

echo "Storefront: $URL"
echo "Region:     $REGION"

section "Edge and load balancer"
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/")
[[ "$code" == "200" ]] && pass "CloudFront home page returns 200" || fail "CloudFront home page returned $code"

code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/static/styles.css")
[[ "$code" == "200" ]] && pass "Static asset served from S3 through CloudFront" || fail "Static asset returned $code"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://$ALB/")
[[ "$code" == "403" || "$code" == "000" ]] \
  && pass "Direct ALB access is blocked (got $code)" \
  || fail "Direct ALB access returned $code (expected 403 or a timeout)"

azs=$(for _ in $(seq 1 20); do curl -s "$URL/api/info" | jq -r .az; done | sort -u | tr '\n' ' ')
count=$(wc -w <<<"$azs")
[[ "$count" -ge 2 ]] && pass "Requests served from multiple AZs: $azs" || fail "Requests served from only: $azs"

section "Web tier"
healthy=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG" \
  --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
[[ "$healthy" -ge 2 ]] && pass "$healthy healthy targets" || fail "Only $healthy healthy targets"

inst_azs=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l)
[[ "$inst_azs" -ge 2 ]] && pass "ASG instances span $inst_azs AZs" || fail "ASG instances span only $inst_azs AZ"

section "Database"
multi_az=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$PRIMARY" \
  --query 'DBInstances[0].MultiAZ' --output text)
[[ "$multi_az" == "True" ]] && pass "Primary is Multi-AZ" || fail "Primary Multi-AZ is $multi_az"

replica_src=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$REPLICA" \
  --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text)
[[ "$replica_src" == "$PRIMARY" ]] && pass "Read replica is replicating from the primary" || fail "Replica source is $replica_src"

encrypted=$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$PRIMARY" \
  --query 'DBInstances[0].StorageEncrypted' --output text)
[[ "$encrypted" == "True" ]] && pass "Database storage is encrypted" || fail "Database storage encryption is $encrypted"

section "Cache"
read -r failover multiaz transit <<<"$(aws elasticache describe-replication-groups --region "$REGION" \
  --replication-group-id "$REDIS" \
  --query 'ReplicationGroups[0].[AutomaticFailover,MultiAZ,TransitEncryptionEnabled]' --output text)"
[[ "$failover" == "enabled" ]] && pass "Redis automatic failover enabled" || fail "Redis automatic failover is $failover"
[[ "$multiaz" == "enabled" ]] && pass "Redis Multi-AZ enabled" || fail "Redis Multi-AZ is $multiaz"
[[ "$transit" == "True" ]] && pass "Redis encryption in transit enabled" || fail "Redis transit encryption is $transit"

section "Application read and write paths"
body=$(curl -s -X POST "$URL/api/orders" -H 'Content-Type: application/json' -d '{"product_id":1,"quantity":1}')
order_id=$(jq -r '.order_id // empty' <<<"$body")
[[ -n "$order_id" ]] && pass "Order $order_id written to the primary" || fail "Order write failed: $body"

found=$(curl -s "$URL/api/orders" | jq --argjson id "${order_id:-0}" '[.orders[].id] | index($id) != null')
[[ "$found" == "true" ]] && pass "Order $order_id read back" || fail "Order $order_id not found in recent orders"

sources=$(for _ in $(seq 1 6); do curl -s "$URL/" | grep -o 'source-[a-z]*' | head -1; done | sort -u | tr '\n' ' ')
[[ "$sources" == *"source-cache"* ]] && pass "Catalog served from Redis cache ($sources)" || fail "Catalog never came from cache ($sources)"

section "Summary"
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]

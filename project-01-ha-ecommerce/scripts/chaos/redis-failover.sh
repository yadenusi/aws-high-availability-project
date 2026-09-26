#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Trigger an ElastiCache primary failover with the TestFailover API and follow
# the replication group until a replica has been promoted.
#
#   ./scripts/chaos/redis-failover.sh
#
# The app should keep serving the catalog from the replica or primary database
# while the cache is failing over, then return to cache hits.
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p evidence

REGION=$(terraform output -raw aws_region)
GROUP=$(terraform output -raw redis_replication_group_id)

roles() {
  aws elasticache describe-replication-groups --region "$REGION" --replication-group-id "$GROUP" \
    --query 'ReplicationGroups[0].NodeGroups[0].NodeGroupMembers[].[CacheClusterId,CurrentRole,PreferredAvailabilityZone]' \
    --output text
}

echo "Current node roles:"
roles

read -r -p "Type 'yes' to fail over the Redis primary: " answer
[[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 0; }

aws elasticache test-failover --region "$REGION" --replication-group-id "$GROUP" --node-group-id 0001 \
  --query 'ReplicationGroup.Status' --output text
echo "Failover requested at $(date -u +%H:%M:%SZ)"

while true; do
  status=$(aws elasticache describe-replication-groups --region "$REGION" --replication-group-id "$GROUP" \
    --query 'ReplicationGroups[0].Status' --output text)
  printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$status"
  [[ "$status" == "available" ]] && break
  sleep 10
done

echo "Node roles after failover:"
roles | tee "evidence/redis-failover-$(date -u +%Y%m%dT%H%M%SZ).txt"

echo
echo "ElastiCache events (last 30 minutes):"
aws elasticache describe-events --region "$REGION" --source-type replication-group --source-identifier "$GROUP" \
  --duration 30 --query 'Events[].[Date,Message]' --output table

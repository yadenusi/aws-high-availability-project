#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Start an AWS FIS experiment and follow it to completion.
#
#   ./scripts/chaos/run-fis.sh az        # terminate the web tier in one AZ
#   ./scripts/chaos/run-fis.sh rds       # force an RDS Multi-AZ failover
#
# Start ./scripts/watch-availability.sh in another terminal first.
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p evidence

case "${1:-}" in
  az)  key="az_web_tier_loss" ;;
  rds) key="rds_force_failover" ;;
  *)   echo "usage: $0 az|rds"; exit 2 ;;
esac

REGION=$(terraform output -raw aws_region)
TEMPLATE=$(terraform output -json fis_experiment_template_ids | jq -r --arg k "$key" '.[$k] // empty')
[[ -n "$TEMPLATE" ]] || { echo "No FIS template '$key'. Is enable_fis = true?"; exit 1; }

echo "About to run FIS experiment '$key' (template $TEMPLATE) in $REGION."
read -r -p "Type 'yes' to inject the failure: " answer
[[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 0; }

EXP=$(aws fis start-experiment --region "$REGION" --experiment-template-id "$TEMPLATE" \
  --tags Name="capstone-p01-$key" --query 'experiment.id' --output text)
echo "Experiment $EXP started at $(date -u +%H:%M:%SZ)"

while true; do
  state=$(aws fis get-experiment --region "$REGION" --id "$EXP" --query 'experiment.state.status' --output text)
  printf '%s  %s\n' "$(date -u +%H:%M:%SZ)" "$state"
  case "$state" in
    completed|stopped|failed) break ;;
  esac
  sleep 5
done

aws fis get-experiment --region "$REGION" --id "$EXP" \
  --query 'experiment.{state:state,started:startTime,ended:endTime,actions:actions}' --output json \
  | tee "evidence/fis-$key-$EXP.json"

if [[ "$key" == "rds_force_failover" ]]; then
  primary=$(terraform output -json db_instance_ids | jq -r .primary)
  echo
  echo "Recent RDS events for $primary:"
  aws rds describe-events --region "$REGION" --source-type db-instance --source-identifier "$primary" \
    --duration 30 --query 'Events[].[Date,Message]' --output table
fi

if [[ "$key" == "az_web_tier_loss" ]]; then
  asg=$(terraform output -raw asg_name)
  echo
  echo "Auto Scaling activity (replacement instances):"
  aws autoscaling describe-scaling-activities --region "$REGION" --auto-scaling-group-name "$asg" \
    --max-items 8 --query 'Activities[].[StartTime,StatusCode,Description]' --output table
fi

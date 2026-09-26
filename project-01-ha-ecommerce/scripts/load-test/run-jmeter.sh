#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Run the storefront load test in JMeter non-GUI mode and build the HTML report.
#
#   ./scripts/load-test/run-jmeter.sh                       # 200 users, 20 minutes
#   THREADS=50 DURATION=300 ./scripts/load-test/run-jmeter.sh   # quick smoke run
#
# Watch the CloudWatch dashboard and the ASG while it runs. Scale out usually
# starts 3 to 5 minutes into the ramp.
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v jmeter >/dev/null || { echo "jmeter not found on PATH (see docs/workstation-setup.md)"; exit 1; }

HOST=$(terraform output -raw storefront_url | sed 's#^https://##')
THREADS="${THREADS:-200}"
RAMPUP="${RAMPUP:-300}"
DURATION="${DURATION:-1200}"
BURN_MS="${BURN_MS:-300}"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RESULTS="scripts/load-test/results/$STAMP"
mkdir -p "$RESULTS" evidence

echo "Target:   https://$HOST"
echo "Users:    $THREADS (ramp $RAMPUP s), duration $DURATION s, CPU work $BURN_MS ms per load request"
echo "Results:  $RESULTS"

jmeter -n \
  -t scripts/load-test/storefront.jmx \
  -Jhost="$HOST" -Jthreads="$THREADS" -Jrampup="$RAMPUP" -Jduration="$DURATION" -Jburn_ms="$BURN_MS" \
  -l "$RESULTS/results.jtl" \
  -j "$RESULTS/jmeter.log" \
  -e -o "$RESULTS/report"

# Keep a copy of the summary with the evidence.
cp "$RESULTS/report/statistics.json" "evidence/jmeter-statistics-$STAMP.json"
echo
echo "HTML report: $RESULTS/report/index.html"
echo "Summary saved to evidence/jmeter-statistics-$STAMP.json"

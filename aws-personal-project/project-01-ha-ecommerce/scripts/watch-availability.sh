#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Measures availability during a failure test. Sends one read and one write per
# interval, logs every result to a CSV, and prints a summary on Ctrl+C.
#
#   ./scripts/watch-availability.sh                 # 1 second interval
#   INTERVAL=0.5 ./scripts/watch-availability.sh
#
# Run it in one terminal, start the FIS experiment in another.
# -----------------------------------------------------------------------------
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

URL=$(terraform output -raw storefront_url)
INTERVAL="${INTERVAL:-1}"
OUT_DIR="evidence"
mkdir -p "$OUT_DIR"
CSV="$OUT_DIR/availability-$(date -u +%Y%m%dT%H%M%SZ).csv"

echo "timestamp_utc,check,http_code,latency_ms,instance,az,detail" > "$CSV"
echo "Watching $URL every ${INTERVAL}s. Results: $CSV. Press Ctrl+C to stop."

reads_ok=0; reads_bad=0; writes_ok=0; writes_bad=0
first_bad=""; last_bad=""

summary() {
  echo
  echo "Reads : $reads_ok ok, $reads_bad failed"
  echo "Writes: $writes_ok ok, $writes_bad failed"
  if [[ -n "$first_bad" ]]; then
    echo "First failure: $first_bad"
    echo "Last failure : $last_bad"
  else
    echo "No failures observed."
  fi
  echo "CSV: $CSV"
  exit 0
}
trap summary INT TERM

probe() {
  local check="$1" method="$2" path="$3" data="${4:-}"
  local ts resp code ms body instance az detail
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  if [[ "$method" == "POST" ]]; then
    resp=$(curl -s -m 5 -X POST -H 'Content-Type: application/json' -d "$data" \
      -w '\n%{http_code} %{time_total}' "$URL$path")
  else
    resp=$(curl -s -m 5 -H 'Cache-Control: no-cache' -w '\n%{http_code} %{time_total}' "$URL$path")
  fi
  body=$(sed '$d' <<<"$resp")
  read -r code secs <<<"$(tail -1 <<<"$resp")"
  ms=$(awk -v s="${secs:-0}" 'BEGIN { printf "%d", s * 1000 }')
  instance=$(jq -r '.instance // "-"' <<<"$body" 2>/dev/null || echo "-")
  az=$(jq -r '.az // "-"' <<<"$body" 2>/dev/null || echo "-")
  detail=$(jq -r '.source // .order_id // .error // ""' <<<"$body" 2>/dev/null | tr ',' ';')
  echo "$ts,$check,$code,$ms,$instance,$az,$detail" >> "$CSV"
  printf '%s %-5s %s %5sms %-20s %-12s %s\n' "$ts" "$check" "$code" "$ms" "$instance" "$az" "$detail"

  if [[ "$code" =~ ^2 ]]; then
    [[ "$check" == "read" ]] && reads_ok=$((reads_ok + 1)) || writes_ok=$((writes_ok + 1))
  else
    [[ "$check" == "read" ]] && reads_bad=$((reads_bad + 1)) || writes_bad=$((writes_bad + 1))
    [[ -z "$first_bad" ]] && first_bad="$ts ($check $code)"
    last_bad="$ts ($check $code)"
  fi
}

while true; do
  # /api/catalog is never cached by CloudFront, so every read reaches an
  # instance and goes through Redis, the replica or the primary.
  probe read GET /api/catalog
  product=$(( (RANDOM % 8) + 1 ))
  probe write POST /api/orders "{\"product_id\":$product,\"quantity\":1}"
  sleep "$INTERVAL"
done

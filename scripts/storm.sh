#!/usr/bin/env bash
# Holdfast's k6 storm, unchanged, against one node of ours and the in-memory
# payments adapter, then the invariants over the auction's log (spec §10). It is a
# correctness run, not a benchmark and not a comparison.
#
#   VUS=30 BIDS_PER_VU=10 ENDS_IN=20 scripts/storm.sh
#
# Needs Postgres (docker compose up -d), Docker, and scripts/fetch-page.sh run once.
set -euo pipefail
cd "$(dirname "$0")/.."

# k6 2.4.0
K6_IMAGE="grafana/k6@sha256:d41bb79cd8de5a7ad619b53570e3712633e8bff0937010a5c6c57a4747e7a276"
VUS="${VUS:-30}"
BIDS_PER_VU="${BIDS_PER_VU:-10}"
ENDS_IN="${ENDS_IN:-20}"
RUN="${RUN:-$(date +%Y%m%d-%H%M%S)}"
export PORT="${PORT:-3000}"
# Every bidder signs in from one address, and bids faster than a person (spec §9).
export BID_RATE_LIMIT="${BID_RATE_LIMIT:-100000}"
export AUTH_RATE_LIMIT="${AUTH_RATE_LIMIT:-100000}"
STORM=vendor/holdfast/load/storm.ts
OUT=tmp/storm

[ -f "$STORM" ] || { echo "run scripts/fetch-page.sh first" >&2; exit 1; }
if curl -s -o /dev/null "http://localhost:$PORT/api/config"; then
  echo "something is already listening on port $PORT" >&2
  exit 1
fi

# The script writes its summary to /load/results, so it runs from a copy.
mkdir -p "$OUT/results"
cp "$STORM" "$OUT/storm.ts"

mix do compile + ecto.create --quiet + ecto.migrate --quiet
mix run --no-halt > "$OUT/$RUN.node.log" 2>&1 &
node_pid=$!
trap 'kill "$node_pid" 2>/dev/null; wait "$node_pid" 2>/dev/null || true' EXIT
for _ in $(seq 100); do
  curl -s -o /dev/null "http://localhost:$PORT/api/config" && break
  sleep 0.2
done

auction=$(mix holdfast.seed --ends-in "$ENDS_IN" --title "Load storm $RUN" | tail -1)
echo "auction $auction: $VUS bidders x $BIDS_PER_VU bids, ends in ${ENDS_IN}s"
echo "payments: in-memory, no added latency or faults"

status=0
docker run --rm --add-host=host.docker.internal:host-gateway --user "$(id -u):$(id -g)" \
  -v "$PWD/$OUT:/load" \
  -e BASE="http://host.docker.internal:$PORT" -e ORIGIN="http://localhost:$PORT" \
  -e AUCTION_ID="$auction" -e VUS="$VUS" -e BIDS_PER_VU="$BIDS_PER_VU" -e ENDS_IN="$ENDS_IN" \
  -e RUN="$RUN" \
  "$K6_IMAGE" run --quiet /load/storm.ts || status=$?

mix holdfast.check "$auction" --wait 150 || status=$?

echo "results: $OUT/$RUN.*"
exit "$status"

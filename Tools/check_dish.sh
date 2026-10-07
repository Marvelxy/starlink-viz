#!/bin/bash
# Verify dish reachability + grpcurl bridge before switching the app to Real mode.
# Usage: ./Tools/check_dish.sh [host]  (default 192.168.100.1)
set -euo pipefail
HOST="${1:-192.168.100.1}"
PROTOSET="$(cd "$(dirname "$0")/.." && pwd)/Proto/dish.protoset"
ADDR="$HOST:9200"

command -v grpcurl >/dev/null || { echo "Install first: brew install grpcurl"; exit 1; }
test -f "$PROTOSET" || { echo "Missing $PROTOSET"; exit 1; }
echo "== ping $HOST =="
ping -c2 -t2 "$HOST" | tail -2
echo "== getStatus =="
grpcurl -plaintext -emit-defaults -protoset "$PROTOSET" -format json -d '{"getStatus":{}}' \
  "$ADDR" SpaceX.API.Device.Device/Handle | head -c 1200; echo
echo "== getHistory (summary) =="
grpcurl -plaintext -emit-defaults -protoset "$PROTOSET" -format json -d '{"getHistory":{}}' \
  "$ADDR" SpaceX.API.Device.Device/Handle \
  | python3 -c "import json,sys; h=json.load(sys.stdin)['dishGetHistory']; print({k:(len(v) if isinstance(v,list) else v) for k,v in h.items()})"
echo OK

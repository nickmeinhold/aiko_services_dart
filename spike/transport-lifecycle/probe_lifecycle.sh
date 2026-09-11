#!/usr/bin/env bash
# Revision 4's must-fail arms against a broker that really dies.
#
# Its OWN broker, deliberately. The island's mosquitto has aiko-registrar-1 and
# aiko-chat-1 depending on it, and an arm here has to kill the broker outright —
# so this stands up an isolated one on a spare port rather than taking the
# island down to measure our own client. The instrument must not damage the
# thing it shares a room with.
set -euo pipefail
cd "$(dirname "$0")/../.."
source spike/probe_support.sh

CONTAINER=aiko-probe-mosquitto
PORT=${AIKO_PROBE_PORT:-1885}

probe_require_tools

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
# The config is written INSIDE the container. A host bind-mount of a generated
# file is not reachable from Docker Desktop's VM unless the path happens to be
# shared, and "Unable to open config file" is a rig failure wearing a protocol
# failure's clothes.
docker run -d --name "$CONTAINER" -p "127.0.0.1:$PORT:1883" \
  --entrypoint sh eclipse-mosquitto:2 \
  -c 'printf "listener 1883\nallow_anonymous true\n" > /tmp/m.conf && exec mosquitto -c /tmp/m.conf' \
  >/dev/null

# WAIT for it to accept, do not assume the run command returning means listening.
# A container id on stdout is a fact about docker, not about mosquitto: the first
# attempt reported "no broker" against a broker that was two seconds from ready,
# and a rig failure that reads as an outage is the worst kind of green.
for _ in $(seq 1 20); do
  mosquitto_pub -h 127.0.0.1 -p "$PORT" -t 'aiko/probe/_ready' -m x 2>/dev/null && break
  sleep 0.5
done

probe_require_broker 127.0.0.1 "$PORT"

out=$(mktemp)
rc=$(AIKO_PROBE_PORT="$PORT" probe_run_bounded 180 "$out" \
  dart run spike/transport-lifecycle/probe_lifecycle.dart)
cat "$out"
rm -f "$out"

if [ "$rc" = "75" ]; then
  echo "WATCHDOG: the probe stalled. That is a HARNESS fact, not a protocol one." >&2
  exit 75
fi
exit "$rc"

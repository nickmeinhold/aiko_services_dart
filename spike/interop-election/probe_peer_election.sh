#!/usr/bin/env bash
#
# THE OTHER HALF OF INTEROP: a real PYTHON registrar reading a DART registrar.
#
# tool/verify.sh has said for a while that "interop is now HALF covered, and the
# halves are not symmetric". spike/election/probe_election.sh covers the easy
# direction — a Dart process reading the live island's Python primary. Its arms
# that PROMOTE deliberately run in a throwaway namespace so they never touch the
# island's boot topic, which means **no Python process has ever read a message a
# Dart registrar wrote.**
#
# Every face in docs/notes/boot-topic-lifecycle.md is a claim about what a PEER
# does when it reads our writes, and the evidence column says "code-reading" for
# most of them for exactly this reason. This probe turns three of them into
# measurements.
#
# SAFE BY CONSTRUCTION. Both sides run in a throwaway namespace on the island's
# broker, so `aiko/service/registrar` is never touched. The Python side is the
# island's own image with AIKO_NAMESPACE overridden — the real implementation,
# not a model of it.
#
#   Arm 1  Dart promotes first, THEN a Python registrar joins.
#          Python must stand down. This has never been observed.
#   Arm 2  Dart promotes, then leaves CLEANLY (will suppressed, retained `found`
#          left standing), THEN Python joins. This is face 1 measured FROM THE
#          VICTIM'S SIDE: does the replacement read the corpse and stand down?
#   Arm 3  Dart promotes, then dies DIRTY (broker fires our `(primary absent)`),
#          THEN Python joins. Python must PROMOTE.
#
# Arm 3 is the positive control and is not optional: without it, arm 2's result
# cannot be told apart from "Python never promotes in this harness". Arms 2 and 3
# apply opposite stimuli and must produce opposite outcomes, or the probe is
# measuring itself.
#
# Exit: 0 pass, 1 an assertion failed, 2 missing dependency, 3 no broker/docker.
set -uo pipefail
cd "$(dirname "$0")/../.."
. spike/probe_support.sh

BROKER_HOST=${AIKO_MQTT_HOST:-127.0.0.1}
BROKER_PORT=${AIKO_MQTT_PORT:-1883}
ISLAND_NET=${AIKO_ISLAND_NET:-aiko_default}
ISLAND_IMAGE=${AIKO_ISLAND_IMAGE:-ghcr.io/nickmeinhold/aiko-chat-island:edge}
# The hostname the registrar CONTAINER uses to reach the broker — a docker
# network alias, not the host-side address the Dart side uses.
BROKER_IN_NET=${AIKO_BROKER_IN_NET:-mosquitto}
PY_NAME=aiko-probe-peer-registrar

probe_require_tools
probe_require_broker "$BROKER_HOST" "$BROKER_PORT"
command -v docker >/dev/null || { echo "docker not found — cannot run the Python peer. A skip is NOT a pass." >&2; exit 2; }
docker image inspect "$ISLAND_IMAGE" >/dev/null 2>&1 || {
  echo "image $ISLAND_IMAGE not present locally — pull it or set AIKO_ISLAND_IMAGE. A skip is NOT a pass." >&2; exit 3; }

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

cleanup() { docker rm -f "$PY_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Start the island's OWN registrar image in namespace $1, sniffing that namespace
# for the whole window so the peer's LIVENESS can be proven independently of its
# election decision.
#
# THIS IS NOT DECORATION. Without it, "the Python peer stood down" is
# indistinguishable from "the Python peer crashed on startup and did nothing" —
# a check whose success value equals its disabled value. The image logs NOTHING
# to stdout (measured: 0 bytes), so docker logs cannot witness it either. What a
# live registrar DOES emit, whatever role it lands in, is an `(add ...)` self
# registration on its own `/out` topic.
PEER_SNIFF=""
start_python_peer() {
  docker rm -f "$PY_NAME" >/dev/null 2>&1 || true
  PEER_SNIFF=$(mktemp)
  mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "$1/#" -v > "$PEER_SNIFF" 2>&1 &
  PEER_SNIFF_PID=$!
  docker run -d --rm --name "$PY_NAME" --network "$ISLAND_NET" \
    -e AIKO_MQTT_HOST="$BROKER_IN_NET" -e AIKO_NAMESPACE="$1" \
    "$ISLAND_IMAGE" aiko_registrar >/dev/null
}

# Assert the peer reached the bus at all. $1 = the DART path, so we can tell the
# peer's own traffic from ours.
assert_peer_was_alive() {
  probe_unwatch "$PEER_SNIFF_PID" 2>/dev/null
  local running peer_lines
  running=$(docker inspect -f '{{.State.Running}}' "$PY_NAME" 2>/dev/null)
  peer_lines=$(grep -c "registrar github.com/geekscape" "$PEER_SNIFF" 2>/dev/null); peer_lines=${peer_lines:-0}
  if [ "$running" = "true" ] && [ "$peer_lines" -ge 1 ]; then
    ok "the Python peer was ALIVE and on the bus ($peer_lines self-registration message(s))"
  else
    bad "the Python peer never reached the bus (running=$running, its messages=$peer_lines) — this arm proves NOTHING"
  fi
}

# Wait until the boot topic of $1 holds a `found` whose path contains $2, or
# time out. Echoes the last payload seen. Waiting on the CONDITION, never on a
# fixed sleep: a fixed margin is the flaky-gate complaint in claude-tasks #1.
await_found_from() {  # $1 namespace  $2 path-substring  $3 budget-seconds
  local deadline=$(( $(date +%s) + $3 )) payload=""
  while [ "$(date +%s)" -lt "$deadline" ]; do
    payload=$(timeout 2 mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
      -t "$1/service/registrar" -C 1 -W 1 2>/dev/null)
    case "$payload" in *"$2"*) printf '%s' "$payload"; return 0;; esac
    sleep 1
  done
  printf '%s' "$payload"; return 1
}

boot_topic_now() {  # $1 namespace
  timeout 3 mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
    -t "$1/service/registrar" -C 1 -W 2 2>/dev/null
}

# ---------------------------------------------------------------- ARM 1
printf '\n\033[1mArm 1 — a Python registrar joins a namespace a DART registrar already owns\033[0m\n'
NS1="probe_peer_$$_1"
DART_OUT=$(mktemp)
# `hold` promotes, stays up for hold-ms, then disconnects cleanly.
( dart run spike/election/probe_election.dart --mode hold --namespace "$NS1" \
    --host "$BROKER_HOST" --port "$BROKER_PORT" --settle-ms 8000 --hold-ms 22000 \
    > "$DART_OUT" 2>&1 ) &
DART_PID=$!

DART_PATH=""
for _ in $(seq 1 20); do
  DART_PATH=$(grep -m1 '^TOPIC_PATH=' "$DART_OUT" 2>/dev/null | cut -d= -f2)
  [ -n "$DART_PATH" ] && break
  sleep 1
done
if [ -z "$DART_PATH" ]; then
  bad "the Dart driver never reported a topic path"; cat "$DART_OUT"; exit 1
fi
# Wait for the Dart side to actually own the cell before introducing the peer.
if [ -n "$(await_found_from "$NS1" "$DART_PATH" 20)" ]; then
  ok "the Dart registrar owns $NS1/service/registrar"
else
  bad "the Dart registrar never announced in $NS1"; cat "$DART_OUT"; kill $DART_PID 2>/dev/null; exit 1
fi

start_python_peer "$NS1"
sleep 12
AFTER=$(boot_topic_now "$NS1")
printf '  boot topic after the Python peer joined: %s\n' "${AFTER:-<empty>}"
case "$AFTER" in
  *"$DART_PATH"*) ok "the PYTHON registrar stood down — the Dart announcement still owns the cell" ;;
  *) bad "the Python registrar OVERWROTE a live Dart primary (got: ${AFTER:-<empty>})" ;;
esac
assert_peer_was_alive "$DART_PATH"
docker rm -f "$PY_NAME" >/dev/null 2>&1
wait $DART_PID 2>/dev/null
grep -q '^LEFT_CLEANLY=1' "$DART_OUT" && ok "the Dart registrar then left cleanly" || bad "the Dart registrar did not leave cleanly"

# ---------------------------------------------------------------- ARM 2
printf '\n\033[1mArm 2 — FACE 1 FROM THE VICTIM'"'"'S SIDE: Dart leaves CLEANLY, then Python joins\033[0m\n'
NS2="probe_peer_$$_2"
D2=$(mktemp)
dart run spike/election/probe_election.dart --mode hold --namespace "$NS2" \
  --host "$BROKER_HOST" --port "$BROKER_PORT" --settle-ms 8000 --hold-ms 1000 > "$D2" 2>&1
D2_PATH=$(grep -m1 '^TOPIC_PATH=' "$D2" | cut -d= -f2)
grep -q '^LEFT_CLEANLY=1' "$D2" || { bad "arm 2 setup: the Dart side did not leave cleanly"; cat "$D2"; }
RESIDUE=$(boot_topic_now "$NS2")
printf '  retained after a CLEAN Dart departure: %s\n' "${RESIDUE:-<empty>}"
case "$RESIDUE" in
  *"$D2_PATH"*) ok "setup: a clean departure leaves the retained (primary found) standing — the corpse exists" ;;
  *) bad "setup: expected the corpse to remain, got ${RESIDUE:-<empty>}" ;;
esac

start_python_peer "$NS2"
sleep 14
AFTER2=$(boot_topic_now "$NS2")
printf '  boot topic after the replacement joined: %s\n' "${AFTER2:-<empty>}"
case "$AFTER2" in
  *"$D2_PATH"*)
    printf '  \033[33mMEASURED\033[0m the replacement STOOD DOWN to a corpse — face 1 confirmed against the real Python implementation\n'
    FACE1="stood-down-to-corpse" ;;
  *)
    printf '  \033[33mMEASURED\033[0m the replacement PROMOTED over the corpse — face 1 does NOT reproduce this way\n'
    FACE1="promoted-over-corpse" ;;
esac
assert_peer_was_alive "$D2_PATH"
docker rm -f "$PY_NAME" >/dev/null 2>&1

# ---------------------------------------------------------------- ARM 3
printf '\n\033[1mArm 3 — POSITIVE CONTROL: Dart dies DIRTY, then Python joins. It MUST promote.\033[0m\n'
NS3="probe_peer_$$_3"
D3=$(mktemp)
# `promote` exits WITHOUT a DISCONNECT, so the broker fires our will.
dart run spike/election/probe_election.dart --mode promote --namespace "$NS3" \
  --host "$BROKER_HOST" --port "$BROKER_PORT" --settle-ms 8000 > "$D3" 2>&1
D3_PATH=$(grep -m1 '^TOPIC_PATH=' "$D3" | cut -d= -f2)
sleep 3
TOMB=$(boot_topic_now "$NS3")
printf '  retained after a DIRTY Dart death: %s\n' "${TOMB:-<empty>}"
case "$TOMB" in
  *absent*) ok "setup: the broker fired our will — the cell says (primary absent)" ;;
  *) bad "setup: expected (primary absent), got ${TOMB:-<empty>}" ;;
esac

start_python_peer "$NS3"
sleep 14
AFTER3=$(boot_topic_now "$NS3")
printf '  boot topic after the replacement joined: %s\n' "${AFTER3:-<empty>}"
case "$AFTER3" in
  *"$NS3"*)
    case "$AFTER3" in
      *"$D3_PATH"*) bad "control: the cell still names the DEAD Dart process — the peer did not take over" ;;
      *) ok "CONTROL HOLDS: the Python replacement PROMOTED itself after a dirty death" ;;
    esac ;;
  *) bad "control: no announcement at all from the replacement (got ${AFTER3:-<empty>})" ;;
esac
assert_peer_was_alive "$D3_PATH"
docker rm -f "$PY_NAME" >/dev/null 2>&1

# ---------------------------------------------------------------- verdict
printf '\n\033[1mFace 1, measured against the real Python implementation: %s\033[0m\n' "$FACE1"
printf '\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

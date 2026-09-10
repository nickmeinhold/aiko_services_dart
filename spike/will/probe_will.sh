#!/usr/bin/env bash
#
# Two-arm acceptance for the transport's Last Will, against a REAL broker.
#
# Arm 1 (die): the process exits without disconnecting -> the broker MUST
#              publish the will.
# Arm 2 (bye): the process disconnects cleanly       -> the broker MUST NOT.
#
# Both arms are required. Arm 1 alone cannot distinguish "the will works" from
# "the broker publishes this on any disconnect". Arm 2 alone cannot distinguish
# "correctly suppressed" from "no will was ever set". Each is the other's
# control, and the pair is what makes the check able to fail.
#
# Needs a broker on 127.0.0.1:1883 (the island rig's dev-ports overlay
# publishes one) and mosquitto_sub on PATH.
set -uo pipefail
cd "$(dirname "$0")/../.."

BROKER_HOST=${AIKO_MQTT_HOST:-127.0.0.1}
BROKER_PORT=${AIKO_MQTT_PORT:-1883}
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Two DISTINCT exit codes, because the two causes are not the same fact and a
# caller must be able to tell them apart. Collapsing them is what let verify.sh
# treat "this machine has no mosquitto_sub" as though it were "there is no
# broker", and skip a check while the island it depends on was demonstrably up.
#   2 = no mosquitto_sub on this machine (a tooling gap here)
#   3 = no broker reachable (the rig is down)
command -v mosquitto_sub >/dev/null || {
  echo "mosquitto_sub not found — cannot observe the broker. A skip is NOT a pass." >&2
  exit 2
}
if ! timeout 3 mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" -t '$SYS/#' -C 1 -W 2 >/dev/null 2>&1; then
  # $SYS may be disabled; fall back to proving we can connect at all.
  if ! timeout 3 mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" -t 'aiko/probe/will/ping' -m x 2>/dev/null; then
    echo "no broker at $BROKER_HOST:$BROKER_PORT — bring the island rig up. A skip is NOT a pass." >&2
    exit 3
  fi
fi

run_arm() {  # $1 = die|bye ; echoes the observed will payload (empty if none)
  local arm=$1 out sub_log sub_pid
  out=$(mktemp); sub_log=$(mktemp)
  # Cleanup on EVERY exit from this function, including the early return below.
  # A `return` that skips its own `rm` leaks a temp file per arm, quietly.
  trap 'rm -f "$out" "$sub_log"' RETURN

  # The subscriber's lifetime is OWNED here, not fused to a timeout that races
  # the probe. An earlier version backgrounded it in a subshell under
  # `timeout 14`, which hid the child's PID and made two things possible:
  # a cold `dart run` compile outliving the fuse (arm 1 false-reds against an
  # un-retained will that is gone the moment it is published), and reading the
  # log while mosquitto_sub still held it (grepping a userspace buffer rather
  # than what the broker actually said).
  mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
    -t 'aiko/probe/will/+/0/state' -v > "$sub_log" 2>&1 &
  sub_pid=$!
  # Give the SUBSCRIBE a moment to be established at the broker. An un-retained
  # will published before this lands is unobservable, forever.
  sleep 1

  # Unbounded on purpose: a cold compile is slow and that is not a failure.
  dart run spike/will/probe_will.dart "$arm" > "$out" 2>&1
  # Let a will published at exit reach the broker and the subscriber.
  sleep 4

  # Stop the subscriber and WAIT for it, so its stdio is flushed before the file
  # is read. Reading a live process's redirect is reading a block buffer.
  kill "$sub_pid" 2>/dev/null
  wait "$sub_pid" 2>/dev/null

  grep -q 'connected as will_probe' "$out" || {
    echo "PROBE_DID_NOT_CONNECT"
    cat "$out" >&2
    return
  }
  grep -oE '\(absent\)' "$sub_log" | head -1
}

printf '\n\033[1mArm 1 — exit without disconnecting: the will MUST fire\033[0m\n'
got=$(run_arm die)
if [ "$got" = "(absent)" ]; then
  ok "the broker published (absent) on the process state topic"
else
  bad "no will observed (got: '${got:-nothing}') — the will never reached the broker"
fi

printf '\n\033[1mArm 2 — clean disconnect: the will MUST NOT fire\033[0m\n'
got=$(run_arm bye)
if [ -z "$got" ]; then
  ok "silence after a clean disconnect, as MQTT requires"
elif [ "$got" = "PROBE_DID_NOT_CONNECT" ]; then
  bad "the probe never connected — arm 2's silence proves nothing"
else
  bad "the broker published '$got' after a CLEAN disconnect"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d passed, 0 failed\033[0m\n' "$pass"
  printf 'Scope: proves the will is CARRIED and correctly suppressed. Does NOT\n'
  printf 'cover the frozen-process path (socket stays open; the broker needs\n'
  printf '1.5 x keepalive to notice), nor a will CHANGE, which needs a reconnect.\n'
  exit 0
fi
printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
exit 1

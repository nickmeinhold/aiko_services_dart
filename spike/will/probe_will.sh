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
# Exit codes: 0 pass, 1 an assertion failed, 2 a missing harness dependency,
# 3 no reachable broker, 75 the harness stalled. The last three are NOT
# assertion failures and the caller must be able to tell them apart.
set -uo pipefail
cd "$(dirname "$0")/../.."
. spike/probe_support.sh

BROKER_HOST=${AIKO_MQTT_HOST:-127.0.0.1}
BROKER_PORT=${AIKO_MQTT_PORT:-1883}
# `${VAR:-default}` does not substitute for set-but-EMPTY, which would hand an
# empty string to mosquitto_sub -p and to the Dart half separately.
[ -n "$BROKER_HOST" ] || BROKER_HOST=127.0.0.1
[ -n "$BROKER_PORT" ] || BROKER_PORT=1883

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

probe_require_tools
probe_require_broker "$BROKER_HOST" "$BROKER_PORT"

run_arm() {  # $1 = die|bye ; echoes the observed will payload, or a marker
  local arm=$1 out sub_log sub_pid run_id topic rc
  out=$(mktemp); sub_log=$(mktemp)
  trap 'rm -f "$out" "$sub_log"' RETURN

  # A run id chosen HERE, so the will topic is known before the subscriber
  # starts. Watching a wildcard instead lets concurrent runs read each other:
  # a clean `bye` arm fails on somebody else's `die`, and — worse — a `die` arm
  # PASSES on somebody else's will.
  run_id="$$_${arm}_$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
  topic="aiko/probe/will/${run_id}/0/state"

  sub_pid=$(probe_watch "$BROKER_HOST" "$BROKER_PORT" "$topic" "$sub_log")
  sleep 1

  rc=$(probe_run_bounded 60 "$out" \
    dart run spike/will/probe_will.dart "$run_id" "$arm" "$BROKER_HOST" "$BROKER_PORT")
  # Let a will published at exit reach the broker and the subscriber.
  sleep 4
  probe_unwatch "$sub_pid"

  if [ "$rc" = "75" ]; then echo "PROBE_STALLED"; return; fi
  grep -q 'connected as will_probe' "$out" || {
    echo "PROBE_DID_NOT_CONNECT"
    cat "$out" >&2
    return
  }
  grep -oE '\(absent\)' "$sub_log" | head -1
}

printf '\n\033[1mArm 1 — exit without disconnecting: the will MUST fire\033[0m\n'
got=$(run_arm die)
case "$got" in
  '(absent)')        ok "the broker published (absent) on the process state topic" ;;
  PROBE_STALLED)     bad "the probe STALLED (watchdog) — the harness could not complete, which is not the protocol failing" ;;
  PROBE_DID_NOT_CONNECT) bad "the probe never connected — nothing here proves anything" ;;
  *)                 bad "no will observed (got: '${got:-nothing}') — the will never reached the broker" ;;
esac

printf '\n\033[1mArm 2 — clean disconnect: the will MUST NOT fire\033[0m\n'
got=$(run_arm bye)
case "$got" in
  '')                ok "silence after a clean disconnect, as MQTT requires" ;;
  PROBE_STALLED)     bad "the probe STALLED (watchdog) — arm 2's silence proves nothing" ;;
  PROBE_DID_NOT_CONNECT) bad "the probe never connected — arm 2's silence proves nothing" ;;
  *)                 bad "the broker published '$got' after a CLEAN disconnect" ;;
esac

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

#!/usr/bin/env bash
#
# Does the EC lease RENEW on the wire? Observed at the broker, against a live
# producer, in seconds rather than the four minutes the production default needs.
#
# The gap this closes, named honestly in docs/notes/bus-observer-findings.md:
# tool/observer_acceptance.sh proves the lease is TAKEN and CANCELLED, and never
# that it is RENEWED. The renewal fires at 0.8 x 300s = 240s and no run has ever
# lasted that long, so the single most protocol-specific mechanism in the
# consumer has never been watched doing its job.
#
# `leaseTime` is an ordinary constructor parameter with its own validation, so
# this exercises the SAME timer production uses, merely wound tighter. It is not
# a test-only branch, which is what would have made the measurement worthless.
set -uo pipefail
cd "$(dirname "$0")/../.."

HOST=${AIKO_MQTT_HOST:-127.0.0.1}
PORT=${AIKO_MQTT_PORT:-1883}
NS=${AIKO_NAMESPACE:-aiko}
LEASE=${AIKO_PROBE_LEASE:-5}
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

command -v mosquitto_sub >/dev/null || { echo "no mosquitto_sub — a skip is NOT a pass" >&2; exit 2; }

# Find a live ECProducer by asking the registrar, exactly as a real consumer
# would. Hardcoding a topic would make this a fact about one island.
BOOT=$(timeout 5 mosquitto_sub -h "$HOST" -p "$PORT" -t "$NS/service/registrar" -C 1 -W 4 2>/dev/null)
REG=$(printf '%s' "$BOOT" | sed -n 's/^(primary found \([^ ]*\).*/\1/p')
[ -n "$REG" ] || { echo "no primary registrar on $NS/service/registrar — is the rig up? A skip is NOT a pass." >&2; exit 3; }

RESP="$NS/leaseprobe/$$/roster"
ROSTER=$(mktemp)
# Owned and flushed, like the control subscriber below. An earlier version
# backgrounded this in a subshell under `timeout` and parsed the file while
# mosquitto_sub still held it -- reading a userspace buffer rather than what the
# broker sent, so a perfectly good roster could still be in flight and the probe
# would exit 3 "no chat_server". The SAME hazard was already fixed for the
# control subscriber in this file, which is what made leaving it here an
# inconsistency rather than an oversight.
mosquitto_sub -h "$HOST" -p "$PORT" -t "$RESP" > "$ROSTER" 2>&1 &
ROSTER_SUB=$!
sleep 1
mosquitto_pub -h "$HOST" -p "$PORT" -t "$REG/in" -m "(share $RESP * * * * *)"
sleep 4
kill "$ROSTER_SUB" 2>/dev/null; wait "$ROSTER_SUB" 2>/dev/null
# Any service advertising ec=true has an ECProducer; the ChatServer is the one
# the island always has.
# The payload is `(add <topic_path> <name> <protocol> <transport> <owner> (tags))`,
# so the path is field 2 and NOT adjacent to the opening paren. Matching on
# `(<path> chat_server` looks right and finds nothing, silently, forever.
PRODUCER=$(sed -n "s/^(add \($NS\/[^ ]*\) chat_server .*/\1/p" "$ROSTER" | head -1)
if [ -z "$PRODUCER" ]; then
  echo "no chat_server with an ECProducer in the roster — a skip is NOT a pass." >&2
  echo "roster the registrar actually returned:" >&2
  sed 's/^/    /' "$ROSTER" >&2
  rm -f "$ROSTER"
  exit 3
fi
rm -f "$ROSTER"
CONTROL="$PRODUCER/control"
printf 'producer: %s\nlease:    %ss (renewal at 0.8x = %ss)\n' "$CONTROL" "$LEASE" \
  "$(awk -v l="$LEASE" 'BEGIN{printf "%.1f", l*0.8}')"

# NOTE on the consumer topic you will see below: it embeds the producer's WHOLE
# control topic inside our own share-in topic, e.g.
#   aiko/leaseprobe/<pid>/0/aiko/<host>/<pid>/1/control/1/in
# That is not a bug and not ours. `share.py:455-456` is
#   f"{service.topic_path}/{ec_producer_topic_control}/{ec_consumer_id}/in"
# so the reference nests one topic inside another. It looks wrong at a glance,
# which is exactly why it is written down here — a future reader "fixing" it
# would silently break interop with every Python producer.
#
# Watch the producer's control topic for OUR requests. Own the subscriber's
# lifetime and flush it before reading — a log read while mosquitto_sub still
# holds it is a userspace buffer, not what the broker saw.
LOG=$(mktemp)
PROBE_OUT=$(mktemp)
mosquitto_sub -h "$HOST" -p "$PORT" -t "$CONTROL" > "$LOG" 2>&1 &
SUB=$!
sleep 1
# mktemp, not a fixed path. Two concurrent verify.sh runs sharing one file makes
# each read the other's CONSUMER_TOPIC -- one run counting another's renewals, or
# reporting a bogus attach failure. This file already treats a shared name as a
# real defect (the will probe carries a per-run id for the same reason), so a
# global path here was the inconsistency.
dart run spike/lease/probe_lease.dart "$CONTROL" "$LEASE" > "$PROBE_OUT" 2>&1
sleep 2
kill "$SUB" 2>/dev/null; wait "$SUB" 2>/dev/null

MY_TOPIC=$(sed -n 's/^CONSUMER_TOPIC=//p' "$PROBE_OUT")
if [ -z "$MY_TOPIC" ]; then
  bad "the probe never attached — nothing below proves anything"
  cat "$PROBE_OUT" >&2
else
  # Only OUR requests. The producer's control topic is shared, so counting every
  # (share ...) would count other consumers' traffic as our renewals.
  MINE=$(grep -F "$MY_TOPIC" "$LOG")
  TAKES=$(printf '%s\n' "$MINE" | grep -cE "\(share $MY_TOPIC $LEASE ")
  CANCELS=$(printf '%s\n' "$MINE" | grep -cE "\(share $MY_TOPIC 0 ")

  printf '\n\033[1mrequests observed on the producer control topic\033[0m\n'
  printf '%s\n' "$MINE" | sed 's/^/    /'
  printf '\n'

  if [ "$TAKES" -ge 2 ]; then
    ok "the lease RENEWED: $TAKES requests at ${LEASE}s (take + $((TAKES - 1)) renewal(s))"
  else
    bad "only $TAKES request at ${LEASE}s — the renewal never landed"
  fi
  # The negative control. A renewal is only meaningful if the cancellation is
  # ALSO distinguishable: without this, "two messages" could be one take plus a
  # teardown and we would be calling a goodbye a renewal.
  if [ "$CANCELS" -eq 1 ]; then
    ok "and terminate cancelled with lease 0, distinct from the renewals"
  else
    bad "expected exactly 1 cancellation at lease 0, saw $CANCELS"
  fi
fi
rm -f "$LOG" "$PROBE_OUT"

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d passed, 0 failed\033[0m\n' "$pass"
  printf 'Scope: proves the renewal TIMER fires and re-requests at the same lease.\n'
  printf 'Does NOT prove a producer honours the extension, nor what happens when a\n'
  printf 'lease is allowed to LAPSE — that needs a producer we control (increment 2).\n'
  exit 0
fi
printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
exit 1

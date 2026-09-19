#!/usr/bin/env bash
#
# Three-arm acceptance for the registrar's primary election, against a REAL
# broker. `RegistrarElection` has a thorough unit suite; it proves the machine
# TRANSITIONS correctly given events, and says nothing about whether the events
# arrive correctly from a broker holding a real retained message.
#
# Arm 1 (secondary)  Join the LIVE island, where a Python registrar is already
#                    primary. We must read its retained announcement, stand
#                    down, and publish NOTHING. Also reports the delivery
#                    latency, which is the margin on the dual-primary race.
# Arm 2 (primary)    Join a namespace with no registrar. We must promote,
#                    publish a retained (primary found ...), and — on a hard
#                    exit — have the broker publish our retained will.
# Arm 3 (not deaf)   After promoting, hear an EXTERNAL (primary absent) and
#                    stand down. Promotion changes the will, which MQTT permits
#                    only in a CONNECT packet, so promotion RECONNECTS. A
#                    reconnect with startClean throws the session away. This is
#                    the only arm that can see whether the subscriptions came
#                    back, and no fake can reach it.
#
# Arms 2 and 3 run in a THROWAWAY namespace on the same broker, so they never
# touch the live island's boot topic. Arm 1 uses the real one and is read-only
# BY ASSERTION rather than by hope — see the guard below, which refuses to run
# it unless the island already has a primary. Without that guard a run against
# a registrar-less island would promote OUR process onto the island's boot
# topic, which is a hijack rather than a test.
#
# Exit codes: 0 pass, 1 an assertion failed, 2 a missing harness dependency,
# 3 no reachable broker or no island primary, 75 the harness stalled.
set -uo pipefail
cd "$(dirname "$0")/../.."
. spike/probe_support.sh

BROKER_HOST=${AIKO_MQTT_HOST:-127.0.0.1}
BROKER_PORT=${AIKO_MQTT_PORT:-1883}
NAMESPACE=${AIKO_NAMESPACE:-aiko}
[ -n "$BROKER_HOST" ] || BROKER_HOST=127.0.0.1
[ -n "$BROKER_PORT" ] || BROKER_PORT=1883
[ -n "$NAMESPACE" ]   || NAMESPACE=aiko

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

probe_require_tools
probe_require_broker "$BROKER_HOST" "$BROKER_PORT"

RUN_ID="$$_$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')"
NS_PRIMARY="probe_election_${RUN_ID}_b"
NS_DEAF="probe_election_${RUN_ID}_c"

# A retained message outlives the process that published it, so a probe that
# leaves one behind has littered the broker permanently. Cleared on EVERY exit
# path, including the assertion failures.
cleanup() {
  for ns in "$NS_PRIMARY" "$NS_DEAF"; do
    mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" \
      -t "$ns/service/registrar" -n -r 2>/dev/null
  done
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
printf '\n\033[1mArm 1 — the live island already has a primary: we MUST stand down\033[0m\n'

BOOT_TOPIC="$NAMESPACE/service/registrar"
island_primary=$(mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
  -t "$BOOT_TOPIC" -C 1 -W 3 2>/dev/null)
case "$island_primary" in
  '(primary found '*)
    printf '  island primary: %s\n' "$island_primary" ;;
  *)
    echo "no (primary found ...) retained on $BOOT_TOPIC — this arm would PROMOTE" >&2
    echo "our process onto the island's boot topic rather than test anything." >&2
    echo "Bring the island rig up. A skip is NOT a pass." >&2
    exit 3 ;;
esac

sniff=$(mktemp); out=$(mktemp)
sub_pid=$(probe_watch "$BROKER_HOST" "$BROKER_PORT" "$BOOT_TOPIC" "$sniff")
sleep 1
rc=$(probe_run_bounded 45 "$out" \
  dart run spike/election/probe_election.dart \
    --mode observe --namespace "$NAMESPACE" \
    --host "$BROKER_HOST" --port "$BROKER_PORT" --settle-ms 4000)
probe_unwatch "$sub_pid"

our_path=$(grep -oE '^TOPIC_PATH=.*' "$out" | head -1 | cut -d= -f2-)
if [ "$rc" = "75" ]; then
  bad "the probe STALLED (watchdog) — the harness could not complete, which is not the protocol failing"
elif [ -z "$our_path" ]; then
  bad "the probe never reported a topic path — nothing here proves anything"
  cat "$out" >&2
else
  grep -q '^FINAL_ROLE=secondary$' "$out" \
    && ok "stood down to secondary against a live Python primary" \
    || bad "did NOT stand down: $(grep -E '^FINAL_ROLE=' "$out" || echo 'no role reported')"

  # The negative half. A second registrar that announced itself would put two
  # retained `found` payloads on one topic, and every joining peer would read
  # whichever landed last.
  if grep -qF "$our_path" "$sniff"; then
    bad "we published to the island's boot topic while secondary"
    grep -F "$our_path" "$sniff" >&2
  else
    ok "published nothing to $BOOT_TOPIC"
  fi

  latency=$(grep -oE '^LATENCY_MS=[0-9]+' "$out" | cut -d= -f2)
  if [ -n "$latency" ]; then
    # Reported, not asserted against a threshold. 2000ms is the promotion timer
    # both implementations use; this is how much room the race actually has, and
    # a number is more use to the next reader than a boolean.
    ok "retained announcement arrived in ${latency}ms (promotion timer is 2000ms)"
  else
    bad "no delivery latency measured — the announcement never arrived while searching"
  fi
fi
rm -f "$sniff" "$out"

# --------------------------------------------------------------------------- #
printf '\n\033[1mArm 2 — no primary: we MUST promote, announce, and retract on death\033[0m\n'

sniff=$(mktemp); out=$(mktemp)
sub_pid=$(probe_watch "$BROKER_HOST" "$BROKER_PORT" "$NS_PRIMARY/service/registrar" "$sniff")
sleep 1
rc=$(probe_run_bounded 45 "$out" \
  dart run spike/election/probe_election.dart \
    --mode promote --namespace "$NS_PRIMARY" \
    --host "$BROKER_HOST" --port "$BROKER_PORT" --settle-ms 8000)
# Let a will published at exit reach the broker and the subscriber.
sleep 4
probe_unwatch "$sub_pid"

our_path=$(grep -oE '^TOPIC_PATH=.*' "$out" | head -1 | cut -d= -f2-)
if [ "$rc" = "75" ]; then
  bad "the probe STALLED (watchdog) during promotion"
elif [ -z "$our_path" ]; then
  bad "the probe never reported a topic path"
  cat "$out" >&2
else
  found_line=$(grep -nE "\(primary found ${our_path} 2 [0-9.]+\)" "$sniff" | head -1 | cut -d: -f1)
  absent_line=$(grep -nF '(primary absent)' "$sniff" | head -1 | cut -d: -f1)

  [ -n "$found_line" ] \
    && ok "retained (primary found $our_path 2 <timestamp>) on the boot topic" \
    || { bad "no valid announcement on the wire"; cat "$sniff" >&2; }

  # The will. Only observable at the BROKER — nothing in our own output can
  # distinguish a will that was carried from one silently dropped.
  [ -n "$absent_line" ] \
    && ok "the broker published (primary absent) after a hard exit" \
    || bad "the will did NOT fire — a dead registrar's announcement would stand forever"

  # Order, not just presence. An announcement AFTER the retraction would mean we
  # had read our own tombstone as news.
  if [ -n "$found_line" ] && [ -n "$absent_line" ]; then
    [ "$absent_line" -gt "$found_line" ] \
      && ok "retraction followed the announcement" \
      || bad "the retraction arrived BEFORE the announcement (lines $absent_line, $found_line)"
  fi
fi
rm -f "$sniff" "$out"

# --------------------------------------------------------------------------- #
printf '\n\033[1mArm 3 — promotion reconnects: we MUST still be able to hear\033[0m\n'

out=$(mktemp)
dart run spike/election/probe_election.dart \
  --mode hold --namespace "$NS_DEAF" \
  --host "$BROKER_HOST" --port "$BROKER_PORT" \
  --settle-ms 8000 --hold-ms 9000 > "$out" 2>&1 &
hold_pid=$!

# Wait for the probe to say it has announced and is listening. Bounded, because
# a probe that never promotes must fail this arm rather than hang the gate.
held=0
for _ in $(seq 1 40); do
  grep -q '^HOLDING=' "$out" && { held=1; break; }
  kill -0 "$hold_pid" 2>/dev/null || break
  sleep 0.5
done

if [ "$held" = "0" ]; then
  kill -9 "$hold_pid" 2>/dev/null; wait "$hold_pid" 2>/dev/null
  bad "the probe never reached the holding state — it did not promote"
  cat "$out" >&2
else
  # Speak to it from OUTSIDE, on the topic it subscribed to BEFORE its
  # promotion reconnect. Un-retained, so nothing is left behind.
  mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" \
    -t "$NS_DEAF/service/registrar" -m '(primary absent)'
  wait "$hold_pid" 2>/dev/null

  # Only role lines AFTER the hold began count. Every run has a primary_search
  # at startup, so matching the whole file would pass on a process that went
  # deaf the moment it promoted — which is exactly the defect this arm exists
  # for, and it would have looked green.
  if awk '/^HOLDING=/{seen=1; next} seen && /^ROLE=primary_search$/{found=1} END{exit !found}' "$out"; then
    ok "heard an external (primary absent) after promoting, and stood down"
  else
    bad "DEAF after promotion: the reconnect dropped the subscription"
    cat "$out" >&2
  fi
fi
rm -f "$out"

# --------------------------------------------------------------------------- #
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

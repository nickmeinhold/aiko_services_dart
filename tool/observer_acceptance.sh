#!/usr/bin/env bash
#
# observer_acceptance.sh — the six-verb falsifier for the Dart bus observer.
#
# The capability invariant from docs/notes/bus-observer-scope.md is six verbs:
# connect, discover, subscribe, receive, leave, recover. "A run that only
# demonstrates connect-and-print has exercised one of six." This script
# exercises all six against a LIVE Python island and fails on any of them.
#
# Two properties make it a check rather than a ceremony:
#
#   * The expected channel list is DERIVED from the island by an independent
#     instrument (mosquitto_sub inside the broker container), never hand-typed.
#     If the island's channels change, the expectation changes with it.
#   * Two verbs carry negative controls — a `discover` arm with the ChatServer
#     STOPPED that must not print a channel list, and a `leave` arm that reads
#     the BROKER's log rather than ours. Both were able to fail: the discover
#     arm's assertion is what a silent observer would trip, and the leave arm
#     caught a real protocol defect (MQTT 3.1 vs 3.1.1) that our own output
#     showed no trace of.
#
# Requires the local island rig:
#
#   docker compose -f ~/git/orgs/aiko/aiko-chat-island/docker-compose.yml \
#                  -f tool/island-rig/compose.dev-ports.yml \
#                  up -d mosquitto registrar chat
#
# Usage: tool/observer_acceptance.sh
set -uo pipefail

BROKER_CONTAINER=${BROKER_CONTAINER:-aiko-mosquitto-1}
CHAT_CONTAINER=${CHAT_CONTAINER:-aiko-chat-1}
NAMESPACE=${NAMESPACE:-aiko}
WORK=$(mktemp -d)
trap 'kill -INT "$(cat "$WORK/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

require_container() {
  docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q true || {
    echo "island container '$1' is not running — see the header for the rig command" >&2
    exit 2
  }
}
require_container "$BROKER_CONTAINER"
require_container "$CHAT_CONTAINER"

# --- the oracle: ask the island what its channels are, without our code ------
# The registrar's retained announcement gives the registrar's topic path; the
# registrar's roster gives the ChatServer's; the ChatServer's own EC share gives
# the channels. Three hops, all through mosquitto_sub, none through Dart.
oracle_channels() {
  local registrar chat
  registrar=$(docker exec "$BROKER_CONTAINER" timeout 3 mosquitto_sub \
      -h localhost -t "$NAMESPACE/service/registrar" -C 1 2>/dev/null \
    | sed -n 's/^(primary found \([^ ]*\).*/\1/p')
  [ -n "$registrar" ] || { echo "ORACLE: no registrar announcement" >&2; return 1; }

  chat=$(docker exec "$BROKER_CONTAINER" sh -c "
      (mosquitto_sub -h localhost -t '$NAMESPACE/probe/oracle/roster' > /tmp/oracle_roster 2>&1 &)
      sleep 1
      mosquitto_pub -h localhost -t '$registrar/in' \
        -m '(share $NAMESPACE/probe/oracle/roster * * * * *)'
      sleep 2
      cat /tmp/oracle_roster" \
    | sed -n 's/^(add \([^ ]*\) chat_server .*/\1/p' | head -1)
  [ -n "$chat" ] || { echo "ORACLE: no chat_server in the roster" >&2; return 1; }

  docker exec "$BROKER_CONTAINER" sh -c "
      (mosquitto_sub -h localhost -t '$NAMESPACE/probe/oracle/ec' > /tmp/oracle_ec 2>&1 &)
      sleep 1
      mosquitto_pub -h localhost -t '$chat/control' \
        -m '(share $NAMESPACE/probe/oracle/ec 300 channel_list)'
      sleep 2
      mosquitto_pub -h localhost -t '$chat/control' \
        -m '(share $NAMESPACE/probe/oracle/ec 0 channel_list)'
      cat /tmp/oracle_ec" \
    | sed -n 's/^(add channel_list\.\([^ ]*\) .*/\1/p' | sort -u | paste -sd, -
}

# Channel names as our observer printed them, from its "channels (N): a, b" line.
observed_channels() {
  sed -n 's/^.*channels ([0-9]*): //p' "$1" | tail -1 | tr -d ' '
}

# Launch the observer directly, not under `timeout`: the leave verb is tested
# by sending SIGINT to the observer itself, and `timeout` does not forward a
# signal it receives to its child — the observer would never run its leave path
# and the test would pass for the wrong reason.
run_observer() { # run_observer <logfile>
  dart run example/bus_observer.dart --namespace "$NAMESPACE" > "$1" 2>&1 &
  echo $! > "$WORK/pid"
}

stop_observer() {
  local observer_pid
  observer_pid=$(cat "$WORK/pid" 2>/dev/null) || return 0
  kill -INT "$observer_pid" 2>/dev/null
  wait "$observer_pid" 2>/dev/null
}

step "Oracle — asking the island directly (no Dart involved)"
EXPECTED=$(oracle_channels) || exit 2
echo "  island channels: $EXPECTED"

step "connect / discover / subscribe / receive"
BROKER_MARK=$(docker exec "$BROKER_CONTAINER" date +%s)
run_observer "$WORK/main.log"
sleep 12

grep -q 'connection state: registrar' "$WORK/main.log" \
  && ok "connect — reached ConnectionState.registrar" \
  || bad "connect — never reached registrar"

grep -q 'subscribing to .*/control filter=channel_list' "$WORK/main.log" \
  && ok "discover — found the ChatServer through the registrar" \
  || bad "discover — never located the ChatServer"

CONTROL_TOPIC=$(sed -n 's/^.*subscribing to \([^ ]*\) .*/\1/p' "$WORK/main.log" | tail -1)
if [ -n "$CONTROL_TOPIC" ]; then
  ok "subscribe — share request addressed to $CONTROL_TOPIC"
else
  bad "subscribe — no share request was addressed"
fi

OBSERVED=$(observed_channels "$WORK/main.log")
if [ -n "$OBSERVED" ] && [ "$OBSERVED" = "$EXPECTED" ]; then
  ok "receive — replica matches the island: $OBSERVED"
else
  bad "receive — observer saw '${OBSERVED:-<nothing>}', island has '$EXPECTED'"
fi

stop_observer

step "leave — and what the ISLAND saw, not what we said"
LEAVE_SNIFF="$WORK/leave.txt"
docker exec -d "$BROKER_CONTAINER" sh -c \
  "mosquitto_sub -h localhost -t '$CONTROL_TOPIC' -v > /tmp/leave_sniff 2>&1"
sleep 1
run_observer "$WORK/leave.log"
sleep 10
stop_observer
sleep 2
docker exec "$BROKER_CONTAINER" cat /tmp/leave_sniff > "$LEAVE_SNIFF" 2>/dev/null

grep -qE '\(share [^ ]+ 300 channel_list\)' "$LEAVE_SNIFF" \
  && ok "leave — the lease was taken" \
  || bad "leave — no lease request reached the producer"
grep -qE '\(share [^ ]+ 0 channel_list\)' "$LEAVE_SNIFF" \
  && ok "leave — the lease was cancelled on exit" \
  || bad "leave — the lease was abandoned, not cancelled"

MALFORMED=$(docker logs --since "$((BROKER_MARK))" "$BROKER_CONTAINER" 2>&1 \
  | grep -c 'malformed packet')
[ "$MALFORMED" -eq 0 ] \
  && ok "leave — the broker logged nothing a clean disconnect would not" \
  || bad "leave — the broker logged $MALFORMED malformed packet(s)"

step "discover, with the ChatServer STOPPED (negative control)"
docker stop "$CHAT_CONTAINER" >/dev/null
run_observer "$WORK/absent.log"
sleep 10
if grep -q 'channels (' "$WORK/absent.log"; then
  bad "discover/absent — printed a channel list with no ChatServer running"
else
  ok "discover/absent — printed no channel list"
fi
grep -q 'not present on this island' "$WORK/absent.log" \
  && ok "discover/absent — said so, rather than going quiet" \
  || bad "discover/absent — stayed silent, which reads as success"
stop_observer
docker start "$CHAT_CONTAINER" >/dev/null
sleep 12

step "recover — the producer restarts underneath a running observer"
run_observer "$WORK/recover.log"
sleep 12
BEFORE_GEN=$(sed -n 's/^.*as consumer \([0-9]*\)$/\1/p' "$WORK/recover.log" | tail -1)
docker restart "$CHAT_CONTAINER" >/dev/null
sleep 30
stop_observer

# What "rebound" means is NOT that the producer's topic path changed. It often
# does not: `docker restart` hands the new ChatServer the same PID inside the
# container's namespace, and the topic path is
# {namespace}/{host}/{pid}/{service_id}. An earlier version of this arm asserted
# the paths differed and failed a working recovery for that reason — it was
# measuring PID churn, a property of Docker, not of the observer.
#
# The property is: the observer NOTICED the producer instance go, and
# established a FRESH subscription rather than assuming its old one survived.
# That is a strictly stronger claim than a changed path, and it is also what
# keeps the reused path safe — old and new share-in topics differ only by the
# consumer generation, so a naive constant id would land both on one address.
grep -q 'left — waiting for it to come back' "$WORK/recover.log" \
  && ok "recover — noticed the producer leave" \
  || bad "recover — never noticed the producer leave"

AFTER_GEN=$(sed -n 's/^.*as consumer \([0-9]*\)$/\1/p' "$WORK/recover.log" | tail -1)
if [ -n "$BEFORE_GEN" ] && [ -n "$AFTER_GEN" ] && [ "$AFTER_GEN" -gt "$BEFORE_GEN" ]; then
  ok "recover — re-subscribed as a new consumer ($BEFORE_GEN -> $AFTER_GEN)"
else
  bad "recover — no fresh subscription (consumer '$BEFORE_GEN' -> '$AFTER_GEN')"
fi

# Only the channel list printed AFTER the producer left counts. Reading the last
# line of the whole log would pass on the list received before the restart.
RECOVERED=$(sed -n '/left — waiting for it to come back/,$p' "$WORK/recover.log" \
  | observed_channels /dev/stdin)
if [ -n "$RECOVERED" ] && [ "$RECOVERED" = "$EXPECTED" ]; then
  ok "recover — re-received the full channel list after the restart"
else
  bad "recover — saw '${RECOVERED:-<nothing>}' after the restart"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

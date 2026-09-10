#!/usr/bin/env bash
#
# GATE A — an island whose registrar is OURS.
#
# The claim increment 2 exists to make: a Dart process takes the registrar's
# chair on a live island, and the Python side notices nothing. The falsifier is
# not a new suite. It is `tool/observer_acceptance.sh`, written for increment 1
# and UNMODIFIED, run against an island whose registrar we replaced. If those
# fourteen assertions still pass, an island stopped caring which language its
# registrar is written in.
#
# That reuse is the point. A bespoke suite written alongside the thing it checks
# tends to check what was built; this one was written before the registrar
# existed, by somebody asking a different question.
#
# WHAT THIS DOES TO THE RIG. It stops `aiko-registrar-1`, clears the retained
# boot topic, runs our registrar in its place, and restores everything on EVERY
# exit path including the failures. That is a real mutation, and it is in the
# same class as what the observer suite already does — that one stops the
# ChatServer and restarts the BROKER.
#
# WHY THE BOOT TOPIC MUST BE CLEARED BY HAND. A cleanly stopped registrar does
# NOT retract: a clean DISCONNECT suppresses its will, so the retained
# `(primary found <dead>)` stands. A replacement then reads it and stands down
# to secondary, and the island has no registrar that will take the job. Measured
# and filed for upstream; here it is simply a step we cannot skip.
#
# Exit codes: 0 pass, 1 an assertion failed, 2 a missing harness dependency,
# 3 the rig is not usable, 75 the harness stalled.
set -uo pipefail
cd "$(dirname "$0")/.."
. spike/probe_support.sh

BROKER_HOST=${AIKO_MQTT_HOST:-127.0.0.1}
BROKER_PORT=${AIKO_MQTT_PORT:-1883}
NAMESPACE=${AIKO_NAMESPACE:-aiko}
[ -n "$BROKER_HOST" ] || BROKER_HOST=127.0.0.1
[ -n "$BROKER_PORT" ] || BROKER_PORT=1883
[ -n "$NAMESPACE" ]   || NAMESPACE=aiko

REGISTRAR_CONTAINER=${REGISTRAR_CONTAINER:-aiko-registrar-1}
BOOT_TOPIC="$NAMESPACE/service/registrar"
WORK=$(mktemp -d)
DART_PID=""

probe_require_tools
probe_require_broker "$BROKER_HOST" "$BROKER_PORT"

docker inspect -f '{{.State.Running}}' "$REGISTRAR_CONTAINER" 2>/dev/null \
  | grep -q true || {
  echo "$REGISTRAR_CONTAINER is not running — this gate REPLACES it, so there" >&2
  echo "is nothing to replace and nothing proved. A skip is NOT a pass." >&2
  exit 3
}

# Restore on every path. Registered BEFORE the first mutation, not after it:
# a failure between stopping the container and installing the trap would leave
# the island without a registrar and with a corpse on its boot topic.
restore() {
  local status=$?
  if [ -n "$DART_PID" ]; then
    kill -TERM "$DART_PID" 2>/dev/null
    for _ in $(seq 1 10); do
      kill -0 "$DART_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$DART_PID" 2>/dev/null
    wait "$DART_PID" 2>/dev/null
  fi
  # OUR registrar leaves the same corpse for the same reason, so the topic is
  # cleared before the Python one comes back — otherwise it reads our tombstone
  # and stands down, and the restore silently leaves a broken island.
  mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "$BOOT_TOPIC" -n -r 2>/dev/null
  docker start "$REGISTRAR_CONTAINER" >/dev/null 2>&1
  rm -rf "$WORK"
  return $status
}
trap restore EXIT

printf '\n\033[1mGate A — replacing the island'"'"'s registrar with ours\033[0m\n'

docker stop "$REGISTRAR_CONTAINER" >/dev/null 2>&1 \
  || { echo "could not stop $REGISTRAR_CONTAINER" >&2; exit 3; }
mosquitto_pub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "$BOOT_TOPIC" -n -r

dart run example/registrar.dart \
  --namespace "$NAMESPACE" --host "$BROKER_HOST" --port "$BROKER_PORT" \
  > "$WORK/registrar.log" 2>&1 &
DART_PID=$!

# Bounded. A registrar that never announces must FAIL this gate, not hang it.
announced=0
for _ in $(seq 1 60); do
  grep -q '^ANNOUNCED=' "$WORK/registrar.log" && { announced=1; break; }
  kill -0 "$DART_PID" 2>/dev/null || break
  sleep 0.5
done

if [ "$announced" = "0" ]; then
  printf '  \033[31mFAIL\033[0m our registrar never announced itself\n'
  cat "$WORK/registrar.log" >&2
  exit 1
fi
printf '  our registrar: %s\n' \
  "$(grep -oE '^TOPIC_PATH=.*' "$WORK/registrar.log" | head -1 | cut -d= -f2-)"

# The whole gate, in one line: somebody else's suite, unchanged.
tool/observer_acceptance.sh
ACCEPTANCE_RC=$?

# A registrar that CRASHED while serving fails this gate even if the assertions
# passed — a process that dies at the end of a run would have died in the
# middle of a longer one, and the suite would not have noticed.
if ! kill -0 "$DART_PID" 2>/dev/null; then
  printf '  \033[31mFAIL\033[0m our registrar did not survive the run\n'
  tail -20 "$WORK/registrar.log" >&2
  exit 1
fi

case "$ACCEPTANCE_RC" in
  0)
    printf '\n  \033[32mPASS\033[0m the island'"'"'s own acceptance suite passes against a Dart registrar\n'
    exit 0
    ;;
  2|3)
    printf '  \033[31mFAIL\033[0m the acceptance suite could not run (rc %s)\n' "$ACCEPTANCE_RC"
    exit 1
    ;;
  *)
    printf '  \033[31mFAIL\033[0m the acceptance suite failed against a Dart registrar\n'
    exit 1
    ;;
esac

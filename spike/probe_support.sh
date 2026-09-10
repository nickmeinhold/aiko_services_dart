# Shared driver plumbing for the live-broker probes.
#
# WHY THIS FILE EXISTS. The will probe and the lease probe were near-duplicates,
# and across three cage-match rounds they drifted apart three separate times —
# each round finding a property fixed in one and missing in its twin:
#
#   * `mosquitto_pub` checked in the will probe, not the lease probe
#   * the hardcoded host fixed in the lease probe, not the will probe
#   * the "names a cadence nothing measured" green fixed in verify.sh, not in
#     the probe's own PASS line
#
# Each was fixed where a reviewer pointed and left standing in the other copy.
# That is a class, and the remedy for a class is not nine more patches nor a
# drift-gate keeping two copies honest — it is one copy. Sourced, not templated:
# a property fixed here is fixed for every probe by construction.
#
# Usage: source "$(dirname "$0")/../probe_support.sh"

# Both binaries, not just the one this probe happens to call first. The
# reachability check publishes, so verifying only the subscriber let a machine
# with sub-but-not-pub report "no broker" for a broker that was fine — and the
# driver then records a live-rig failure for a missing host dependency.
#   2 = a harness dependency is missing on this machine
#   3 = the rig is not reachable
probe_require_tools() {
  local bin
  for bin in mosquitto_sub mosquitto_pub; do
    command -v "$bin" >/dev/null || {
      echo "$bin not found — cannot observe the broker. A skip is NOT a pass." >&2
      exit 2
    }
  done
}

probe_require_broker() {  # $1 host $2 port
  # BOUNDED. This is the first current the script sends, and an unbounded
  # mosquitto_pub against a host that drops SYN (a wrong overlay, a firewall,
  # an AIKO_MQTT_HOST aimed at a black hole) sits in TCP's long dark until the
  # whole gate looks dead. The file that defines a bounding primitive had no
  # spark gap on its own first wire.
  #
  # Bounded with probe_run_bounded rather than a flag: `-W` is mosquitto_SUB's
  # timeout and mosquitto_PUB has no such option — passing it makes pub exit 1
  # with "Unknown option", which this function then reports as "no broker",
  # turning a reachable rig into a failed gate. (Measured: it did exactly that.)
  # Assuming a flag carries across sibling tools is the same twin-instance
  # mistake these probes have already made three times.
  local out rc
  out=$(mktemp)
  rc=$(probe_run_bounded 8 "$out" \
    mosquitto_pub -h "$1" -p "$2" -t 'aiko/probe/_reachability' -m x)
  rm -f "$out"
  [ "$rc" = "0" ] || {
    if [ "$rc" = "75" ]; then
      echo "broker at $1:$2 did not answer within 8s — it is unreachable or black-holing. A skip is NOT a pass." >&2
    else
      echo "no broker at $1:$2 — bring the island rig up. A skip is NOT a pass." >&2
    fi
    exit 3
  }
}

# Start a subscriber whose lifetime WE own, and echo its pid.
#
# Never a subshell under `timeout`: that hides the child's pid, so the log gets
# read while mosquitto_sub still holds it — a userspace buffer rather than what
# the broker sent — and a slow probe can outlive the fuse and lose the very
# message it was watching for.
probe_watch() {  # $1 host $2 port $3 topic $4 outfile ; echoes pid
  mosquitto_sub -h "$1" -p "$2" -t "$3" -v > "$4" 2>&1 &
  echo $!
}

# Stop a subscriber AND WAIT for it, so its stdio is flushed before the file is
# read. `kill` alone leaves the read racing the flush.
probe_unwatch() {  # $1 pid
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

# Run a Dart probe under an EXTERNAL deadline, and echo its exit code.
#
# External on purpose. An in-process Dart `Timer` cannot bound two of the three
# ways this actually hangs: `dart run` stalling in COMPILE before `main` is
# entered, and an isolate blocked in a native connect where no timer gets to
# fire. A watchdog that shares a fate with the thing it watches is not a
# watchdog — the instrument has to be able to fail differently from the checked.
#
# Implemented without `timeout(1)`, which is absent on a default macOS host.
#
# Exit 75 (EX_TEMPFAIL) means "the harness stalled", which is a different fact
# from "the protocol failed", and the caller must be able to say which.
probe_run_bounded() {  # $1 budget-seconds  $2 outfile  $3... command
  local budget=$1 out=$2; shift 2
  "$@" > "$out" 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$budget" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "WATCHDOG: probe exceeded ${budget}s — refusing to hang a gate" >> "$out"
      echo 75
      return
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  echo $?
}

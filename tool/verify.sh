#!/usr/bin/env bash
#
# Everything that can falsify this package, in one command.
#
# WHY THIS IS A SCRIPT AND NOT A CI WORKFLOW
# ------------------------------------------
# This script is not an argument against CI. It predates the decision to open the
# repo to contributors, and a gate does become worth its latency once a second
# party can push -- see the CI restoration task.
#
# The gap CI would actually have filled is a *scheduler*: the differential-fuzz
# rigs are the instruments that can genuinely surprise you — the `\s` divergence
# was 3604 mismatches that 63 green golden vectors ran straight past — and they
# only run when somebody remembers. This script is the cheapest thing that makes
# "run everything" one command instead of a memory.
#
# Interop is now HALF covered, and the halves are not symmetric. A Dart consumer
# reading a live Python producer is exercised by tool/observer_acceptance.sh
# below, against a real island. The other direction — a real Python ECConsumer
# reading a live Dart share snapshot (ADR-0001 §3 test 12) — still needs a Dart
# service to point it at, which is ADR-0002's Actor. Building the trigger before
# the thing it fires on is how a workflow ends up never having run while its
# silence reads as safety.
#
# Usage:
#   tool/verify.sh              # cheap checks + fuzz + the island run, if available
#   tool/verify.sh --quick      # cheap checks only
#   AIKO_SERVICES=/path tool/verify.sh
set -uo pipefail

cd "$(dirname "$0")/.."
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
REF="${AIKO_SERVICES:-$HOME/git/orgs/aiko/aiko_services}"
FAILED=()

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$1"; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "$1"; FAILED+=("$1"); }

step "analyze (strict-casts / strict-inference / strict-raw-types)"
# --fatal-infos: bare `dart analyze` exits 0 on info-level issues, so every
# lint in analysis_options.yaml was configured and unenforceable. Proven by
# this gate reporting ALL CHECKS PASSED over two live lints (PR #13). The
# repo is clean at info level, so this costs nothing today.
dart analyze --fatal-infos && ok "no issues" || bad "dart analyze"

step "format"
# example/ and spike/unsubscribe/ are in this package and in this gate. `example/`
# holds a real program (the bus observer) and `spike/unsubscribe/` holds the probe
# that measured a live defect — both are source, not scratch. The other spike/
# directories are separate packages with their own resolution and are excluded for
# that reason, not because they read untidily.
FORMAT_DIRS="lib/ test/ tool/ benchmark/ example/ spike/unsubscribe/"
# shellcheck disable=SC2086
if dart format --output=none --set-exit-if-changed $FORMAT_DIRS; then
  ok "formatted"
else
  bad "dart format (run: dart format $FORMAT_DIRS)"
fi

step "tests"
dart test && ok "suite green" || bad "dart test"

if [ "$QUICK" = "1" ]; then
  printf '\n--quick: skipped the differential fuzz, which is the part that can surprise you.\n'
else
  if [ ! -d "$REF" ]; then
    printf '\n\033[33mSKIPPED the fuzz rigs: no aiko_services at %s\033[0m\n' "$REF"
    printf 'Set AIKO_SERVICES=/path/to/aiko_services. A skip is NOT a pass.\n'
    bad "fuzz rigs did not run (reference not found)"
  else
    step "encoder differential fuzz vs CPython parser.py"
    if python3 tool/generate_fuzz_corpus.py /tmp/verify-fuzz.json "$REF" >/dev/null 2>&1 \
       || python3 tool/generate_fuzz_corpus.py /tmp/verify-fuzz.json >/dev/null 2>&1; then
      dart run tool/fuzz_generate_parity.dart /tmp/verify-fuzz.json && ok "encoder parity" \
        || bad "encoder differential fuzz"
    else
      bad "could not build the encoder corpus (is $REF importable by python3?)"
    fi

    step "decoder differential fuzz vs CPython parser.py"
    if python3 tool/generate_parse_fuzz_corpus.py /tmp/verify-pfuzz.json 20000 "$REF" >/dev/null 2>&1 \
       || python3 tool/generate_parse_fuzz_corpus.py /tmp/verify-pfuzz.json 20000 >/dev/null 2>&1; then
      dart run tool/fuzz_parse_parity.dart /tmp/verify-pfuzz.json && ok "decoder parity" \
        || bad "decoder differential fuzz"
    else
      bad "could not build the decoder corpus (is $REF importable by python3?)"
    fi
  fi
fi

ISLAND_RAN=0
if [ "$QUICK" = "1" ]; then
  :
elif docker inspect -f '{{.State.Running}}' aiko-chat-1 2>/dev/null | grep -q true; then
  step "six-verb acceptance against a live Python island"
  if tool/observer_acceptance.sh; then
    ISLAND_RAN=1
    ok "connect / discover / subscribe / receive / leave / recover"
  else
    bad "observer acceptance against a live island"
  fi
else
  printf '\n\033[33mSKIPPED the island run: no aiko-chat-1 container.\033[0m\n'
  printf 'Bring the rig up (see tool/island-rig/compose.dev-ports.yml), then re-run.\n'
  # A skip is NOT a pass, and until this line it was one: the message said so
  # while the script went on to print ALL CHECKS PASSED and exit 0 — the same
  # silence-reads-as-success shape the six verbs exist to hunt, committed by the
  # thing doing the hunting. Now it fails, exactly as the fuzz rigs already do
  # when the reference checkout is missing. `--quick` remains the escape hatch
  # for a machine that legitimately cannot run either.
  bad "island acceptance did not run (no aiko-chat-1 container)"
fi

printf '\n'
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '\033[32mALL CHECKS PASSED\033[0m\n'
  printf 'Scope: parity with this reference, not correctness. Not covered — a real\n'
  printf 'Python ECConsumer reading a live Dart share snapshot (ADR-0001 §3 test 12).\n'
  if [ "$ISLAND_RAN" = "0" ]; then
    printf '\033[33mAlso not covered this run: the six-verb island acceptance did not run.\033[0m\n'
  fi
  exit 0
fi
printf '\033[31m%d CHECK(S) FAILED:\033[0m\n' "${#FAILED[@]}"
printf '  - %s\n' "${FAILED[@]}"
exit 1

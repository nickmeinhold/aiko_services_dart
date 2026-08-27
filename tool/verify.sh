#!/usr/bin/env bash
#
# Everything that can falsify this package, in one command.
#
# WHY THIS IS A SCRIPT AND NOT A CI WORKFLOW
# ------------------------------------------
# The cheap checks (analyze, format, test) run in ~2s and are run constantly, so
# a CI *gate* would report what is already known, minutes later, to the only
# person who could have broken it. A gate needs a second party; this repo has
# none yet.
#
# The gap CI would actually have filled is a *scheduler*: the differential-fuzz
# rigs are the instruments that can genuinely surprise you — the `\s` divergence
# was 3604 mismatches that 63 green golden vectors ran straight past — and they
# only run when somebody remembers. This script is the cheapest thing that makes
# "run everything" one command instead of a memory.
#
# When there is a running Dart service to point a real Python ECConsumer at
# (ADR-0002's Actor), the interop check becomes worth real infrastructure. Not
# before: building the trigger before the thing it fires on is how a workflow
# ends up never having run while its silence reads as safety.
#
# Usage:
#   tool/verify.sh              # cheap checks + fuzz, if the reference is found
#   tool/verify.sh --quick      # cheap checks only
#   AIKO_SERVICES=/path tool/verify.sh
set -uo pipefail

cd "$(dirname "$0")/.."
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
REF="${AIKO_SERVICES:-$HOME/git/orgs/aiko/aiko_services}"
# The decoder corpus is seeded. Override to explore a different slice of the
# input space: AIKO_FUZZ_SEED=12345 tool/verify.sh
SEED="${AIKO_FUZZ_SEED:-20260825}"
# How many decoder cases to request. Passed to BOTH the generator and the rig's
# floor, so the two cannot drift apart.
DECODER_CASES="${AIKO_FUZZ_CASES:-20000}"
ENCODER_CASES="${AIKO_FUZZ_ENCODER_CASES:-40000}"

# Checked before any work, so a misconfigured run gets no further than its
# configuration and --quick fails too. A count of 0 would leave the generator
# emitting only its seed case and the floor at 0 — a whole differential fuzz
# reduced to one comparison, under ALL CHECKS PASSED.
for _knob in DECODER_CASES ENCODER_CASES SEED; do
  eval "_v=\$$_knob"
  case "$_v" in
    ''|*[!0-9]*)
      printf '\033[31mrefusing to run: %s=%s is not a non-negative integer\033[0m\n' "$_knob" "$_v" >&2
      exit 2;;
  esac
done
# How much of a requested corpus may be unusable before the run stops meaning
# anything. The rigs' floor is REQUEST minus this, computed before the corpus
# exists so it cannot be derived from what it checks.
# Measured rates the budgets allow headroom over: encoder ~100% comparable,
# decoder ~75% (4915 of 20000 skipped as RFC-0001 s8 errata).
ENCODER_ERRATA_BUDGET_PCT="${AIKO_ENCODER_ERRATA_BUDGET_PCT:-10}"
DECODER_ERRATA_BUDGET_PCT="${AIKO_DECODER_ERRATA_BUDGET_PCT:-40}"

if [ "$ENCODER_CASES" -lt 1000 ] || [ "$DECODER_CASES" -lt 1000 ]; then
  printf '\033[31mrefusing to run: fuzz counts must be >= 1000 (got encoder=%s decoder=%s)\033[0m\n' \
    "$ENCODER_CASES" "$DECODER_CASES" >&2
  printf 'A differential fuzz over a handful of cases is a green that means nothing.\n' >&2
  exit 2
fi
FAILED=()

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$1"; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "$1"; FAILED+=("$1"); }

# .dart_tool is gitignored, and `dart analyze` walks into the spike packages —
# without this a fresh clone fails at step one on unresolved imports.
step "resolve dependencies (root + spikes)"
BOOTSTRAP_OK=1
dart pub get >/dev/null 2>&1 || BOOTSTRAP_OK=0
for spike in spike/*/; do
  (cd "$spike" && dart pub get >/dev/null 2>&1) || BOOTSTRAP_OK=0
done
[ "$BOOTSTRAP_OK" = "1" ] && ok "resolved" || bad "dart pub get (root or a spike package)"

step "analyze (strict-casts / strict-inference / strict-raw-types)"
dart analyze && ok "no issues" || bad "dart analyze"

step "format"
if dart format --output=none --set-exit-if-changed lib/ test/ tool/ benchmark/ spike/; then
  ok "formatted"
else
  bad "dart format (run: dart format lib/ test/ tool/ benchmark/ spike/)"
fi

step "tests"
dart test && ok "suite green" || bad "dart test"

# Separate pub packages, so the root `dart test` never discovers them while
# `dart analyze` above does.
for spike in spike/*/; do
  step "tests: $spike"
  if (cd "$spike" && dart test); then
    ok "$spike green"
  else
    bad "dart test in $spike"
  fi
done

if [ "$QUICK" = "1" ]; then
  printf '\n--quick: skipped the differential fuzz, which is the part that can surprise you.\n'
else
  if [ ! -d "$REF" ]; then
    printf '\n\033[33mSKIPPED the fuzz rigs: no aiko_services at %s\033[0m\n' "$REF"
    printf 'Set AIKO_SERVICES=/path/to/aiko_services. A skip is NOT a pass.\n'
    bad "fuzz rigs did not run (reference not found)"
  elif ! REF_SHA="$(git -C "$REF" rev-parse HEAD 2>/dev/null)"; then
    printf '\n\033[33mSKIPPED the fuzz rigs: %s is not a git checkout\033[0m\n' "$REF"
    printf 'The oracle must be pinnable to a ref. A skip is NOT a pass.\n'
    bad "fuzz rigs did not run (reference is not a git repo)"
  else
    # $REF is a working tree somebody else edits; it moved across four branches
    # in one evening while these rigs ran against it. Snapshot a pinned ref so
    # the oracle is git-derivable rather than whatever is checked out now.
    # mktemp failing assigns an EMPTY string, which `set -u` does not catch
    # because the variable IS set — and `tar -x -C ""` extracts into the cwd.
    SNAPSHOT_OK=1
    SNAPSHOT="$(mktemp -d "${TMPDIR:-/tmp}/aiko-oracle.XXXXXX")"
    CORPUS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiko-corpus.XXXXXX")"
    if [ -z "$SNAPSHOT" ] || [ ! -d "$SNAPSHOT" ] || [ -z "$CORPUS_DIR" ] || [ ! -d "$CORPUS_DIR" ]; then
      bad "could not create temp dirs for the oracle snapshot / corpora"
      printf '\n\033[31m   refusing to continue: an empty temp path would extract into the working tree\033[0m\n'
      SNAPSHOT_OK=0
      CORPUS_DIR="${CORPUS_DIR:-/nonexistent}"
    fi
    trap 'rm -rf "$SNAPSHOT" "$CORPUS_DIR"' EXIT
    if ! git -C "$REF" archive "$REF_SHA" | tar -x -C "$SNAPSHOT"; then
      bad "could not snapshot the oracle at $REF_SHA"
      SNAPSHOT_OK=0
    fi
    printf '\n\033[2m   oracle: %s @ %s (snapshot, not the live tree)\033[0m\n' \
      "$REF" "${REF_SHA:0:12}"
    # Printed so corpus isolation is OBSERVABLE rather than merely asserted: two
    # concurrent runs both passing proves little on its own, since the old fixed
    # paths could collide without failing. Two different dirs in two logs is the
    # discriminating evidence.
    printf '\033[2m   corpora: %s\033[0m\n' "$CORPUS_DIR"
    if [ -n "$(git -C "$REF" status --porcelain 2>/dev/null)" ]; then
      printf '\033[2m   note: that checkout has uncommitted changes; they are NOT in the snapshot\033[0m\n'
    fi
    if [ "$SNAPSHOT_OK" = "0" ]; then
      # No snapshot means no oracle, so the rigs below cannot mean anything.
      printf '\n\033[33m   skipping both fuzz rigs: no oracle snapshot. A skip is NOT a pass.\033[0m\n'
    else
    step "encoder differential fuzz vs CPython parser.py"
    # The generator prints COMPARABLE=<n>: how many cases carry an oracle result
    # and can therefore actually be compared. Passing it back as the rig's floor
    # makes the expected work a fact declared by the producer, replacing a 0.5
    # ratio whose meaning moved whenever the generator did.
    ENC_FLOOR=$(( ENCODER_CASES * (100 - ENCODER_ERRATA_BUDGET_PCT) / 100 ))
    if ENC_OUT=$(python3 tool/generate_fuzz_corpus.py "$CORPUS_DIR/encoder.json" "$SNAPSHOT" "$ENCODER_CASES"); then
      ENC_COMPARABLE=$(printf '%s\n' "$ENC_OUT" | sed -n 's/^COMPARABLE=//p')
      dart run tool/fuzz_generate_parity.dart "$CORPUS_DIR/encoder.json" "$ENCODER_CASES" "$ENC_FLOOR" \
        && ok "encoder parity ($ENCODER_CASES requested, floor $ENC_FLOOR, $ENC_COMPARABLE comparable)" \
        || bad "encoder differential fuzz"
    else
      bad "could not build the encoder corpus from the oracle snapshot"
    fi

    step "decoder differential fuzz vs CPython parser.py"
    DEC_FLOOR=$(( DECODER_CASES * (100 - DECODER_ERRATA_BUDGET_PCT) / 100 ))
    if DEC_OUT=$(python3 tool/generate_parse_fuzz_corpus.py "$CORPUS_DIR/decoder.json" "$SNAPSHOT" "$DECODER_CASES" "$SEED"); then
      DEC_COMPARABLE=$(printf '%s\n' "$DEC_OUT" | sed -n 's/^COMPARABLE=//p')
      dart run tool/fuzz_parse_parity.dart "$CORPUS_DIR/decoder.json" "$DECODER_CASES" "$DEC_FLOOR" \
        && ok "decoder parity (seed $SEED, floor $DEC_FLOOR, $DEC_COMPARABLE comparable)" \
        || bad "decoder differential fuzz (seed $SEED)"
    else
      bad "could not build the decoder corpus from the oracle snapshot"
    fi
    fi
  fi
fi

printf '\n'
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '\033[32mALL CHECKS PASSED\033[0m\n'
  printf 'Scope: parity with this reference, not correctness. Not covered — a real\n'
  printf 'Python ECConsumer reading a live Dart share snapshot (ADR-0001 §3 test 12).\n'
  exit 0
fi
printf '\033[31m%d CHECK(S) FAILED:\033[0m\n' "${#FAILED[@]}"
printf '  - %s\n' "${FAILED[@]}"
exit 1

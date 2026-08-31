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
# Requested, not read back. Passed to the generator AND to the rig as its floor,
# so a generator that silently produced fewer cases trips the gate. Deriving it
# from the written corpus (the previous shape) compared a file against its own
# length — theatre that could only fail if two JSON parsers disagreed.
ENCODER_CASES="${AIKO_FUZZ_ENCODER_CASES:-40000}"

# Validate the knobs BEFORE any work, and refuse non-positive counts. A
# configurable floor that accepts zero is entropy with a command-line
# interface: AIKO_FUZZ_ENCODER_CASES=0 made the generator emit its single
# seed case, passed 0 as the rig's floor so `cases.length < minimumCases`
# could not fire, and the whole gate reported ALL CHECKS PASSED over one
# empty-string comparison. Checked here rather than at the point of use so
# --quick fails too: a misconfigured run should not get further than the
# configuration.
for _knob in DECODER_CASES ENCODER_CASES SEED; do
  eval "_v=\$$_knob"
  case "$_v" in
    ''|*[!0-9]*)
      printf '\033[31mrefusing to run: %s=%s is not a non-negative integer\033[0m\n' "$_knob" "$_v" >&2
      exit 2;;
  esac
done
# ERRATA BUDGET: how much of a requested corpus is allowed to be unusable
# before the run stops meaning anything. The floor is then REQUEST minus this
# budget — a number chosen by the caller, computed before the corpus exists,
# and therefore independent of it.
#
# The previous shape asked the generator to declare how many cases it had made
# comparable and used that as the floor. It looked rigorous and could not fail:
# the rig's `checked` IS the count the generator reported, both derived from one
# file, so the comparison held by construction. It was also a REGRESSION on what
# it replaced — a 0.5 ratio is a badly chosen constant, but it is an independent
# one, and independence is the property that matters here.
#
# Budgets are set against measured rates with headroom, and the measurement is
# named so a future reader can re-check it rather than trust it: the encoder
# corpus is normally 100% comparable, the decoder ~75% (4915 of 20000 skipped as
# reference errata, RFC-0001 s8). Exceeding a budget is a real signal — the
# oracle started throwing, or the errata classification widened — and should
# stop the run rather than quietly shrink the evidence.
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

# A fresh clone has no .dart_tool anywhere (it is gitignored), and the spike
# packages are separate packages that `dart analyze` DOES walk into. Without
# this, a clean checkout fails at step one with 27 unresolved-import errors,
# which meant "verify.sh green" was a fact about one laptop rather than about
# the commit.
step "resolve dependencies (root + spikes)"
BOOTSTRAP_OK=1
# Captured and replayed on failure, not discarded. Swallowing a mutating
# command's error channel turns "resolve dependencies FAIL" into a red with no
# cause attached — survivable at a laptop where you re-run it by hand, useless
# in a CI log, which is the only thing anyone will read.
bootstrap() {
  local out
  if ! out=$(cd "$1" && dart pub get 2>&1); then
    printf '%s\n' "$out" >&2
    BOOTSTRAP_OK=0
  fi
}
bootstrap .
for spike in spike/*/; do
  bootstrap "$spike"
done
[ "$BOOTSTRAP_OK" = "1" ] && ok "resolved" || bad "dart pub get (root or a spike package)"

step "analyze (strict-casts / strict-inference / strict-raw-types)"
dart analyze && ok "no issues" || bad "dart analyze"

step "format"
# spike/ included. analyze walks the spikes (that was the 27-import surprise on
# a fresh clone) and the suites now run there too, so leaving format out kept
# them half-in — the one option this PR already called clearly wrong.
if dart format --output=none --set-exit-if-changed lib/ test/ tool/ benchmark/ spike/; then
  ok "formatted"
else
  bad "dart format (run: dart format lib/ test/ tool/ benchmark/ spike/)"
fi

step "tests"
dart test && ok "suite green" || bad "dart test"

# The spike packages are separate pub packages, so the root `dart test` never
# discovers them, while `dart analyze` above DOES cover them. Half-in is the
# worst of the two: thirteen tests — including the ones pinning the
# mixin-composition and isolate deep-copy premise corrections — were passing
# unobservedly, and nobody would have learned if they broke.
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
    # Oracle against a SNAPSHOT of a pinned ref, never the live checkout.
    #
    # That directory is somebody's working tree. It moved across four branches
    # in one evening while these rigs were being run against it, and no result
    # recorded which. We got away with it — parser.py happened to be identical
    # on all four — but which of those two outcomes you get is a fact about the
    # environment, not about this code, and it can change with nothing here
    # changing.
    #
    # `git archive` makes the oracle git-derivable by construction. Recording
    # the SHA would only report the problem, and would need somebody to compare
    # the number afterwards.
    # One temp dir for the oracle snapshot AND both corpora. The corpora used
    # fixed names under /tmp, so two concurrent runs of this script overwrote
    # each other between generation, counting and replay — a false red at best,
    # and at worst a green earned against another run's oracle or seed. This
    # repo demonstrably has concurrent sessions.
    # mktemp failing (disk full, bad TMPDIR) assigns an EMPTY string, which
    # `set -u` does not catch because the variable IS set. `tar -x -C ""` then
    # extracts the reference into the current working tree, and
    # "$CORPUS_DIR/encoder.json" becomes "/encoder.json". Refuse rather than
    # guess, the same way the generators refuse to guess an oracle.
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
    # No `|| <same command without the reference>` fallback here any more. That
    # shape hid a caller/callee disagreement: the primary invocation failed on
    # every run and the fallback quietly rescued it, so the disagreement never
    # surfaced. A fallback that absorbs a mismatch produces a green that means
    # nothing.
    if [ "$SNAPSHOT_OK" = "0" ]; then
      # Without a snapshot there is no oracle, so the fuzz steps below cannot
      # mean anything. Running them anyway reported the SAME failure three
      # times — once for the real cause and twice for its symptoms — with the
      # symptoms last and loudest. Worse, it left the run leaning on the
      # generators staying strict: soften them and this path becomes a fuzz
      # against a half-extracted tree.
      printf '\n\033[33m   skipping both fuzz rigs: no oracle snapshot. A skip is NOT a pass.\033[0m\n'
    else
    step "encoder differential fuzz vs CPython parser.py"
    # The generator prints COMPARABLE=<n>: how many cases carry an oracle result
    # and can therefore actually be compared. Passing it back as the rig's floor
    # makes the expected work a fact declared by the producer, replacing a 0.5
    # ratio whose meaning moved whenever the generator did.
    ENC_FLOOR=$(( ENCODER_CASES * (100 - ENCODER_ERRATA_BUDGET_PCT) / 100 ))
    if ENC_OUT=$(python3 tool/generate_fuzz_corpus.py "$CORPUS_DIR/encoder.json" "$SNAPSHOT" "$ENCODER_CASES"); then
      # The generator's COMPARABLE line is a LOG, not the floor. The floor came
      # from the request above, before this corpus existed.
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

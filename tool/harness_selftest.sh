#!/usr/bin/env bash
#
# Can verify.sh go red?
#
# WHY THIS EXISTS
# ---------------
# verify.sh is the only gate this repo has. A gate that cannot fail is worse
# than no gate, because its green is read as evidence. Nothing in verify.sh's
# own output distinguishes "checked everything, found nothing" from "checked
# nothing" — and on 2026-08-26 two of its instruments turned out to report
# success over zero work.
#
# So this script does not inspect verify.sh. Inspection is what fails: a
# harness examined for whether it can fail tends to look like it can, because
# you read its structure and infer capability. Instead each arm PLANTS a known
# defect, runs the real gate, and asserts it goes red. An arm that stays green
# names a blind instrument.
#
# The ordering matters and is the whole discipline: build the arm that MUST go
# red before trusting any green.
#
# WHAT A RESULT MEANS, AND DOES NOT
# ---------------------------------
# All arms red is a FLOOR, not a distribution. It shows the gate detects THESE
# defects — the ones somebody thought of. It is not evidence that it detects an
# arbitrary one. Add an arm whenever a real defect gets through.
#
# Runs in a throwaway git worktree; your working tree is never modified.
#
# Usage:
#   tool/harness_selftest.sh            # every arm; exit 0 only if all went red
#   tool/harness_selftest.sh --quick    # skips the arms needing the Python
#                                       # reference, and therefore ALWAYS EXITS 1
#
# --quick exiting non-zero is deliberate and differs from `verify.sh --quick`,
# which exits 0. The two are answering different questions. verify.sh --quick
# says "the cheap checks passed", a claim it can honestly make about the checks
# it ran. This script's claim is "the gate can go red", and that claim is not
# separable per-arm: the arms it skips are the ones covering the differential
# rigs and the oracle wiring, so a partial run cannot support the only sentence
# this script exists to say. It reports what ran, then refuses to exit 0.
# A skip is not a pass.
set -uo pipefail

cd "$(dirname "$0")/.."
REPO="$(pwd)"
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/harness-selftest.XXXXXX")"
RESULTS=(); BLIND=0; SKIPPED=0; VOID=0; WRONGREASON=0

# cd out of the probe BEFORE dissolving it: `git worktree remove` often refuses
# while the shell's cwd is inside the worktree, and the rm -rf then leaves a
# stale worktree registration in the parent repo.
cleanup() {
  cd "$REPO" 2>/dev/null || cd /
  git -C "$REPO" worktree remove --force "$WORK/probe" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

note() { printf '\033[2m   %s\033[0m\n' "$1"; }
red()   { RESULTS+=("  \033[32mRED\033[0m    $1"); }
blind() { RESULTS+=("  \033[31mBLIND\033[0m  $1  <- gate stayed green under a defect it should catch"); BLIND=$((BLIND+1)); }
# A skip is not a pass: an arm that did not run says nothing about the
# instrument it was built to test.
skip()  { RESULTS+=("  \033[33mSKIP\033[0m   $1  <- DID NOT RUN"); SKIPPED=$((SKIPPED+1)); }
# An arm that went red for a reason OTHER than the one it names has not tested
# the instrument it claims to test. Distinct from BLIND (gate saw nothing) and
# from VOID (plant did nothing): here the gate DID fail, on something else.
wrong() { RESULTS+=("  \033[31mWRONG\033[0m  $1  <- went red, but not on the check it names"); WRONGREASON=$((WRONGREASON+1)); }

# The probe is built from HEAD, NOT from your working tree. That is deliberate:
# it makes the result a fact about a commit, which is what everybody else gets.
# It is also the easiest thing in here to misread, so it says so out loud —
# running this with uncommitted fixes will faithfully report the state of the
# last commit, and the arms will look unchanged.
PROBE_SHA="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
printf '\033[1m== building an isolated probe worktree at %s\033[0m\n' "$PROBE_SHA"
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
  printf '\033[33m   note: you have uncommitted changes; they are NOT under test\033[0m\n'
fi
git -C "$REPO" worktree add --detach "$WORK/probe" HEAD >/dev/null 2>&1 || {
  printf 'could not create a worktree; is this a git repo with a commit?\n'; exit 2; }
cd "$WORK/probe"
dart pub get >/dev/null 2>&1
for d in spike/*/; do (cd "$d" && dart pub get >/dev/null 2>&1); done

# A baseline that is not green makes every arm meaningless: an arm would go red
# for the pre-existing reason rather than the planted one.
printf '\033[1m== baseline must be green before any arm runs\033[0m\n'
if ! tool/verify.sh --quick >"$WORK/baseline.log" 2>&1; then
  printf '\033[31mBASELINE IS NOT GREEN — arms would be meaningless. Fix this first:\033[0m\n'
  tail -20 "$WORK/baseline.log"; exit 2
fi
note "baseline green"

# arm <name> <plant-fn> <command...>
#
# The plant is verified to have changed the tree first: every perl plant here
# is one reformat of its target line away from being a silent no-op.
# `plant_nothing` is the deliberate exception — the degenerate-corpus arms plant
# nothing and pass the corpus as an argument.
# arm_expect <name> <plant-fn> <expected-failure-substring> <command...>
#
# Asserts the gate went red ON THE CHECK THE ARM NAMES. `dart test` runs before
# the fuzz rigs and catches codec bugs too, so a full-gate arm would otherwise
# report RED whether or not the rig it names works.
arm_expect() {
  local name="$1"; local plant="$2"; local expect="$3"; shift 3
  git checkout -- . >/dev/null 2>&1
  git clean -fdq -e .dart_tool -e 'spike/*/.dart_tool' >/dev/null 2>&1
  "$plant"
  if [ "$plant" != "plant_nothing" ] && [ -z "$(git status --porcelain)" ]; then
    RESULTS+=("  \033[31mVOID\033[0m   $name  <- $plant CHANGED NOTHING; the arm never tested anything")
    VOID=$((VOID+1)); return
  fi
  if "$@" >"$WORK/arm.log" 2>&1; then
    blind "$name"
  elif grep -q "$expect" "$WORK/arm.log"; then
    red "$name"
  else
    wrong "$name (expected a failure matching: $expect)"
  fi
  git checkout -- . >/dev/null 2>&1
  git clean -fdq -e .dart_tool -e 'spike/*/.dart_tool' >/dev/null 2>&1
}

arm() {
  local name="$1"; local plant="$2"; shift 2
  git checkout -- . >/dev/null 2>&1
  git clean -fdq -e .dart_tool -e 'spike/*/.dart_tool' >/dev/null 2>&1
  "$plant"
  if [ "$plant" != "plant_nothing" ] && [ -z "$(git status --porcelain)" ]; then
    RESULTS+=("  \033[31mVOID\033[0m   $name  <- $plant CHANGED NOTHING; the arm never tested anything")
    VOID=$((VOID+1))
    return
  fi
  if "$@" >"$WORK/arm.log" 2>&1; then blind "$name"; else red "$name"; fi
  git checkout -- . >/dev/null 2>&1
  git clean -fdq -e .dart_tool -e 'spike/*/.dart_tool' >/dev/null 2>&1
}

plant_type_error()  { printf '\nint _selftestTypeError() { String s = 42; return s; }\n' >> lib/src/codec/s_expression.dart; }
plant_bad_format()  { printf '\n\nvoid   _selftestFormat (  ) {   }\n' >> lib/src/codec/s_expression.dart; }
plant_failing_test() { cat > test/selftest_planted_test.dart <<'EOF'
import 'package:test/test.dart';
void main() => test('planted by harness_selftest: MUST fail', () => expect(1, equals(2)));
EOF
}
# One arm per spike package, generated from the packages that exist — guarding
# the set rather than one representative path.
plant_failing_spike_test_in() {
  cat > "$1/test/selftest_planted_test.dart" <<'EOF'
import 'package:test/test.dart';
void main() => test('planted by harness_selftest: MUST fail', () => expect(1, equals(2)));
EOF
}
# The real historical defect: RFC-0001's code-points-vs-UTF-16 length prefix,
# which 63 green golden vectors ran straight past. If the fuzz rigs cannot see
# this one, they cannot see the class they were built for.
plant_codepoint_bug() {
  perl -0pi -e "s/element = '\\\$\{_codePointCount\(element\)\}:\\\$element';/element = '\\\${element.length}:\\\$element';/" \
    lib/src/codec/s_expression.dart
}
# Decode-side mirror of the encoder plant: consume UTF-16 units instead of code
# points. Gives the parse rig a real defect to catch, where its only other arms
# are meter checks (empty / all-errata corpora).
plant_decoder_codepoint_bug() {
  perl -0pi -e 's/\Qend = _codePointEnd(s, end);\E/end = end + 1;/' \
    lib/src/codec/s_expression.dart
}

# Breaks the oracle WIRING rather than the code under test: the argument order
# that shipped, with the reference path in the seed slot.
plant_broken_oracle_wiring() {
  perl -0pi -e 's/"\$CORPUS_DIR\/decoder\.json" "\$SNAPSHOT" "\$DECODER_CASES" "\$SEED"/"\$CORPUS_DIR\/decoder.json" "\$DECODER_CASES" "\$SNAPSHOT"/' \
    tool/verify.sh
}
# Rejects payloads the reference decodes, with a message no RejectCause class
# matches — so it lands in RejectCause.other and the unclassified gate must fire.
plant_unclassifiable_rejection() {
  perl -0pi -e "s/\Q(String, Object) parse(String payload) {\E/(String, Object) parse(String payload) {\n  if (payload.contains('q')) {\n    throw FormatException('selftest probe: no class for this', payload, 0);\n  }/" \
    lib/src/codec/s_expression.dart
}
plant_nothing() { :; }

printf '\033[1m== arms\033[0m\n'
arm "analyze catches a type error in lib/"            plant_type_error          dart analyze
arm "format catches misformatted lib/"                plant_bad_format          dart format --output=none --set-exit-if-changed lib/ test/ tool/ benchmark/
arm "dart test catches a failing test in test/"       plant_failing_test        dart test
arm "verify.sh propagates one failure to its exit"    plant_failing_test        tool/verify.sh --quick
for spike in spike/*/; do
  # shellcheck disable=SC2317
  eval "plant_$(basename "$spike" | tr -c 'a-zA-Z0-9' '_')() { plant_failing_spike_test_in '${spike%/}'; }"
  # Asserts the failure names THAT package's suite: spike tests sit before the
  # --quick branch today, and moving them behind it must fail loudly here.
  arm_expect "the gate catches a failing test in $spike" \
      "plant_$(basename "$spike" | tr -c 'a-zA-Z0-9' '_')" \
      "dart test in $spike" tool/verify.sh --quick
done

# A gate reporting success over zero work.
printf '[]' > "$WORK/empty.json"
# A knob that can hollow out the gate is a defect in the gate. Cheap because
# the validation happens before any work, so --quick reaches it.
arm_expect "the gate refuses a hollowed-out fuzz count" plant_nothing \
  "fuzz counts must be" env AIKO_FUZZ_ENCODER_CASES=0 tool/verify.sh --quick

arm "encoder fuzz refuses an empty corpus"            plant_nothing  dart run tool/fuzz_generate_parity.dart "$WORK/empty.json"
arm "decoder fuzz refuses an empty corpus"            plant_nothing  dart run tool/fuzz_parse_parity.dart "$WORK/empty.json"

if [ "$QUICK" = "1" ]; then
  skip "encoder fuzz catches the code-point length bug (--quick)"
else
  REF="${AIKO_SERVICES:-$HOME/git/orgs/aiko/aiko_services}"
  if ! REF_SHA="$(git -C "$REF" rev-parse HEAD 2>/dev/null)"; then
    skip "encoder fuzz catches the code-point length bug (no git reference at $REF)"
  else
    # Same discipline as verify.sh: oracle a snapshot of a pinned ref, never
    # the live checkout.
    ORACLE="$WORK/oracle"; mkdir -p "$ORACLE"
    # The baseline at the top is --quick, which says nothing about the oracle
    # snapshot, the corpus builds or either rig. An already-red full gate would
    # paint every arm below RED with the plant doing no work.
    printf '\033[1m== full-gate baseline must be green before the full arms run\033[0m\n'
    if ! tool/verify.sh >"$WORK/full-baseline.log" 2>&1; then
      printf '\033[31mFULL GATE IS ALREADY RED — the full arms below would be meaningless.\033[0m\n'
      sed 's/\x1b\[[0-9;]*m//g' "$WORK/full-baseline.log" | tail -15
      exit 2
    fi
    note "full-gate baseline green"

    # THE ARMS THAT RUN THE REAL GATE, FULL. Slow (each is a complete verify.sh
    # including both differential rigs) and that is the price of covering the
    # half of the gate --quick cannot reach: the corpus builds, the oracle
    # snapshot, the argument wiring, and both rigs' verdicts AS verify.sh
    # invokes them rather than as this script invokes them directly.
    arm_expect "verify.sh (full) catches an encoder codec bug" \
      plant_codepoint_bug "encoder differential fuzz" tool/verify.sh
    arm_expect "verify.sh (full) catches a decoder codec bug" \
      plant_decoder_codepoint_bug "decoder differential fuzz" tool/verify.sh
    arm_expect "verify.sh (full) fails closed on broken oracle wiring" \
      plant_broken_oracle_wiring "could not build the decoder corpus" tool/verify.sh

    SELFTEST_CASES=4000
    # Two failure modes, two messages. Collapsing them into one `&&` chain
    # reported a bad oracle snapshot as a corpus-generation problem — the wrong
    # distinction to lose in a harness whose whole job is telling void work from
    # real work. verify.sh already separates these with SNAPSHOT_OK; this
    # mirrors it (Carnot's catch).
    if ! git -C "$REF" archive "$REF_SHA" | tar -x -C "$ORACLE"; then
      skip "encoder fuzz catches the code-point length bug (oracle snapshot of $REF_SHA failed)"
    elif python3 tool/generate_fuzz_corpus.py "$WORK/corpus.json" "$ORACLE" "$SELFTEST_CASES" >/dev/null 2>&1 \
         && python3 tool/generate_parse_fuzz_corpus.py "$WORK/decoder-corpus.json" "$ORACLE" "$SELFTEST_CASES" >/dev/null 2>&1; then
      note "oracle ${REF_SHA:0:12} (snapshot)"
      # Floor derived from what THIS arm asked the generator for, not a constant
      # that silently disagrees with it. A shrunken generator would otherwise
      # make this arm go red on the floor rather than on the code-point bug —
      # a false RED, which is the diabolical twin of a false green.
      # Run a rig DIRECTLY against a purpose-built corpus, so `dart test`
      # cannot supply the red on their behalf. Reverting the RejectCause key to
      # a string must make one of these go BLIND.
      python3 - "$WORK/corpus.json" "$WORK/nothing-comparable.json" <<'ERRATA_EOF'
import json, sys
cases = json.load(open(sys.argv[1]))
for c in cases:
    c.pop('w', None)
    c['err'] = 'ValueError'
json.dump(cases, open(sys.argv[2], 'w'))
ERRATA_EOF
      # The floor is caller-chosen (request minus a declared errata budget), so
      # unlike the COMPARABLE handshake it replaced, it CAN fail. This arm is
      # what makes that a property rather than a claim: a corpus whose
      # comparable count falls under the floor must be refused.
      python3 - "$WORK/corpus.json" "$WORK/under-floor.json" <<'UNDER_EOF'
import json, sys
cases = json.load(open(sys.argv[1]))
for c in cases[len(cases) // 4:]:
    c.pop('w', None)
    c['err'] = 'ValueError'
json.dump(cases, open(sys.argv[2], 'w'))
UNDER_EOF
      arm_expect "encoder fuzz refuses a corpus under the caller-chosen floor" \
        plant_nothing "need $(( SELFTEST_CASES * 90 / 100 ))" \
        dart run tool/fuzz_generate_parity.dart "$WORK/under-floor.json" "$SELFTEST_CASES" "$(( SELFTEST_CASES * 90 / 100 ))"

      arm_expect "encoder fuzz refuses a corpus with nothing comparable" \
        plant_nothing "carried an oracle result" \
        dart run tool/fuzz_generate_parity.dart "$WORK/nothing-comparable.json" "$SELFTEST_CASES" "$SELFTEST_CASES"

      arm_expect "decoder fuzz catches an UNCLASSIFIED rejection" \
        plant_unclassifiable_rejection "unclassified-rejections" \
        dart run tool/fuzz_parse_parity.dart "$WORK/decoder-corpus.json" 1 1

      arm_expect "encoder fuzz catches the code-point length bug" plant_codepoint_bug \
        "MISMATCH" \
        dart run tool/fuzz_generate_parity.dart "$WORK/corpus.json" "$SELFTEST_CASES" 1
    else
      skip "encoder fuzz catches the code-point length bug (could not build the corpus)"
    fi
  fi
fi

printf '\n\033[1m== results\033[0m\n'
for r in "${RESULTS[@]}"; do printf '%b\n' "$r"; done
printf '\n'
if [ "$WRONGREASON" -gt 0 ]; then
  printf '\033[31m%d ARM(S) WENT RED ON THE WRONG CHECK.\033[0m They did not test what they name.\n' "$WRONGREASON"
  printf 'A red that another gate produced is not evidence about this one.\n'
  exit 1
fi
if [ "$VOID" -gt 0 ]; then
  printf '\033[31m%d VOID ARM(S).\033[0m A plant changed nothing, so that arm tested nothing.\n' "$VOID"
  printf 'Fix the plant before reading any other result — a void arm is not evidence either way.\n'
  exit 1
fi
if [ "$BLIND" -gt 0 ]; then
  printf '\033[31m%d BLIND INSTRUMENT(S).\033[0m A planted defect did not turn the gate red.\n' "$BLIND"
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  printf '\033[33m%d ARM(S) DID NOT RUN.\033[0m The rest went red, which says nothing about these.\n' "$SKIPPED"
  if [ "$QUICK" = "1" ]; then
    printf 'This is --quick, so the omission was requested — and it is still not a pass.\n'
    printf 'The skipped arms are the ones covering the differential rigs and the oracle\n'
    printf 'wiring, so a partial run cannot support "the gate can go red". Exit 1 by design;\n'
    printf 'verify.sh --quick exits 0 because it makes a narrower claim about what it ran.\n'
  else
    printf 'A skip is not a pass. Re-run with the Python reference available.\n'
  fi
  exit 1
fi
printf '\033[32mEVERY ARM WENT RED.\033[0m The gate detects these defects.\n'
printf 'Scope: a floor, not a distribution — it says nothing about defects no arm plants.\n'
exit 0

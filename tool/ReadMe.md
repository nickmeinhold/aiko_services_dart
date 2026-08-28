# Codec conformance toolchain

Three instruments, in increasing order of how much they can surprise you.

## 1. Golden vectors — `generate_codec_fixtures.py`

Runs Aiko's real `parser.py` and records what it produces, into
`test/codec/fixtures/s_expression_golden.json`. Four categories:

| Category | Assertion |
|---|---|
| `generate` | Dart emits byte-identical output |
| `parse` | Dart decodes to the identical structure |
| `parse_errors` | the reference fails to decode, and Dart rejects cleanly |
| `divergences` | the reference **decodes** and Dart deliberately rejects |

That last category exists so a chosen divergence stays reviewable instead of
becoming undocumented drift. It records the reference's value alongside.

```
python3 tool/generate_codec_fixtures.py [PATH_TO_aiko_services]
```

Vectors are strong evidence and structurally blind in one way: they only cover
inputs somebody thought of, and the same person wrote the code. Both bugs found
in this codec's second hardening pass sat in the gap that leaves.

## 2. Encoder differential fuzz — `generate_fuzz_corpus.py` + `fuzz_generate_parity.dart`

```
python3 tool/generate_fuzz_corpus.py /tmp/fuzz.json
dart run tool/fuzz_generate_parity.dart /tmp/fuzz.json
```

Random atoms drawn from an alphabet loaded with every character the encoder
reasons about. Found the `\s` divergence: Dart's and Python's whitespace
classes are different sets, so the two implementations length-prefixed
different atoms. 3604 mismatches in 40k cases, invisible to 63 green vectors.
Now 0. See RFC-0001 §4.1, which enumerates the set rather than deferring to
`\s`.

## 3. Decoder differential fuzz — `generate_parse_fuzz_corpus.py` + `fuzz_parse_parity.dart`

```
python3 tool/generate_parse_fuzz_corpus.py /tmp/pfuzz.json 20000 [SEED]
dart run tool/fuzz_parse_parity.dart /tmp/pfuzz.json
```

Structurally random assemblies of the grammar's own tokens, plus raw character
soup. Outcomes are bucketed by **kind**, because they carry different weight:

| Bucket | Meaning | Gate |
|---|---|---|
| `value-differs` | both decode, values disagree | **must be 0** — silent wire divergence |
| `CRASHES` | Dart throws something other than `FormatException` | **must be 0** — escapes the declared contract |
| `ref-only-decodes` | Dart rejects what the reference accepts | allowed, but every instance must fall in a chosen class |
| `dart-only-decodes` | Dart accepts what the reference crashes on | allowed: reference crashes are §8 errata |
| `ref-errata-skipped` | reference returned `(list, int)` | excluded, see below |

Two lessons are built into that table. **Bucket by cause, not by count**: the
harness tallies *why* Dart rejected each `ref-only-decodes` case, and the
result is only acceptable because every one lands in a documented class —
1010 overlong length prefix (§8.2), 675 non-symbol command (§8.6), zero
`OTHER`. And **exclude the reference's own errata explicitly**: a stray
top-level `)` makes `parse` return from inside its loop, handing back
`(list, int)` instead of `(car, cdr)`. That is ~25% of a random corpus and
swamped every real finding until it was tagged and skipped.

Findings from the first run:

- **103 crashes.** A nested list in command position threw a raw `TypeError`
  from the `as String?` cast, escaping the "decodes, or throws
  `FormatException`" contract on untrusted wire input.
- **579 wrong values.** A `0:` in command position was silently flattened to
  `""`, conflating a null command with an empty one.
- Both are one **representation mismatch**: `parse` returns `(String, Object)`
  while the reference's `car` can be a String, a List, or None. A type that
  cannot express its domain fails as a crash on one input and a silent wrong
  answer on another. Resolved by rejecting (RFC-0001 §8.6).
- **A canonical-symbol boundary.** `RE_CANONICAL_SYMBOL` is `^(\d+):(.+)`, and
  that `.+` requires a character after the colon — so a bare trailing `0:` is
  the atom `"0:"`, not null. Now RFC-0001 §3.3.

Current baseline, four independent seeds, 20k cases each:

```
value-differs 0 | CRASHES 0 | ref-only-decodes ~1120-1184 | dart-only ~147-178
```

**Vary the seed before trusting a clean run.** One seed is an observation, not
a distribution.

## 4. Can the gate go red? — `harness_selftest.sh`

The three instruments above check the codec. This one checks *them*.

`verify.sh` is the only gate this repo has, and nothing in its output separates
"checked everything, found nothing" from "checked nothing". Two of its
instruments turned out to report success over zero work: both fuzz rigs exited 0
on an empty corpus, and the decoder's unclassified-rejection gate read a map key
that was never written, so its count was structurally always zero.

It does **not** inspect `verify.sh`. Inspection is what fails — a harness
examined for whether it *can* fail tends to look like it can, because you read
its structure and infer capability. Each arm instead plants a known defect, runs
the real gate, and asserts it goes red on the check the arm names.

```
tool/harness_selftest.sh            # every arm; exit 0 only if all went red
tool/harness_selftest.sh --quick    # skips the arms needing the Python
                                    # reference, and therefore always exits 1
```

Five verdicts, each meaning something different: **RED** (the gate caught the
plant), **BLIND** (it did not), **VOID** (the plant changed nothing, so the arm
tested nothing), **SKIP** (the arm did not run), **WRONG** (the gate went red on
a different check than the arm names).

**Sixteen arms going red is a floor, not a distribution.** It shows the gate
detects the defects somebody thought to plant — the same blind spot the golden
vectors have in §1. Add an arm whenever a real defect gets through.

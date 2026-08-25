# Codec benchmarks

Head-to-head throughput for the S-expression codec against the Python
reference (`aiko_services/main/utilities/parser.py`) on identical payloads.
This measures the ONE component both implementations share — it is not a
port-wide or language-wide claim.

```
dart compile exe benchmark/codec_bench.dart -o /tmp/codec_bench && /tmp/codec_bench 100000
python3 benchmark/codec_bench.py 100000
```

Measured 2026-08-25, Apple Silicon, Dart 3.13.0 AOT vs CPython 3.13.7,
100k iterations x 3 payloads:

| | parse us/msg | generate us/msg |
|---|---|---|
| Python 3.13 | 11.78 | 3.98 |
| Dart, before | 5.78 | 3.23 |
| Dart, after | **1.00** | **0.91** |

Deeply-nested 26 KB payload, `generate`: 1440 -> 279 us (5.2x).
Varying-payload traffic (`realistic_bench.dart`, 5000 distinct messages):
0.45 us/msg, ~2.2M msg/s.

## What worked, and what did not

Everything that won removed work. Nothing that won was inlining.

| Change | Removed | Gain |
|---|---|---|
| Atom as an index range, not `token += c` | a String per character | 1.5x parse |
| Guard the two parse regexes on one code-unit compare | a `Match` per position | 3.1x parse |
| Replace `_reDelimiters` with an enumerated predicate | a regex per string element | 2.9x generate |
| Shared `StringBuffer` in the encoder | quadratic accumulation per nesting level | 1.25-1.45x generate |
| Copy-on-write `_listToDict` | a List copy per list in every tree | ~2-5% parse |
| Inline the `hasToken`/`flushToken` closures | a heap box on the loop counters | 1.11x parse |

**An atom intern cache LOST, 0.451 -> 0.529 us/msg (17% slower).** The idea was
sound -- command names and keywords repeat forever on a bus, so why allocate a
byte-identical String every time -- but Dart's young generation is a bump
allocator, and a short-lived small String costs a pointer bump plus a memcpy
and then dies before it is ever traced. Paying a hash pass and a verification
compare to avoid that loses. Recorded so nobody re-tries it: the rule is not
"avoid allocation", it is "do not do work you can skip". Allocation was simply
the largest skippable work in the loop.

## What is left

Little worth taking. At ~1M parse/s and ~1.1M generate/s single-threaded the
codec is orders of magnitude below the millisecond MQTT round-trip that bounds
the system. The remaining structural idea is not in this file: parsing straight
from the MQTT `Uint8List` would skip materialising a Dart `String` for the
payload at all. That changes the public API, so it is a design call.

## Differential fuzzing

`tool/generate_fuzz_corpus.py` builds random atoms from an alphabet covering
every character the encoder reasons about and records what the Python
reference emits; `tool/fuzz_generate_parity.dart` replays them.

```
python3 tool/generate_fuzz_corpus.py /tmp/fuzz.json
dart run tool/fuzz_generate_parity.dart /tmp/fuzz.json
```

This found a real wire-format bug that 63 hand-picked vectors had missed:
Dart's `\s` and Python's `\s` are different sets, so the two implementations
length-prefixed different atoms -- 3604 mismatches in 40k cases. See RFC-0001
section 4.1, which now enumerates the set rather than deferring to `\s`.

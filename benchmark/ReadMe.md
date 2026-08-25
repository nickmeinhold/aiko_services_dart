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
| Dart, before this pass | 5.78 | 3.23 |
| Dart, after | 1.00 | 2.56 |

On a 26 KB deeply-nested payload (depth 5, branching 4) the `generate`
rewrite is worth more, 1440 -> 996 us: the quadratic accumulation it removes
compounds once per nesting level, so the win scales with payload complexity
rather than being flat.

What is left, and why we stopped: the last regex in a hot path is
`_reDelimiters.hasMatch()`, run per string element in `generate`. Dart's `\s`
is Unicode-aware, so hand-rolling it risks the astral-plane correctness this
codec is oracle-pinned on — and at ~1M parse/s and ~390k generate/s
single-threaded, the codec is orders of magnitude off the millisecond MQTT
round-trip that actually bounds the system. Further tuning here optimises
something that is not the bottleneck.

Run the Dart side AOT-compiled, not `dart run`: the JIT figures reflect
warmup, not the shipped artifact.

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
| Dart, after | 1.00 | 3.23 |

`generate` is untouched and remains only ~1.2x the reference — CPython does
that work in C string joins. It is the obvious next target.

Run the Dart side AOT-compiled, not `dart run`: the JIT figures reflect
warmup, not the shipped artifact.

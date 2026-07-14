#!/usr/bin/env python3
"""Generate golden interop fixtures for the Dart S-expression codec.

The fixtures are the EXTERNAL ORACLE for `lib/src/codec/s_expression.dart`:
they are produced by running Aiko's REAL Python reference codec
(`aiko_services/main/utilities/parser.py`), so the Dart tests assert
byte-for-byte agreement with the exact code Andy's framework uses on the
wire — not a reimplementation's self-consistency.

Usage:
    python3 tool/generate_codec_fixtures.py [PATH_TO_aiko_services_repo]

Defaults to the sibling checkout `../aiko_services`. Re-run whenever
parser.py changes upstream; commit the regenerated fixture.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_AIKO = os.path.normpath(os.path.join(HERE, "..", "..", "aiko_services"))

aiko_repo = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_AIKO
parser_dir = os.path.join(
    aiko_repo, "src", "aiko_services", "main", "utilities")
if not os.path.isfile(os.path.join(parser_dir, "parser.py")):
    sys.exit(f"parser.py not found under {parser_dir!r} — pass the "
             f"aiko_services repo path as argv[1]")
sys.path.insert(0, parser_dir)
import parser  # noqa: E402  (the real Aiko reference codec)

# ---- generate() cases: (command, params) -> payload string --------------
# params use JSON-native types (str / int / None / list / dict) so the Dart
# side loads them verbatim and must produce the identical payload.
GENERATE_CASES = [
    ("increment", [5]),
    ("count", [8]),
    ("add", ["topic", "protocol", "owner"]),
    ("update", ["log_level", "DEBUG"]),
    ("command", ["aloha honua"]),          # whitespace -> length-prefixed
    ("parens", ["(not a list)"]),           # parens -> length-prefixed
    ("ping", [None]),                        # None -> 0:
    ("empty", [""]),                         # empty string -> ""
    ("nested", ["a", ["b", "c"]]),           # nested list
    ("mixed", ["a", ["c", "d"], ["e", "f", ["g", "h"]]]),
    ("a", {"b": "1", "c": "2"}),             # dict -> b: 1 c: 2
    ("a", {"b": ["c", "d"]}),                # dict with list value
]

# ---- parse() cases: payload string -> (command, cdr) --------------------
# Includes the parser.py docstring examples, exercising dict detection,
# canonical null, and empty-list edges.
PARSE_CASES = [
    "(increment 5)",
    "(add topic protocol owner)",
    "(command 11:aloha honua)",
    "(ping 0:)",
    "(nested a (b c))",
    "(mixed a (c d) (e f (g h)))",
    "(a b: 1 c: 2)",
    "(a b: 1 c: (d e))",
    "(a b: 1 c: (d: 1 e: 2))",
    "(a 0: b)",                              # canonical null consumed pre-dict
    "(a b ())",                              # empty nested list
    '(empty "")',
]


def car_cdr(payload):
    command, cdr = parser.parse(payload)
    return {"payload": payload, "command": command, "cdr": cdr}


def main():
    fixture = {
        "_source": "aiko_services/main/utilities/parser.py",
        "_note": "Regenerate via tool/generate_codec_fixtures.py; do not hand-edit.",
        "generate": [
            {"command": c, "params": p, "expected": parser.generate(c, p)}
            for c, p in GENERATE_CASES
        ],
        "parse": [car_cdr(p) for p in PARSE_CASES],
    }
    out = os.path.join(
        HERE, "..", "test", "codec", "fixtures", "s_expression_golden.json")
    out = os.path.normpath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(fixture, f, indent=2)
        f.write("\n")
    print(f"wrote {len(fixture['generate'])} generate + "
          f"{len(fixture['parse'])} parse vectors -> {out}")


if __name__ == "__main__":
    main()

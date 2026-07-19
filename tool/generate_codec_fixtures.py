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
    # Unicode: length prefix counts CODE POINTS (Python len), not UTF-16
    # units. The astral cases below caught a real Dart divergence (2026-07-18).
    ("emoji", ["a \U0001F600"]),             # astral + space -> 3:a 😀
    ("emoji", ["\U0001F600\U0001F389 x"]),   # two astral + space -> 4:
    ("accents", ["héllo wörld"]),  # BMP non-ASCII + space
    # Malformed UTF-16 (cage-match round 1, unanimous): a LONE surrogate is
    # ONE code point to Python len() and to Dart runes — the decode walk must
    # not pair a high surrogate with a non-low follower (it would swallow
    # delimiters). JSON carries \ud800 escapes fine in both languages.
    ("lone", ["\ud800x y"]),                 # lone high + ascii -> 4:
    ("lone", ["a \ud800"]),                  # lone high at end -> 3:
    ("lone", ["\udc00 z"]),                  # lone low -> 3:
    # Multi-code-point grapheme: ZWJ family is ONE glyph, SEVEN code points.
    # Guards against anyone "fixing" toward grapheme-cluster length later.
    ("family", ["\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466 x"]),
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
    # Mixed positional-THEN-keyword: because the first cdr element is positional
    # ("a"), dict detection never fires and the "c:"/"d:" markers stay literal
    # atoms. Pinned so nobody "fixes" this into a partial dict later.
    "(cmd a b c: 1 d: 2)",
    # Trailing data after the first complete list is SILENTLY IGNORED by the
    # reference (car/cdr reads only tree[0]). Pinned as PARITY — a stricter Dart
    # envelope check would decode a payload the Python wire end accepts, so the
    # two ends would disagree. Includes a smuggled second list, which is dropped.
    "(a b) trailing junk",
    "(c)(evil a: 1)",
    '(empty "")',
    "(emoji 3:a \U0001F600)",                # astral: 3 code points, 4 UTF-16
    "(emoji 4:\U0001F600\U0001F389 x b)",    # astral prefix mid-list
    "(accents 11:héllo wörld)",    # BMP non-ASCII
    "(lone 2:\ud800x b)",                    # lone high + ascii, then next atom
    "(lone 1:\ud800 b)",                     # lone high alone; must NOT eat the space
    "(lone 1:\udc00 b)",                     # lone low
]


# ---- parse() error cases: payloads the reference REJECTS ----------------
# The success suite is oracle-pinned but blind to malformed input; a codec can
# be self-consistently wrong on the error paths too. Each payload here MUST
# fail to decode under the reference. We record the reference exception type so
# the Dart side can assert "rejects" against real Python behaviour, not an
# author's guess. Two flavours:
#   * ValueError — a DELIBERATE reference rejection (RFC-0001 §7 MUST-reject).
#   * TypeError  — an UNDELIBERATE reference crash (RFC-0001 §8 errata); the
#                  spec only requires "does not decode successfully".
PARSE_ERROR_CASES = [
    "(c a: 1 b:)",         # §7: odd-length dictionary
    "(c a: 1 (x y) 2)",    # §7: keyword-position element is not a string
    "(c a: 1 b c: 2 d)",   # §7: keyword-position string does not end with ":"
    "(c 99:ab)",           # §8.2: overlong length prefix (reference crashes)
    "(c a b",              # §8.1: unterminated list (reference crashes)
]


def car_cdr(payload):
    command, cdr = parser.parse(payload)
    return {"payload": payload, "command": command, "cdr": cdr}


def parse_error(payload):
    try:
        parser.parse(payload)
    except Exception as e:  # noqa: BLE001 — recording the reference's own type
        return {"payload": payload, "raises": type(e).__name__,
                "message": str(e)}
    raise AssertionError(
        f"PARSE_ERROR_CASES vector decoded successfully: {payload!r}")


def main():
    fixture = {
        "_source": "aiko_services/main/utilities/parser.py",
        "_note": "Regenerate via tool/generate_codec_fixtures.py; do not hand-edit.",
        "generate": [
            {"command": c, "params": p, "expected": parser.generate(c, p)}
            for c, p in GENERATE_CASES
        ],
        "parse": [car_cdr(p) for p in PARSE_CASES],
        "parse_errors": [parse_error(p) for p in PARSE_ERROR_CASES],
    }
    out = os.path.join(
        HERE, "..", "test", "codec", "fixtures", "s_expression_golden.json")
    out = os.path.normpath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(fixture, f, indent=2)
        f.write("\n")
    print(f"wrote {len(fixture['generate'])} generate + "
          f"{len(fixture['parse'])} parse + "
          f"{len(fixture['parse_errors'])} parse-error vectors -> {out}")


if __name__ == "__main__":
    main()

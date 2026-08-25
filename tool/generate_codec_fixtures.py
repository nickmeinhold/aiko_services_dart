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

REGEN DEPENDENCY: parser.py is imported directly, standalone, so this only
works while it imports nothing but `re` and `sys`. If upstream adds an
intra-package import, this script fails loudly at import time. That is a
REGENERATION-time dependency only -- the fixtures are committed, so the test
suite is unaffected and CI stays green; you simply cannot refresh the oracle
until the import is satisfied (pass the repo path as argv[1], or import via
the installed package).
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
    # Whitespace-class parity. Dart's `\s` and Python's `\s` are NOT the same
    # set, and RE_DELIMITERS decides whether an atom is length-prefixed -- so a
    # regex-based Dart port emits different BYTES than the reference for these.
    # Neither tokeniser splits on any of them (both split on exactly space, tab
    # and newline), so a round-trip always survived; what diverged was the
    # canonical encoding, which is what RFC-0001 pins. Found by differential
    # fuzzing (tool/fuzz_generate_parity.dart), 3604 mismatches in 40k atoms.
    ("ws", ["a\u0085b"]),      # NEL: Python \s, NOT Dart \s -> MUST prefix
    ("ws", ["a\u001cb"]),      # C0 file separator: Python \s, not Dart's
    ("ws", ["a\u001fb"]),      # C0 unit separator: Python \s, not Dart's
    ("ws", ["a\ufeffb"]),      # BOM: Dart \s, NOT Python \s -> must NOT prefix
    ("ws", ["\ufeff"]),        # BOM alone: bare, no prefix
    ("ws", ["a\u00a0b"]),      # NBSP: in BOTH -> prefix
    ("ws", ["a\u3000b"]),      # ideographic space: in BOTH -> prefix
    ("ws", ["a\u2028b"]),      # line separator: in BOTH -> prefix
    ("ws", ["a\u0001b"]),      # C0 SOH: in NEITHER -> must NOT prefix
    ("ws", ["a\u007fb"]),      # DEL: in NEITHER -> must NOT prefix
    # Mixed positional + keyword in ONE payload. This is not hypothetical: it
    # is the exact shape the remote proxy puts on the wire. Both
    # transport/transport_mqtt.py:79 and discovery.py:164 build parameters as
    #     args if not kwargs else [args[0], kwargs]
    # so a kwargs call sends EXACTLY ONE positional followed by the dict, and
    # silently DISCARDS args[1:]. These pin the wire shape the Dart proxy must
    # mirror when it is written (issue #2038).
    ("update", ["log_level", {"level": "DEBUG"}]),
    ("update", ["log_level", {"level": "DEBUG", "force": "1"}]),
    ("add", ["topic", {"protocol": "mqtt", "owner": "nick"}]),
    ("cfg", ["a", {"nested": ["x", "y"]}]),      # dict value that is a list
    ("cfg", ["a", {"k": None}]),                 # dict value that is null
    ("cfg", ["a", {"k": "has space"}]),          # dict value needing a prefix
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
    # A nested list mid-atom does NOT terminate the atom: the reference keeps
    # accumulating and emits the joined atom AFTER the sublist. Pinned because
    # the Dart tokeniser tracks a bare atom as an index range into the payload,
    # which a nested list splits -- these are the only vectors that exercise
    # that carry path, and a "simplification" that flushed on "(" would pass
    # every other vector here.
    "(c ab(x)cd)",                           # -> [["x"], "abcd"]
    "(c ab(x)cd ef)",                        # carry then a normal atom
    "(c a(b)(d)e)",                          # TWO interruptions: -> "ae"
    "(c (x)ab)",                             # sublist first, atom after
    "(c ab(x))",                             # atom flushed by the closing paren
    # Canonical-symbol boundary: RE_CANONICAL_SYMBOL is `^(\d+):(.+)`, and that
    # `(.+)` demands at least one character AFTER the colon. So a trailing
    # `0:` / `12:` at end of input is NOT a canonical symbol -- it is the
    # ordinary atom "0:" / "12:". Inside a payload the closing paren supplies
    # the required character, which is why `(ping 0:)` is still null. Found by
    # differential fuzzing (tool/fuzz_parse_parity.dart); the Dart scan
    # initially decoded a bare `0:` as null and threw on a bare `12:`.
    "0:",                                    # bare -> atom "0:", NOT null
    "12:",                                   # bare -> atom "12:", NOT a throw
    " 0:",                                   # leading whitespace, same
    "(c 0:)",                                # inside a list -> IS null
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
    # §8.2 again, at the canonical-symbol boundary: the `)` satisfies the
    # `(.+)` so `12:` IS parsed as a length prefix here, and 12 characters
    # overrun the input. Sibling of the bare `12:` in PARSE_CASES, which is an
    # ordinary atom precisely because nothing follows the colon.
    "(c 12:)",
]


# ---- deliberate divergences: reference DECODES, Dart MUST REJECT --------
# A third category, distinct from PARSE_ERROR_CASES (where the reference also
# fails). Here the reference decodes and the Dart port deliberately refuses,
# so the fixture records what the reference produced -- making the divergence
# a reviewable, pinned decision rather than an undocumented behaviour drift.
#
# The reference is dynamically typed, so its `car` can come back as None (a
# `0:` in command position) or as a nested list (`((a b) c)`). Dart's parse
# returns (String, Object), which admits neither; before this was pinned, the
# list crashed the cast with a raw TypeError (escaping the "decodes or throws
# FormatException" contract on untrusted input) and the null was silently
# flattened to "". We reject both: a command names a method to dispatch, and
# every reference sender builds one via generate(method_name, ...) with a str,
# so no conformant encoder emits either shape. RFC-0001 §8.6.
DIVERGENCE_CASES = [
    "(0: a)",          # null in command position
    "( 0:)",           # null command, no arguments
    "((a b) c)",       # nested list in command position (crashed the cast)
    "((a))",           # nested list, no arguments
    "(((a)))",         # doubly nested
]


def divergence(payload):
    """Record what the reference decodes, for a payload Dart must reject."""
    car, cdr = parser.parse(payload)
    return {"payload": payload, "reference_car": car, "reference_cdr": cdr}


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
        "divergences": [divergence(p) for p in DIVERGENCE_CASES],
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
          f"{len(fixture['parse_errors'])} parse-error + "
          f"{len(fixture['divergences'])} divergence vectors -> {out}")


if __name__ == "__main__":
    main()

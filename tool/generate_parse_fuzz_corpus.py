#!/usr/bin/env python3
"""Differential-fuzz corpus for parse(), recorded from the Python reference.

The golden vectors pin parse() on inputs a human thought of. This builds
payloads a human would not: structurally random assemblies of the tokens the
grammar is made of (canonical prefixes, quotes, keywords, nesting, stray
delimiters), plus raw character soup. For each one it records what the
reference does -- decode to a value, or raise -- so the Dart side can be held
to the same outcome on inputs nobody curated.

Usage: python3 tool/generate_parse_fuzz_corpus.py OUT.json [COUNT] [SEED]

Vary SEED before trusting a clean run: a single seed proves one sample, not
the absence of divergence.
"""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AIKO = os.path.normpath(os.path.join(HERE, "..", "..", "aiko_services"))
sys.path.insert(0, os.path.join(AIKO, "src", "aiko_services", "main", "utilities"))
import parser  # noqa: E402

SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 20260825
random.seed(SEED)

ATOMS = ["a", "bc", "5", "0", "log_level", "DEBUG", "x:", "k:", "", "12",
         "3:abc", "0:", "-1", "é", "\U0001F600", "\ud800", "\udc00"]


def canonical():
    """A `len:data` symbol -- sometimes with a length that is WRONG."""
    data = random.choice(["ab", "a b", "a(b", "a)b", "12:x", "", "\U0001F600",
                          "\ud800", 'q"q', "x" * 12])
    true_len = len(data)                       # Python len == code points
    n = random.choice([true_len, true_len, true_len, true_len,
                       true_len + 1, max(0, true_len - 1), 0, 99])
    return f"{n}:{data}"


def quoted():
    return random.choice(['"ab"', "'ab'", '""', "''", '"a b"', '"a(b"',
                          '"unterminated', '"a\'b"', '"\U0001F600"'])


def token():
    r = random.random()
    if r < 0.40: return random.choice(ATOMS)
    if r < 0.60: return canonical()
    if r < 0.70: return quoted()
    if r < 0.80: return random.choice(["(", ")"])
    return random.choice([" ", "  ", "\t", "\n", "", "k:"])


def payload():
    if random.random() < 0.15:                 # raw soup
        return "".join(random.choice('()"\' \t\n:0125abk\U0001F600')
                       for _ in range(random.randint(0, 14)))
    body = " ".join(token() for _ in range(random.randint(0, 7)))
    return random.choice(["({})", "({})", "({})", "{}", "({}", "{})"]).format(body)


def main():
    out_path = sys.argv[1]
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 30000
    cases, seen = [], set()
    while len(cases) < count:
        p = payload()
        if p in seen:
            continue
        seen.add(p)
        try:
            car, cdr = parser.parse(p)
            # A stray top-level ")" makes the reference `return result, i+1`
            # from INSIDE its loop, skipping the car/cdr tail entirely -- so it
            # hands back (list, int) instead of (car, cdr). That is RFC-0001
            # section 8 errata, not a contract, and it dominates a random
            # corpus. Tag it so the comparison does not drown in one quirk.
            if isinstance(cdr, int):
                cases.append({"p": p, "errata": "stray_close_paren"})
            else:
                cases.append({"p": p, "car": car, "cdr": cdr})
        except Exception as e:  # noqa: BLE001 -- the reference's own outcome
            cases.append({"p": p, "raises": type(e).__name__})
        except RecursionError:
            continue
    json.dump(cases, open(out_path, "w"))
    ok = sum(1 for c in cases if "raises" not in c)
    print(f"{len(cases)} cases -> {out_path}  ({ok} decode, {len(cases)-ok} reject)")


if __name__ == "__main__":
    main()

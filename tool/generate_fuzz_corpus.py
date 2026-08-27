"""Builds the generate() oracle corpus from a Python aiko_services checkout.

Usage: generate_fuzz_corpus.py <out.json> <aiko_services-root> [count]

Pass a `git archive` snapshot rather than a live checkout: a path names a
directory, a ref names a state.
"""
import sys, json, random, os
if len(sys.argv) < 3:
    sys.exit("usage: generate_fuzz_corpus.py <out.json> <aiko_services-root>")
REF = sys.argv[2]
COUNT = int(sys.argv[3]) if len(sys.argv) > 3 else 40000
if COUNT < 1:
    sys.exit(f"refusing to build a corpus of {COUNT} cases — a fuzz over nothing is not a fuzz")
SRC = os.path.join(REF, "src")
if not os.path.isdir(SRC):
    sys.exit(f"no src/ under reference root {REF!r} — refusing to guess an oracle")
sys.path.insert(0, SRC)
from aiko_services.main.utilities.parser import generate
random.seed(7)
# Every character the predicate reasons about, in BOTH divergence directions:
# ASCII text/digits/colon/parens, all of Python's \s, all of Dart's \s, plus
# astral and BMP non-ASCII that are in neither.
alpha = list("abc0123456789:() \t\n") + [chr(c) for c in
    (0x0b,0x0c,0x0d,0x1c,0x1d,0x1e,0x1f,0x85,0xa0,0x1680,0x2000,0x200a,
     0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff,0x00e9,0x1F600,0x0001,0x007f)]
cases = [""]
for _ in range(COUNT):
    cases.append("".join(random.choice(alpha) for _ in range(random.randint(1,6))))
out=[]
for c in cases:
    try: out.append({"e": c, "w": generate("c", [c])})
    except Exception as ex: out.append({"e": c, "err": type(ex).__name__})
json.dump(out, open(sys.argv[1],"w"))
# Cases carrying an oracle result, i.e. what the parity rig can compare.
comparable = sum(1 for c in out if "w" in c)
print("oracle cases:", len(out), "| covers both divergence directions | oracle:", REF)
print(f"COMPARABLE={comparable}")

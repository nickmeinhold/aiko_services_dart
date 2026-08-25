import sys, json, random
sys.path.insert(0, "/Users/nick/git/orgs/aiko/aiko_services/src")
from aiko_services.main.utilities.parser import generate
random.seed(7)
# Every character the predicate reasons about, in BOTH divergence directions:
# ASCII text/digits/colon/parens, all of Python's \s, all of Dart's \s, plus
# astral and BMP non-ASCII that are in neither.
alpha = list("abc0123456789:() \t\n") + [chr(c) for c in
    (0x0b,0x0c,0x0d,0x1c,0x1d,0x1e,0x1f,0x85,0xa0,0x1680,0x2000,0x200a,
     0x2028,0x2029,0x202f,0x205f,0x3000,0xfeff,0x00e9,0x1F600,0x0001,0x007f)]
cases = [""]
for _ in range(40000):
    cases.append("".join(random.choice(alpha) for _ in range(random.randint(1,6))))
out=[]
for c in cases:
    try: out.append({"e": c, "w": generate("c", [c])})
    except Exception as ex: out.append({"e": c, "err": type(ex).__name__})
json.dump(out, open(sys.argv[1],"w"))
print("oracle cases:", len(out), "| covers both divergence directions")

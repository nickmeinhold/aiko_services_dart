import sys, time
sys.path.insert(0, "/Users/nick/git/orgs/aiko/aiko_services/src")
from aiko_services.main.utilities.parser import parse, generate

payloads = [
  '(process_frame (stream_id: 42 frame_id: 7) (image (width: 1920 height: 1080)))',
  '(add_message chat_1 nick 13:hello, world!)',
  '(state_update (topic: aiko/host/1/1/state count: 99 tags: (a b c)) 0:)',
]
iters = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
for _ in range(5000):
    for p in payloads: parse(p)

t0 = time.perf_counter()
for _ in range(iters):
    for p in payloads: parse(p)
t1 = time.perf_counter()

trees = [parse(p) for p in payloads]
t2 = time.perf_counter()
for _ in range(iters):
    for c, params in trees: generate(c, params)
t3 = time.perf_counter()

n = iters * len(payloads)
print(f"py   parse    {(t1-t0)*1e6/n:.3f} us/msg  ({n/(t1-t0):.0f} msg/s)")
print(f"py   generate {(t3-t2)*1e6/n:.3f} us/msg  ({n/(t3-t2):.0f} msg/s)")

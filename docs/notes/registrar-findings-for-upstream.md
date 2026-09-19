# Draft for Andy: three registrar findings that share one root

> **STATUS: DRAFT, NOT SENT.** Outward facing, so it waits for Nick's go.
>
> **Queue check first.** Three threads are already open with Andy (Discussion #98, plus
> the duplicate-snapshot finding filed as claude-tasks #3993 and not yet sent). The
> standing rule is not to open a fourth while three are waiting. This document exists so
> the material is durable and ready, not so it goes out today.
>
> **Before sending:** run the global inventory (`gh issue list -R nickmeinhold/claude-tasks
> --search "<topic>" --state all`) and enumerate Andy's existing Discussions. #84 already
> contained a question a previous session re-asked.
>
> Channel: a Discussion on `geekscape/aiko_services`, which is his channel. Signature is
> ON for that repo.

---

## The draft

Hi Andy,

While building the Dart registrar we read `registrar.py` end to end and then ran the real
Python registrar against an isolated local broker to check what it does with bad input.
It is genuinely hard to break: the arity gates drop malformed commands silently, a bad
topic path parses to `None` and falls through, and the blanket handler in `process.py`
catches the rest. Seven consecutive malformed payloads and it still answered a valid
`(share ...)` correctly.

The three things below are the ones that did not fall through, and they share a root.

**1. `topic_response` is not validated before the registrar publishes to it.**

`services_history` and `services_share` publish straight to the topic the caller names.
We looked for a check of any kind between the dispatch at `registrar.py:304` and the last
publish at `:337` and did not find one, so the only rejections we saw were incidental,
from paho refusing wildcards and empty strings.

Measured on our isolated broker: `(history victim/inbox 4096)` is 27 bytes in, and
produced 301 messages and 19,215 bytes out to `victim/inbox` with 300 history entries
seeded. With the ring buffer full the ceiling is 4,097 messages and about 263 KB.

One honest qualifier on that ratio, because it flatters the attack: reaching a full ring
buffer costs roughly 8,192 messages first, which is more than the first shot buys back.
The large multiplier is real for a repeated request against an already busy island, and
not for a cold start.

We also pointed `topic_response` at a topic outside the registrar's own namespace, and at
`$SYS`, and both were published to.

**2. A negative history count is not clamped, and it composes with (1).**

`services_history` clamps only downward, when the history is shorter than the count
(`:308-309`), so a negative count survives and is published as `(item_count -5)`.

That number lands in a consumer's frame counter. `share.py:785` takes it with a bare
`int()`, decrements at `:791`, and completes at `:803` on exactly zero, so a negative seed
never converges and the cache does not reach `ready`. Combined with (1), one message from
any peer aims that at any consumer on the island, and it arrives from the legitimate
registrar on the consumer's legitimate topic, so there is nothing about it that looks
wrong from the receiving side.

We had the same defect on our side, incidentally. Our Dart cache guarded the value with a
"does this parse" check that also admits a negative. Fixing it is what led us to look at
where the number comes from.

**3. `(add <path> n p t o 0:)` stores `tags = None` and breaks `(share ...)` for everyone
else.**

The `0:` literal parses to `None`, and the reply builders call
`" ".join(service_details["tags"])` at `:317` and `:340`. Measured: after one such `add`,
an unrelated `(share innocent/client * * * * *)` delivered `(item_count 3)` and then only
two of the three records before raising `TypeError: can only join an iterable`. The
victim's cache is left expecting one more record that never comes. Removing the poisoned
service moves it into the history deque, where it does the same to `(history ...)` and
survives up to 4,096 further removals.

**The root, and why we are writing rather than patching.**

All three are the same shape: a value arrives from the bus and is used structurally
without being narrowed at admission. The reply address is the sharpest instance, because
a caller naming its own reply topic is what turns a local robustness question into a
remote one.

We can make the Dart registrar stricter than the reference on all three, and we would
rather not do that silently, because a Dart registrar is meant to be swappable into an
island and a unilateral divergence is an interop problem wearing a fix's clothes.

So: would you like these as issues on `aiko_services`, as a PR against the Python side, or
neither for now? We are happy to write conformance vectors for whichever shape you land
on. We have the reproductions and they run against a throwaway broker in a few seconds.

Also worth saying plainly: none of this is reachable in a deployment where the broker is
authenticated, and ADR-023 already rules the arbitrary-invocation hole CLOSED by default-deny (P12), so
you may well have all three filed under "that is what the sandbox is for".

---

## A separate item: `time_started` — a question, not a defect

> **Deliberately kept OUT of the three-finding message above**, whose thesis is one root
> (unvalidated input reaching a publish). This shares nothing with that root, and stapling
> it on would blunt a message that is currently sharp. It travels on its own, or with the
> duplicate-snapshot finding, whenever the queue drains.

Hi Andy — one thing we had to decide unilaterally while porting the registrar, flagged
because we would rather be corrected early than diverge quietly.

`on_enter_primary` publishes `(primary found {topic_path} {version} {time_started})`, and
`time_started` is `time.monotonic()` sampled at service start (`service.py:564`). CPython
documents that clock's origin as undefined; on Linux it is boot, which is what makes the
values on one host comparable with each other.

Dart has no equivalent clock, so exact parity is not available at any price. The two
options and what each costs:

* A `Stopwatch` — the same KIND of quantity (monotonic seconds, unspecified origin), but
  it resets to ~0 on every restart. A freshly started Dart registrar would then look like
  the *oldest* process on the island.
* Wall-clock seconds since the Unix epoch — a different SCALE from yours (about 1.7e9
  against 8.3e5), so the two cannot be compared, but it rises across restarts.

We took the second, on one specific ground: `registrar.py:166` carries a TODO to promote
*"the oldest known secondary"*. Under a `Stopwatch` a Dart registrar would win every
election it ever entered; under epoch seconds it always looks newest and therefore always
defers to a Python one. Given the choice was forced, we picked the direction that fails
safe against your own stated intention.

Nothing reads the field today — `process.py:332-337` stores it into `aiko.registrar` and
never compares it — so this costs nothing right now. It becomes load-bearing the moment
that TODO is implemented.

The question for you: is `time_started` meant to be *comparable across processes*? If yes,
it probably wants to be a wall-clock value on both sides, and we would send a patch. If it
is only ever a per-process liveness marker, our divergence is harmless and we will note it
in our own docs and leave yours alone.

---

## Notes for us, not for the message

* Everything above about Python was verified in source at the cited lines by the main
  session, not taken from the probe that first reported it. The runtime measurements were
  taken by a subagent against a local broker on port 18830 in namespace `fuzz3`,
  deliberately not the real island.
* The 9,731x byte figure appears in our internal notes without the cold-start qualifier.
  It should not leave the building without it.
* Our own fix for the negative count went through two rounds: a `>= 0` bound, then the
  actual invariant (only open a frame we asked for), because a large positive count wedges
  the cache exactly as well and no bound on the value closes that.
* The related duplicate-snapshot finding is claude-tasks #3993, also filed and not sent.
  If the queue drains, these two probably travel together as one Discussion rather than
  two.

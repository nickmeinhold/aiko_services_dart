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
authenticated, and ADR-023 already treats the unauthenticated bus as the threat model, so
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

## The big one: a cleanly stopped registrar leaves an island that cannot recover

> **STATUS: DRAFT, NOT SENT.** Probably the one worth sending first when the queue drains —
> it is reproducible in two commands and it is a stuck state, not a slow one.

Hi Andy — we found this while running a Dart registrar against a live island, and it
reproduces entirely on the Python side.

**Stopping a registrar leaves a retained `(primary found …)` naming the dead process.**
Measured on our local island: `docker stop aiko-registrar-1` at 08:19:15; 139 seconds later
`aiko/service/registrar` still held
`(primary found aiko/fddd654e4b5a/1/1 2 831255.387865359)`. No `(primary absent)` ever
arrived.

The broker says why:

```
1789078755: Client … [172.22.0.3:58683] disconnected: connection closed by client.
```

That is mosquitto's phrasing for a clean DISCONNECT packet, and a clean DISCONNECT
**suppresses the will**. So the retained `(primary absent)` the registrar armed at promotion
(`registrar.py:189-190`) never fires on an orderly shutdown — which is exactly the shutdown
an operator performs. (The container was SIGKILLed ten seconds later, exit 137, but by then
the MQTT session was already closed.)

**The consequence is a stuck island, not just a stale value.** A replacement registrar
starting up reads that retained `found`, sees that somebody is already primary, and
transitions `primary_found → secondary` (`registrar.py:272-275`). We verified this rather
than reasoning about it: with the registrar container stopped and nothing else running, a
fresh registrar joining the island reported `FINAL_ROLE=secondary`. So the island has zero
registrars and every replacement will decline the job. Restarting does not escape it;
clearing the retained topic by hand is the only exit we found.

Three possible shapes for a fix, and we do not know which you would prefer:

1. Publish `(primary absent)` explicitly on the way down, so a graceful stop retracts
   deliberately instead of relying on a will that a graceful stop cancels.
2. Have a joining registrar treat a retained `found` naming a topic path that does not
   answer as stale — which needs a liveness probe and a timeout, so it is the expensive one.
3. Put a monotonic `time_started` or a session token in the announcement and let a joiner
   reject its own predecessor. This is the one that interacts with the `time_started`
   question above.

We have not implemented any of them; our port reproduces the behaviour faithfully, including
the stuck state.

## Three smaller ones, all in `process.py`

**`topic_matcher` is not an MQTT matcher** (`:408-424`). For a `+` filter it compares only
`tokens[0]` and `tokens[-1]`, so `aiko/+/+/+/state` matches `aiko/a/state` and
`aiko/a/b/c/d/e/state` locally. It is harmless today because the broker does the real
filtering and a process holds one wildcard subscription — but a second wildcard subscription
would misroute between them.

**`remove_message_handler` raises on a wildcard topic** (`:227-230`).
`_message_handlers_wildcard_topics` is a list (`:152`), and both branches do
`del self._message_handlers_wildcard_topics[topic]` with a string index — a `TypeError`.
The first branch also keys the wildcard delete off `_message_handlers_binary_topics`, which
looks like a copy-paste. Latent because nothing currently removes a wildcard handler.

**`(add …)` is built two different ways.** `service_add` (`:355-357`) goes through
`generate()`, while `services_share` (`:340-347`) concatenates an f-string with
`" ".join(tags)`. A tag containing a space or a parenthesis is length-prefixed by the live
path and not by the snapshot path, so a consumer would decode the same service differently
depending on which message it learned about it from.

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

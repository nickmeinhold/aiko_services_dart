# ADR-0002 — The Dart Actor concurrency model

- **Status:** **proposed, NOT converged.** Split out of ADR-0001 on 2026-08-26 (Nick's call) after
  three cross-family design-temper rounds returned RECAST / RECAST / NOT-SOUND. Every unresolved
  flaw from those rounds lives here; ADR-0001 kept the surface that converged.
- **Why the split:** three rounds found **nothing new in ADR-0001's D1–D7 after round 1**. Rounds 2
  and 3 were consumed almost entirely by one mechanism invented mid-loop (parking, now deleted).
  Holding the settled surface hostage to the contested one was costing build time for no evidence.
- **Strike record:** `0001-TEMPER.md`, `0001-TEMPER-round2.md`, `0001-TEMPER-round3.md`.
- **Substrate pass (2026-08-26):** §1 records six measurements of what Dart actually does, taken
  before any prose here was revised. They **confirmed** D8's keepalive physics, its failure-linking
  consequence and its unbounded-`SendPort` consequence; they **corrected** two factual errors (§5's
  account of why parking dies, and D8's claim that web isolates map onto web workers); and F5 is
  **new**, constraining §4.1. Rigs: `tool/experiments/`.
- **Gate:** no `lib/` code implementing anything in this document until it survives a strike. The
  value types in ADR-0001 are explicitly NOT blocked by this.

## Why this document is separate, in one paragraph

The mailbox, the epoch fence and the transport isolate are one interlocking mechanism, and every
round proved it: a fix to any one of them broke another. Revision 2's handler timeout broke the
closure law. Revision 3's parking broke the loopback path. The fence's narrowing was refuted by a
laundering path through private state. That coupling is real, so these decisions must be settled
**together** — and separately from the value types, which do not depend on any of them.

## The lesson that produced this split

> **A strike is an adversary, not a collaborator.** Bringing a fresh, unstruck mechanism *into* a
> cross-family round is an expensive way to iterate on it — two of three rounds went to one idea
> that a language fact killed outright. Bring a design to the fire; do not design in it.
> (`dir-id 7c6e` — an outlier in your own process metric is a stop-and-reframe signal.)

## 1. The measured substrate

*Added 2026-08-26, before any prose below it was revised.*

Every claim in this section is a **measurement**, not an argument, and each one is a runnable file
in `tool/experiments/` with a positive control, a null arm, or both. Findings are stated for
**Dart SDK 3.13.0 (stable), macos_arm64**; re-run `tool/experiments/` on an SDK bump before
relying on one.

This section exists because two of the three temper rounds on ADR-0001 were spent on `parking`, a
mechanism one ten-line script would have killed on day one. The order is now inverted:

> **Pin the substrate by experiment first, then strike.**

| | Measured fact | What it forbids this document from claiming |
|---|---|---|
| **F1** | A **synchronous** slice starves microtasks, `Timer`s and inbound isolate messages alike. Every `Timer` whose deadline expires during a 300ms slice fires *together*, late, after it. A long `await` starves nothing — 4 keepalive ticks landed during a 250ms `await`. | That any `Timer`-based `HandlerTimeout` can fire during the slice it exists to interrupt. It fires only once the actor yields — when it is no longer needed. |
| **F1b** | With all three genuinely pending at the yield point, service order is **microtask → `Timer` → inbound isolate message**, 8/8 runs. | That transport traffic is serviced promptly relative to timers. Inbound messages queue *behind* every already-due `Timer`. |
| **F2** | `.timeout()` abandons the **wait**, not the **work**. The caller timed out at 100ms; the handler ran to completion at 300ms, **mutated actor state**, and the abandoned future still completed with a value. | That a timed-out `ask` is over. Every abandoned `ask` leaves a live handler that will still mutate state at an unbounded later time. "Timed out" describes the caller only. |
| **F3** | Isolates are **not** failure-linked. A child that throws dies; its `SendPort` accepts further sends silently, forever; the parent gets no error and no exit signal. `onExit`/`onError` fire only if requested at `spawn`. The death prints a stack trace to **stderr** — visible to a human, invisible to the program. | That a dead actor is detectable without explicit wiring. Supervision is opt-in at spawn time, and its absence looks healthy in production while looking loud in dev. |
| **F4** | `SendPort` never blocks and never signals. With the consumer paused, a producer sent **400,000 messages in 478ms** and the receiving isolate's RSS grew **+345MB** with **zero** drained. Live-consumer control arm: all 400,000 drained, RSS flat. | That the transport provides any backpressure. Credit must be carried **in-band**; the port will never tell a producer to stop. |
| **F5** | An `await` continuation resumes as a microtask, and its **tick cost depends on when the awaited future's completion was *scheduled*, not on whether the future is complete when awaited.** `Future.value` / a pre-completed `Completer` / `Future.microtask` schedule at **construction** (`_Future.immediate` → `_asyncCompleteWithValue`) and their continuation runs *inside* that microtask, preempting microtasks queued later. `Future.sync` / `await null` complete synchronously at construction (`_Future.zoneValue` → `_setValue`) and schedule at **await** time, running after. | That reply ordering follows await order. It is entangled with **future construction order**. Any §4.1 guarantee must be stated against construction order or it is not a guarantee. |
| **F6** | There are no isolates on **either** web backend. Under dart2js, `ReceivePort.sendPort` throws `UnsupportedError` — a port cannot even be obtained. `dart:isolate` is a pure stub on both: 221 lines of `throw` in `js_runtime/lib/isolate_patch.dart`, 197 in `wasm/common/isolate_patch.dart`, against 827 lines of real implementation in `vm/lib/isolate_patch.dart`. | That web isolates are a *constrained* version of the real thing. They are absent, and the failure is one layer lower than "spawn fails". |

**Corollary to F6, and a trap worth naming.** Flutter's `compute()` — the usual reach for "move
this off the main thread" — is, on web, verbatim from `_isolates_web.dart`:

```dart
await null;
return callback(message);
```

It runs the callback **on the main thread**, one microtask later. Same API, same call site, same
green tests, no offload. Combined with F1, a synchronous callback there starves everything,
timers included.

**Three of these experiments were void on their first pass** and returned plausible, wrong
results — e4's "slow consumer" never awaited; e1b settled before the slice so the contest never
happened (its corrected run *inverts* the original ordering); e6 read a successful
`dart compile js` as "isolates work on web". The methodological record is kept in
`tool/experiments/README.md` rather than tidied away, because it is the same failure shape that
cost this design three rounds.

## 2. The central question: does Dart need a mailbox?

### 2.1 The physics (unchanged, and unchallenged by the strike)

Python needs an explicit mailbox because its threads are preemptive and share state. Dart's event
loop already serialises, so the tempting answer is that the mailbox is redundant.

That answer is wrong:

> Dart gives one-at-a-time **scheduling** for free. It does not give one-at-a-time
> **completion**.

A synchronous handler runs to completion uninterrupted. An `async` handler yields at every
`await` — so message B can begin, and observe state, while message A is suspended half-way
through mutating it. Every family accepted this. The mailbox stays.

### 2.2 Why it stays — reordered, because revision 1 had this backwards

Revision 1 led with completion-ordering and called it "the real one". It is the *weakest* of the
three, because completion-ordering alone does not need a mailbox — it needs three lines:

```dart
_tail = _tail.then((_) => handler());   // a serialising Future chain
```

No queue, no drain loop, no dequeue policy. **Considered and rejected**, because it cannot
express the other two reasons, which are the ones that actually require a queue:

1. **Uniform local/remote call path.** Behaviour must not depend on where the caller lives. A
   local call is enqueued exactly as a remote one is — which is why, in the reference,
   `actor.test(1)` does *nothing* until the loop runs. A Future chain has no queue to inspect,
   reorder, defer, or drain on shutdown.
2. **Deferral, delayed commands, and priority ordering** (D4). A chain cannot hold an item
   against a deadline.
3. **Completion-ordering across `await` points.** Real, necessary, and the cheapest of the three
   to obtain.

### 2.3 Replies: conform to `do_request()`'s SHAPE — but it has no request identity

All four families found revision 1's reentrancy deadlock: a mailbox that awaits each handler to
completion, plus replies arriving as messages, wedges any handler that `await`s a reply. Python is
immune because `Message.invoke()` is **synchronous**.

The reference's answer: `discovery.py::do_request()` has the caller nominate a **`response_topic`**,
registers the handler at **process** level via `add_message_handler()`, fires `do_command()` and
**returns immediately**. `pipeline.py:1873`'s `topic_response_handler` is the identical shape — two
independent call sites, so this is the reference's pattern, not one function's habit.

**Revisions 2 and 3 each tried to keep `await` ergonomics on top of that, and both failed.**
Revision 2 floated an `await`-shaped `Completer`, which head-of-line blocks for unbounded peer
latency. Revision 3 invented *parking* — awaiting would release the turn and the continuation would
re-enter as a fresh turn. Round 3 killed it unanimously, on a fact about the language:

> **`await t.ask()` does not yield a mailbox turn.** Completing that Future resumes the handler as
> a **microtask** — precisely the side door §2.4 exists to nail shut. The mailbox never owns "the
> rest of the function."

It also failed *deterministically where it mattered most*: §5's in-memory loopback completes a reply
synchronously, so parking would be guaranteed **absent** on the uniform local/remote path that is
§2.2's reason 2 — the very reason the mailbox exists. And it bought nothing: completion-ordering
across the `await` was surrendered, while the two remaining justifications are exactly what the
simple form still provides.

**Decision — strict continuation style. A handler does not `await` a reply.**

```dart
void join(String id) {
  ask(directory, GetProfile(id), replyTo: onProfile, context: id);
  // handler ends here. The actor keeps serving.
}

void onProfile(Profile profile, String id) {   // a fresh turn, via the mailbox
  if (!profile.banned) addMember(id);
}
```

Two methods instead of one, and a multi-step request becomes N handlers. **That is the honest
price, and it is the only proposal in three rounds that no family could break.** What the
subtraction removes in one edit: the reply-before-park race, the loopback determinism hole, nested
and concurrent `ask` semantics, continuation ordering, and the ownership of a parked caller's
Future. `dir-id 5e1f` — remove the coupling, do not guard the window.

Inherited constraints: reply reassembly is a **process-level** state machine
(`(item_count N)` then N × `(response …)`) with its own timeout, and each `response_topic` is
**single-use** — a reused topic mixes two requests' replies (`dir-id f7a8`).

#### The single-use constraint is real, and the reference does not satisfy it

*Amended 2026-08-26. Revision 4 recorded the single-use rule as a constraint the reference
**provides**. It is a constraint the reference **requires and never enforces**, and none of its own
callers satisfy it.* Read from `discovery.py:217` at `d31ba17`:

- **There is no correlation id anywhere.** The reply payload carries `(item_count N)` and
  `(response …)` and nothing that identifies *which request* it answers.
- **`response_topic` is a parameter, and every caller passes the same value** —
  `_RESPONSE_TOPIC = aiko.topic_in`, the process's own inbound topic. Four call sites:
  `discovery.py:334`, `process_manager.py:468`, `category.py:178`,
  `examples/aloha_honua/aloha_honua_3.py:92`.
- **Handlers are added and never removed.** `do_request` calls `add_message_handler` and never
  `remove_message_handler` — which exists (`process.py:221`) and is used elsewhere
  (`share.py:531`, `dashboard.py:712`). A completed request keeps its handler registered.
- **The accumulator is shared and resettable.** `nonlocal item_count, items_received, response`,
  and the `item_count` branch sets `items_received = 0; response = []`. A *second* request's
  `(item_count N)` therefore resets the *first* closure's accumulator mid-flight.

**Measured** against a live broker with two real peer Actors (by the peer Claude session working in
`aiko_services`; mechanism above verified independently from source here). Two requests issued
A-then-B, A replying at 4s and B at 0.5s:

```
t=0.684  HANDLER(to_A_slow) fired  <- [['peer_B:to_B_fast']]     <- B's payload
t=0.684  HANDLER(to_B_fast) fired  <- [['peer_B:to_B_fast']]
t=4.783  HANDLER(to_A_slow) fired  <- [['peer_A:to_A_slow']]
t=4.783  HANDLER(to_B_fast) fired  <- [['peer_A:to_A_slow']]     <- already completed
```

**Two requests, four firings.** Each handler saw every response; `to_A_slow` fired with B's payload
before its own peer had replied. Null arm: one request to one peer fires exactly once.

Also measured: a requester torn down with a request in flight exits cleanly, the peer replies into
a dead topic, and **neither side notices**. A peer that never replies produces no timeout, no
completion and no cleanup — the handler stays registered for the life of the process.

#### Why this is not a defect report, and what it means for us

**Every one of the four call sites also passes `terminate=True`.** `do_request` fires one request,
runs the response handler, and terminates the process. Under that usage there is exactly **one
in-flight request per process lifetime** — so no correlation id is needed, a leaked handler is
irrelevant, and reusing `aiko.topic_in` is harmless. `do_request` is a **one-shot CLI primitive**
and it is correct as one.

The error was ours. **"Conform all the way" bound a long-lived actor runtime to the semantics of a
fire-once-and-exit helper**, and it made §4.1 unanswerable: *"do two replies arrive in request
order, arrival order or causal order?"* presupposes a correlation the wire does not carry. Three
temper rounds never caught it because all four families reasoned about ordering for a mechanism
that has no request identity to order by — the same shared-premise failure as round 1's flat-map
description of `share` (`dir-id 7c2a`: N rounds from one unverified premise are one premise counted
N times).

**Amended decision.** We conform to `do_request()`'s **shape** — continuation style, caller-nominated
response topic, process-level handling, multi-part `(item_count N)` + N × `(response …)`
reassembly. We do **not** conform to its absence of request identity, because our actors are
long-lived and will have more than one request in flight.

**Adding request identity is a WIRE change, and the wire is Andy's.** Same class as the
`lifecycle`/`running` consolidation: a proposal he is likely to welcome, not a pushback. §4.1 is
therefore **withdrawn, not answered** — it is replaced by an upstream question, and ADR-0002 cannot
settle continuation ordering until that question has an answer.

**Do not "fix" this locally by picking a per-request topic scheme.** A Dart-side correlation the
Python side does not read is not interop; it is a second protocol wearing the first one's clothes.

**Handlers should be synchronous wherever possible.** With replies no longer awaited, the remaining
reasons to `await` inside a handler are local I/O — and each one holds the turn for its duration.
That is a real constraint on authors and it is the same one Python imposes.

### 2.4 The closure law

Revision 1 promised "no message observes torn state" without stating a closure condition.
Revision 2 stated one that **contradicted §2.3** — everything re-enters as a message, versus
replies never entering the mailbox. Kelvin's reformulation, plus Tesla's epoch clause, resolves
it by distinguishing events that *initiate* work from events that *feed* work already in flight:

> **Every event that INITIATES a unit of work on actor state enters as a message.**
> **Process-level code may only resume the turn that is currently live, or enqueue a new one.**
> **After a turn's epoch dies, nothing that turn closed over may write or publish.**

Consequences, each with its enforcing construct rather than a promise:

| Side door | Enforcement |
|---|---|
| `Timer` (D4) | the callback **enqueues**; it never invokes a handler |
| D3's error `Stream` | outbound only — the type exposes no mutator |
| transport stream callbacks | deliver into the mailbox, never to an actor method |
| inbound `(update …)` | enters through the mailbox like any command |
| a closure capturing `this` | cannot reach state: mutators require a live `Turn` (D9) |

### 2.5 D9 — the epoch fence, and why it is one mechanism not two

**Revision 2's timeout was fatally wrong.** It said "abandon the wait, surface `HandlerTimeout`,
continue draining." Dart **cannot cancel a Future**. An abandoned handler is not stopped, only
un-awaited — so it resumes later and mutates concurrently with whatever turn is now live. Kelvin:
*"a wedged actor is better than a silently corrupt one."*

The fix and the stale-read problem from §2.3 are **the same problem** — *work performed on behalf
of a turn that is over* — so they get one mechanism.

**Every turn carries an epoch. Every mutation that leaves the actor requires a live turn.**

```dart
extension type Turn._(({ActorState st, int epoch}) _t) {
  int get epoch => _t.epoch;
  bool get live => _t.st.epoch == _t.epoch;

  Future<(R, Turn)> ask<R>(...) async { /* parks; bumps epoch; returns a new Turn */ }
}

extension type Reading<T>._(({T value, int epoch}) _r) {
  T at(Turn t) {                       // unwrapping REQUIRES naming a turn
    if (t.epoch != _r.epoch) throw StaleReadError(_r.epoch, t.epoch);
    return _r.value;
  }
}
```

Two properties, and they are different in kind — the distinction matters:

- **Compile-time, genuinely enforced.** `Reading<int>` is *not* an `int`. It cannot be added,
  printed, or passed where an `int` goes. The only way to the value is `.at(someTurn)`. A stale
  read therefore **cannot be used silently** — the language forces the author to name a turn at
  every use site.
- **Runtime.** Dart has no linear types, so `ask` cannot *consume* `t`; presenting the dead turn
  is caught by the epoch check and throws deterministically at the exact line.

Prototyped and run on Dart 3.13 with both controls: the stale arm throws
`value read in turn 0 used in turn 1`, the re-read arm succeeds. The remaining gap — reaching for
the dead `t` at all — is a dataflow lint (`custom_lint`), feasible and **not yet written**.

**The fence is ABSOLUTE — revision 3's narrowing was fatal.** Revision 3 branded only
`share.update()` and `publish()`, arguing private tearing "stays local". Carnot supplied the
mechanism that refutes it: a timed-out handler sets `_memberBanned = false`, fails to publish
because its Turn is dead, and **a later valid turn reads that private field and publishes it with
live authority. The lie leaves the actor one turn later, laundered through fresh authority.**
Kelvin: *"the fence is a decorative feature ... ensuring eventual wire-visible corruption. There is
no middle ground."*

So a dead epoch may not: write private state, publish, update the share, **enqueue a message,
start a timer, initiate an ask, complete an actor-visible Completer, or consume reserved mailbox
headroom.** The rule is **authority**, not egress: *a dead epoch cannot schedule work.* Actor state
is private behind the turn context; there are no freely-writable fields for a closure to capture.

**A timed-out handler is therefore fenced, not killed.** It keeps running (Dart offers nothing
else), but its epoch is dead, so its writes are rejected and its publishes suppressed, both
reported on D3's stream. `HandlerTimeout` becomes true rather than reassuring.

### 2.6 The policies revision 2 named but did not design

Round 2 found these as a **class**, not three items (`dir-id 3c9d`), so they are swept together.

**Shutdown.** `close()` stops admission, drains for a bounded grace period, then kills the
remaining epoch. In-flight handlers are fenced, not awaited. Pending mailbox entries are reported
on D3's stream, never dropped silently. Note from §1: a **clean `disconnect()` does not fire the
last will** — so a `close()` that cannot finish must publish `(absent)` itself rather than relying
on the broker.

**Overflow, by message class** — one undifferentiated policy was the round-2 finding:

| Class | Policy on a full mailbox |
|---|---|
| lifecycle / shutdown / cancellation | **never dropped** — reserved headroom |
| reply continuation for in-flight work | never dropped — it completes work already begun |
| delayed timer expiry (D4) | never dropped — its deadline was already accepted |
| inbound remote command | drop **newest**, report on D3 |
| local command | reject at the call site — the caller is present to be told |

Drop-oldest is rejected outright: it replays the past and discards the present.

**Cancellation** is the epoch kill of §2.5, not a concurrent mutator and not a priority number.
Priority remains **dequeue ordering, not preemption** — with a stuck handler, only the epoch kill
recovers the actor, which is why control traffic gets reserved headroom above rather than a
higher priority.

## 2.7 Acceptance tests — restored, renamespaced, and audited

**These were LOST in the split (`1405a56`), and this document has been citing them ever since.**
The pre-split ADR-0001 held one table of 18 tests. The split moved §2's *prose* here and kept
tests 11–18 (the value types) in ADR-0001, renumbered `1–12`. Tests 1–10 — every concurrency
test, the ones that test *this* document — were **deleted from both**.

Three references here dangled, and two of them dangled **invisibly**:

| this document said | resolved to (ADR-0001) | actually meant |
|---|---|---|
| "Test ● 5 goes *green* for that death" (D8) | `share['metrics']` escaped | CPU-bound handler vs keepalive |
| "Test ● 2 asserts *any byte reaches the broker*" (§2.5) | `(update log_level junk)` | zombie publishes |
| "whether tests ● 1–5 can be written red-first" (§4.6) | — | **nothing; the table was gone** |

A reviewer following "Test ● 2" landed on a real, plausible, wrong test in a sibling document.
`dir-id f7a8` — a label reused as a stable key silently collides.

**Fixed by renamespacing, not by care.** This document's tests are **`C1…C10`** (concurrency);
ADR-0001's are **`V1…V12`** (value types). The two sets can no longer be confused, and no future
split can make them ambiguous again. `dir-id 5e1f` — remove the coupling, do not guard the window.

### The tests

**● marks a negative control.** A leak/teardown/liveness suite with no arm that *forces* the bad
state cannot clear it: if a test reports the same thing whether or not the failure is present, it
is **void**. The ● arms must be written and seen **red** before their mechanisms exist.

| # | Test | Goes red when |
|---|---|---|
| ● C1 | timed-out handler resumes and calls `share.update()` | the write **lands** — the epoch fence is absent or not on the mutator |
| ● C2 | timed-out handler resumes and calls `publish()` | **any byte reaches the broker** — the zombie-publishes case |
| ● C3 | value read before `await`, unwrapped after | `.at(deadTurn)` returns instead of throwing |
| ● C4 | `close()`, then the fenced handler resumes | the zombie is not mute |
| ● C5 | *(void as written — see the audit)* | — |
| C6 | *(stale — see the audit)* | — |
| C7 | `Timer` (D4) fires **during a handler's `await`** and touches state | the Timer **executes** instead of enqueuing |
| C8 | mailbox full; a shutdown message arrives | shutdown is dropped — reserved headroom absent |
| C9 | mailbox full; a reply continuation arrives | the continuation is dropped, orphaning begun work |
| C10 | delayed messages with out-of-order deadlines | the reference's drain-everything bug is ported |

### The audit — §4.6 answered

§4.6 asked whether C1–C5 can be written red-first. **Five can, in some form; two cannot as
written, and one has a precondition that was already documented and is easy to violate.**

**C1, C3, C4, C8, C10 — writable red-first.** C1's failure is not hypothetical: §1 F2 *is* the
rig. A timed-out handler demonstrably resumes and mutates state 200ms after the caller gave up,
so removing the fence produces the red arm directly. C3 is the `Reading<T>` epoch check, already
prototyped on 3.13 with both a compile-time and a runtime control.

**C2 — writable ONLY against a recording loopback.** §4 already warns that
`AikoRuntime.inMemory()` must not copy the reference's `Castaway` Null Object, because Castaway
silently drops every publish. A test asserting *"no byte reached the broker"* passes **trivially**
against a dropper. This is the void-instrument trap and the document already knew it; it is
restated here as a **precondition of C2**, not a note elsewhere.

**C5 — VOID AS WRITTEN. It goes green for the death it exists to detect.** It was
*"CPU-bound handler longer than the keepalive interval → red when the broker fires our LWT."*
D8's round-3 consequence is that once the transport is on its own isolate, a **dead** actor also
never fires the LWT, because the transport keeps pinging over the corpse (§1 F3: a dead isolate's
`SendPort` accepts sends silently forever, and the parent is told nothing). So C5 is satisfied by
a runtime that never fails over **anything** — including a genuinely dead one. It must be **split
in two**, and neither half is optional:

- **C5a** *(busy is not dead)* — CPU-bound handler exceeds the keepalive interval → **red if the
  LWT fires.**
- **C5b** *(dead IS dead)* — the actor isolate is killed outright → **red if the LWT does NOT
  fire within the liveness-proof deadline.** The deadline now has a **measured** benchmark to beat:
  the reference takes **86 seconds** to notice a frozen-but-socket-alive process (D8). A liveness
  proof whose deadline is not far below that buys nothing, so C5b's threshold is a real number and
  not a placeholder.

Without C5b, C5a is passed by disconnecting the LWT entirely. **This is the same defect the
tests exist to catch, sitting in the test.**

Both are **○-class**: they need a real broker and real keepalive timing, so they are blocked on
the same infrastructure as ADR-0001's `○ V12` and **must not be counted as passing** until it
exists.

**C6 — STALE. Its red condition names a mechanism that was deleted.** It read *"`ask` during a
long peer delay, other messages queued behind → red when the mailbox does not drain — **parking is
absent**."* Parking is dead (§5). The test asserts the presence of a mechanism this document now
forbids, so as written it must **always** be red. Rewriting it needs the continuation-ordering
answer, which is **withdrawn and blocked upstream** (§2.3, §4.1) — so C6 stays empty and named,
rather than quietly deleted.

**C7 — needs an F1 qualification, or it cannot construct its own condition.** It read *"`Timer`
fires **mid-handler**"*. §1 F1: during a **synchronous** slice **no `Timer` fires at all**. So
against a synchronous handler the Timer cannot fire mid-handler, the condition never occurs, and
the test passes for the wrong reason. "Mid-handler" is only constructible **during an `await`**,
and C7 now says so.

**C9 — partially blocked upstream.** "A reply continuation arrives" presupposes knowing *which*
request a reply belongs to. Per §2.3 the wire carries no request identity, so C9 is writable for
a **single** in-flight request and not for the concurrent case it is really about.

### What this says about the document

§4.6 asked *"can these tests be written red-first?"*. The honest answer is that **the question
could not be executed as asked, because the tests were not there** — and of the eight that
survive scrutiny, one was void, one was stale, and one could not construct its own precondition.

**No strike should be scheduled against this document until C5a/C5b, C6 and C7 are settled.** An
adversarial round grades a design against its acceptance criteria; three cross-family rounds
already read "Test ● 2" and "Test ● 5" and agreed with sentences pointing at nothing.

## 3. Decisions held here

### D4 — Delayed messages honour their deadlines

*Python:* the timer starts only on an empty→non-empty transition, and when it fires it drains the
**entire** queue regardless of each entry's deadline — so longer-delayed entries fire **early**.

*Dart:* a deadline-ordered queue with a `Timer` for the earliest deadline only, rescheduled on
insert. **The Timer enqueues a message; it never executes a handler** (§2.4).

### D6 — `run()` lives on Actor, not Service

*Python:* `Service.run()` raises `SystemExit` — *"currently only supported by Actor."*

*Dart:* that is a runtime throw standing in for a fact the type system can state. `run()` belongs
to the type that can actually do it.

### D8 — The two-thread hop collapses — and that is a tradeoff, not a win

*Python:* paho's `loop_start()` runs network I/O on a **background thread**, so
`ProcessImplementation.on_message()` does nothing but `event.queue_put(...)`, bouncing every
incoming message onto the main event loop. `message.md` documents the bug this leaves: framework
code that waits on the paho thread for a condition driven by an *incoming* message deadlocks.

*Dart:* there is no second thread. The hop is a Python artifact, and **that** deadlock class
cannot be constructed here.

**RECAST TWICE.** Revision 1 called the thread-collapse a pure win. Revision 2 attached a cost
but got the **physics wrong**, and Tesla caught it:

- **A long `await` does not block keepalives at all.** Timers and socket callbacks run during an
  await — that is what an event loop is *for*. **Measured: §1, F1** — 4 keepalive ticks fired during
  a 250ms `await`. Revision 2 proposed bounding handler *wall-clock*
  duration, which is the wrong quantity.
- **The danger is uninterrupted SYNCHRONOUS work** — a fat S-expression parse, a tight loop.
- **And during a synchronous slice no `Timer` fires**, so §2.5's handler timeout — itself a Timer
  — *cannot fire either*. Revision 2's mitigation was provably incapable of protecting the thing
  it was proposed to protect. A smoke alarm wired to the fire. **Measured: §1, F1** — a 300ms slice
  held a `Timer(0)`, a `Timer(50ms)` and a `Timer(150ms)`, all three firing together and already
  late once it ended.

The failure it permits: a ping is missed, the broker publishes our retained last will `(absent)`
on `{ns}/{host}/{pid}/0/state`, and **the fleet fails over a process that was only busy.**

**Decision: the MQTT client runs on its own isolate. Default, not fallback.** Reached
independently by Kelvin and Tesla once the timeout was shown non-viable, and the third option —
stretching keepalive to worst-case handler duration — is rejected because it deafens genuine
crash detection.

Unusually cheap for us: isolates copy what crosses the port, and **what crosses here is already
flat text**. We hand the transport isolate the S-expression bytes we were about to put on the
wire regardless. No object graphs, no deep copies. The costs are a little setup, stack traces
that do not cross the boundary, and one isolate's memory.

The handler timeout survives, with its purpose corrected: it exists for **head-of-line
loudness**, sized independently of the keepalive interval. D8 no longer claims it protects pings.

**Two consequences round 3 found, and neither is optional.**

**(1) Failure-linking, or we trade a false-negative for a false-positive.** Rounds 1 and 2 fixed
"a busy process is declared dead". Round 3 found the inverse: **Dart isolates are not
failure-linked by default** (**measured: §1, F3** — a corpse's `SendPort` accepts sends silently
forever and the parent receives neither error nor exit signal unless both ports were requested at
`spawn`), so if the actor isolate wedges — or *dies* — the transport isolate
keeps pinging, the broker withholds the last will, and **the fleet never fails over a corpse whose
heart still beats on the other side of the port.** Test **C5** goes *green* for that death — which
is why §2.7 splits it into C5a/C5b.
The LWT is our only liveness signal, and D8 has just decoupled it from the organ whose liveness it
reports. **The actor isolate must periodically prove it is serving; if that proof lapses, the
transport isolate stops pinging and lets `(absent)` fire.** Health must be pinned to the terminal
observable, not to the nearest green thing one hop before it.

#### D8's hole, measured: **86 seconds** — and the LWT is per-PROCESS, not per-Actor

*Added 2026-08-26. Measured by the peer Claude session in `aiko_services` against a live broker,
Registrar, victim and peer, with `mosquitto_sub` capturing the raw wire as an independent
instrument. Every source claim below verified here at `d31ba17`.*

**The structural finding changes the shape of the answer.** `process.py:101-104`:

```python
topic_path = f"{topic_path_process}/0"      # service id 0 IS the Process
topic_lwt  = f"{topic_path}/state"
```

The last will is registered **per-Process, on service id 0**, hardcoded. Actors get other ids via
`get_topic_path(service_id)`. So:

- **There is no per-Actor liveness signal anywhere.** An observer watching an Actor's
  `.../1/state` sees nothing, ever — the signal was always on `.../0/state`.
- **N Actors in one Process die as one indistinguishable unit.** The OS process is the only fault
  boundary, now with wire evidence rather than source reading.

**The corpse case, measured directly.** `SIGSTOP` freezes the app while the kernel holds the TCP
socket `ESTABLISHED` — D8's scenario exactly:

```
20:56:31  SIGSTOP                          process TN, socket ESTABLISHED
20:57:57  aiko/…/20050/0/state (absent)    ← +86 seconds
```

Consistent with MQTT's 1.5 × `keepalive`, and `keepalive=60` (`mqtt.py:130`). **For 86 seconds the
Actor stayed registered, discoverable, returned by `do_discovery`, and accepting pings into a
frozen process. No peer could tell.**

> **So D8's liveness proof is not belt-and-braces. It is the only thing that closes an 86-second
> hole.** Any fleet that must fail over faster than ~90s for anything short of outright process
> death gets nothing from the reference, and an application-level heartbeat is mandatory.

By contrast, **process death is fast and for an uninteresting reason**: on both clean `terminate()`
and `SIGKILL` the LWT fires in under a second — because the OS closes the socket, not because
anything detected anything. `keepalive` is irrelevant when the socket closes.

**Two consequences we would otherwise have got wrong.**

**(a) A graceful disconnect would DELETE the only death signal.** `terminate()` calls only
`event.terminate()` — no deregistration, no farewell publish — and the process exits *without*
sending an MQTT DISCONNECT, which is precisely why the broker fires the will. `mqtt.py:143` is
explicit: `disconnect()  # Note: Does not cause LWT to be sent`. Adding a "proper" graceful
shutdown path to the Dart port would **suppress** the death notification. This is a landmine
labelled as an improvement.

**(b) Liveness routes through the Registrar, not from the dying Actor.** Nothing reaches a peer
from the corpse. The peer learns because it is subscribed to the Registrar's `/out`, which
publishes `(remove <topic>)` ~0.3s after the LWT. **No Registrar means no death notification
regardless of the LWT.** That dependency is inherited and must be stated wherever D8's liveness
proof is specified.

#### The silent proxy — architectural, not a Dart regression, and it hands us a free win

14+ `proxy.ping(n)` calls after confirmed death, every one returning normally with no error.
`_make_service_proxy` closes over `aiko.message.publish(...)` with no error path; the publishes
land on a topic with zero subscribers and the broker discards them.

This is the exact analogue of §1 F3's silent `SendPort`. **Both runtimes fail the same way, so
this is a property of the architecture and D8 is the right shape rather than a Dart-specific
patch.** We are not inheriting a regression.

But the sharpest detail is an opportunity, not a warning:

> **The same process had already fired `remove_handler` for that Actor at t=7.9s, and went on
> calling the proxy at t=8, 9, 10…** The liveness information was *in the process*. The proxy does
> not consult it.

That is an **unconsulted** signal, not a missing one. A Dart proxy can consult the Registrar state
the runtime already holds and fail loudly on a known-dead target — **no wire change, no upstream
dependency, strictly better than the reference.** Recorded here rather than built: it belongs with
D8's liveness specification.

**Scope of the measurement, honestly.** Single host, localhost, one broker, one Registrar.
`SIGSTOP` models a *frozen application with a live socket*. A true network partition also stops
kernel ACKs, so TCP retransmission timers could interact and that case is **not measured**. The
86s figure is "frozen app, socket alive" and must not be quoted as a partition-detection time.


**(2) The `SendPort` is an unbounded queue in FRONT of the bounded mailbox.** **Measured: §1, F4** —
400,000 messages into a paused consumer in 478ms, +345MB RSS, zero drained, producer never blocked. §2.6's carefully
classed overflow table is defeated one layer upstream: drop-newest fires only *after* the port has
already eaten the RAM and MQTT QoS has already ACKed, and `(absent)` / disconnect sit behind bulk
publishes with no reserved headroom on the port. **Credit-based backpressure across the boundary**
— the transport isolate issues credits, `publish()` consumes one, no credit means no send — with
reserved credits for control frames. Kelvin: *"a system without a control loop is just a pipe
waiting to burst."*

Also inherited from the boundary and to be specified with it: per-topic ordering (one `SendPort`
preserves order; control-vs-bulk does not), error propagation, connection-lost/reconnect and
session state living only on the transport isolate while the runtime believes it is connected, and
outbound flush during `close()`.

**The publish fence sites in the MAIN isolate, before the `SendPort`.** §2.5 suppresses a dead
epoch's publishes; if that check runs anywhere downstream the bytes are already across the boundary
and the zombie has published. Test **C2** asserts *"any byte reaches the broker"*, so the mechanism
must sit upstream of the hand-off.

**The web has no isolates at all — MEASURED, and the earlier wording was wrong.** Revision 4 said
`Isolate.spawn` "maps onto web workers with far tighter constraints". It does not map onto anything.
F6: `dart:isolate` is a pure stub on **both** web backends, and the failure lands one layer lower
than spawn — under dart2js `ReceivePort.sendPort` itself throws `UnsupportedError`, so a port cannot
even be obtained to hand a child.

Two consequences, neither optional:

- **The platform seam must sit ABOVE the port abstraction**, not around `Isolate.spawn`. Anything
  typed in terms of `SendPort` is already unbuildable on web.
- **`compute()` is not an escape hatch** — see §1's corollary. On web it runs the callback on the
  main thread after one microtask, so it satisfies the type checker and the test suite while
  offloading nothing.

The JS equivalent of an isolate is a **Web Worker** (`worker_threads` under Node), and the models
correspond closely: separate heap, no shared mutable state, copy-on-boundary (structured clone),
transferables ≈ `TransferableTypedData`. Dart does not bridge them because `Isolate.spawn` takes a
**function** and `Worker` takes a **script URL**, and a closure cannot be structured-cloned.

So the browser target has two honest answers, and this document does not yet pick one:

1. **A hand-written Web Worker over `dart:js_interop`** — a second compiled entry point, with
   S-expression **text** across `postMessage`. Unusually viable for us: what crosses our boundary is
   already flat text, so structured clone's type limits cost nothing. This is the only option that
   preserves D8's shape.
2. **No offload** — keep handlers non-blocking and accept the risk, since MQTT-over-WebSockets has
   different failure behaviour anyway.

Option 1 is a separate design with its own tracker item; it is deliberately **not** folded in here,
because it is a second build artifact rather than a conditional import, and #3240's conditional-import
split (WebSockets vs raw TCP) is a different axis that stands on its own.


## 4. What must be settled before any of this is built

Carried from `0001-TEMPER-round3.md`, none of it folded yet:

1. ~~**Continuation ordering.**~~ **WITHDRAWN 2026-08-26 — the question was malformed.** It asked
   whether two outstanding `ask` replies run in original-turn, arrival or causal order. All three
   presuppose a correlation between request and reply that **the wire does not carry** (§2.3). The
   reference broadcasts every reply to every registered handler; measured at two requests → four
   firings, with cross-talk. This is now blocked on an upstream wire proposal to Andy (request
   identity), not on a decision available to this document.
2. **`ask` Future/handler completion, exhaustively** — peer timeout, actor close, epoch kill,
   cancellation, mailbox overflow, malformed `item_count` stream, partial response, transport
   loss. Every path must complete exactly once.
3. **`close()` versus in-flight reply continuations.** §2.6 says continuations are never dropped
   *and* that close stops admission. Both rules apply to the most likely real sequence.
4. **An admission algorithm**, not a policy table: concrete capacities, reserved budgets per
   class, the classification point when the queue is already full, starvation rules.
5. **Isolate failure-linking and credit-based backpressure** (D8), plus per-topic ordering,
   error propagation, reconnect/session state, and outbound flush during close.
6. ~~**Whether tests ● 1–5 can be written red-first**~~ **ANSWERED 2026-08-26 in §2.7** — and the
   question could not be executed as asked, because the tests had been lost in the split. C5 was
   VOID (green for the death it detects), C6 STALE (its red condition names deleted `parking`), C7
   could not construct its own condition (F1). Original note follows. Test 5 depends on broker LWT timing,
   keepalive configuration and isolate scheduling; until the boundary is specified it is an
   aspiration, not an acceptance test.

## 5. Recorded so it is not reinvented

**Parking (`await` releases the turn; the continuation re-enters as a fresh turn) does not work.**
`await`'s continuation resumes as a **microtask**; the mailbox never owns "the rest of the
function". Measured in `e5_await_ordering.dart`: handler B's body ran between handler A's two halves
and mutated state under it.

*Revision 4 stated the second half of this wrong, and F5 corrects it.* It said the in-memory loopback
"completes replies synchronously". No `await` continuation ever runs synchronously — it is always a
microtask. What is actually true is sharper, and worse for parking: **the tick at which a continuation
runs depends on when the awaited future's completion was scheduled, not on whether it is complete when
awaited** (§1, F5). So on the loopback the continuation does not merely resume in the wrong *turn* — it
can resume ahead of microtasks queued after the reply future was constructed, i.e. its position depends
on **construction order**, which no mailbox observes. The verdict is unchanged and now rests on a
measurement rather than on a mis-stated mechanism.

It is an attractive idea. It is not implementable in Dart.

**Likewise: a `Completer`-based `await`-shaped `ask` inside a handler** head-of-line blocks the
actor for unbounded peer latency. Both attempts had the same motive — keep `await`'s ergonomics —
and the same outcome. Python's continuation style is not a limitation of Python.

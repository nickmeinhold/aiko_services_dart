# ADR-0002 — The Dart Actor concurrency model

- **Status:** **proposed, NOT converged.** Split out of ADR-0001 on 2026-08-26 (Nick's call) after
  three cross-family design-temper rounds returned RECAST / RECAST / NOT-SOUND. Every unresolved
  flaw from those rounds lives here; ADR-0001 kept the surface that converged.
- **Why the split:** three rounds found **nothing new in ADR-0001's D1–D7 after round 1**. Rounds 2
  and 3 were consumed almost entirely by one mechanism invented mid-loop (parking, now deleted).
  Holding the settled surface hostage to the contested one was costing build time for no evidence.
- **Strike record:** `0001-TEMPER.md`, `0001-TEMPER-round2.md`, `0001-TEMPER-round3.md`.
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

### 2.3 Replies: conform to `do_request()`, all the way

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

Inherited constraints, not negotiable: reply reassembly is a **process-level** state machine
(`(item_count N)` then N × `(response …)`) with its own timeout, and each `response_topic` is
**single-use** — a reused topic mixes two requests' replies (`dir-id f7a8`).

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
  await — that is what an event loop is *for*. Revision 2 proposed bounding handler *wall-clock*
  duration, which is the wrong quantity.
- **The danger is uninterrupted SYNCHRONOUS work** — a fat S-expression parse, a tight loop.
- **And during a synchronous slice no `Timer` fires**, so §2.5's handler timeout — itself a Timer
  — *cannot fire either*. Revision 2's mitigation was provably incapable of protecting the thing
  it was proposed to protect. A smoke alarm wired to the fire.

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
failure-linked by default**, so if the actor isolate wedges — or *dies* — the transport isolate
keeps pinging, the broker withholds the last will, and **the fleet never fails over a corpse whose
heart still beats on the other side of the port.** Test ● 5 goes *green* for that death.
The LWT is our only liveness signal, and D8 has just decoupled it from the organ whose liveness it
reports. **The actor isolate must periodically prove it is serving; if that proof lapses, the
transport isolate stops pinging and lets `(absent)` fire.** Health must be pinned to the terminal
observable, not to the nearest green thing one hop before it.

**(2) The `SendPort` is an unbounded queue in FRONT of the bounded mailbox.** §2.6's carefully
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
and the zombie has published. Test ● 2 asserts *"any byte reaches the broker"*, so the mechanism
must sit upstream of the hand-off.

**Open, and honest: the web has no real isolates.** Compiled to JavaScript, `Isolate.spawn` maps
onto web workers with far tighter constraints, so this mitigation is unavailable for the browser
target (#3240 / #2268). That build needs its own answer — likely "keep handlers non-blocking and
accept the risk", since MQTT-over-WebSockets has different failure behaviour anyway. Naming it
now beats discovering it after building on the assumption.


## 4. What must be settled before any of this is built

Carried from `0001-TEMPER-round3.md`, none of it folded yet:

1. **Continuation ordering.** Two outstanding `ask`s from one actor: do their replies run in
   original-turn order, arrival order, or causal order? Unspecified.
2. **`ask` Future/handler completion, exhaustively** — peer timeout, actor close, epoch kill,
   cancellation, mailbox overflow, malformed `item_count` stream, partial response, transport
   loss. Every path must complete exactly once.
3. **`close()` versus in-flight reply continuations.** §2.6 says continuations are never dropped
   *and* that close stops admission. Both rules apply to the most likely real sequence.
4. **An admission algorithm**, not a policy table: concrete capacities, reserved budgets per
   class, the classification point when the queue is already full, starvation rules.
5. **Isolate failure-linking and credit-based backpressure** (D8), plus per-topic ordering,
   error propagation, reconnect/session state, and outbound flush during close.
6. **Whether tests ● 1–5 can be written red-first** at all. Test 5 depends on broker LWT timing,
   keepalive configuration and isolate scheduling; until the boundary is specified it is an
   aspiration, not an acceptance test.

## 5. Recorded so it is not reinvented

**Parking (`await` releases the turn; the continuation re-enters as a fresh turn) does not work.**
`await`'s continuation resumes as a **microtask**; the mailbox never owns "the rest of the
function". It also fails *deterministically* on the in-memory loopback, which completes replies
synchronously — i.e. exactly on the uniform local/remote path the mailbox exists to make
identical. It is an attractive idea. It is not implementable in Dart.

**Likewise: a `Completer`-based `await`-shaped `ask` inside a handler** head-of-line blocks the
actor for unbounded peer latency. Both attempts had the same motive — keep `await`'s ergonomics —
and the same outcome. Python's continuation style is not a limitation of Python.

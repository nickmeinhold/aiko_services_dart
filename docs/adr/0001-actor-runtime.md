# ADR-0001 — The Dart Actor runtime

- **Status:** proposed — **revision 3 (recast)**, 2026-08-26. Revision 1 returned RECAST on 13
  flaws (`0001-TEMPER.md`); revision 2 returned RECAST on 9 more (`0001-TEMPER-round2.md`),
  unanimous across all four families. This revision folds all 9. **Round 3 is the last permitted
  round.** No `lib/` code until it returns SOUND.
- **Date:** 2026-08-25, recast 2026-08-26
- **Context:** first framework code in `lib/`; everything after it inherits these shapes
- **Mandate:** Nick, 2026-08-25 — *"framework port should be designed, not just ported"*

## 0. What the recast changed, and why it is worth reading twice

Revision 1 stated one rule — *below the wire conform exactly, above the wire design* — and then
broke it twice, in the two places it felt most creative. Both breaks were found by reading
`share.py` and `discovery.py`, **not** by reading Andy's concept docs, and not by any of the four
adversaries, three of whom struck the same decision on a premise they had inherited from the
document they were reviewing.

The lesson is now a design rule of its own, recorded here because it will fire again:

> **The concept docs are intent. The source is the contract.** Before any decision claims a
> behaviour is "above the wire", open the reference implementation and read the function that
> implements it. Four reviewers agreeing is four copies of one premise, not four observations.

**Round 2 added a second rule, and it is the one that cost the most:**

> **A fix is not folded until it has a MECHANISM.** Round 2 found that three of revision 1's
> flaws had been *described* rather than repaired — shutdown, overflow and cancellation were each
> answered with the phrase "by a stated rule" and no rule. A prose gate is not a gate. Every
> policy in revision 3 either names its enforcing construct or is explicitly listed as open.

Three things changed shape in revision 2, and one decision inverted outright:

1. **D2/D5 were seam violations.** `lifecycle` is a live, cross-service, remotely-subscribed wire
   key, and `share` is a depth-2 tree, not a flat map. Both are now inherited contract in §1.
2. **§2's deadlock has an answer already in the reference**, and it is better than anything the
   strike proposed. `do_request()` is continuation-style with a caller-nominated response topic
   handled at *process* level — replies never enter the actor mailbox. We conform (§2.3).
3. **D8 inverted from a pure win to a priced tradeoff.** Deleting paho's network thread also
   deletes the thing that kept MQTT keepalives alive while a handler thought (D8).

**And revision 2's own fix broke revision 2.** Its handler timeout said "abandon the wait and
continue draining" — but **Dart cannot cancel a Future**, so the abandoned handler kept running
and mutated state concurrently with the next one. Worse, it *published*: remote Python
ECConsumers would converge on a corpse's last thought while the dashboard read `ready`. The
mechanism added to make a stuck actor observable was the mechanism that made it corrupt. That is
D9, and it is the centre of this revision.

## 1. The seam

One rule governs every decision below.

> **Below the wire: conform, exactly. Above the wire: design.**

The wire is `RFC-0001`, the conformance vectors in
`test/codec/fixtures/s_expression_golden.json`, **and the reference behaviours enumerated in
this table**. It does not move to accommodate anything here.

| Surface | Contract |
|---|---|
| topic path | `{namespace}/{host}/{pid}/{service_id}` |
| derived topics | `/control` `/in` `/out` `/log` `/state` |
| command | `(method_name arg …)` published to `topic_in` |
| reply | **none by default** — one-way. Request/response is a *separate topic*, not a return value (see below) |
| shared state | `(add k v)` / `(update k v)` / `(remove k)` on `/control` |
| **share addressing** | **dotted paths — `(update metrics.running 3)`. `share.py::_ec_parse_item_path()` splits on `.` and raises `EC "share" dictionary depth maximum is 2`. The share is a depth-2 tree, not a flat map.** |
| **share missing path** | **`_ec_modify_item()` with `create_path=False` silently no-ops when an intermediate level is absent. A malformed path is dropped, not reported.** |
| **framework share keys** | **`lifecycle` (str), `log_level` (str), `running` (bool) at top level. `lifecycle` is read cross-service (`pipeline.py:287` reads *another element's*), branched on (`:949`, `:1032`), and published remotely (`lifecycle.py:265` → `(update lifecycle absent)`).** |
| subscription | `(share <topic> <lease> *)` or `… (lifecycle x)` on `/control` — **the subscription form names the key, so key names are protocol** |
| **request/response** | **`discovery.py::do_request()` — caller nominates a `response_topic`, registers a handler at *process* level via `add_message_handler()`, fires `do_command()` and returns immediately. The reply is a multi-part stream: `(item_count N)` then N × `(response …)`.** |
| **mailbox naming** | **`f"{name}/{service_id}/{topic}"` (`actor.py:248`), bound at registration time in `__init__`** |
| presence | MQTT **last will** `(absent)`, retained by the broker, published on `{namespace}/{host}/{pid}/0/state` when a process dies ungracefully — a clean `disconnect()` does *not* fire it |
| broker transport | `tcp` (1883) or **`websockets` (1884, WSS 9884)** — already selectable in the reference via `AIKO_MQTT_TRANSPORT` |
| proxy send | `args if not kwargs else [args[0], kwargs]` — one positional + dict, `args[1:]` discarded |

Everything above that line is ours. Where the Python's shape is an artifact of *Python*, we take
the shape Dart wants.

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

### 2.3 Replies: conform to `do_request()`, and park the turn

All four families found the same flaw in revision 1: if the mailbox awaits each handler to
completion and a reply arrives *as a message*, a handler that `await`s a reply wedges forever.
Python is immune because `Message.invoke()` is **synchronous** — a Python handler physically
cannot suspend mid-flight.

The reference's answer is structural, and revision 2 correctly found it:
`discovery.py::do_request()` has the caller nominate a **`response_topic`**, registers the
handler at **process** level via `add_message_handler()`, fires `do_command()` and **returns
immediately**. `pipeline.py:1873`'s `topic_response_handler` uses the identical shape, so this is
a pattern with two independent call sites, not one function's habit.

**Revision 2 then reintroduced the bug it had just diagnosed** by floating an `await`-shaped
`Completer` API. Tesla: the reference *returns immediately*, and that is precisely why Python
never holds an actor across a round-trip. An `await ask(...)` inside a handler head-of-line blocks
the mailbox for **unbounded peer latency**.

**Decision — `ask` parks the turn.** The handler may `await`, but awaiting **releases the actor's
turn**; the mailbox immediately dequeues the next message. When the reply lands, the continuation
is queued and runs as a **fresh turn**.

```dart
Future<void> join(String id, Turn t) async {
  final (profile, t2) = await t.ask<Profile>(directory, GetProfile(id));
  // t is spent. t2 is a NEW turn; other messages ran in between.
  if (!profile.banned) t2.addMember(id);
}
```

This keeps `await`'s ergonomics, keeps the actor live throughout, and honours §2.4's law exactly
— the continuation *does* re-enter through the mailbox. What it costs is that **anything read
before the `await` may be stale after it**, which is what D9 exists to catch.

Constraints inherited from the reference, not negotiable: reply reassembly is a **process-level**
state machine (`(item_count N)` then N × `(response …)`) with its own timeout, and each
`response_topic` is **single-use** — a reused topic mixes two requests' replies (`dir-id f7a8`,
identity-as-mutable-key).

*(Candidate, not settled: parking is one hour old at the time of writing and has not been struck.
Round 3 must hit it. The fallback if it fails is strict continuation style — `ask(…, replyTo:)`
with no `await` — which is uglier but certainly correct.)*

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

**Scope deliberately narrow.** Turn-branding applies to mutations that **leave the actor** —
`share.update()` and `publish()` — not to every private field read. That is the set where a stale
value becomes a *wire-visible lie* that remote ECConsumers converge on. Private tearing stays
local; a bad publish poisons the mesh.

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

## 3. Decisions

### D1 — `AikoRuntime`, not a global

*Python:* a mutable module-level `aiko` singleton every module imports.

The invariant is **"exactly one runtime per OS process."** The *global* is Python's spelling of
that invariant, not the invariant itself — and it is the part that makes tests share state and
blocks the roadmap's own "multiple Actors per Process as a first-class feature."

*Dart:* an explicit `AikoRuntime` object, threaded through construction.

**DECIDED 2026-08-25 (Nick):** the explicit object, over both the module-level global and a
Zone-scoped current-runtime. The Zone option is ambient-but-scoped and would give real isolation,
but it makes the dependency invisible at the call site; threading the reference is more typing
and more honest.

**Recast — construction order.** Revision 1's example had the dependency pointing the wrong way.
The LWT can only be registered **at connect time**, and its topic is `{ns}/{host}/{pid}/0/state`,
so identity must exist *before* the transport connects. The runtime therefore builds its
transport from configuration rather than receiving a connected one:

```dart
final runtime = await AikoRuntime.connect(config);   // identity, then LWT, then connect
final counter = runtime.addService(CounterDefinition(name: 'counter'));

// tests get isolation without process teardown:
final rt = AikoRuntime.inMemory();   // loopback, NOT a null transport — see §5
addTearDown(rt.dispose);
```

**Recast — multiple runtimes are TEST-ONLY.** Revision 1 sold multiple-runtimes-per-process as a
win without pricing it. Two runtimes in one VM contend over MQTT client identity, LWT ownership,
retained process state, namespace, and `service_id` allocation. Until that allocation is
designed, **production multi-runtime is out of scope**; `inMemory()` exists for test isolation.
*(Conservative arm taken 2026-08-26 pending Nick's ruling — flagged in §6.)*

### D2 — `ServiceState` is an internal view; the wire keys do not move

**RECAST — revision 1 was a seam violation.** It proposed merging `lifecycle` and `running` into
one `state` key, on the strength of the reference's own roadmap. But `lifecycle` is live wire
vocabulary: `pipeline.py:287` reads **another element's** `share["lifecycle"]`, `:949` and
`:1032` branch control flow on it, `lifecycle.py:265` publishes `(update lifecycle absent)` to
remote clients, and §1's subscription form `(share <topic> <lease> (lifecycle x))` **names the
key in the protocol**. Dashboard filters, `mosquitto_pub`, Category and ServicesCache all match
on key names across a mixed Dart/Python mesh.

*Dart:* a sealed `ServiceState`, exhaustive at compile time, mutated through exactly one door so
a notification cannot be skipped — but it is a **projection over the inherited keys**, not a
replacement for them. We publish `lifecycle` and `running` unchanged, with their existing types
and values. No `state` key is introduced.

The consolidation is still the right idea. It is **Andy's to make on the wire**, and it goes to
him as a proposal (§6), not into a port unilaterally.

What survives from revision 1 intact: `run()` must mutate through `ec_producer.update()`, never
by direct assignment. The reference's direct assignment (`actor.py:313`, `:320`) means remote
consumers are never notified — a real bug, and fixing it changes no key names.

### D3 — Failures surface; they do not vanish

*Python:* `Message.invoke()` catches `Exception` and **swallows** it. The doc says the quiet part
out loud: *"a catch of everything hides bugs in the target function."*

*Dart:* invocation failures are surfaced on an error `Stream` on the runtime, in addition to
logging. Outbound only (§2.4). This costs nothing on the wire and is `dir-id 3f6b`.

Now also carries: `HandlerTimeout`, mailbox overflow, share-path drops (§1's silent no-op), and
invalid inbound framework values (D5).

### D4 — Delayed messages honour their deadlines

*Python:* the timer starts only on an empty→non-empty transition, and when it fires it drains the
**entire** queue regardless of each entry's deadline — so longer-delayed entries fire **early**.

*Dart:* a deadline-ordered queue with a `Timer` for the earliest deadline only, rescheduled on
insert. **The Timer enqueues a message; it never executes a handler** (§2.4).

### D5 — A typed facade over one canonical share tree

**RECAST — revision 1 had the wrong data model, not merely a missing collision policy.** It
proposed "a typed framework slice beside an open `Map`", with everything serialising to
`(update <key> <value>)`. That is flat. The contract (§1) is a **depth-2 tree addressed by dotted
paths**, with a hard `depth maximum is 2` and a **silent no-op** when an intermediate level is
missing. All four families struck this decision on collision policy and none on shape, because
all four were reading revision 1's flat description rather than `share.py`.

*Dart:* **one canonical wire-shaped share tree as the single source of truth**, with typed
accessors as a *facade* over it — not a second storage location. This dissolves the projection
layer, the snapshot-merge rules and the dual-writer problem rather than specifying them.

- Framework keys (`lifecycle`, `log_level`, `running`) are **reserved centrally**; an application
  write to a reserved key is rejected at the mutator with an error on D3's stream.
- Depth > 2 is rejected at the mutator, matching the reference's `ValueError`.
- **TWO inbound paths, because there is a tree per consumed topic** (round-2 flaw 6, Tesla).
  Revision 2 wrote one mutator law for one tree, which is wrong for a mesh:
  - **Our own `/control`** — an invalid framework value (`(update log_level junk)`) or a
    `(remove <framework-key>)` is **rejected**, the previous value retained, the rejection
    surfaced on D3's stream. Neither thrown (a malformed remote message must not kill an actor)
    nor silently ignored (the silence D3 abolishes).
  - **An ECConsumer replica of a peer's share** — we **store what the producer sent** and warn on
    D3. We do *not* "correct" another service's state. Rejecting it would make Dart diverge from
    the mesh it exists to converge with, while `pipeline.py:287` still reads whatever the peer
    actually stored.
- **The sealed view carries an `unknown` case.** When Python adds a lifecycle string we have not
  enumerated, a closed Dart type would be blind to a state Python branches on. `unknown(String)`
  preserves the value and keeps exhaustiveness honest.
- **The tree never leaks a nested `Map`.** Handing `share['metrics']` to application code creates
  a dual writer by alias — mutation with no mutator, no reserved-key check, no `ec_producer`
  notification. Nested access returns copies or turn-scoped views, never the live map.
- A missing intermediate path is a **reported** drop, not a silent one — the one place we are
  deliberately louder than the reference while remaining wire-identical.

### D6 — `run()` lives on Actor, not Service

*Python:* `Service.run()` raises `SystemExit` — *"currently only supported by Actor."*

*Dart:* that is a runtime throw standing in for a fact the type system can state. `run()` belongs
to the type that can actually do it.

### D7 — Registration is the constructor boundary

**RECAST — revision 1 named the requirement and skipped the decision.** All four families called
it a TODO wearing a decision's clothes, and Tesla found the live bug: mailbox naming is
`f"{name}/{service_id}/{topic}"` (`actor.py:248`), bound at registration time in `__init__`. Two
unregistered `'counter'`s therefore collide — `dir-id f7a8`, identity-as-mutable-key, in the
example revision 1 itself printed.

The observers that exist before `service_id` does: the user's binding, mailbox naming, ECProducer
(control + state topics), the per-Actor logger (`/log`), `add_message_handler` subscriptions,
local proxies posting into a nameless box, Registrar announce, and any collaborator constructed
with `this`. Python hides the gap because `ServiceImpl.__init__` admits as a *constructor
side-effect*.

*Dart:* two types, and no nullable identity anywhere.

- **`ServiceDefinition`** — configuration only. Has no `serviceId` and no `topicPath` *field to
  be null*. Cannot publish, subscribe, or name a mailbox.
- **`RegisteredService`** — **returned by** `runtime.addService(definition)`. Identity is
  non-nullable and final; every identity-bearing operation lives here.

Registration is the constructor boundary. There is no reachable half-built object, no nullable
`topicPath` taxing every call site, and no throwing getter re-implementing the `SystemExit` D6
exists to delete.

*Constraint preserved (not a divergence):* identity still flows Process → Service, and `Process`
is still deliberately not composable because it *creates* the context the composition machinery
needs.

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

**Open, and honest: the web has no real isolates.** Compiled to JavaScript, `Isolate.spawn` maps
onto web workers with far tighter constraints, so this mitigation is unavailable for the browser
target (#3240 / #2268). That build needs its own answer — likely "keep handlers non-blocking and
accept the risk", since MQTT-over-WebSockets has different failure behaviour anyway. Naming it
now beats discovering it after building on the assumption.

## 4. First vertical slice

Dependency order:

1. `ServiceTopicPath` — the five-topic fan-out as a value type
2. `ServiceState` — sealed lifecycle **with `unknown`**, projected over inherited keys (D2)
3. `Turn` / `Reading` / epoch fence (D9) — **before** the mailbox, because the mailbox's
   guarantee is expressed in terms of it
4. `Mailbox` — deadline-ordered, class-aware bounded, parking-capable
5. `Actor` — mailbox + share facade + error stream, `topic_in` → dispatch
6. `TransportIsolate` — MQTT on its own isolate (D8)
7. `AikoRuntime` — identity, then LWT, then connect; `addService` → `RegisteredService`

Acceptance tests first. Round 2's finding was that revision 2's thirteen tests *"can all pass
while the zombie still publishes — they are tests of round 1's war."* Each test below names the
condition under which it goes **red**, and the ones marked ● are the arms that force the failure
rather than merely observing its absence.

| # | Test | Goes red when |
|---|---|---|
| ● 1 | timed-out handler resumes and calls `share.update()` | the write **lands** — the epoch fence is absent or not on the mutator |
| ● 2 | timed-out handler resumes and calls `publish()` | **any byte reaches the broker** — this is the zombie-publishes case |
| ● 3 | value read before `await`, unwrapped after | `.at(deadTurn)` returns instead of throwing |
| ● 4 | `close()`, then the fenced handler resumes | the zombie is not mute |
| ● 5 | CPU-bound handler longer than the keepalive interval | the broker fires our LWT — i.e. transport is **not** on its own isolate |
| 6 | `ask` during a long peer delay; other messages queued behind | the mailbox does not drain — parking is absent |
| 7 | `Timer` (D4) fires mid-handler and touches state | the Timer **executes** instead of enqueuing (fails under a Future chain, passes under a mailbox) |
| 8 | mailbox full; a shutdown message arrives | shutdown is dropped — reserved headroom absent |
| 9 | mailbox full; a reply continuation arrives | the continuation is dropped, orphaning begun work |
| 10 | delayed messages with out-of-order deadlines | the reference's drain-everything bug is ported |
| 11 | app writes a reserved share key | accepted, or dropped without report |
| 12 | inbound `(update log_level junk)` on **our** `/control` | throws, **or** is silently ignored |
| 13 | inbound invalid value on a **peer replica** | we reject it — we must store and warn (D5) |
| 14 | inbound `(update a.b.c 1)` — depth 3 | accepted, or dropped without report |
| 15 | `share['metrics']` handed out and mutated | the live map escaped |
| 16 | Python adds an unseen lifecycle string | the sealed view cannot represent it |
| ○ 17 | a real Python ECConsumer reads our snapshot | `lifecycle`/`running` missing or renamed |
| 18 | two `ServiceDefinition`s named `'counter'` | identity assigned before admission (D7) |

**● are the negative controls.** A leak/teardown/liveness suite with no arm that *forces* the bad
state cannot clear it — if a test would report the same thing whether or not the failure is
present, it is void. Tests 1–5 must be written and seen **red** before their mechanisms exist.

**○ 17 is blocked on infrastructure and must not be counted as passing.** It needs a live Python
reference plus a broker, and **this repo has no `.github/workflows/` at all** (`dir-id 7b3e` — a
trigger that never fires reads as safety). Tracked separately; it is the only test standing
between this port and a silent wire regression, so `dir-id c0de` applies: a self-roundtrip proves
self-consistency, not correctness.

**D7's admission rule, stated so test 18 has something to assert:** duplicate `name`s are
**permitted**; `service_id` alone distinguishes mailboxes, matching `actor.py:248`'s
`{name}/{service_id}/{topic}`. What must be impossible is a mailbox named before `service_id`
exists — which `ServiceDefinition` having no identity field guarantees by construction.

## 5. Test transport: loopback, not Null Object

`Castaway` is the reference's Null Object — no-op publish/subscribe when no broker is reachable.
`AikoRuntime.inMemory()` must **not** copy it. Castaway silently drops every publish, so a test
against it passes whether or not the message was correct. The in-memory runtime is an in-process
**loopback** that round-trips through the real codec, so acceptance tests exercise the wire
without a server.

## 6. Open — Nick's call, and Andy's

**Conservative arms taken 2026-08-26 so the recast was not blocked. Both are "conform below the
wire", so neither needs new authority — but both are reversible and flagged for veto.**

- **(a) `lifecycle`/`running` → `state`.** Taken: publish the inherited keys unchanged,
  `ServiceState` internal only (D2). **The consolidation goes to Andy as a wire proposal** — his
  own `actor.py:86` TODO wants it, and it is his wire.
- **(b) Multiple runtimes per process.** Taken: test-only (D1). If it should be a production
  capability, identity allocation (MQTT client id, LWT ownership, retained state cleanup,
  `service_id`) needs designing first.
- **(c) MQTT on its own isolate (D8).** Taken: yes, as the default. An architecture cost, arrived
  at independently by two families once revision 2's timeout was shown incapable of protecting a
  keepalive. Flagged because it is a real cost, not because the engineering is uncertain.
- **(d) Parking the turn (§2.3) is a CANDIDATE, not a decision.** It is hours old and unstruck,
  and it is the newest load-bearing idea in the document. Round 3 must aim at it. Fallback:
  strict continuation style, uglier and certainly correct.

**Resolved and not to be re-litigated:** the explicit `AikoRuntime` (D1, Nick 2026-08-25);
Castaway is a Null Object and not a transport, so #3240/#2268 are conformance work against the
reference's existing `AIKO_MQTT_TRANSPORT=websockets` on 1884/9884.

## 7. What this document does NOT claim

The codec beneath this is **parity-tested against a reference that has its own bugs** — a parity
claim, not a correctness claim.

Nothing here has been implemented. This is a design proposal at **revision 2**, folding a
four-family strike it has **not yet been re-struck against**. Revision 1 read as confident and
was wrong in two places; revision 2 is better evidenced and carries the same warning. It is
UNPROVEN until it exists, runs, and survives round 2.

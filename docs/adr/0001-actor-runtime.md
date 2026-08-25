# ADR-0001 — The Dart Actor runtime

- **Status:** proposed — **revision 2 (recast)**, 2026-08-26. Revision 1 was struck by a
  four-family design-temper and returned RECAST on 13 flaws; see `0001-TEMPER.md`. This
  revision folds all 13. It has **not** been re-struck, and no `lib/` code should be written
  against it until a round-2 strike returns SOUND.
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

Three things changed shape as a result, and one decision inverted outright:

1. **D2/D5 were seam violations.** `lifecycle` is a live, cross-service, remotely-subscribed wire
   key, and `share` is a depth-2 tree, not a flat map. Both are now inherited contract in §1.
2. **§2's deadlock has an answer already in the reference**, and it is better than anything the
   strike proposed. `do_request()` is continuation-style with a caller-nominated response topic
   handled at *process* level — replies never enter the actor mailbox. We conform (§2.3).
3. **D8 inverted from a pure win to a priced tradeoff.** Deleting paho's network thread also
   deletes the thing that kept MQTT keepalives alive while a handler thought (D8).

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

### 2.3 The reentrancy deadlock, and why the reference already answers it

All four families independently found this, and it is the flaw that most nearly sank revision 1:
if the mailbox awaits each handler to completion before dequeuing the next, and a reply arrives
*as a message*, then any handler that `await`s a reply wedges permanently. Python is immune
because `Message.invoke()` is **synchronous** — a Python handler physically cannot suspend
mid-flight — so the idiom forces continuation style. Dart's `async` invites exactly the `await`
that kills it.

The strike proposed reentrancy tokens, bypass lanes and bounded reentrancy. **All three are
unnecessary.** `discovery.py::do_request()` shows the reference has already solved it, and the
solution is structural rather than clever:

- the caller nominates its own **`response_topic`**;
- the response handler is registered with `aiko.process.add_message_handler()` — at **process**
  level, not on the actor's mailbox;
- `do_request()` fires `do_command()` and **returns immediately**;
- the reply is a multi-part stream, `(item_count N)` followed by N × `(response …)`.

**Decision:** conform. Replies are delivered to a process-level response-topic handler and
**never enter the originating actor's mailbox**. There is therefore no cycle to deadlock, and no
mechanism to build.

**Consequence we accept:** a request cannot be written as `final r = await actor.ask(...)` with
the reply routed back through the same mailbox. Dart may still offer an `await`-shaped API — a
`Completer` completed by the process-level response handler — but the completion path must
provably bypass the mailbox. `dir-id 5e1f`: remove the coupling, do not guard the window.

### 2.4 The closure law — what revision 1 promised but did not state

§2.1 promises "no message observes torn state". A mailbox alone delivers only "no *mailbox
message* observes torn state". Every other entry point into actor state is a hole, and D4 opens
one **by design**. So the guarantee is stated as a law, in Erlang's form:

> **The mailbox is the only legal mutator of actor state. Every I/O completion, timer, reply and
> stream event that needs to touch the actor re-enters as a message.**

Concrete side doors this closes, all of which mutate *after* the mailbox has dequeued the next
command: `unawaited(save())`, `Timer(...)`, `stream.listen`, `publish().then`, and any Zone
microtask closing over `this`. Consequences:

- **D4's `Timer` must enqueue, not execute.** Its callback posts a message; it does not run the
  handler.
- D3's error `Stream` is **outbound only** — nothing may mutate actor state from a subscription.
- Inbound `(update …)` share events from the wire enter through the mailbox like any command.

This is `dir-id 6b6a` — the single door is the MUTATOR — which revision 1 applied to D2 and
never applied to §2.

### 2.5 Liveness — a hung handler must not be a silent permanent wedge

Head-of-line blocking is the cost of §2.4. Priced explicitly:

- **Handler timeout**, defaulted and per-actor overridable. On expiry: abandon the wait, surface
  a `HandlerTimeout` on D3's error stream, continue draining. A wedged actor must be *loud*
  (`dir-id 3f6b`).
- **Bounded mailbox** with an explicit overflow policy, also surfaced on the error stream. A
  broker that never stops must not become an OOM.
- **Shutdown** drains or discards pending work by a stated rule, and `close()` is observable.
- **Priority is dequeue ordering, not preemption.** This is a correction, not a clarification:
  if the mailbox awaits handler A to completion, priority can only reorder *the next dequeue*.
  It cannot rescue lifecycle, `log_level` or shutdown from a stuck A. The reference is honest
  about this — `actor.py:241`, *"First mailbox added has priority handling"* — and its roadmap
  wants a priority mailbox precisely for `(raise_exception …)` (`actor.py:73`). Control traffic
  that must survive a stuck handler gets a **separate cancellation path**, not a priority number.

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
- **Inbound is specified, in both directions.** An invalid framework value from a peer
  (`(update log_level junk)`) is neither thrown (a malformed remote message must not kill an
  actor) nor silently ignored (that is exactly the silence D3 exists to abolish): the value is
  rejected, the previous value retained, and the rejection surfaced on the error stream.
- `(remove <framework-key>)` from a peer is rejected the same way — a reserved key cannot be
  removed.
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

**RECAST — revision 1 stopped there, and that was the most consequential error in the document.**
Deleting the network thread also deletes what it was doing for us. **MQTT keepalives now share
the isolate with application handlers.** A slow handler — a fat S-expression parse, a long
`await` — blocks pings; the broker fires the retained last will `(absent)` on
`{ns}/{host}/{pid}/0/state`; and **the fleet fails over a process that was only busy.** Python's
two-thread hop was ugly, and it also kept the heart beating while the actor thought.

Mitigations, to be chosen with measurement (`dir-id db83`) rather than by assertion:

- set the keepalive interval from a **measured** worst-case handler duration, not a default;
- bound handler duration against the keepalive interval (§2.5's timeout, with this as its
  sizing input, not an arbitrary constant);
- if neither holds, keep the transport's ping on a **separate isolate** — reintroducing the hop
  deliberately, for the one reason that justified it, rather than inheriting it by accident.

This decision is now the strongest argument for §2.5's handler timeout: without it, a slow
handler is not slow, it is *evicted*.

## 4. First vertical slice

Dependency order:

1. `ServiceTopicPath` — the five-topic fan-out as a value type
2. `ServiceState` — sealed lifecycle, projected over the inherited keys (D2)
3. `Mailbox` — deadline-ordered, bounded, timeout-enforcing, dequeue-ordered
4. `Actor` — mailbox + share facade + error stream, `topic_in` → dispatch
5. `AikoRuntime` — identity, then LWT, then connect; service table; `addService` returning
   `RegisteredService`

Acceptance tests first (ATDD). **Revision 1 named one test, and it could not go red** — "an async
handler that awaits mid-mutation must not be observed torn" passes *identically* under the
mailbox and under the rejected Future chain, so it is not evidence for the design. Every test
below either forces the failure or distinguishes the mechanism from its alternative:

| # | Test | Must go red when |
|---|---|---|
| 1 | async handler awaits mid-mutation; next message must not observe torn state | the serialisation mechanism is deleted |
| 2 | a `Timer` (D4) fires mid-handler and touches state | the Timer executes instead of enqueuing — **fails under a Future chain, passes under a mailbox** |
| 3 | request/response completes while its originating handler is suspended | replies are routed through the actor mailbox (§2.3) |
| 4 | a handler that never completes | no timeout; must surface `HandlerTimeout`, not wedge |
| 5 | long handler + queued control message | priority is claimed as preemption rather than dequeue ordering |
| 6 | mailbox fed faster than drained | unbounded growth; must surface overflow |
| 7 | shutdown with pending work | pending work vanishes silently |
| 8 | delayed messages with out-of-order deadlines | the reference's drain-everything bug is ported |
| 9 | app write to a reserved share key | it is accepted, or silently dropped |
| 10 | inbound `(update log_level junk)` from a peer | it throws, **or** it is silently ignored |
| 11 | inbound `(update a.b.c 1)` — depth 3 | it is accepted, or silently dropped without report |
| 12 | a Python ECConsumer reads our share snapshot | `lifecycle`/`running` are missing or renamed |
| 13 | two `ServiceDefinition`s named `'counter'` | identity is assigned before admission (D7) |

Test 12 is the one that must run against the **real Python reference**, not a Dart double —
`dir-id c0de`: a self-roundtrip proves self-consistency, not correctness.

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

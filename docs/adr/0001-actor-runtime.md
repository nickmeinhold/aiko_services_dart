# ADR-0001 — The Dart Actor runtime

- **Status:** proposed — **revision 5 (split)**, 2026-08-26. Revision 1 returned RECAST on 13
  flaws (`0001-TEMPER.md`); revision 2 returned RECAST on 9 more (`0001-TEMPER-round2.md`);
  revision 3 returned NOT SOUND (`0001-TEMPER-round3.md`) with all four families converging on the
  same fold — **delete parking**. Revision 4 is that subtraction plus the two fences it does not
  remove. The three-round budget is **spent**; whether the simplified design gets one confirmation
  strike is an open process question (§6e).
- **Date:** 2026-08-25, recast 2026-08-26
- **Context:** first framework code in `lib/`; everything after it inherits these shapes
- **Mandate:** Nick, 2026-08-25 — *"framework port should be designed, not just ported"*

> **SPLIT 2026-08-26 (Nick's call).** The concurrency model — the mailbox, the epoch fence, the
> transport isolate, and decisions D4, D6, D8, D9 — moved to **`0002-actor-concurrency-model.md`**,
> which is **not converged** and gates no work here. This document keeps the surface that
> converged: the wire seam and the value types.
>
> **Evidence for that claim, stated at its proven scope:** three cross-family strikes hit this
> whole document. Round 1 found flaws in D1, D2, D5 and D7; they were folded in revision 2, and
> **rounds 2 and 3 found nothing new in any of them.** That is "struck three times, unchanged
> since round 1" — not a clean SOUND verdict, which this document has never received. It is
> enough to build on; it is not enough to stop testing.

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
2. **§2's deadlock has an answer already in the reference**, and its *shape* is better than
   anything the strike proposed. `do_request()` is continuation-style with a caller-nominated
   response topic handled at *process* level — replies never enter the actor mailbox. We conform
   to that shape (ADR-0002 §2.3). **Amended 2026-08-26: we do NOT conform "all the way".**
   `do_request()` carries **no request identity** — no correlation id, one shared
   `_RESPONSE_TOPIC`, handlers never removed — and is safe only because all four of its call sites
   pass `terminate=True`, bounding each process to one in-flight request. It is a one-shot CLI
   primitive. Our actors are long-lived and will have several requests outstanding, so adding
   request identity is required, and that is a **wire change belonging to Andy**. See ADR-0002
   §2.3 for the source reading and the measurement.
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
| **request/response** | **`discovery.py::do_request()` — caller nominates a `response_topic`, registers a handler at *process* level via `add_message_handler()`, fires `do_command()` and returns immediately. The reply is a multi-part stream: `(item_count N)` then N × `(response …)`.** ⚠ **No correlation id**: the reply carries nothing identifying which request it answers, every caller passes the same `aiko.topic_in`, and handlers are never removed. Safe only under `terminate=True` (one request per process). See ADR-0002 §2.3. |
| **mailbox naming** | **`f"{name}/{service_id}/{topic}"` (`actor.py:248`), bound at registration time in `__init__`** |
| presence | MQTT **last will** `(absent)`, retained by the broker, published on `{namespace}/{host}/{pid}/0/state` when a process dies ungracefully — a clean `disconnect()` does *not* fire it |
| broker transport | `tcp` (1883) or **`websockets` (1884, WSS 9884)** — already selectable in the reference via `AIKO_MQTT_TRANSPORT` |
| proxy send | `args if not kwargs else [args[0], kwargs]` — one positional + dict, `args[1:]` discarded |

Everything above that line is ours. Where the Python's shape is an artifact of *Python*, we take
the shape Dart wants.

## 2. Decisions

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

**Scope after the split:** this document owns `AikoRuntime`'s *construction order* only. The
running loop, the mailbox it drives and the transport isolate belong to `0002`.

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


## 3. First vertical slice — the part that does not need a mailbox

Everything here is a value type or a pure state container. None of it depends on ADR-0002.

1. `ServiceTopicPath` — the five-topic fan-out (§1)
2. `ServiceState` — sealed lifecycle **with `unknown`**, projected over inherited keys (D2)
3. `Share` — the canonical depth-2 wire-shaped tree with a typed facade (D5)
4. `ServiceDefinition` → `RegisteredService` — registration as the constructor boundary (D7)
5. `AikoRuntime` construction *order* only — identity, then LWT, then connect (D1). The running
   loop belongs to ADR-0002.

ATDD: every test below names the condition under which it goes **red**, and the ● arms force the
failure rather than observing its absence. Write the ● arms and see them red **before** the
mechanism exists.

| # | Test | Goes red when |
|---|---|---|
| ● 1 | app writes a reserved share key (`lifecycle`/`log_level`/`running`) | accepted, or dropped without report |
| ● 2 | inbound `(update log_level junk)` on **our** `/control` | throws, **or** is silently ignored |
| ● 3 | inbound invalid value on a **peer replica** | we reject it — we must store and warn (D5) |
| ● 4 | inbound `(update a.b.c 1)` — depth 3 | accepted, or dropped without report |
| ● 5 | `share['metrics']` handed out and mutated | the live map escaped |
| 6 | Python adds an unseen lifecycle string | the sealed view cannot represent it (`unknown`) |
| 7 | `(update metrics.running 3)` round-trips | dotted-path addressing is not honoured |
| 8 | `(remove lifecycle)` from a peer on our `/control` | a reserved key is removable |
| 9 | topic fan-out from one path | any of the five derived topics is wrong |
| 10 | `ServiceDefinition` exposes `topicPath` or `serviceId` | identity exists before admission (D7) |
| 11 | two `ServiceDefinition`s named `'counter'` | duplicate names are rejected — `service_id` distinguishes them |
| ○ 12 | a real Python ECConsumer reads our share snapshot | `lifecycle`/`running` missing or renamed |

**○ 12 is blocked on infrastructure** and must not be counted as passing: it needs a live Python
reference plus a broker, and this repo has **no `.github/workflows/` at all**. It is the only test
standing between the port and a silent wire regression (`dir-id c0de` — a self-roundtrip proves
self-consistency, not correctness).

## 4. Test transport: loopback, not Null Object

`Castaway` is the reference's Null Object — no-op publish/subscribe when no broker is reachable.
`AikoRuntime.inMemory()` must **not** copy it. Castaway silently drops every publish, so a test
against it passes whether or not the message was correct. The in-memory runtime is an in-process
**loopback** that round-trips through the real codec, so acceptance tests exercise the wire
without a server.

## 5. Open — Nick's call, and Andy's

**Conservative arms taken 2026-08-26 so the recast was not blocked. Both are "conform below the
wire", so neither needs new authority — but both are reversible and flagged for veto.**

- **(a) `lifecycle`/`running` → `state`.** Taken: publish the inherited keys unchanged,
  `ServiceState` internal only (D2). **The consolidation goes to Andy as a wire proposal** — his
  own `actor.py:86` TODO wants it, and it is his wire.
- **(b) Multiple runtimes per process.** Taken: test-only (D1). If it should be a production
  capability, identity allocation (MQTT client id, LWT ownership, retained state cleanup,
  `service_id`) needs designing first.
- **(c) MQTT on its own isolate (D8) — MOVED to `0002`.** Recorded here because it was taken as a decision: yes, as the default. An architecture cost, arrived
  at independently by two families once revision 2's timeout was shown incapable of protecting a
  keepalive. Flagged because it is a real cost, not because the engineering is uncertain.
- **(d) Parking — CLOSED, deleted.** Struck unanimously in round 3 on a fact about the language
  (an `await`'s continuation resumes as a microtask; the mailbox never owns it). Strict
  continuation style adopted (§2.3). Recorded so it is not reinvented: the idea is attractive and
  it does not work.
- **(e) THE PROCESS QUESTION — RESOLVED 2026-08-26 (Nick): split §2 into its own ADR and build
  the settled surface now.** Original framing kept for the record: Three rounds, three non-SOUND verdicts,
  budget spent. But rounds 2 and 3 were consumed almost entirely by **one mechanism invented
  mid-loop** (parking), not by the inherited design — three rounds found *nothing new* in §1 or
  D1–D7. With parking removed the document is round 1's survivors plus specification work. The
  options: one confirmation strike on the **simplified** design; accept as-is and build; or split
  §2 into its own ADR on its own timeline. The lesson either way (`dir-id 7c6e`): a strike is an
  adversary, not a collaborator, and designing *inside* the loop is an expensive way to use it.

**Resolved and not to be re-litigated:** the explicit `AikoRuntime` (D1, Nick 2026-08-25);
Castaway is a Null Object and not a transport, so #3240/#2268 are conformance work against the
reference's existing `AIKO_MQTT_TRANSPORT=websockets` on 1884/9884.

## 6. What this document does NOT claim

The codec beneath this is **parity-tested against a reference that has its own bugs** — a parity
claim, not a correctness claim.

Nothing here has been implemented. This is a design proposal at **revision 2**, folding a
four-family strike it has **not yet been re-struck against**. Revision 1 read as confident and
was wrong in two places; revision 2 is better evidenced and carries the same warning. It is
UNPROVEN until it exists, runs, and survives round 2.

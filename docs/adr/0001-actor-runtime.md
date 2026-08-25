# ADR-0001 — The Dart Actor runtime

- **Status:** **proposed — RECAST** by a 3-family design-temper strike, 2026-08-25.
  See `0001-TEMPER.md`. D1 is decided; the document as a whole is NOT accepted and no
  `lib/` code may be written against it until a round-2 strike returns SOUND.
- **Date:** 2026-08-25
- **Context:** first framework code in `lib/`; everything after it inherits these shapes
- **Mandate:** Nick, 2026-08-25 — *"framework port should be designed, not just ported"*

## 1. The seam

One rule governs every decision below.

> **Below the wire: conform, exactly. Above the wire: design.**

The wire is `RFC-0001` plus the conformance vectors in
`test/codec/fixtures/s_expression_golden.json`. It does not move to accommodate
anything here. Concretely, the contracts we inherit unchanged:

| Surface | Contract |
|---|---|
| topic path | `{namespace}/{host}/{pid}/{service_id}` |
| derived topics | `/control` `/in` `/out` `/log` `/state` |
| command | `(method_name arg …)` published to `topic_in` |
| reply | **none by default** — one-way; request/response is layered on top by Discovery |
| shared state | `(add k v)` / `(update k v)` / `(remove k)` on `/control` |
| subscription | `(share <topic> <lease> *)` or `… (lifecycle x)` on `/control` |
| proxy send | `args if not kwargs else [args[0], kwargs]` — one positional + dict, `args[1:]` discarded |
| presence | MQTT **last will** `(absent)`, retained by the broker, published on `{namespace}/{host}/{pid}/0/state` when a process dies ungracefully — a clean `disconnect()` does *not* fire it |
| broker transport | `tcp` (1883) or **`websockets` (1884, WSS 9884)** — already selectable in the reference via `AIKO_MQTT_TRANSPORT` |

Everything above that line is ours. Where the Python's shape is an artifact of
*Python*, we take the shape Dart wants.

## 2. The central question: does Dart need a mailbox?

Python needs an explicit mailbox because its threads are preemptive and share
state; the doc says so outright — *"serialization is the concurrency model …
the framework's alternative to locks."*

Dart's event loop already serialises. So the tempting answer is: the mailbox is
redundant, an Actor is just an object, and we get the guarantee free.

**That answer is wrong, and the reason is the most important sentence in this
document:**

> Dart gives one-at-a-time **scheduling** for free. It does not give
> one-at-a-time **completion**.

A synchronous handler does run to completion uninterrupted. But an `async`
handler yields at every `await` — so message B can begin, and observe state,
while message A is suspended half-way through mutating it. The bug this
produces is a *torn* actor state, and it is invisible in every synchronous test.

**Decision: keep the mailbox.** It earns its place for three reasons, none of
which is locking:

1. **Completion-ordering across `await` points.** The real one. The mailbox
   awaits each handler to completion before dequeuing the next.
2. **Uniform local/remote call path.** Behaviour must not depend on where the
   caller lives. In the Python this is `proxy_post_message()`; the observable
   consequence is that `actor.test(1)` does *nothing* until the loop runs.
3. **Deferral, delayed commands, and priority.**

**Consequence we accept:** a local call cannot return a value synchronously,
because it is queued. This matches the reference (one-way by default) and it is
the honest shape — a call that may cross a network cannot pretend to be a
function return.

## 3. Decisions

### D1 — `AikoRuntime`, not a global

*Python:* a mutable module-level `aiko` singleton every module imports.

The invariant is **"exactly one runtime per OS process."** The *global* is
Python's spelling of that invariant, not the invariant itself — and it is the
part that makes tests share state, makes two runtimes in one process
impossible, and blocks the roadmap's own "multiple Actors per Process as a
first-class feature."

*Dart:* an explicit `AikoRuntime` object, threaded through construction. One per
process by convention, not by language enforcement.

**DECIDED 2026-08-25 (Nick):** the explicit `AikoRuntime` object, over both the
module-level global and a Zone-scoped current-runtime. Rationale for the record:
the Zone option is ambient-but-scoped and would give real isolation, but it makes
the dependency invisible at the call site; threading the reference is more typing
and more honest.

```dart
final runtime = AikoRuntime(transport: mqtt);
final counter  = CounterActor(runtime, name: 'counter');
await runtime.run();

// tests get isolation without process teardown:
final rt = AikoRuntime.inMemory();
addTearDown(rt.dispose);
```

### D2 — Lifecycle as a sealed state, not two dict keys

*Python:* `share["lifecycle"]` and `share["running"]` are separate string keys.
The roadmap explicitly wants them merged into `share["state"]`. Additionally
`run()` sets `share["running"]` by **direct dict assignment**, bypassing
`ec_producer.update()` — so remote consumers are never notified.

*Dart:* one sealed `ServiceState`, exhaustive at compile time, mutated through
exactly one door so a notification cannot be skipped. Serialises to the same
`(update state …)` on the wire.

This is `dir-id 6b6a` — *the single door is the MUTATOR, not the route* —
applied literally.

### D3 — Failures surface; they do not vanish

*Python:* `Message.invoke()` catches `Exception` and **swallows** it. The doc
says the quiet part out loud: *"a catch of everything hides bugs in the target
function."*

*Dart:* invocation failures are surfaced on an error `Stream` on the runtime,
in addition to logging. A dropped message must be *observable*. This costs
nothing on the wire and is `dir-id 3f6b` — *silence reads as success*.

### D4 — Delayed messages honour their deadlines

*Python:* the timer starts only on an empty→non-empty transition, and when it
fires it drains the **entire** queue regardless of each entry's deadline — so
longer-delayed entries fire **early**, and entries added while a longer timer is
pending must wait for it. The doc's own advice is to treat `delay` as *"at
least roughly, not before other work."*

*Dart:* a deadline-ordered queue with a `Timer` for the earliest deadline only,
rescheduled on insert. Trivially correct here; genuinely awkward in the Python.

### D5 — The share splits in two, and the wire does not notice

*Python:* `share` is one untyped dict mixing framework-reserved keys
(`lifecycle`, `log_level`, `running`) with arbitrary application state — which
is why the change handler string-matches `log_level` and silently ignores
invalid values.

*Dart:* a typed framework slice (closed, known, exhaustive) beside an open
`Map` for application state. Both serialise identically to
`(update <key> <value>)`, so a Python ECConsumer cannot tell the difference.

### D6 — `run()` lives on Actor, not Service

*Python:* `Service.run()` raises `SystemExit` with the message *"currently only
supported by Actor."*

*Dart:* that is a runtime throw standing in for a fact the type system can
state. `run()` belongs to the type that can actually do it.

### D7 — Identity flows Process → Service

*Not a divergence — a constraint to preserve.* `add_service()` is what assigns
`service_id` and `topic_path`; a Service has no identity until the runtime
admits it. And `Process` is deliberately not composable because it *creates*
the context the composition machinery needs.

Dart must preserve both. A `Service` is therefore constructed *unregistered*
and acquires identity on admission — which the type system should make
explicit rather than leaving a half-built object reachable.

### D8 — The two-thread hop collapses, and a documented deadlock disappears

*Python:* paho-mqtt's `loop_start()` runs network I/O on a **background thread**.
`ProcessImplementation.on_message()` therefore does nothing but
`event.queue_put(...)`, bouncing every incoming message onto the main event loop
so application handlers never run on the MQTT thread. `message.md` documents the
bug this leaves behind: framework code that waits on the paho thread for a
condition driven by an *incoming* message deadlocks, because the same thread
must deliver that message. The reference's own proposed fix is "queue all
incoming messages onto the main event loop by default".

*Dart:* there is no second thread to bounce off. `mqtt_client` delivers on the
same isolate's event loop, so the hop is not a workaround we port — it is a
Python artifact, and **the deadlock class cannot be constructed in Dart at all.**

Two consequences we take deliberately:

- The `wait_connected()` / `wait_disconnected()` / `wait_published()` family —
  1 ms busy-wait polls, capped at ~2 s, that log an error and then *continue
  anyway* — become `Future`s. A timeout becomes a `TimeoutException` a caller
  can see, not a log line the caller never reads (`dir-id 3f6b` again).
- The mailbox's ordering guarantee (§2) is now the *only* serialisation
  mechanism in the stack, rather than one of two. That raises the stakes on §2
  being right, which is exactly why it is the first thing the temper should hit.

## 4. First vertical slice

Smallest thing that is genuinely end-to-end, in dependency order:

1. `ServiceTopicPath` — the five-topic fan-out as a value type
2. `ServiceState` — sealed lifecycle
3. `Mailbox` — deadline-ordered, priority-aware, awaits completion
4. `Actor` — mailbox + state + error stream, `topic_in` → dispatch
5. `AikoRuntime` — owns transport, event loop, service table, identity assignment

Acceptance tests first (Nick's standing ATDD rule). The one that matters most:
**an async handler that awaits mid-mutation must not be observed torn by the
next message** — that is D2 and the whole §2 argument, and it is the test that
fails if we got the mailbox wrong.

## 5. Open forks — Nick's call, not to be built past silently

**(a) The `aiko` global (D1) — ✅ RESOLVED.** Explicit `AikoRuntime` object; see
D1 for the decision and rationale.

**(b) Castaway — ✅ RESOLVED 2026-08-25 by reading `message.md` in full.**
Castaway is **not** an alternative transport. It is the *Null Object* of the
`Message` family — a no-op `publish`/`subscribe` used when no broker can be
reached, so a process can run standalone (`mqtt_connection_required=False`).
It carries no wire format of its own.

Two things fall out of that reading, and both are better news than the fork was:

1. **#3240 / #2268 are conformance, not invention.** The reference already
   selects `AIKO_MQTT_TRANSPORT=websockets` on port 1884 (9884 WSS). A Dart
   `MqttBrowserClient` behind the conditional-import split talks to the *same
   broker on the same documented port* as the IO client. The browser target is
   a config the reference already supports, not a protocol we have to design.
2. **The Dart in-memory runtime should be a LOOPBACK, not a Null Object.**
   Castaway silently drops every publish, which is dir-id 3f6b (*silence reads
   as success*) at the transport layer — a test against Castaway passes whether
   or not the message was correct. `AikoRuntime.inMemory()` therefore uses an
   in-process broker that actually round-trips through the codec, so acceptance
   tests exercise the wire without a server.

**(c) Design-temper before implementing? — ✅ RESOLVED: yes.** Nick chose to
temper this document BEFORE any `lib/` code. The two claims most worth striking:
§2 (the mailbox is non-redundant in Dart because scheduling ≠ completion — now
load-bearing alone, see D8) and D5
(splitting `share` into a typed framework slice plus an open app map). Recast on
a landed hit, then build.

**No forks remain open.** (a), (b) and (c) are all resolved; the next gate is the
design-temper strike itself.

## 6. What this document does NOT claim

The codec beneath this is **parity-tested against a reference that has its own
bugs** — that is a parity claim, not a correctness claim. Nothing here has been
implemented or tested yet; this is a design proposal, and the implementation is
UNPROVEN until it exists and runs.

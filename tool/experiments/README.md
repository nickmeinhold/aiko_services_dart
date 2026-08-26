# Substrate experiments for ADR-0002

Six falsifiable measurements of what Dart's scheduler, futures and isolates
**actually do**, taken before ADR-0002's prose was opened.

They exist because two of the three `/design-temper` rounds on ADR-0001 were
burned on a mechanism (`parking`) that a five-minute `dart run` would have
killed on day one. The rule this encodes:

> **Pin the substrate by experiment first, then strike.**

Every claim below is one runnable file. Run them all:

```sh
for f in tool/experiments/e*.dart; do echo "== $f"; dart run "$f"; done
```

Measured on **Dart SDK 3.13.0 (stable), macos_arm64**. A finding is a fact
about *this* substrate; re-run on an SDK bump before relying on one.

---

## F1 — Occupying an actor means SYNCHRONOUS occupancy, and nothing else

`e1_scheduling.dart`

A synchronous slice blocks microtasks, `Timer`s and inbound isolate messages
alike. A 300ms slice held all of them; every `Timer` whose deadline expired
during the slice — including a 150ms one — fired *together*, immediately after
it, already late. A long `await` starves nothing: four 50ms keepalive ticks
fired during a 250ms `await`.

> **A `HandlerTimeout` implemented as a `Timer` cannot fire during the
> synchronous slice it exists to interrupt.** It fires only once the actor
> voluntarily yields — which is precisely when it is no longer needed.

This confirms the round-2 physics correction: a long `await` does **not** starve
MQTT keepalives. A synchronous slice does.

## F1b — Source priority at the yield point

`e1b_source_priority.dart`

With a microtask, a `Timer` and an inbound isolate message all genuinely pending
when the actor yields, the service order is **microtask → Timer → isolate
message**, stable across 8/8 runs.

> An inbound isolate message is serviced **after** an already-due `Timer`.

*Instrument note:* the first version of this experiment was **void** — it
settled for 50ms before the slice, so the message was consumed before the
contest began. The child now sends mid-slice.

## F2 — A Future cannot be cancelled

`e2_cancellation.dart`

`.timeout()` abandons the **wait**, not the **work**. The caller timed out at
100ms; the handler ran to completion at 300ms, mutated shared state, and the
abandoned future still completed with a value nobody was listening for.

> **Every abandoned `ask` leaves a live handler that will still mutate actor
> state at an unbounded later time.** "Timed out" is a statement about the
> caller, never about the callee.

## F3 — Isolates are not failure-linked

`e3_isolate_failure.dart`

A child isolate that throws dies. Its `SendPort` accepts further sends silently,
forever. The parent receives **no error and no exit signal** and keeps running.
`onExit` / `onError` ports must be requested explicitly at `spawn` time —
positive control confirms both fire when asked for.

> **A dead actor leaves the transport happily pinging and no peer is told.**
> Supervision is opt-in and must be wired at spawn, not discovered at failure.

Sharpest detail: the death **does** print a stack trace to stderr. It is visible
to a human watching a terminal and invisible to the program — observable in dev,
silent in production.

## F4 — `SendPort` has no backpressure at all

`e4_backpressure.dart`

With the consumer's subscription paused, a producer sent **400,000 messages in
478ms without ever blocking**, and the receiving isolate's RSS grew **+345MB**
with **zero** messages drained. Positive-control arm (live consumer) drained all
400,000 with flat RSS (-0.2MB).

> **The queue in front of a mailbox is unbounded and silent.** A producer cannot
> discover that a consumer is not keeping up. Credit-based backpressure must be
> carried **in-band**, because the transport will never provide it.

## F5 — A continuation is a microtask, and its tick cost depends on CONSTRUCTION time

`e5_await_ordering.dart`, `e5b_completion_ordering.dart`

An `await`'s continuation resumes as a microtask. No queue can own "the rest of
the function" — this is what killed `parking`. Handler B's body ran between
handler A's two halves and mutated state under it.

The sharper, unexpected result:

> **The microtask-tick cost of an `await` depends on when the awaited future's
> completion was *scheduled*, not on whether the future is complete when you
> await it.**

| awaited shape | observed order | why |
|---|---|---|
| `Future.value()` | `CONTINUATION, M1, M2` | `_Future.immediate` → `_asyncCompleteWithValue` schedules a completion microtask **at construction** |
| pre-completed `Completer` | `CONTINUATION, M1, M2` | same |
| `Future.microtask(…)` | `CONTINUATION, M1, M2` | same |
| `Future.sync(…)` | `M1, M2, CONTINUATION` | `_Future.zoneValue` → `_setValue` completes **synchronously**; listener scheduled at *await* time |
| `Future.delayed(zero)` | `M1, M2, CONTINUATION` | completes on a timer event |
| `await null` | `M1, M2, CONTINUATION` | as above |

Stable across 3/3 runs; mechanism read from
`dart-sdk/lib/async/future_impl.dart` (`_Future.immediate` vs
`_Future.zoneValue`), not inferred.

> Consequence for ADR-0002 §5: on the in-memory loopback, **reply-delivery order
> is entangled with when the reply future was built**, not with the order asks
> were awaited. Any "continuation ordering" or "exhaustive ask-completion"
> guarantee must be stated against construction order or it is not a guarantee.

## F6 — There are no isolates on the browser target

`e6_web_isolates.dart`

Compiled with `dart compile js` and run under node:

```
RESULT: Isolate.spawn THREW UnsupportedError: Unsupported operation: ReceivePort.sendPort
```

The same program on the VM spawns and round-trips a message. Both arms carry
positive controls.

> **D8's transport-isolate mitigation is unavailable on web.** It fails at
> `ReceivePort.sendPort` — you cannot even *obtain* a port to hand a child — so
> the platform seam must sit **above the port abstraction**, not around
> `Isolate.spawn`.

*Instrument note:* `dart compile js` **succeeded** on this program. The compile
is a cheap proxy and proves nothing; only running it does.

---

## Methodological record

Three of these experiments were **void on their first pass** and reported
plausible, wrong results:

- **e4** — the "slow consumer" never awaited, so it drained at full speed and no
  queue built. Fixed by pausing the subscription and adding a live-consumer
  control arm.
- **e1b** — settled before the slice, so the contest never happened. The
  observed ordering was an artifact; the corrected run **inverts** it.
- **e6** — a successful `dart compile js` was read as "isolates work on web".

Each was caught by asking what the instrument would report *if the failure were
present*. Where the answer was "the same thing", the run was discarded. Every
experiment here now carries either a positive control, a null arm, or both.

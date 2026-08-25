# TEMPER round 3 — ADR-0001 revision 3

**Overall verdict:** **NOT SOUND.** Maxwell RECAST, Kelvin RECAST, Tesla RECAST, **Carnot
DISSOLVE**. Full four-family panel, `dt3-1787694940`, 2026-08-26. Round 3 of 3 — the budget is
spent.

**But the panel converged, and it converged on a SUBTRACTION.** All four families independently
reached the same fold: **delete parking, adopt strict continuation style.** That is not a fourth
round of patching — it is removing the mechanism that generated rounds 2 and 3's hardest flaws.

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | Parking creates a two-tier `await` where only one tier is safe and nothing enforces which you use. |
| Kelvin (Gemini) | RECAST | Each mechanism introduced to solve a prior flaw is itself unsound; parking is a race. |
| Carnot (GPT) | **DISSOLVE** | Parking gives up the serialisation guarantee without admitting it; strict continuation style dissolves four failure classes at once. |
| Tesla (Grok) | RECAST | Parking is round 2's physics error in a new coat — Dart cannot splice an `async` continuation into a mailbox any more than it can cancel a Future. |

## The finding: parking is not implementable as specified

Tesla states it most precisely, and it is a fact about the language rather than a design opinion:

> **`await t.ask()` does not yield a mailbox turn. Completing that Future resumes the handler as a
> MICROTASK** — which is exactly the side door §2.4 exists to nail shut. **The mailbox never owns
> "the rest of the function."**

Everything else follows:

- **The reply-before-park race** (Kelvin and Carnot, independently). Turn-release and suspension
  are not atomic. A reply arriving before `await` is reached completes the Future without ever
  suspending — so the turn is never released and head-of-line blocking returns.
- **And it is deterministic on the path that matters.** §5's in-memory loopback — the *uniform
  local/remote path* that is §2.2's reason 2, the reason the mailbox exists at all — completes
  the reply synchronously. **Parking is guaranteed absent exactly where the design most needs it
  to behave identically.**
- **Nested and concurrent asks are undefined** (all four). Dart cannot consume `t`, so two
  concurrent asks share one epoch bump and two Completers; a nested `await t2.ask` parks a frame
  whose outer activation is already a lie. Continuation ordering is unspecified: original turn
  order, reply arrival order, or causal order — the document picks none.
- **`close()` vs in-flight continuations is doubly-defined** (all four): §2.6 says continuations
  are never dropped, and also that `close()` stops admission. Nobody owns the parked caller's
  Future.

**And parking bought nothing.** Tesla: completion-ordering across the `await` — §2.2's third
reason — *was surrendered*, and the two remaining reasons (inspectable queue, deferral) are
**exactly what the `ask(…, replyTo:)` fallback still buys.** The mechanism cost three failure
classes and delivered no guarantee the simpler design lacks.

## The second finding: the epoch fence's narrowing is fatal, via laundering

Carnot supplies the mechanism the rest of us missed. §2.5 deliberately fenced only `share.update()`
and `publish()`, on the grounds that private tearing "stays local". It does not:

> A timed-out handler sets `_memberBanned = false`, fails to publish because its Turn is dead —
> and **a later valid turn reads that private field and publishes it with a live Turn. The lie
> leaves the actor one turn later, laundered through fresh authority.**

Kelvin independently: *"the fence is a decorative feature ... ensuring eventual wire-visible
corruption."* Carnot also enumerates what a dead epoch can still do besides write: enqueue
messages, start timers, initiate asks, complete Completers, consume reserved mailbox headroom.
**A dead epoch must be unable to schedule work, not merely unable to write two blessed sinks.**

## The third finding: D8's isolate has two unpriced holes

- **False-life, and worse than I wrote it.** I found that a wedged main isolate still looks
  healthy. Tesla found the real version: **Dart isolates are not failure-linked by default**, so
  if the actor isolate *dies*, the transport isolate keeps pinging, the broker withholds the LWT,
  and the fleet never fails over a corpse. **Test ● 5 goes green for that death.** Rounds 1 and 2
  fixed a false-negative; round 3 finds we bought a false-positive.
- **The `SendPort` is an unbounded queue in front of the bounded mailbox** (Kelvin, Carnot,
  Tesla). Drop-newest fires *after* the port has already eaten the RAM and MQTT QoS has already
  ACKed, and `(absent)`/disconnect sit behind bulk publishes with no reserved headroom on the
  port. §2.6's carefully classed overflow table is defeated one layer upstream. Kelvin wants
  credit-based backpressure; nothing weaker will do.

## What holds — and it is now most of the document

Three rounds have found **nothing new** in §1, D1, D2, D3, D4, D5, D6 or D7. Endorsed again by
every family: the seam rule and §0's two laws; the two inbound paths and `unknown` case; the
no-leaked-`Map` rule; §2.1's physics; the mailbox as an inspectable, deferrable, uniformly
addressed queue with the Future chain correctly rejected; D7's two-type split; §4's
negative-control discipline; D8's *diagnosis*.

**The contested surface is exactly §2.3, §2.5's scope, §2.6's tables, and D8's boundary.**
Everything else has converged.

## Disposition — subtract, do not iterate

**Applied immediately (Maxwell's call, stated for veto):**

1. **Parking is deleted.** `ask(…, replyTo:)` — strict continuation style, conforming to
   `do_request()` all the way, as the document itself already named as the fallback. This
   dissolves in one edit: the reply race, the loopback determinism hole, nested/concurrent ask
   semantics, continuation ordering, the parked-Future ownership problem, and most of the
   stale-read branding.
2. **The epoch fence goes absolute.** A dead epoch may not write private state, publish, enqueue,
   start timers, initiate asks, or consume headroom. Kelvin: *"There is no middle ground."*
3. **D8 gains failure-linking and backpressure.** The transport isolate must stop pinging when the
   actor isolate stops proving liveness, and the port must be bounded with credit-based flow
   control and reserved headroom for control frames.

**Nick's call — the process question, which is the real one:**

Three rounds, three non-SOUND verdicts, and the budget is spent. But rounds 2 and 3 were spent
almost entirely on **one mechanism I invented mid-loop** (parking, §2.3) rather than on the
inherited design. The reframe (`dir-id 7c6e` — an outlier in your own process metric is a
stop-and-reframe signal): I was *designing inside the strike loop* instead of bringing a design
to it. The strike is an adversary, not a collaborator, and it is expensive to use as one.

With parking removed, the document returns to what survived round 1 plus specification work.
Options: a single confirmation strike on the **simplified** design, or accept it as-is and start
building, or hand §2 to a separate ADR on its own timeline.

**Method note, three rounds running.** Tesla was seated last in round 1, given more runway in
round 2, and seated first in round 3 — and produced the decisive finding every time (keepalive
starvation; the await/sync-occupancy physics error; the microtask fact that kills parking). That
is not luck three times.

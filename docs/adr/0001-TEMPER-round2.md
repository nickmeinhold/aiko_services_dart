# TEMPER round 2 — ADR-0001 revision 2

**Overall verdict:** **RECAST** — unanimous, 4 of 4 families, on the same fatal flaw.
**Struck:** `dt2-1787693016`, 2026-08-26. Maxwell (Claude) + Kelvin (Gemini 2.5 Pro) + Carnot
(GPT) + Tesla (Grok). Full panel. Round 2 of ≤3.

Round 1 found what revision 1 got wrong. Round 2 found what **the fold itself introduced** — and
the headline is that the mechanism added to make a stuck actor *observable* is the mechanism that
makes it *corrupt*.

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | §2.5's "timeout" is not a timeout — Dart cannot cancel a Future, so the recast's liveness fix breaks its own closure law. |
| Kelvin (Gemini) | RECAST | The design mistakes "abandoning a future" for "terminating a computation", creating zombie handlers. |
| Carnot (GPT) | RECAST | Folds several round-1 strikes but introduces a worse leak: the mutator law is declared, then two paths escape it. |
| Tesla (Grok) | RECAST | Three laws on one crystal — any two can hold; all three ring the glass at 3am. |

## Fatal flaws

**1. The zombie handler — §2.5 manufactures the exact torn state §2 exists to prevent.**
*All four families, independently. The round-2 blocker.*
§2.5 says on expiry: *"abandon the wait, surface a `HandlerTimeout`, continue draining."*
**Dart cannot cancel a Future.** An abandoned handler is not stopped, only un-awaited. Handler A
keeps running, the mailbox dequeues B, and when A's `await` resolves, A resumes and mutates state
**concurrently with B**. Kelvin: *"a wedged actor is better than a silently corrupt one."*
Tesla names the blast radius the rest of us missed: **the zombie publishes.** It calls
`ec_producer.update()`, so remote Python ECConsumers converge on a corpse's last thought while
the dashboard reads `ready` and the operator, seeing `HandlerTimeout`, believes the actor
recovered.
This is `dir-id 2e4b` — check each fix against the OTHER fixes, not only the defect it repairs.
**DISPOSITION:** fold. **Epoch fence at the single mutator**, covering state writes **and**
publishes; Completers of a dead generation complete with error; continuations of a dead epoch
no-op. Never "abandon and continue" with a live closure over `this`.

**2. D8's mitigation is aimed at the wrong physical quantity — a physics error, not an omission.**
*Tesla alone, and he is right.*
D8 proposes bounding *handler wall-clock duration* against the keepalive interval. But **a long
`await` does not block keepalives at all** — timers and socket callbacks run during an await;
that is what an event loop is for. What starves the ping is a **synchronous slice**: a fat
S-expression parse, CPU-bound work. And during a synchronous slice **no `Timer` fires** — so
`HandlerTimeout`, being itself a Timer, **cannot fire either.** §2.5 provably cannot protect the
keepalive. Tesla: *"aimed the radar at ocean while the tsunami is the mountain."*
Kelvin reaches the same destination by a different road: since two of D8's three mitigations are
non-viable (one brittle, one broken), deferring the choice "to measurement" is an unpriced hole.
**DISPOSITION:** fold. **MQTT transport on a separate isolate is the DEFAULT, not the fallback.**
The handler timeout is for head-of-line loudness only, sized independently of keepalive, and D8
must stop claiming it protects pings. Never stretch keepalive to worst-case handler duration —
that deafens crash detection.

**3. `await ask()` inside a handler reopens the coupling §2.3 claims to have removed.**
*Tesla, sharpened by Carnot.*
The reference's `do_request()` **returns immediately** — that is precisely why Python never holds
an actor across a round-trip. §2.3 nonetheless floats an `await`-shaped `Completer` API, which
head-of-line blocks the mailbox for **unbounded peer latency**. Compose that with flaw 1 and the
failure is specific: the timeout fires on slow discovery, the turn is abandoned, the next command
starts, and then the multi-part `(item_count N)` + N × `(response …)` stream completes a Completer
whose continuation writes A's reply into B's actor — or, on a **reused `response_topic`**, mixes
two asks' replies (`dir-id f7a8`, identity-as-mutable-key).
**DISPOSITION:** fold. **No `await ask()` inside a mailbox turn.** Completers live on the runtime
for callers *outside* an actor. Multi-part reassembly is a process-level state machine with its
own timeout and a **single-use** `response_topic`.

**4. §2.3 and §2.4 are formally contradictory as written.** *All four families.*
§2.4: every reply that touches actor state re-enters as a message. §2.3: replies **never** enter
the mailbox. Both cannot stand. Kelvin supplies the reformulation: distinguish events that
**initiate** work from events that **provide data** to work already in flight.
**DISPOSITION:** fold, in Kelvin's words plus Tesla's epoch clause — *"The current mailbox turn
may mutate. Process-level code may only resume THAT turn, or enqueue. After epoch death, nothing
that turn closed over may write or publish."*

**5. The mutator law is unenforceable in the proposed type shape.** *Carnot; Tesla's alias case.*
Dart cannot stop a closure capturing `this` and mutating after an `await`, in a `Timer`, in a
stream callback. §2.4 names forbidden patterns and supplies no mechanism — a prose-only gate.
Tesla's concrete instance: D5 hands `share['metrics']` to application code as a nested `Map`, and
**that alias mutates the tree with no mutator, no reserved-key check, no `ec_producer`.**
Revision 1's typed slice at least made framework keys unaddressable as map entries; the facade
gave that up and did not replace it.
**DISPOSITION:** fold — actor state private behind a mailbox turn context; the tree never leaks a
nested `Map`; framework keys writable only through the privileged mutator.

**6. D5's rejection policy is correct for our own `/control` and WRONG for a consumer replica.**
*Tesla alone.*
D5 says an invalid inbound framework value is rejected and the previous value retained. That is
right for our own share. But an **ECConsumer replica of a Python peer** is a different tree —
rejecting the producer's value makes Dart **diverge from the mesh it is meant to converge with**,
while `pipeline.py:287` still reads whatever the peer actually stored. One mutator law was
written for one tree; **the system has a tree per consumed topic.**
Related: a sealed `ServiceState` **cannot represent an unknown wire value**. When Python adds a
lifecycle string, Dart is blind to a state Python branches on.
**DISPOSITION:** fold — two inbound paths (self `/control`: reject loudly; consumer replica:
store what the producer sent, warn on D3, never "correct" another service's share), and add an
`unknown` case to the sealed view.

**7. Policies named but not designed — and this is a CLASS, not three items.**
*Carnot and Tesla, converging.*
Shutdown ("drains or discards by a stated rule" — no rule stated), mailbox overflow (one
undifferentiated policy for control vs command vs continuation vs delayed timer), and the
"separate cancellation path" (a phrase, not a design) are all round-1 flaws **described rather
than folded**. Tesla connects shutdown to §1's presence row: a clean `disconnect()` does **not**
fire the last will, so a `close()` that cannot finish also cannot die loudly.
**DISPOSITION:** fold all three together. The class is the finding (`dir-id 3c9d`) — round 3 must
sweep every "by a stated rule" / "explicit policy" / "to be chosen" in the document and *state
them*, not add a fourth.

**8. Several §4 tests still cannot go red.** *Carnot, Kelvin, Tesla.*
Test 1's red condition still does not distinguish mailbox from Future chain. Test 4 goes red for
a *missing* timeout, never for a *leaky* one — it proves the system is loud, not that it fails
safe. Test 7 cannot be written until the shutdown rule exists. Test 13's red condition is a
type-state property that will not execute as described. Tesla: *"thirteen ghosts can all pass
while the zombie still publishes. They are tests of round 1's war."*
**DISPOSITION:** fold — new arms whose red is: a timed-out handler's write does not land; a
timed-out handler's **publish** does not reach the broker; a CPU-bound handler vs keepalive/LWT;
`close()` then the zombie is mute; `ask` does not head-of-line the mailbox.

**9. Test 12 has no runner.** *Maxwell.* The single test standing between this design and a wire
regression needs a live Python reference and a broker, and **this repo has no
`.github/workflows/` at all.** `dir-id 7b3e`: a trigger that never fires reads as safety.
**DISPOSITION:** mark blocked on infrastructure; file the CI gap separately.

## What holds — and it is more than round 1

- **§0's rule** ("the concept docs are intent, the source is the contract") is endorsed by Tesla
  as *"the only reason D2/D5 are no longer wire vandalism."*
- **D2 and D5's seam fixes are real folds, not renames** — all four families say so explicitly.
- **§2.1's physics** and the mailbox-as-queue justification survive a second strike intact; the
  Future chain is correctly rejected on uniform dispatch, deferral, inspection and drain.
- **D7's two-type split** closes the nameless-mailbox collision. Unanimously endorsed.
- **D1** (identity → LWT → connect; multi-runtime demoted to test-only), **D3**, **D4**'s
  enqueueing Timer, **D6**, **§5**'s loopback, `Status: proposed`, and the parity-not-correctness
  note all hold.
- **D8's diagnosis** is still right. Only its treatment was slag.

## Disposition

**RECAST — round 3, the last permitted round.** Do not start `lib/` code.

Round 3 is narrower than round 2: flaws 4, 5, 7, 8 are specification work on decisions already
made. Three are genuine choices, and two of those are **Nick's**:

- **Zombie fix** *(Maxwell's call, stated for veto)*: **epoch fence at the single mutator**, over
  writes and publishes. Chosen over cancellation tokens (needs every handler author to cooperate)
  and over actor-poisoning (takes the actor offline for one slow call).
- **D8 → separate transport isolate as the default** — an architecture cost, arrived at
  independently by Kelvin and Tesla, and forced by the fact that §2.5's timeout provably cannot
  protect a keepalive. **Nick's call.**
- **No `await ask()` inside a handler** — an API-shape decision every actor author will feel.
  **Nick's call.**

**Method note.** Round 2's most valuable finding was a *physics error* in the recast's own
reasoning (flaw 2), caught by the one family that had been written off as a dark seat in round 1
and given more runway in round 2. Two rounds, two occasions where Tesla's late answer was the one
that changed the build. Seat him first next time.

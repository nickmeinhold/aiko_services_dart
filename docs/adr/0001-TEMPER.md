# TEMPER.md — ADR-0001 "The Dart Actor runtime"

**Overall verdict:** **RECAST** — unanimous across every seated family.
**Struck:** `dt-1787665955`, 2026-08-25. Families seated: **Maxwell (Claude) + Kelvin (Gemini
2.5 Pro) + Carnot (GPT/Codex) + Tesla (Grok)** — full 4 of 4. **Wu (Kimi K3) disabled** upstream.
**Panel note:** Tesla was written off as a dark seat after an agentic read-loop and then landed
late — which turned out to matter more than any other single fact about this strike. His axis is
blast-radius, and he produced flaws 3 and 13, the two findings that most change what gets built.
An adversary that reports late is not an adversary that found nothing; the earlier draft of this
document was wrong to bank the verdict without him.

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | §2 wins against a strawman and then imports a deadlock class Python cannot have. |
| Kelvin (Gemini) | RECAST | The Pythonic frost-heave is correctly isolated, but the type-safety promises are vaporware until proven. |
| Carnot (GPT) | RECAST | Right boundary condition, but bespoke machinery where Dart already has simpler reservoirs; the equivalence claims are under-proven. |
| Tesla (Grok) | RECAST | A crystal cut to ring at one frequency, and the first live input that arrives is a different note. |

## Fatal flaws (deduped, most-severe first)

**1. D5/D2 violate §1's own seam rule — the `share` redesign is a WIRE change, not an
above-the-wire one.** *Raised by Carnot; CONFIRMED against the reference source, and the
confirmation is worse than the finding.*
`pipeline.py:287` reads **another element's** `share["lifecycle"]`; `:949` and `:1032` branch
control flow on it; `lifecycle.py:265` publishes `(update lifecycle absent)` to remote clients.
`lifecycle` is a live, cross-service, remotely-consumed wire key. Merging it into `state` (D2)
is therefore a **breaking wire change** — and §1 says the wire does not move. Andy's own
`actor.py:86` TODO wants the consolidation, which makes it **his** call on the wire, not ours
to take unilaterally in a port.
Tesla sharpens it further: §1's own inherited subscription form is literally
`(share <topic> <lease> (lifecycle x))` — **the subscription protocol names the key**. So
retuning `lifecycle` breaks *subscriptions*, not merely reads, and Dashboard filters,
`mosquitto_pub`, Category and ServicesCache all match on key names across a mixed Dart/Python
mesh.
**DISPOSITION:** fold. Either publish `lifecycle` + `running` unchanged and keep `ServiceState`
as a purely internal typed *view*, or make `state` strictly additive — and take the
consolidation to Andy as a wire proposal, not a port decision.

**2. D5's data model is the wrong SHAPE — the share is a depth-2 tree, not a flat map.**
*Found by verifying Carnot's claim against source; no reviewer had this — they had the docs, not
`share.py`.*
`_ec_parse_item_path()` splits on `.` and hard-enforces `EC "share" dictionary depth maximum
is 2`. The wire form is `(update metrics.running 3)`; `hyperspace.py:153` and
`process_manager.py:186` both use `share["metrics"]["running"]`. Worse, `_ec_modify_item()`
**silently no-ops** when an intermediate level is missing and `create_path=False` — the wire's
own silence-reads-as-success bug, which D3 exists to abolish one layer up.
D5 models "a typed slice beside an open `Map`" with everything serialising to
`(update <key> <value>)`. That is flat. The contract is a dotted-path tree with a documented
depth limit and a silent-drop failure mode.
**DISPOSITION:** fold — D5 must be rewritten against the real shape, and the depth-2 limit +
missing-path behaviour belong in §1's table as inherited contract.
*Method note: four reviewers all struck D5 on **collision policy**. They corroborated each
other's premise, not reality. The actual defect only appeared by reading the source.*

**3. D8 is not a free win — collapsing paho's thread puts the MQTT keepalive in the same
isolate as application handlers, so a BUSY process gets declared DEAD.** *Tesla alone.*
This is the strike's most consequential finding because it inverts a decision the ADR presented
as pure gain. With no background network thread, a slow handler — a fat S-expression parse, a
long `await` — blocks MQTT keepalive pings. The broker then fires the retained last will
`(absent)` on `{ns}/{host}/{pid}/0/state` (the very row added to §1 this session), and **the
fleet fails over a process that was only busy.** Tesla: *"Python's two-thread hop was ugly; it
also kept the heart beating while the actor thought."*
Third harmonic, same night: an unbounded mailbox fed by a broker that never stops — queue
growth, client buffers, OOM.
**DISPOSITION:** fold — D8 must state its cost, not just its benefit. Options: keep the
transport's ping on a separate isolate, bound handler duration against the keepalive interval,
or set keepalive from a measured worst-case handler. Plus a bounded mailbox with an explicit
overflow policy surfaced on D3's error stream.

**4. §2's mailbox creates a same-actor reentrancy deadlock that Python cannot have.**
*Raised independently by all three seated families.*
The mailbox awaits each handler to completion before dequeuing the next; §1 says
request/response is layered on top, so a reply arrives **as a message**. Any handler that
`await`s a reply wedges permanently. Python is immune because `Message.invoke()` calls handlers
*synchronously* — a Python handler physically cannot suspend mid-flight — so the idiom forces
continuation style. Dart's `async` invites exactly the `await` that deadlocks. Under D8 the
mailbox is the sole serialisation lane, so there is no second thread to escape through.
Carnot's framing: *"remove one irreversible coupling and another appears if request/response is
routed through the same serialized lane it is waiting to drain."*
**DISPOSITION:** fold — pick an explicit rule (replies bypass the mailbox and complete a
`Completer`; or handlers may not await same-actor replies; or bounded reentrancy) and test it.

**5. §2's guarantee has no stated closure condition — and D4 violates it by design.**
*Maxwell; Carnot's liveness finding is adjacent.*
§2 promises "no message observes torn state"; it delivers "no *mailbox message* observes torn
state." D4's `Timer` callbacks, D3's error `Stream`, transport stream callbacks and inbound
ECConsumer updates are all entry points that bypass the mailbox.
Tesla states the law the ADR is missing: **the mailbox is the only legal mutator of actor
state; every I/O, timer and reply that needs to touch the actor re-enters as a message** — which
is exactly Erlang's rule, and the reason Erlang has no note like this. His concrete side doors:
`unawaited(save())`, `Timer(...)`, `stream.listen`, `publish().then`, and any Zone microtask that
closed over `this`. All of them mutate *after* the mailbox has dequeued the next command.
**DISPOSITION:** fold — write that law into §2 verbatim (this is `dir-id 6b6a`, applied to D2 but
never to §2), then audit D4's Timer to **enqueue** rather than execute.

**6. No liveness policy: a hung handler is a silent permanent wedge.** *Carnot, Maxwell.*
No timeout, no cancellation, no shutdown semantics, no answer for what happens to queued
messages after an actor fails. Head-of-line blocking means a slow network await starves control
traffic, log-level changes and shutdown.
**DISPOSITION:** fold — timeout defaults + cancellation + shutdown-with-pending-work, all
surfaced on D3's error stream.

**7. Priority and completion-ordering are in direct tension.** *Carnot — nobody else saw it.*
If the mailbox awaits handler A to completion, priority only reorders the **next dequeue**; it
cannot rescue shutdown or control traffic from a stuck A. If priority is meant to interrupt,
§2's single-completion guarantee is false. The design cannot have both.
**DISPOSITION:** fold — call it *dequeue ordering*, not preemption, and give lifecycle/shutdown
a separate cancellation path.

**8. The mailbox is justified by its weakest reason, and the simpler alternative is unexamined.**
*Maxwell + Carnot, converging.*
Completion-ordering does not require a mailbox: `_tail = _tail.then((_) => handler())` — a
serialising `Future` chain — delivers §2's reason 1 in three lines with no queue. What genuinely
needs a queue is reasons 2 and 3 (uniform local/remote path; deferral/delay/priority). The ADR
ranks its justifications backwards and calls the weakest one "the real one".
**DISPOSITION:** fold — reorder the justifications, and record the Future chain (or Carnot's
`SerialExecutor`) as the considered-and-rejected alternative with the reason it loses.

**9. §4's only acceptance test cannot go red.** *Maxwell.*
"An async handler that awaits mid-mutation must not be observed torn" passes **identically**
under the mailbox and under the three-line Future chain. A test that cannot distinguish the
design from its simpler alternative is not evidence for the design.
**DISPOSITION:** fold — add a forcing arm (must go red without the mechanism) and an arm that
separates mailbox from Future chain. Extend coverage per Carnot: same-actor request deadlock,
long-handler-vs-control-message, shutdown with pending work, deadline ordering, reserved-key
collision, invalid inbound framework value, Python-ECConsumer snapshot compatibility.

**10. D7 is a TODO wearing a decision's clothes.** *All three families.*
"the type system should make explicit rather than leaving a half-built object reachable" names
the requirement and skips the decision. Nullable `topicPath` taxes every call site; a throwing
getter re-implements the `SystemExit` D6 exists to delete.
Tesla enumerated the observers that exist *before* `service_id` does, and one is a live bug:
mailbox naming is `{name}/{service_id}/{topic}`, so **two unregistered `'counter'`s collide** —
`dir-id f7a8`, identity-as-mutable-key, in the first example D1 prints. Also observing early:
ECProducer (control + state topics), the per-Actor logger (`/log`), `add_message_handler`
subscriptions, local proxies posting into a nameless box, Registrar announce, and any
collaborator constructed with `this`. Python hides the gap because `ServiceImpl.__init__` admits
as a *constructor side-effect*; this ADR deletes the side-effect and leaves a TODO where the
type-state protocol should be.
**DISPOSITION:** fold — two types. `ServiceDefinition` (configuration only, no identity field
exists) and a `RegisteredService` **returned by** `runtime.addService(...)`. Registration
becomes the constructor boundary.

**11. D1's construction order contradicts the LWT contract.** *Maxwell.*
`AikoRuntime(transport: mqtt)` takes a connected transport, but the LWT can only be registered
**at connect time** and its topic is `{ns}/{host}/{pid}/0/state` — so identity must exist
*before* the transport connects. The dependency points the wrong way.
**DISPOSITION:** fold — runtime builds its transport from config, or the transport takes the
LWT at connect. Fix D1's example.

**12. D1's own benefit is an un-priced wire hazard.** *Carnot — nobody else.*
D1 sells "multiple runtimes per process" as a win. Two runtimes in one VM contend over MQTT
client identity, LWT ownership, retained process state, namespace and `service_id` allocation.
**DISPOSITION:** fold — state whether multiple runtimes are test-only or production-legal; if
production-legal, define identity allocation per runtime.

**13. Status overclaim.** The header reads `Status: accepted` on a document whose own line says
`design-temper pending`. **DISPOSITION:** `Status: proposed` until a strike returns SOUND.

## What holds

- **The seam rule itself** — "below the wire conform exactly, above the wire design" — is
  endorsed by all three families as the right organising principle. Flaws 1 and 2 are failures
  to *apply* it, not arguments against it.
- **§2's core physics is correct and unchallenged:** Dart serialises synchronous execution, not
  async completion. Every family accepted this. The mailbox survives — on reasons 2 and 3.
- **D1's central move** — separating the invariant from Python's *spelling* of it — is called
  sound by all three, including the honest rejection of the Zone option.
- **D3, D4, D6** are clean, cheap, wire-neutral fixes to documented reference debts.
- **D8** is the strongest new content: correctly identifying the paho thread-hop as a Python
  artifact, and *raising its own stakes* by noting what that leaves exposed.
- **§6 and the parity-not-correctness note** — the right epistemic hygiene; keep verbatim.
- **The Castaway → loopback conclusion** was independently endorsed by Carnot.

## Disposition

**RECAST.** Fold flaws 1–13 into ADR-0001 and re-strike (round 2 of ≤3). Do **not** start `lib/`
code: flaws 1, 2 and 3 each change the shape of types in §4's vertical slice, and flaw 2 changes
`§1`, which is the part everything else is measured against.

Two items are **Nick's**, not foldable by Maxwell:
- **Flaw 1** — consolidating `lifecycle`/`running` into `state` is a wire change that belongs to
  Andy. Ours is either strict-additive or internal-view-only.
- Whether **multiple runtimes per process** (flaw 11) is a production capability or test-only.

**Method note for round 2.** Two of the three heaviest flaws (1, 2) came from *verifying a
reviewer's claim against the reference source* rather than accepting it, and the third (3) came
from an adversary this document had already written off as dark. Both are the same lesson:
the panel's agreement is not the evidence — the source and the full panel are.

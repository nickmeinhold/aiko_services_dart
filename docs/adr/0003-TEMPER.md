# TEMPER.md — ADR-0003, the sealed `Reply` type

**Overall verdict: DISSOLVE.** Two of four families voted DISSOLVE, which is decisive under the
>=2 rule. The candidate is invalidated. The two RECAST votes converge on the *same* deletions as
the two DISSOLVEs, so the disagreement is only over whether the survivor is a recast or a new
design. This is an honest negative result, and the strike produced the replacement rather than
merely a rejection.

**Struck:** `dt-1788521696`. **Full 4-way panel**: Maxwell (Claude), Kelvin (Gemini 2.5 Pro),
Carnot (GPT), Tesla (Grok). Wu (Kimi K3) disabled.

**Tesla note (recorded because the first synthesis got it wrong).** Tesla was written up as a
dark seat after two apparent stalls; it was still running and delivered a full strike late. The
first version of this file therefore claimed the blast-radius flaw stood uncorroborated. It does
not — Tesla corroborated it and went further. An adversary that has not finished is not an
adversary that found nothing, which is the same not-yet-versus-absent confusion this repo keeps
paying for.

Bundle: the ADR, `message_dispatcher.dart`, and the **primary sources it cites** — `s_02` in
full, P1, `actor.py:160-195` — specifically so the adversaries could check the ADR's readings
rather than inherit them. That mattered: two flaws below are misreadings the ADR made *after*
already self-correcting three times.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | Well-chosen type inside a frame the design never justified; two cases carry data nothing reads |
| Kelvin (Gemini) | **DISSOLVE** | "A solution for a function that cannot be called" |
| Carnot (GPT) | **DISSOLVE** | "`Reply` preserves the return slot; deleting the slot is the design" |
| Tesla (Grok) | RECAST | "The type makes every handler a publisher of destinations instead of sealing the send behind the dispatcher that actually parsed the request" |

**Author-bias note.** Maxwell named the wrong-option-frame as its *top* flaw and still voted
RECAST. Two independent families read the same flaw as fatal. The author instance graded its
own design one notch generously, which is the exact bias the cross-family strike exists to
catch, and it is recorded rather than quietly reconciled.

## Fatal flaws (deduped, most severe first)

- **The type cannot be constructed by the function that must return it.** — Kelvin (uniquely).
  `CommandHandler` is `String? Function(List<Object?> arguments)`. It receives **no topic and no
  token**, so a handler literally cannot build `ReplyTo` or `Deferred`. The ADR designed a
  return type without designing the input. DISPOSITION: fatal on its own; folds into the
  replacement below, where the destination arrives *in* the handler's context.

- **Wrong option-frame: the design re-types a return value that s_02 says to REPLACE.** —
  Maxwell, Carnot (independently). §2 is titled *"The no-return-value discipline (what replaces
  return values)"*. The unexamined alternative: **handlers return `void` and send.** No `Reply`,
  no obligation hole, no error case, no dispatcher branch. Carnot: *"deleting the slot is the
  design."* DISPOSITION: adopt — see replacement.

- **`CorrelationToken?` as a nullable field is wrong, unanimously.** — Maxwell, Kelvin, Carnot
  (all three seated families). The token is a property of the **request**, fixed before the
  responder sees it; nullable on the reply encodes "the responder may drop it", which is the bug
  the token prevents. Kelvin and Carnot independently propose the same fix: two distinct shapes
  (`ReplyAddress(topic)` vs `CorrelatedReplyAddress(topic, token)`), not one nullable field.
  DISPOSITION: adopt the two-shape form, in the request context.

- **`Deferred` is a phantom debt marker, unanimously.** — Maxwell, Kelvin, Carnot. It records an
  obligation and enforces none; the design names **no reader** for either of its fields. Maxwell:
  behaviourally identical to `NoReply` with extra syntax — the repo's own *"unused parameter is
  unexercised intent"* lesson, reproduced by the instance that filed it. Kelvin calls it a
  DoS/leak vector and a *"spiritual violation of P1"* — a hand-rolled `Future` without compiler
  support. DISPOSITION: delete the case.

- **`ReplyError` belongs to the owning interface's spec — and the ADR half-quoted the sentence
  that says so.** — Carnot and Tesla (Maxwell had listed this under "what holds"). §2 reads
  *"an error message to the reply topic, **or an error value in shared state, per the owning
  interface's spec**"*; the ADR leaned on the first clause only. Tesla adds that the enforcement
  claim is false in any case: a throwing handler must still not take the actor loop down, so the
  catch site survives and `ReplyError` merely types an exception string as protocol. §2: a failed request produces an error
  message *"per the owning interface's spec"*. A reply interface with `found` / `not_found` /
  `failed` methods makes those **payload** cases, not a universal dispatcher variant. The ADR
  centralized what s_02 explicitly decentralizes. DISPOSITION: delete the case.

- **Correction 3 is itself an overclaim.** — Carnot AND Tesla independently, with receipts.
  Tesla names §3's catalog and it checks out: `find(filters, reply_topic)` with *"standing-query
  attach"* (line 141), `share(topic_response, …filter…)` and `history(topic_response, count)`
  (line 169). Those are N messages **to a reply topic** — pattern 2, not `topic_out`. The
  standing query is precisely the case the ADR declared inexpressible and then closed with
  "nothing here". The ADR "corrected" reply-N-times
  into §2's third pattern. That holds for continuous sequences (frames, telemetry) on `topic_out`.
  It does **not** clearly hold for a *finite multi-message response to one genuine request*, which
  may be an owning-interface reply protocol with correlation. So a self-correction, written to fix
  an overclaim, overshot into the opposite overclaim. DISPOSITION: restate at the proven scope —
  §2 assigns *continuous sequences* to pattern 3; finite multi-message replies are **open**.

- **Under-counted blast-radius: an attacker-chosen reply topic is a reflection primitive.** —
  Maxwell (uniquely; Tesla dark, and this is the flaw class Tesla exists to find). ADR-023 states
  the bus is unauthenticated and any client may invoke any public method. `ReplyTo(String topic,…)`
  puts attacker-supplied data in the destination slot, so a hostile peer can name a victim's
  `/in` and have our service publish there under our identity. The ADR prices none of it.
  DISPOSITION: carries into the replacement unchanged — a reply address is still attacker-supplied.
  **Must be designed, not inherited.**

- **No counterpart upstream, so nothing to conform against.** — Maxwell (uniquely). Python's
  `Message.invoke` calls the method and discards the return. A dispatcher-level `Reply` has no
  Python counterpart and therefore no golden trace can validate it, in a project whose purpose is
  being a second implementation. DISPOSITION: the replacement must state whether it is a
  conformance artifact or a Dart-local ergonomic, and keep the latter out of wire-facing claims.

## What holds

- The rejection of `Future` is correct and survives all three strikes — both because P1 forbids
  it and because it models the wrong thing. Carnot: *"Calling a `Future` by another name would
  fool the design; this ADR avoids that literal error."*
- `String?` genuinely is an impoverished representation. The diagnosis was right; the cure was not.
- Corrections 1 and 2 (the token is normative; there is no synchronous reply) hold under all
  three strikes against the full primary source.
- Surfacing the unknown-command divergence without tie-breaking it, refusing to self-assign an
  AS-RFC number, and marking the `do_request` measurement `unbacked` all hold.

## The replacement the strike converged on

All four families arrived at the same shape from different biases, and Tesla sharpens it into an
inversion: **parse the reply address once, in the dispatcher, and bind it — handlers never
construct a topic.** The handler return then collapses to `NoReply | Send(payload)`.

```dart
typedef CommandHandler = void Function(List<Object?> arguments, HandlerContext context);
```

where `HandlerContext` carries the parsed request metadata — including a reply address as a
sealed two-shape type, correlated or not — and exposes an ordinary `publish`. A handler that
must answer later simply **retains the address and sends later**; the obligation is enforced by
the caller's own timeout or by state observation, which is §2's preferred pattern anyway.

That deletes: the `Reply` type, `Deferred`, `ReplyError`, the nullable token, and the
unconstructable-return-type flaw — five of the seven fatal flaws, structurally.

It does **not** by itself close the reply-topic blast-radius: even a dispatcher-bound address
came from the wire. Tesla's fold is to publish only to an allowlisted inbox shape — the caller's
declared reply interface per §4 — and otherwise `NoReply` plus a log, which is what `actor.py`
already does.

The pattern-2-vs-3 boundary is now **answered against the ADR**: §3's catalog puts N-message and
standing-query responses on the reply topic. What remains open for Andy is Q1, the token's wire
grammar — and Tesla is right that a typed token with no specified encoding is exactly how two
implementations diverge while both claiming conformance.

## Disposition

**DISSOLVE at ≥2 families → candidate invalidated; do not re-cast this design.**

Next move is a *new, much smaller* ADR for the handler-context shape, which must open with the
two questions this strike could not close: reply-address validation on an unauthenticated bus,
and the pattern-2-vs-3 boundary for finite multi-message replies. The second is a question for
Andy, not for us.

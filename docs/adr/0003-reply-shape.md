# ADR-0003 — The reply shape: a sealed `Reply`, not a `Future`

- **Status:** **proposed.** Not struck. No `lib/` code implementing this until it survives a
  design-temper round.
- **Supersedes nothing.** Opens the question `docs/notes/bus-observer-scope.md` deliberately
  deferred: the observer is read-only, so it never sends, so nothing it does is evidence here.
- **Source of authority:** `constitution/s_02_InterfaceComposition.md` §2, read in full on
  2026-09-04, and P1 in `p_00_DesignPrinciples.md`. Both are Andy's, both normative.

## The defect

`lib/src/dispatch/message_dispatcher.dart:23`:

```dart
typedef CommandHandler = String? Function(List<Object?> arguments);
```

`String?` smuggles two cases into nullability — *here is a payload* and *no reply* — and
cannot express a reply whose destination is data, or one that does not exist yet. This is a
**representation** problem. No amount of tuning a return type reaches a shape it cannot
express, so the fix is a different type, not a better one.

## What s_02 §2 actually says, and three corrections it forces

§2 gives three patterns "in order of preference", replacing every use a return value would
have had. Reading it closely corrects our own prior framing three times, so each correction is
recorded rather than quietly absorbed.

**Correction 1 — the correlation token is normative, not a proposal.** §2: the request message
carries the caller's reply topic *"(and a correlation token when the caller multiplexes)"*. We
had been treating a token as something we would be **proposing** to Andy, on the grounds that
`do_request` has no correlation id upstream. That reasoning confused the **implementation**
with the **specification**. The implementation lacks it; the specification requires it when
the caller multiplexes. So modelling it is conformance, and omitting it would have shipped a
knowingly non-conformant type.

**Correction 2 — there is no synchronous reply, so `ReplyNow` is not a case.** §2 is explicit
that *"the response is itself a one-way message to an interface method the caller
implements"*. Every reply has an explicit destination. An earlier sketch of this type had a
`ReplyNow(String payload)` case carrying a payload with no destination — which is exactly the
implicit-channel assumption the whole discipline exists to remove. Deleted.

**Correction 3 — "reply-N-times" is not a reply at all.** It was named three times in this
repo as one of three things our type could not express. §2 routes continuous results to the
third pattern: *"Results that are sequences — frames, detections, telemetry — are streams on
`topic_out` or Pipeline graph edges, never iterated returns."* A stream of partial results is
a different mechanism with a different topic, not a variant of a reply. Modelling it as a
`Reply` case would have imported an inexpressibility that was misfiled from the start.

And the pattern §2 puts **first**, which reframes the whole question:

> **State observation (most queries).** ... Usually, what a `get_x()` would have returned must
> be a key in shared state.

Most things that want an answer should not be requests. The reply machinery serves §2's
*second* pattern, "genuine requests", and a type that makes replying easy makes the
less-preferred pattern the path of least resistance. That is a real risk of this ADR and is
recorded in Consequences.

## Why sealed, and why not `Future`

P1 forbids the reflex: it names as Forbidden *"wrapping message sends in futures/promises as a
core API"*, and states the framework *"does not need, and deliberately does not use,
async/await"* in framework interfaces.

Every Dart instinct answers "the answer does not exist yet" with `Future<String>`. That is the
forbidden shape, and it is also the wrong one — a `Future` models *this call will produce a
value here*, while §2 says the answer arrives **as a separate inbound message on a topic the
caller declared**. The two are not the same thing wearing different syntax.

A sealed `Reply` is **data describing what to send**. It is not a promise, it never awaits, and
`Deferred` is the case that says "not now, and not through this return value."

## Decision

```dart
/// What a handler decided to do about replying. Data, never a promise.
sealed class const Reply();

/// Nothing is sent. The request was fire-and-forget, or the answer belongs in
/// shared state (s_02 §2 pattern 1) or on `topic_out` (pattern 3).
final class const NoReply() extends Reply;

/// The answer, now, as its own one-way message to the caller's declared topic.
final class const ReplyTo(
  final String topic,
  final CorrelationToken? token,
  final String payload,
) extends Reply;

/// The handler accepted responsibility and will send later, against this
/// destination. NOT a Future: nothing awaits, and the eventual send is an
/// ordinary outbound message.
final class const Deferred(
  final String topic,
  final CorrelationToken? token,
) extends Reply;

/// A failed request, routed to the reply topic rather than thrown.
/// s_02 §2: "no exceptions cross the wire".
final class const ReplyError(
  final String topic,
  final CorrelationToken? token,
  final String diagnostic,
) extends Reply;
```

`CorrelationToken` is nullable because §2 makes it conditional — *"when the caller
multiplexes"*. It is a type rather than a `String` so that it cannot be confused with the
topic beside it.

### What each case discharges

| Inexpressibility | Discharged by | Note |
|---|---|---|
| reply-to-a-topic-named-in-the-request | `ReplyTo` / `Deferred` carrying `topic` | needs no wire change; `response_topic` already exists as an unused parameter |
| reply-later | `Deferred` | the send is a later ordinary message, not an awaited value |
| reply-N-times | **nothing here — see Correction 3** | it is pattern 3, `topic_out` |

### Why `ReplyError` is its own case

It is not merely `ReplyTo` with an `(error …)` payload. Today the dispatcher **catches** a
throwing handler and synthesises a diagnostic. That makes "no exceptions cross the wire" a
property of one `try` block. As a case, the handler must *declare* the failure and its
destination, and the rule is enforced by the type rather than by a catch site that a future
refactor can move.

## An open conformance divergence, surfaced not resolved

Three sources disagree about an unknown command, and this ADR does not tie-break:

| Source | Behaviour |
|---|---|
| `actor.py:177-182` (implementation) | logs, publishes nothing |
| our `MessageDispatcher` | returns `(error …)` |
| `s_02` §2 (specification) | *"A failed request produces an error message to the reply topic, or an error value in shared state"* |

Our behaviour is closer to Andy's specification than his implementation is. That is a question
for him, not a licence for us to pick.

The type does clarify one thing: an unknown command may not have carried a reply topic at all,
and `ReplyError` **requires** a destination. So `NoReply` plus a local log is forced in exactly
that case — which is what `actor.py` does. The divergence is narrower than it looked: it is
about commands that *did* declare a reply topic.

## Consequences

- **The less-preferred pattern gets easier.** §2 prefers shared state; a comfortable reply type
  invites requests instead. Mitigation is documentation, not machinery: `NoReply`'s doc comment
  names patterns 1 and 3 as the reasons to choose it, so the first thing a handler author reads
  is the case that means "this should not have been a request".
- **`Deferred` creates an obligation the type cannot enforce.** Nothing makes a handler
  that returned `Deferred` actually send. That is a genuine hole — a correlation token with no
  reply is indistinguishable from one still in flight. Detecting it needs a timeout, which is
  runtime machinery, and this ADR does not propose one.
- **Adding a fifth case later is a compile error at every switch.** That is the intended
  failure mode.

## Open questions for Andy

1. **Is the correlation token's form specified anywhere?** §2 shows `(found <token> <results…>)`
   but does not give the token a grammar. Two implementations will pick different ones.
2. **Unknown-command behaviour** — the three-way divergence above. Which is normative?
3. **`do_request` has no correlation id in the implementation** while §2 requires one for
   multiplexing callers. Is that a known gap, or is `do_request` deliberately outside §2's
   "genuine requests"?
4. **AS-RFC numbering.** `t_01` names `documentation/specifications/ReadMe.md` as the AS-RFC
   number registry. That directory does not exist in `geekscape/aiko_services @ 3fa546f`, and
   no AS-RFC appears to have been published. If this belongs in that series, the number is
   Andy's to allocate — deliberately not self-assigned here.

## Status of the evidence

Read: `s_02` §2 in full, `t_01` numbering and style rules, `p_00` P1, `actor.py:177-182`,
`discovery.py:182-198`, `message_dispatcher.dart`.

**Not verified:** the claim that `do_request` fires 2 requests as 4 handler invocations is
still `unbacked` — quoted from session notes with no artifact in this repo. It appears in this
document only as an open question, and no decision above rests on it.

**Not struck:** no adversarial round has been run on this design.

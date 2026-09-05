## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The type is well-chosen inside a frame the design never justified — s_02 says return values are REPLACED, and this ADR re-types one — and two of its four cases carry data that nothing in the design reads.

`John McClane: "Welcome to the party, pal."`

**Fatal flaws:**

- **WRONG OPTION-FRAME (the illegal move).** The ADR asks "what shape should a handler's return value be?" But s_02 §2 is titled *"The no-return-value discipline (what replaces return values)"* — its whole claim is that return values are **replaced by sends**, not re-typed. The unexamined alternative that dissolves the entire type: a handler returns `void` and, when it has an answer, **sends a message**, exactly as it would send any other message. No `Reply`, no obligation hole, no `ReplyError` case, no dispatcher branch. The ADR never states this option, let alone prices it. That is the enthusiasm smuggling in a Dart instinct — "a function returns a result" — inside a document whose own primary source says stop doing that.

- **NO COUNTERPART UPSTREAM = NOTHING TO CONFORM AGAINST (unstated assumption).** `MessageDispatcher` is *our* invention, the mirrors-free stand-in for `getattr`. Python's `Message.invoke` calls the method and **discards** whatever it returns. So `Reply` is an abstraction with no Python counterpart, in a project whose stated purpose is being a second implementation rigorous enough that differences become findings. A type with no counterpart cannot be validated by a golden trace — there is nothing on the other side to trace against. The ADR treats "s_02 says X" as licence to build X in the dispatcher, without asking whether the dispatcher is where X lives.

- **`Deferred` is a comment wearing a type (unexercised intent — a lesson this repo already filed).** The ADR admits nothing enforces the eventual send. It is worse than admitted: `Deferred(topic, token)` carries two fields and **the design names no reader for either**. Nothing records the outstanding token, nothing times it out, nothing correlates the later send back to it. Behaviourally it is `NoReply` with extra syntax. This repo has a memory note — *"unused parameter is unexercised intent"* — written after `response_topic` was quoted three times as evidence of a constraint it did not impose. This is that pattern, reproduced by the instance that filed it.

- **`CorrelationToken?` puts the token in the wrong OWNER'S hands.** s_02: a token is present *"when the caller multiplexes"* — a property of the **request**, fixed before the responder ever sees it. Modelling it as nullable **on the reply** hands the responder a choice it does not have: it may only echo what the request carried. Nullable therefore encodes "the responder may drop it", which is precisely the bug the token exists to prevent. The token belongs to a request context the handler is given, not to a field the handler fills in.

- **UNDER-COUNTED BLAST-RADIUS: `ReplyTo(String topic, …)` on an unauthenticated bus is a reflection primitive.** ADR-023's own context states the bus is unauthenticated and *"any MQTT client can invoke any public method on any Service"*. A reply topic is attacker-chosen data. Nothing in this ADR constrains it — so a hostile peer sends a request naming a victim's `/in` control topic as its reply topic, and our conformant service publishes attacker-influenced payload there, with our identity. The design prices zero of this. On a two-implementation conformance project this is worse than a local bug: we would be building a faithful implementation of an exploitable shape.

**What holds:**

- The three s_02 corrections are correct and independently checkable against the quoted primary source. Recording them in the document rather than absorbing them silently is the right move.
- The P1 reasoning is sound as far as it goes: a `Future` is both forbidden and the wrong model, for the reason given.
- Refusing to self-assign an AS-RFC number, and surfacing the unknown-command divergence rather than tie-breaking it, are both correct.
- Marking the `do_request` measurement `unbacked` and resting no decision on it is exactly right.

**If RECAST, what to fold back:**

- Add and price the **`void` + send** alternative as the primary option. If `Reply` survives that comparison, say why in the ADR; if it does not, the ADR becomes a much shorter one.
- State explicitly whether `Reply` is a **conformance** artifact or a **Dart-local ergonomic** one. If ergonomic, it must not appear in any wire-facing claim.
- Either give `Deferred` a named reader (what records the token, what times it out) or delete the case and let `NoReply` cover it.
- Move the correlation token out of `Reply` into the request context the handler receives, and make it non-nullable there when present in the request.
- Add a section on reply-topic validation: what constrains an attacker-supplied topic, referencing ADR-023's threat model. An unconstrained `String` here is a design decision, not a detail.

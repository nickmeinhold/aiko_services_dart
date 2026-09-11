# TEMPER — the socket is a handle; the intent is the state

**Overall verdict: RECAST** — zero DISSOLVE, four RECAST. The candidate is **not**
invalidated; it is not yet SOUND either.
**Struck:** dt-1789107309, 2026-09-11. Four families seated: Maxwell, Kelvin, Carnot, Tesla.
Wu disabled. Bundle 63KB, under Carnot's validated point; sentinel-confirmed
(`LAUNCHER_DONE`), all three adversary RCs 0, no dark seats.

> **Kelvin seated on `gemini-2.5-pro` — the PRIMARY model**, which the probe reached on the
> first attempt. The predecessor's strike ran on the `gemini-3-pro-preview` fallback, the
> configuration measured to return zero-finding approvals in four controls. This is the
> stronger seat, and Kelvin's findings here are weighted accordingly.

**Against the done-test the candidate set itself:** *0 DISSOLVE from ≥3 families (met, 0/4),
≤1 RECAST tolerable (NOT met, 4/4).* Fold and re-strike.

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | §5 answers a finding it does not actually answer, and `connect()` — the ordinary recovery path — is unspecified while the exotic one gets four arms. |
| Kelvin (Gemini, **primary model**) | RECAST | The core abstraction is sound but stands on uncontained entropy: naming the dependency's infinite loop is an abdication, not a containment. |
| Carnot (GPT) | RECAST | The right decomposition, not yet reversible — async lifecycle races and a fake that openly violates the contract the prose claims for it. |
| Tesla (Grok) | RECAST | Of the six constraints I set, FakeBus parity is still a sermon, `connect()` is an unsketched third writer, and §6 treats a path convention as a law. |

## Fatal flaws (deduped, most-severe first)

- **The fifth situation was never removed — it was stuffed into `Attached` and the type was
  named `_Reach`.** — **Tesla, alone.** The boot-topic note lists FIVE encodings; §1's table
  has four. *Auto-reconnecting* (`_client != null`, wire down) is filed under `Attached`
  with "publish" as the right answer, so `_publishable` returns a handle whose
  `publishMessage` throws a **package** exception rather than `TransportUnavailable`.
  **The observation measures handle PRESENCE and answers as though it measured
  REACHABILITY.** That is this document's own diagnosis, one level up, committed by the
  document. A promotion during a broker blip does not take the `Detached` arm that was
  sealed — it takes `_reopen` on a client already fighting to live, which is the third
  policy §5 claims to have abolished.
  — DISPOSITION: fold. Either `_publishable` treats a non-connected live handle as
  `TransportUnavailable` (dip and Detached share the transient), or the type is renamed to
  what it actually measures and the gap is written down. No third option.

- **§9's FakeBus parity is prose, and the design never priced its own blast radius.** —
  **Tesla AND Carnot**, independently, both calling the section self-contradicting. The
  bundled `fake_bus.dart` is one `connected` bool, starts LIVE, lets `connect()` resurrect
  after `disconnect()`, and throws `StateError` for everything. `_Reach` is private to
  `AikoClient`, so the compiler that makes the collapsed branch unwritable in §2 **cannot
  see the double at all** — §10's must-fail arm can go red on `AikoClient` and stay green on
  every registrar test, which is the production-only prophet the section was written to
  prevent. The fourteen tests that assume a live bus at construction are uncounted.
  — DISPOSITION: fold. §9 becomes a sketch, not a vow. Lift the observation type into
  `lib/src` so both implementations share it, or write one contract suite both must pass.
  The fourteen tests get a named `FakeBus.alreadyAttached()` with a written reason — the
  same medicine §8 prescribes for identity reuse.

- **`connect()` and `_reopen()` are never written, and the §5 partition depends on them.** —
  **Maxwell, Tesla AND Carnot.** §4 gives `setWill` four arms; §8 specifies `connect()` on
  `Retired` only. `_reopen` is invoked and never sketched. Tesla: *"Disjointness is true
  only if every writer of `_client` is in the sketch. Two of the three are not."* And
  `connect()` is the ONLY recovery a plain caller has — an observer or an ECConsumer never
  calls `setWill` in its life, so the design specifies the exotic path and leaves the
  ordinary one to whatever the implementer types.
  — DISPOSITION: fold. Both methods, all four reaches, explicitly.

- **No lifecycle serialization: the corpse-client class returns through TIME rather than
  nullability.** — **Carnot, Kelvin AND Tesla.** Every public lifecycle method mutates
  `_started`/`_closed`/`_client`/`_will`/callbacks/subscriptions across `await`
  boundaries with no mutex, drain, generation token or happens-before rule. A `disconnect()`
  landing inside `setWill`'s reopen window retires the bus while an in-flight `_open()`
  later installs a new client — producing `_closed && _client != null`, which §1's own table
  declares unreachable. Kelvin adds that `client.disconnect()` is never awaited, so teardown
  relies on the NEXT connect's same-client-id eviction to clean up the LAST one.
  — DISPOSITION: fold. One async gate, or an epoch on `_open()` that may install `_client`
  only if the epoch is still current and `_closed` is still false after every await.

- **§6 states a uniqueness LAW it has not got, and the failure is worse than the bug it
  fixes.** — **Maxwell, Carnot AND Tesla.** "A different incarnation has a different pid" is
  empirical, not a law: containers run as pid 1, a host component can be a logical name.
  Tesla names the consequence, which none of the rest of us reached: two replicas sharing
  `(host, pid, service id)` do not ignore their own residue — **they ignore EACH OTHER, and
  both promote. Dual primary, silent.** Returning `null` also makes own-residue
  indistinguishable from a malformed payload, so the filter's success is invisible.
  — DISPOSITION: fold. Write the instance-uniqueness requirement as a named INVARIANT with
  dual-primary as its stated failure, keep the `found` filter, and log own-residue as its
  own case rather than collapsing it into the malformed arm.

- **§5 is an overclaim, and it is the load-bearing paragraph.** — **Maxwell, Kelvin AND
  Carnot.** The disjointness argument proves only that `AikoClient` adds no third
  reconnection policy. It is then sold as *"the answer to Kelvin's and Tesla's
  independently-found CONNECT storm"*, and it is not — the system storms. Traced against the
  real code: `AnnouncePrimary` → `setWill` throws → `onPrimaryFailed()` → at role
  `primary`, `_enterPrimarySearch()` → `_epoch++` + a fresh `StartSearchTimer` → fires →
  re-promotes → `setWill` again. Against a down broker that is one `_open()` (up to 3
  CONNECTs) **every 2 seconds, per registrar, forever.** And §1 LEANS on that same loop to
  argue `Detached` is not a parking state — the design cannot both use the loop to satisfy
  constraint 2 and claim a proof disposes of constraint 1. Kelvin goes further and refuses
  the naming as sufficient: *"A transport layer that knowingly permits a denial-of-service
  loop in its own dependency has not finished its job."*
  — DISPOSITION: fold, split in two. (a) the transport adds no third policy and never loops —
  provable, keep. (b) the SYSTEM retries unboundedly, the owner is `StartSearchTimer` at
  ~2s, and that is OPEN. Then attempt Kelvin's containment (`maxConnectionAttempts`,
  `autoReconnect = false` before teardown) rather than only naming it.

- **`TransportUnavailable` never reaches the election it was minted for.** — **Tesla AND
  Maxwell.** §3 says the distinction lets an election tell a bug from weather. But `_open`
  and `setWill` still throw raw connect failures, and `registrar_process.dart:363` still
  catches `on Object`. As written the new type is `send`/`clearRetained` honesty, not an
  election instrument. Its blast radius across existing call sites is also unpriced.
  — DISPOSITION: fold. Either the promotion catch matches on it, or §3's election sentence
  is retracted. Plus a call-site table: catches / propagates / crashes.

- **`Detached`'s recovery owner is named only for the registrar.** — **Kelvin AND Carnot.**
  `AikoClient` is general-purpose; the design exports transient-failure recovery to every
  caller forever on the strength of one caller's timer. `send` can report transient
  indefinitely if no caller path re-invokes `connect()` or `setWill()`.
  — DISPOSITION: fold. State which public methods are recovery triggers, and which callers
  may depend on them. Kelvin's alternative — a bounded internal retry — is to be priced, not
  assumed away.

## What holds

- **The core decomposition, unanimously.** All four families endorsed INTENT / MECHANISM /
  OBSERVATION / AUTHORITY, and sealing the OBSERVATION rather than the STATE as the fix for
  what killed the predecessor. Tesla: *"the sentence of mine this document actually carried."*
- **The compiled falsifier.** `_publishable`'s four arms analyze clean and the deletion of
  `_Detached()` is rejected by name. Tesla accepted it explicitly as *"a real falsifier for
  that class"* — while immediately noting the class is narrower than the document claims.
- **Three of Tesla's six constraints are GENUINELY met**, by his own scoreboard: **no parking
  state** (`Detached` is intent without mechanism, nothing waits for a privileged writer —
  *"this is not `Broken` in a new robe"*), **one home for the will** (written first, never
  rolled back, not duplicated onto a phase), and **identity-at-close** on `AikoClient`.
- **`_will` before socket work.** Carnot: intent must survive failed mechanism; rolling it
  back would recreate the split-brain will.
- **§7's post-`connect()` orphan.** Both Carnot and Tesla flagged it as a real missing
  failure mode found from the package source rather than panel folklore, and said the
  catch-and-kill belongs in the design.
- **Refusing to deny the boot-topic coupling.** Carnot calls the predecessor's denial *"the
  worst thermodynamic loss"*; Tesla calls this document's scope sentence honest.
- **Maxwell's parked two-connection alternative** is correctly parked rather than pretended
  subsumed. Tesla: if §6's guard turns out not to be an identity, *"that is the next
  frequency to price — do not discover it after shipping."*

## Disposition

**RECAST.** Fold all eight into the design and re-strike (round 2 of ≤3). The two that change
the document's shape rather than its prose are the first two: the fifth situation is still
collapsed, and the test double cannot be held to a contract the compiler cannot see.

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

---

# ROUND 2 — the same shape, a third time

**Overall verdict: RECAST.** Zero DISSOLVE, four RECAST, again.
**Struck:** dt-1789108118, 2026-09-11. Four families seated (Kelvin on `gemini-2.5-pro`, the
primary model). Bundle 69KB; `LAUNCHER_DONE` sentinel, three RCs of 0, verdict markers in all
three payloads. No dark seats.

Round 2's panel was asked a different question: **not "is this design sound" but "is each of
round 1's eight folds REAL, or prose that names the finding without closing it?"** — because
round 1's §9 was precisely that failure.

## Fold audit (consensus across four families)

| round-1 finding | verdict |
|---|---|
| fifth state / `Dipped` | **REAL** — unanimous |
| `connect()` / `_reopen()` written | **REAL** — unanimous |
| §6 RP-1 demoted from law to invariant | **REAL as honesty**, not as safety (see below) |
| §5 overclaim split | **REAL** — Kelvin conceded his own round-1 fold-back was wrong |
| §3 call-site table | **PARTIAL** — the design commits, the code still catches `on Object` |
| §5c recovery triggers | **REAL** — unanimous |
| §0 lifecycle gate | **PARTIAL** — mechanism present, justification circular |
| §9 FakeBus parity | **NOT REAL, second time** — 3 of 4 families |

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | RECAST | Four folds real; §9 now fails on a *type error* rather than a vow, and §0 closed a race by converting it into a hang. |
| Kelvin (Gemini, primary) | RECAST | Every fold real — and the design now achieves local correctness by outsourcing its critical invariant to a layer that admits it cannot enforce it. |
| Carnot (GPT) | RECAST | More precise, still spending machinery defending an ownership model it has not minted; and the intent/mechanism split *lies* about the will. |
| Tesla (Grok) | RECAST | Dipped is the right name for the fifth frequency and the wrong home for the will — round 3 rings one beat later. |

## THE finding: the same defect, a third time, in the fix for the second

**Tesla and Carnot, independently.** Verified at the package source before being accepted.

`setWill` on `Dipped` writes `_will = next` and throws. But `autoReconnect` does not read
`_will` — `MqttConnectionHandlerBase.autoReconnect` calls
`connect(server!, port!, connectionMessage)` with the **stored** CONNECT message
(saved at `:104`, *"Save the parameters for auto reconnect"*), old will inside. So:

1. dip, then `setWill(B)` records B and throws transient
2. `autoReconnect` republishes the CONNECT carrying will **A**
3. the bus returns as `Attached`, socket armed with **A**, `_will == B`
4. next promotion takes the `Attached` arm, `next == _will` holds, it **returns without reopening**

The registrar believes it holds a retained `(primary absent)` on the boot topic. The broker
holds the per-process `(absent)`. On an unclean death the island is never told its primary is
gone. Tesla: *"Round 3 was `_will == next` while `_client == null`. This is `_will == next`
while `_client` is connected and armed with someone else."*

And the comment I wrote beside it says **"already armed AND the socket carries it"** — the
correct spec, in prose, next to code that tests only the first conjunct.

### The class, named at last

Three consecutive fixes, each generating the next round's worst finding, are **one defect**:

| what was compared | what it was standing in for |
|---|---|
| `_client == null` | is this bus reachable |
| `_client != null` (rev 1's `Attached`) | is the socket *connected* |
| `_will == next` (rev 2's short-circuit) | does the socket *carry* this will |

Every one is **a locally-held value used as a proxy for a state of the wire.** That is this
session's inherited crux — ARTIFACT != STATE — committed three times inside the design written
to cure it. `Dipped` fixed instance 2 by reading `connectionStatus` instead of inferring from
`_client`; the same move cures instance 3.

**The rule, which is the round-3 fold:** *a MECHANISM fact is recorded by the mechanism at the
moment it becomes true, never inferred from INTENT.* `_willOnWire` is written inside `_open()`
on success, sits on the mechanism side beside `_client`, and the `Attached` short-circuit tests
`next == _willOnWire`. `_will` stays pure intent. One field, and it closes the class rather
than the instance.

## Also fatal, deduped

- **RP-1 is a precondition, not a mechanism — and the trade is a regression.** — **Kelvin AND
  Carnot**, both as their headline. Kelvin: *"removes a noisy failure (oscillation) and in
  exchange makes a silent, catastrophic failure (dual primary) more likely… a design that
  requires a law of physics must first prove that law exists."* Checked against today's
  behaviour and they are right that it is a REGRESSION, not merely an unclosed gap: **today**,
  two registrars sharing a path give you one primary (B reads A's `found` and stands down);
  **after §6**, both read it as own-residue and both promote.
  — DISPOSITION: fold, and it is cheap. Own-residue requires `path == topicPath.path` **AND**
  that we actually published an announcement. A replica that never announced treats a matching
  `found` as real news and stands down, exactly as today. One bool, and Kelvin's dual-primary
  is closed without needing RP-1 to hold.
- **`connect()` is dishonest about `Dipped`.** — **Maxwell, Tesla AND Carnot.** It returns void
  over a down wire *and then calls `_reportTransport(up: true)`* (Carnot caught the second half;
  I wrote it and missed it). The revision made `send` honest about `Dipped` and left `connect()`
  lying about it in the same pass. Tesla: *"The prose says these are the same rule. They are
  opposite rules."*
  — DISPOSITION: fold. `connect()` on `Dipped` throws `TransportUnavailable`; transport-up
  reporting derives from connection state, never from caller intent.
- **The shared `Reach` is a type the fake cannot construct.** — **Maxwell, Tesla AND Carnot.**
  `Attached(this.client)` carries an `MqttServerClient`; `FakeBus` has none, so
  `alreadyAttached()` has nothing to put in the field. Round 1's §9 promised parity the fake did
  not have; round 2 promised parity **the type system forbids**.
  — DISPOSITION: fold. `Reach` carries no payload; `AikoClient` reads the handle through a
  private accessor. The exhaustiveness force is in the arms, not the cargo. And §9 ships an
  actual fake *sketch*, not a shopping list — three families called the prose insufficient.
- **§0's two mechanisms justify each other circularly, and the gate's cost is unpriced.** —
  **Maxwell AND Carnot.** Rule 2's epoch is justified as fencing an `_open()` whose world
  changed mid-await, but under rule 1 nothing can change it — `disconnect()` is queued behind
  the gate. Carnot: *"the insight wanted here is one owner of lifecycle mutation, not a mutex
  plus a generation charm."* Unpriced cost: a `disconnect()` during `_reopen` now blocks for up
  to 3 connect attempts against a dead broker — a race traded for a hang.
  — DISPOSITION: fold. Name the escape routes (package callbacks, stream listeners,
  `_reportTransport` re-entering election work) or drop the epoch. Write the happens-before
  boundary, and price the shutdown latency.
- **§10's own must-fail arm is unreachable.** — **Maxwell.** *"`disconnect()` during `setWill`'s
  reopen window"* cannot be constructed under a single-entrant gate. A must-fail arm that cannot
  go red is the T7 defect this repo already shipped once.
  — DISPOSITION: fold. Drive `_open()` beneath the gate, or replace it with a serialisation
  assertion — and add Tesla's sequel: dip, `setWill(B)` refuses, autoReconnect, then `setWill(B)`
  must reopen rather than return.
- **`TransportUnavailable` wrapping is incomplete, so §3's election arm is dead.** — **Tesla AND
  Carnot.** §7 rethrows a `StateError` for stale epochs and post-connect failures in their
  original types, and the election's explicit transient catch misses them.
  — DISPOSITION: fold. Define the wrapping boundary around *every* failed mechanism-open path.
- **`_client` is installed before the candidate is fully armed.** — **Carnot, alone.**
  `_client = client` precedes `_updates.listen` and the subscription restore, so for a window
  the bus is externally `Attached` with no listener. The gate serialises lifecycle callers, not
  arbitrary publishers.
  — DISPOSITION: fold. Install last, after all setup succeeds.
- **Nothing takes `Dipped` to `Detached`.** — **Tesla, alone.** No writer nulls `_client` when
  `connectionStatus` goes `faulted`/`disconnected`. *"If the package is infinite, `Dipped` waits
  forever for a daemon; if it is not, `Dipped` is `Broken` in a new robe."*
  — DISPOSITION: fold. Name the writer, or write down that `autoReconnect` is unbounded (§5b
  establishes it is) so that row provably has no other door.

## What holds, round 2

- **The decomposition, unanimous for the second time.** All four families re-endorsed
  INTENT / MECHANISM / OBSERVATION / AUTHORITY and sealing the observation.
- **`Dipped` is a real repair, not a relocation.** Test applied: a state that shares every
  answer with its neighbour is a row, not a state. `Dipped` and `Detached` agree in §3 and
  diverge in §4. Tesla, who raised the original: *"`_publishable` is repaired."*
- **Six of eight round-1 folds are real**, by adversary audit rather than self-assessment.
- **Kelvin conceded §5b.** *"My own proposal is refuted with a superior argument. I concede the
  point; the thermodynamics are correct."* A reviewer fold-back argued with rather than obeyed.
- **Three of Tesla's six constraints MET by his own scoreboard**: one home for the will
  (*"the home can now lie about the wire, which is a different crime"*),
  reopen-as-election-input (*"the sermon about pid-as-law is dead"*), identity-at-close.
- **§7's catch-and-kill, §6's `ownResidue`, §5b/§5c's honesty** — all re-endorsed.

## Disposition

**RECAST, round 3 — the last under this skill's cap.** The round-3 fold is not a fourth guard:
`_willOnWire` closes a CLASS that three consecutive rounds each closed one instance of, and the
`_hasAnnounced` conjunct closes Kelvin's dual-primary regression without requiring RP-1 to hold.
The remaining seven are mechanical.

---

# ROUND 3 — one SOUND, and an adjudication the vote count would have got wrong

**Overall verdict: RECAST (narrow), folded.** Zero DISSOLVE. **Tesla SOUND**;
Kelvin, Carnot and Maxwell RECAST — on a single shared finding, which is folded
below. The severity trend across three rounds is 8 findings → 8 → 1.
**Struck:** dt-1789109272, 2026-09-11. Four families, Kelvin on `gemini-2.5-pro`.
Bundle 74KB; sentinel, three RCs of 0, verdict markers present. No dark seats.

## The finding — and why counting votes would have mis-decided it

All three RECASTs named `_hasAnnounced` as **the fourth instance of the class**:
a local boolean proxying a state of the wire. They gave three different reasons,
and **the loudest one is wrong**:

- **Kelvin (fatal, HAL quote, "the one note it was supposed to forget")** — but
  his mechanism *drops the second conjunct*: "it sees the other's message but,
  because its own lying boolean is true, it filters it as residue." The filter
  was `_hasAnnounced && path == topicPath.path`; a peer's `found` carries the
  peer's path. His stated scenario cannot occur.
- **Carnot (fatal, and correct)** — B announces, stands down, keeps the flag; A,
  **sharing B's path**, announces; B reads A's `found` as its own residue and both
  promote. This does not drop the conjunct. It requires an RP-1 violation.
- **Tesla (SOUND, and also correct)** — not a new instance, but an **overclaim**
  inside a real fold: *"RP-1 is therefore no longer load-bearing for safety"* is
  true only of the never-announced arm.

Carnot and Tesla describe the same surviving hole and grade it differently.
Kelvin describes a different, non-existent one and grades it fatal. **Severity is
not evidence** — the most dramatic verdict on the table was the one whose
load-bearing premise failed first.

But the hole Carnot names is real, and it is a genuine regression versus today:
in the both-announced colliding-path arm, today's code gives one primary and
round 3's first attempt gives two.

## The fold — Carnot asked for a token that was already on the wire

Carnot's fold-back: *"Do not try to save `_hasAnnounced` with another bool. That
is how this design spent three rounds manufacturing one more proxy. The retained
message needs an owner token."* Kelvin's: *"the fix is not another layer of local
state; it is a measurement of the wire itself."*

Both are right, and **the measurement already exists.** `timeStarted` is
parameter 3 of `(primary found <path> <version> <timestamp>)` — published at
`registrar_process.dart:360`, discarded on read at `:274`, microsecond resolution
at `:206`. So `(path, timeStarted)` is an **incarnation identity** already
travelling on every announcement.

`_hasAnnounced` is **deleted, not repaired**. A process that never announced has
never published its pair, so nothing can match it; a colliding path with a
different start time is a different process. Subtract the coupling rather than
guard the window.

| | today | `_hasAnnounced` | `timeStarted` |
|---|---|---|---|
| own residue after demotion (the oscillator) | **stands us down — the bug** | closed | closed |
| colliding path, neither announced | one primary | one primary | one primary |
| colliding path, both announced | one primary | **two, silently** | one primary |

**Verified, red/green plus a positive control** (a green here is also what a
filter that never fires would give):
- `path && _hasAnnounced` → **2 primaries**; `path && started == timeStarted` →
  **1 primary**;
- own residue after a demotion → still `ownResidue`, still ignored.

RP-1 is now demoted to a note in **every** arm — and unlike revision 3's first
version of that sentence, this one is true.

## Also folded

- **`subscribe`/`unsubscribe` were still `_client?.`** — **Maxwell**, found by
  running the revision's own rule back over the revision. Five public members were
  specified across five reaches; these two were left as the exact
  null-guard-whose-subject-is-never-nulled that was round 1 of the original
  cage-match. On `Dipped` the call lands on a downed socket and returns normally.
  New §3b splits it: the `_subscriptions` record is INTENT and happens in every
  reach but `Retired`; the broker call is MECHANISM and happens only on
  `Attached`.
- **§0 claimed "nothing else reaches `_client`"** — **Carnot AND Maxwell**,
  falsified from code in the same bundle. Narrowed to a claim about **writers**:
  only gated `connect`/`setWill` and bypassing `disconnect` may change `_client`,
  `_willOnWire` or `_closed`; everyone else observes through `reach` and uses
  `_live` inside an arm `reach` has proved.
- **Tesla's hygiene** — `_will = next` now lands before the `Attached`
  short-circuit, so a successful `setWill` always records intent.

## What holds

- **Tesla: "I hunted a fourth. It is not here."** He cleared `_willOnWire`
  (*"a field written from the packet at install, cleared with the handle, cannot
  stale the way `_client != null` could — that is a recording, not a proxy"*),
  cleared `_live` (*"a Dart-atomic corollary of the getter just switched on"*),
  and scored **five of his six constraints MET**. Bounded retry remains PROSE and
  is an owned non-goal — *"a named owner is not a bound"*, which is exactly what
  §5b says about itself.
- **§9 was REAL at last** — the only finding that was prose twice. Kelvin: *"the
  double no longer lies."* Tesla: *"that is demonstration."* Carnot holds it at
  PARTIAL until the suite is code rather than a sketch, which is fair and is what
  §9 says the enforcement is.
- **All sixteen prior findings audited REAL or PARTIAL by adversaries**, none
  regressed.
- **The rule earned its keep.** `_willOnWire` closed instances 1–3; the rule then
  found instance 4 twice more — once in `subscribe` (Maxwell) and once in
  `_hasAnnounced` (Carnot, Kelvin) — in places nobody had thought to look. A rule
  that keeps finding its own violations is doing work a changelog would not.

## Disposition

**Round cap reached (3 of 3).** Zero DISSOLVE across all three rounds; findings
8 → 8 → 1; one family SOUND. The round-3 fold is committed and its two decisive
claims carry red/green pairs, but **that delta is itself unstruck** — so the
design is **not** stamped SOUND. It is `RECAST-folded, provisional`, which a
build gate must treat as un-tempered.

The honest options are Nick's: strike the delta once more (it is small and
bounded — §6, §3b, §0's narrowing), or proceed to implement with the delta's risk
named. What is no longer open is the *shape*: three rounds, four families, and
seventeen findings all landed inside one decomposition, and none of them moved it.

# TEMPER.md — the boot topic needs an owner

**Overall verdict: RECAST.** 0 DISSOLVE, 4/4 families seated.
**Struck:** dt-1789162915 — Maxwell (Claude), Kelvin (Gemini 2.5-pro), Carnot (GPT), Tesla (Grok). Wu disabled.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | B2 is unimplementable — `(primary absent)` carries no identity at all |
| Kelvin (Gemini) | RECAST | "The illusion of sovereignty" — a read-side veto is a latent network partition |
| Carnot (GPT) | RECAST | The candidate table contradicts itself on face 1; candidate 1 establishes no owner |
| Tesla (Grok) | RECAST | B2 would REPRODUCE face 4; and face 1 is in the wrong bucket by the design's own cut |

## Fatal flaws, deduped, most severe first

**1. Face 1 is MISCATEGORIZED — it is bucket B, and the design put it in C. (Tesla, alone.)**
A clean stop **suppresses the will while the process is still alive**. Publishing the existing
`(primary absent)` — or an empty retain — *before* the DISCONNECT is not a new message and not
a new parameter. Python already sends that exact payload, as a will; we would send the same
bytes at a moment we can still speak. So it passes the design's OWN "existing fields, read/write
side only" test, and §7 rejected it as "inventing a wire message Python does not send", **which
is false**.
This is the strike's most valuable finding because it INVERTS the conclusion: face 1 is the only
face with a stopwatch on it (measured — `docker stop`, 139s later the retained `found` is still
there, a replacement registrar reads the corpse and stands down, `FINAL_ROLE=secondary` with
ZERO registrars on the island), and the design parked it in Andy's bucket so it could finish the
half-built reader.
**DISPOSITION: fold.** Face 1 moves to the port-local bucket, gated on the same divergence-register
entry as the rest. Unclean death stays lease/Andy.

**2. Bucket B is NOT ours. (Maxwell §9, Kelvin, Carnot, Tesla — 4/4.)**
Unanimous, and the design named it as its own least-sure point. "Read-side only, so it breaks no
parser" is an argument about FORMAT answering a question about SEMANTICS. A Dart registrar that
ignores a message a Python peer acts on is a **split source of truth on one retained cell** —
Kelvin: *"not a divergence-register entry; a bug class"*; Tesla: *"two owners of one retained cell"*;
Carnot: *"parser compatibility is not island compatibility"*.
**DISPOSITION: fold.** Bucket B is deleted as a category. Its contents become a PROPOSAL to Andy
alongside C. The bucket split survives as an instrument for *routing*, not for *authority*.

**3. B2 is wrong twice over, and one of the ways would reproduce the bug it targets.**
*Maxwell:* `(primary absent)` is a two-token S-expression with **zero parameters**; there is no
announcer identity on the wire to compare, so B2 cannot be implemented with existing fields at all.
*Tesla, sharper:* face 4's live crash was **our own will**, fired after a link blip and read back
on reconnect — **we were the announcer**. So "honour a retraction only from the process we believe
is primary" lets that `(absent)` straight through and drops the roster. Face 4 needs `P_own`
(the payload names ME); face 2 needs `P_holder` (it names who I believe is primary). §6 assigned
face 4 to the `P_holder` predicate. Wrong wire.
**DISPOSITION: fold.** Delete B2 as written. Name the two predicates separately, and state that
neither is computable until `absent` carries identity — which makes it a format change.

**4. The candidate table contradicts itself on face 1. (Maxwell, Carnot, Tesla — 3/4.)**
The table says the fencing token closes face 1; the prose says only the lease does. Both cannot
hold. Tesla supplies the resolution: **a fence answers FRESHNESS, face 1 is LIVENESS.** The note's
"a corpse's token is stale by construction" is false — the corpse IS the current token until
somebody increments it, and a joiner that stands down on seeing it never increments.
**DISPOSITION: fold.** Fix the table; separate freshness from liveness as distinct axes.

**5. A1 closes face 5 by re-entering face 5. (Maxwell, Carnot, Tesla — 3/4.)**
Restoring the will is another `setWill`, another reconnect, another await — inside the unwind of
a transaction that was already revoked mid-await. The design gated A1 on a probe of COST and never
asked whether the restore can fail CLOSED, or what a nested revoke during the restore does.
**DISPOSITION: fold.** A1 needs a re-entrancy answer and a fail-closed story before it is built,
not a latency number.

**6. Lease is the end state and the staircase defers it wrongly. (Kelvin, Carnot, Tesla — 3/4.)**
Kelvin: *"a clean stop is not an edge case, it is the most common operational reality"*. The
proposal to Andy should RECOMMEND leases rather than present three neutral options.
**DISPOSITION: fold.** The Andy proposal leads with the recommendation and its reason.

**7. The root is named one level too high. (Maxwell.)**
Not "a cell with no owner" but **`found` carries identity and `absent` does not** — the retraction
channel is identity-free by construction. Candidate 1 closes exactly the faces whose message has a
name, and none of the faces whose message does not. The design reported that as coincidence.
**DISPOSITION: fold** — re-derive §1 and the candidate table from the asymmetry.

**8. Evidence-tier inflation on face 4. (Maxwell.)**
"Live defects we have already observed in production" was measured on OUR island running OUR code.
That Python has it is a code-reading.
**DISPOSITION: fold** — tag the tier in the sentence.

## REFUTED — and the refutation is about MY bundle, not their strike

**Kelvin's lead flaw ("Design on Slush") and part of Tesla's #5 rest on
`boot-topic-lifecycle.md`'s claim that the transport collapses five lifecycle states into one
null.** That was true when the note was written and is **no longer true**: the five-state collapse
is exactly what `Reach` replaced, shipped and cage-matched in this same branch (`3a33e76`
onward, 263 tests + 10/10 live arms).

Two of four families were partially misled, and the cause is **the bundle I assembled** — I fed
them a document containing a superseded section without marking it superseded. A checked-in doc is
not current intent, and I knew that rule and shipped the artifact anyway.

The *residual* of their point survives and is folded under flaw 5: A1 adds a second await to a
failure path, and that is a hazard whether or not the transport states are distinguishable.

## What holds

- The six-face enumeration. Kelvin: *"a flawless piece of systems forensics."* No family disputed
  that the six reduce to one absence.
- Face 5 is correctly identified as ours alone, for a structural reason rather than a convenient one.
- Refusing to fix face 6 is right: the reorder puts the clear after the resubscribe that re-reads
  the tombstone it exists to erase.
- Separating wire-FORMAT from read-SIDE is a real distinction the prior note collapsed — and it is
  what made flaw 1 findable at all. It survives as a routing instrument, demoted from an authority
  argument.
- §9 named the correct load-bearing uncertainty. All four families went straight to it.

## Disposition

**RECAST — do not build.** Round 1 of ≤3. The fold-back list above is concrete and the two
conclusion-changing items are flaws 1 and 2: **face 1 comes back to us, and bucket B goes to Andy.**
The design's shape survives; its central jurisdictional claim does not.

---

# Round 2 — RECAST again. 4/4 families, 0 DISSOLVE.

The forensics survived untouched by all four families for a second round. **Every round-2 flaw
is in the local patch set (N1/N2), and they converge on one cause the recast never questioned.**

| Family | Verdict | One line |
|---|---|---|
| Maxwell | RECAST | N1 adds a THIRD anonymous producer to the identity-free message §1 just named as the root |
| Kelvin | RECAST | N1 aliases clean-stop with dirty-death and destroys operator-visible information |
| Carnot | RECAST | N1 can overwrite a HEALTHY successor's `found` — a destructive retained write on a stale belief |
| Tesla | RECAST | N1's own ECHO re-opens the election on a live process, which can re-announce and leave a fresh corpse |

## The one cause

**A shutting-down process is still a full election participant until `disconnect()` lands.**
N1 and N2 are wire fixes for a role-lifecycle problem, which is why each fails differently:

- **Own-echo (Tesla).** Registrars subscribe to the boot topic; the recast withdrew every
  read-side filter; so N1's own publish comes back and is handled as *"somebody stopped being
  primary"*. The process leaves `primary` WHILE ALIVE, can win the re-election, publishes a fresh
  `found` AFTER N1, then disconnects. **Face 1, reborn from the patch that closed it.** N1 and
  "no read-side changes" cancel each other — a fix-interaction, not two independent flaws.
- **Stale-belief overwrite (Carnot).** If a successor promoted while we were slow, N1's retained
  `absent` lands on their healthy `found`. No CAS on the cell, so the write cannot be conditional.
- **Phase, not bytes (Tesla).** §3's cut is right about the payload and silent about WHEN. A will
  fires when the writer **cannot act**; N1 fires the same bytes while it **can**. Corrected rule:
  *a write into existing vocabulary is partition-free only when it produces a state the protocol
  already produces AT A PHASE the protocol already produces it.*
- **Information destruction (Kelvin).** Clean stop and dirty death become indistinguishable to an
  operator. Kelvin's alternative beats reuse: propose `(primary withdrawn <identity>)` — a NEW
  message carrying identity, which merges with the `absent`-needs-identity thread.
- **Promote-during-restore (Tesla).** §4's re-entrancy answer covers revoke-during-restore and is
  FALSE for its dual. Win again mid-restore: promotion arms the primary will, the in-flight
  restore overwrites it with the per-process will, and a live primary's dirty death no longer
  retracts. **N2 mints face 1.**
- **Fail-noisy, not fail-closed (Kelvin, Carnot, Maxwell — 3/4).** "Say so on an observable
  channel" names no listener, no severity, no action. Kelvin: a process that cannot guarantee its
  safety contract must **terminate**. It is telemetry wearing containment's coat.

## Disputed, and NOT resolved here

**Carnot dissents on the blanket read-side prohibition.** `found` carries identity, so face 3
(self-recognition on an identity-BEARING message) is a different argument from the `absent` veto —
and the port already ships `ownResidue`, which nobody has called a partition. Kelvin and Tesla
hold the blanket line. Recorded as disputed rather than tie-broken.

## Disposition

**RECAST, round 2 of ≤3.** Round 3 leads with role retirement and orders the wire work beneath it.

---

# Round 3 — RECAST. 4/4, 0 DISSOLVE. **CAP REACHED — STOP, do not recast again.**

| Family | Verdict | One line |
|---|---|---|
| Maxwell | RECAST | Abdication can strand a LIVE process out of the election; "terminate" assumes the registrar owns its process |
| Kelvin | RECAST | After three rounds the deliverable is a feature request, not a buildable artifact — say so |
| Carnot | RECAST | "Terminate" is an exhaust port with no proof the heat left; no epoch on in-flight role work |
| Tesla | RECAST | The identity field CANNOT close face 1, because face 1's victim is a JOINER with no memory to protect |

## The finding that ends the loop

Three rounds proposed three different local fixes for face 1, and each died to a different
mechanism. Tesla's round-3 strike supplies the reason that covers all three:

> **Face 1's victim is a JOINER.** The measured incident is a *replacement registrar* reading a
> retained corpse (`FINAL_ROLE=secondary`, zero registrars on the island). A joiner has no prior
> belief, so every fix that works by protecting what a reader already remembers — reader-ignore,
> identity comparison, `ownResidue` — **cannot reach the victim.**

And the retain flag has no third option: a retained `withdrawn X` reopens Carnot's overwrite (it
lands on a healthy successor's `found`); a non-retained `withdrawn X` leaves the joiner reading
`found X` and face 1 untouched. There is no third MQTT.

**Therefore: only expiry closes face 1.** Round 3 filed face 1 under Ask 1 (identity) and called
Ask 1 *"the ask we would take if only one lands"* — putting the one measured, island-down incident
on the ask that provably cannot close it. `"All three dissolve with ONE field"` was numerology
wearing a mechanism's coat.

**Ask 2 (lease) is not the end state. It is the only thing that closes the measured incident.**
Ask 1 is narrower than three rounds claimed: it is attribution for the WILL (face 2's wire half) —
a demoted X's later tombstone must name X so it cannot un-elect Y. Faces 3 and 4 are `found`'s
existing identity plus a real `ownResidue` arm. Stop bundling four faces onto one field.

## Also unresolved at the cap

- **No epoch on in-flight role work (Carnot).** "Retire first" stops NEW campaigning; it does not
  stop promotion work that passed its checks *before* retirement. Own-echo is replaced by
  stale-await resurrection. This is the same class as the `AnnouncePrimary` authority re-read
  already fixed in code (`b31a338`) — the design failed to apply the port's own lesson.
- **"Terminate" is unproven containment (Carnot) and mis-scoped (Maxwell).** A failed restore means
  the socket path is untrustworthy, and a clean DISCONNECT rides that same path; killed or crashed,
  the broker fires the armed will regardless. And a registrar is a SERVICE — `process.py` hosts
  many — so exiting kills unrelated services to disarm one will.
- **Abdication can strand a live process (Maxwell).** It runs on demotion and abandonment too,
  where the process stays alive. Restore hangs → candidacy never resumes → no primary, forever,
  caused by our own abdication. No timeout, no abort, no re-entry.
- **§7 is disputed 2-2, unresolved — and it rested on a FALSE PREMISE.** Tesla's fold-back said
  to verify "ownResidue already ships" against the tree. **It does not ship** (claude-tasks
  #4329): the enum has two members and nothing in the port compares an announced path to its
  own. That claim was load-bearing for §7 — the argument was "we already ship this and nobody
  called it a partition" — so two families debated a premise that was false, in a strike whose
  own round-1 lesson was that a checked-in doc is not current intent. Second instance this
  session, pointing the opposite way: the note described a defect already FIXED, the transport
  design describes a mitigation never BUILT.

  The original dispute, for the record: Maxwell struck it (the key is `(path, timeStarted)`,
  which the design itself documents as collision-prone on dart2js — so the predicate CAN be wrong,
  so it IS a guess). Carnot endorsed it. Kelvin struck it ("the Partition of Theseus"). Tesla
  endorsed the CUT while rejecting its evidence, and adds a check: **`ownResidue` is cited as
  already-shipped — verify that against the tree before it is used as partition-evidence.**

## Verdict at the cap

**RECAST, unresolved after 3 rounds. DO NOT BUILD.**

Kelvin's reframe is accepted as the honest description of what this document actually is:
**an upstream proposal supported by a local mitigation, not a self-contained design.** Three
rounds of striking a proposal that was presenting itself as a design is what produced that clarity,
and it is worth the rounds.

**What survived all three rounds untouched by every family:** the six-face forensics; the root
(`found` names a writer, `absent` names nobody); face 5 as ours alone for a structural reason;
local abdication as an ORDER rather than two wire patches; face 6 correctly refused; the §3 phase
rule; and "a fence is not a lease".

**What must change before any further work:** face 1 moves to Ask 2 and Ask 2 leads. The local
abdication needs an epoch, a bounded failure path, and a containment action that is neither a
process exit nor a log line — and it is the only part of this that is buildable today.

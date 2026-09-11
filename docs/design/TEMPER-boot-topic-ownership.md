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

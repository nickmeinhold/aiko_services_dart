# The boot topic needs an owner — round 3

> **Status: RECAST round 3 of ≤3. UNSTRUCK at THIS revision.**
> Rounds 1 and 2: 8+4 flaws, 4/4 RECAST both times, 0 DISSOLVE — `TEMPER-boot-topic-ownership.md`.
>
> **Round 2 killed both local patches, and the conclusion moved again.** Face 1 went
> "Andy's (hand-waved)" → "ours (round 1)" → **"Andy's, properly derived (round 3)"**. That is
> not a retreat to the starting position: round 1 was right that the CAST's reason was false,
> and round 2 showed the fix is infeasible locally for reasons the cast never reached.
>
> What survived two rounds untouched by every family: the six-face forensics and the root.

## 0. The frame

Aiko elects a leader using **a retained MQTT message as the election primitive** — no CAS, no
fencing, no expiry, no owner. A value cell used as a lock. Every face is a consequence.

## 1. The root

Three independent questions, answered unequally:

| Question | Answered by | Status |
|---|---|---|
| **Who wrote this?** | `found` carries the path. **`absent` carries nothing.** | half |
| **Is this the latest?** | nothing | none |
| **Is the writer alive?** | the will — and only on an UNCLEAN death | conditional |

**The retraction channel is identity-free by construction.**

## 2. The six faces

| # | Face | Fails | Evidence |
|---|---|---|---|
| 1 | A clean stop does not retract | alive? | **measured**, 139s, `FINAL_ROLE=secondary`, zero registrars |
| 2 | A demotion does not disarm the will | who? | code-reading |
| 3 | A registrar reads its OWN `found` as another's | who? | code-reading + Dart repro |
| 4 | Acting on our own residue after a blip | who? | **measured on Dart**; Python is a code-reading |
| 5 | The abandon path keeps the primary will | who? | **measured**, ours alone |
| 6 | The QoS 0 clear rides a discarded socket | latest? | code-reading |

## 3. The cut, corrected twice

Round 1 killed "format vs read-side". Round 2 killed the replacement's silent half:

> **A write into existing vocabulary is partition-free only when it produces a state the
> protocol already produces AT A PHASE the protocol already produces it.**

A will fires when the writer **cannot act**. Every peer that starts an election on `absent`
assumes the announcer cannot still campaign. A retraction published by a process that is still
connected, still subscribed and still `primary` is **a new interleaving the protocol never
generates** — which is why reusing `absent` on a clean stop fails even though the bytes match.

## 4. What the port does now — ONE ordered abdication, not two patches

Round 2's finding is that N1 and N2 were wire fixes for a **role-lifecycle** problem: a
shutting-down process is still a full election participant until `disconnect()` lands. So the
coupling is removed rather than guarded, and the sequence is one door.

**On leaving `primary` for ANY reason — clean stop, demotion, revocation, abandonment:**

1. **RETIRE THE ROLE LOCALLY, FIRST.** Leave `primary`, stop serving, and **stop campaigning**
   until the sequence completes. This is our own lifecycle, not a veto of anyone's messages — and
   it is what makes every later step safe. Tesla's own-echo dies here by construction: *a process
   that is not a candidate cannot be re-elected by its own message.*
2. **Restore the per-process will**, through the SAME gate that serialises socket work. Step 1
   already ended candidacy, so **promote-during-restore cannot interleave** — which is the
   interruption round 2 proved my earlier re-entrancy answer had missed.
3. **Confirm it, or TERMINATE.** A live process holding a primary will it cannot disarm is an
   armed actuator aimed at a healthy successor. Kelvin is right that there is no third state:
   retry until confirmed, or exit so the DISCONNECT suppresses the bad will. Not a log line.

**Faces 5 and 2's local half close here. Face 1 does not** — see §5.

## 5. Why face 1 leaves again, and what replaces it

Round 1 was right that the cast's reason was false. Round 2 showed the fix is still not ours, for
three independent reasons no local ordering removes:

- **Stale belief (Carnot).** If a successor promoted while we were slow, our retraction lands on
  their healthy `found`. The cell has no CAS; the write cannot be made conditional.
- **Information destruction (Kelvin).** Reusing `absent` aliases clean-stop with dirty-death and
  erases a distinction an operator needs.
- **Phase (Tesla, §3).** Same bytes, a phase the protocol never produces.

**All three dissolve with ONE field**, and it is the field faces 2, 3 and 4 already need:

> **`(primary withdrawn <identity>)` — a retraction that names its author.**

A peer holding `found` from Y and receiving `withdrawn X` simply **ignores it**. That is CAS-like
safety implemented at the reader, with no CAS on the cell, and it needs no lease. The identity
field is the single missing thing behind four of six faces, and it arrives from a fourth
independent direction as the incarnation token already drafted in claude-tasks #4264.

## 6. The proposal to Andy — one message, two asks

**Ask 1, concrete: give the retraction an identity.** It closes faces 1, 2, 3 and 4, and it is
the same field #4264 already asks for. This is the ask we would take if only one lands.

**Ask 2, the end state: lease the primacy.** Identity answers *who* and *is-this-latest*. It does
**not** answer *is the writer alive* when the writer cannot act at all — a hung or killed primary
still has no one to speak for it. Only expiry does. A fence is not a lease; a corpse's token is
current until somebody increments it, and a joiner that stands down never does.

Also carried: face 6's QoS-0 clear, and paho's un-jittered backoff. **One** Discussion, after the
existing queue clears. **No self-assigned RFC number.**

## 7. Resolving round 2's disputed item — MY call, offered to be struck

Carnot dissents from the blanket read-side ban: `found` carries identity, so face 3 is a different
argument from the `absent` veto. (The cast and rounds 1-3 also claimed the port *already ships*
`ownResidue`. **It does not** — verified against the tree after Tesla said to: the enum has two
members and nothing compares paths. That claim was load-bearing for this section and is withdrawn;
see claude-tasks #4322.) Kelvin and Tesla hold the blanket line.

**Proposed resolution:** the line is not read-side-vs-write-side, it is **whether the predicate
needs a guess.**

- Ignoring an announcement that **names us** is a predicate both implementations would agree is
  correct — the reader has complete information and Python not doing it is a bug, not a
  convention. Not a partition.
- Ignoring an **identity-free** `absent` requires guessing who sent it. Two implementations
  guessing differently is a partition by construction.

That would keep `ownResidue` — which must be BUILT, not preserved — and keeps B2 dead. **It is a distinction I invented to
settle a 2-1 split among families that each had a point, which makes it the most likely thing in
this revision to be wrong.**

## 8. Done-test

1. A strike on THIS revision: 0 DISSOLVE from ≥2 families.
2. Red arms that must be able to fail, per round 2's widening:
   - a retired process that receives **its own** retraction echo does not re-announce;
   - a peer promoting **during** our shutdown window keeps its `found`;
   - **promote-during-restore** cannot leave a primary holding a per-process will;
   - a failed restore **terminates** rather than continuing.
3. Every arm above driven through `FakeBus`, and face 5's also against the live island.
4. A divergence-register entry before step 1-3 merge (claude-tasks #4306).

## 9. Least sure

**§7.** It is a fresh distinction invented to break a family split, one revision old, and it is
load-bearing for whether `ownResidue` is built at all. The rest of this revision is other people's findings
folded; §7 is mine.

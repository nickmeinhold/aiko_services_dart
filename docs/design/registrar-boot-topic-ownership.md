# The boot topic needs an owner — a design, not a sixth patch

> **Status: STRUCK — RECAST, round 1 of ≤3. DO NOT BUILD.**
> Verdict and the full fold-back list: `TEMPER-boot-topic-ownership.md`.
> 4/4 families, 0 DISSOLVE. Two findings change the conclusion rather than the detail:
> **face 1 is port-local after all** (a clean stop can publish the retraction while it is
> still alive — same payload Python already sends, at a moment we can still speak), and
> **bucket B is not ours** (unanimous: a read-side veto is a split source of truth on a
> shared island, not a local adoption). The text below is the STRUCK cast, kept unedited
> so the fold-back is legible against it.
>
> **What forced it.** Three `/cage-match` rounds on PR #24 produced findings that all
> reduce to one absence, and `docs/notes/boot-topic-lifecycle.md` had already named that
> absence and its four faces. The rounds then added two more faces. Six instances is past
> the point where the honest move is a class-level answer rather than a sixth guard.

## 1. The one sentence

`{namespace}/service/registrar` is **a shared mutable cell that every registrar both writes
and reads, with no identity check, no ownership model, and no lifecycle rules** — and every
process on the island treats whatever it holds as the truth about who is primary.

Every face below is a consequence of that single absence.

## 2. The faces, now six

Faces 1-4 are from `boot-topic-lifecycle.md` and are reproduced here only by name. Faces 5
and 6 are new, from the PR #24 cage-match, and **face 5 is the one that is ours alone.**

| # | Face | Upstream has it? |
|---|---|---|
| 1 | A clean stop does not retract — the retained `found` outlives the process (measured: 139s, still there) | **yes** |
| 2 | A demotion does not disarm — a demoted process still holds the retained `(primary absent)` | **yes** |
| 3 | A registrar can read its OWN announcement as somebody else's | **yes** |
| 4 | The live gate-A crash: a process acting on its own residue | **yes** |
| 5 | **The abandon path** — a promotion revoked mid-`setWill` returns holding the primary will | **NO — ours** |
| 6 | The QoS 0 boot-topic clear is published onto a socket `_reopen` immediately discards | **yes** |

**Face 5 exists only because our `setWill` is asynchronous.** Upstream's `on_enter_primary`
is one synchronous handler and cannot be interrupted between taking the will and announcing.
MQTT's law forces the reconnect on us the same way it forces it on paho, but paho's caller
blocks; ours awaits, and an await is a window. So face 5 is not a parity question and never
was — it is a consequence of a decision the port made.

## 3. The premise this design refuses to inherit

`boot-topic-lifecycle.md` closes with *"All three are wire changes and therefore Andy's to
choose."* **That sentence is not true of candidate 1, and the note says so two paragraphs
earlier** — candidate 1 "closes faces 2-4 **without new messages**."

Both cannot hold. Resolving it changes who decides:

- **A wire-FORMAT change** (new field, changed arity) is unambiguously Andy's. `process.py:333`
  requires exactly four parameters for `found`; adding a fifth breaks every Python peer. ADR
  territory, and the constitution is explicit that a wire change is an ADR.
- **A read-SIDE behaviour change** uses only fields already on the wire and breaks no peer's
  parser. It is still a divergence — our registrar would ignore an announcement Python's would
  act on — but it is observable only as *our* behaviour, not as a malformed packet.

These are different tiers with different bars, and collapsing them into "all wire changes"
hands Andy a decision he does not need to make while blocking the port from one it can.

**And we have already shipped half of candidate 1.** `registrar_process.dart` compares
`(path, timeStarted)` from the announcement against its own and returns
`RegistrarAnnouncement.ownResidue` — identity enforced on read, using existing fields,
already merged. The question is not whether to start; it is whether to finish.

## 4. Scope: three buckets, and only one of them is Andy's

**Bucket A — ours, no wire involvement, decidable now.**
Face 5. The abandon path is port-local by construction.

**Bucket B — ours to PROPOSE and adopt, read-side only, no format change.**
Faces 2, 3, 4: refuse to act on an announcement that names us; do not honour a retraction
from a process that did not announce. Existing fields only. Diverges in behaviour, so it
needs a stated divergence-register entry (claude-tasks #4306) and a batched finding to Andy
— but it does not need his sign-off to be *correct*, only to be *coordinated*.

**Bucket C — Andy's, format change, ADR.**
Faces 1 and 6, and the durable fix for 2-4. A fencing token or a lease changes the payload's
arity. **Do not self-assign an RFC number** — the registry owns them.

## 5. The candidates, priced

| | Closes | Wire change | Needs a dying process to cooperate | Cost |
|---|---|---|---|---|
| **1. Identity on read** | 2, 3, 4 (and half of 5) | none | no | small; half-built |
| **2. Fencing token** | 1, 2, 3, 4, 6 | **yes** — arity | no | ADR + every peer |
| **3. Lease the primacy** | all, including 1 | **yes** | **no** — the only one | largest |

Candidate 3 is the only one that closes face 1, because face 1 is *a corpse that cannot be
asked to retract*. Candidates 1 and 2 both require somebody alive to do something.

**This design proposes: do 1 now, propose 2 to Andy, and name 3 as the end state.**

The reason is not that 1 is cheapest. It is that **1 and 2 are not alternatives** — a
fencing token is identity-on-read with a better discriminator. Building 1 now is building
the read-side machinery 2 needs, against a weaker key. When Andy rules on the token, the
comparison changes and the structure does not.

## 6. What the port does now (buckets A and B)

**A1 — the abandon path restores the will it took.** When `AnnouncePrimary` abandons because
the election revoked our authority, restore `LastWill.processAbsent(...)` before returning.
Face 5 closed at its source.

> **The known cost, named rather than absorbed.** This is a second reconnect on a path that
> is already a failure path. It publishes nothing, so it cannot announce under revoked
> authority — but it is unmeasured, and the reason face 5 exists at all is that somebody
> reasoned about this window instead of measuring it. **A1 is gated on a probe**, not on
> agreement.

**B1 — `ownResidue` is honoured everywhere, not only in the filter.** Today the comparison
exists and one call site reads it. Face 3 is a *different* call site acting on the same
payload without asking.

**B2 — a retraction is only honoured from the announcer.** An `(absent)` that does not name
the process we believe is primary does not drop the roster. This is the read-side half of
face 4, and it is what turns "a process acting on its own residue" into a no-op.

## 7. What this design deliberately does NOT do

- **No retraction-on-shutdown.** It would invent a wire message Python does not send, and
  face 1 is the one face candidate 1 cannot close. It stays open, on purpose, until Andy
  rules.
- **No fix for face 6.** The obvious reorder — reconnect, then clear — puts the clear after
  the resubscribe that re-reads the very tombstone the clear exists to erase. The order is
  load-bearing in the direction it already has. QoS 1 is a wire change.
- **No local workaround for the token.** The design already tried that twice (`_hasAnnounced`,
  then RP-1 as an unenforced invariant) and both were struck.

## 8. Done-test

1. A `/design-temper` strike scores 0 DISSOLVE from ≥2 families.
2. Face 5 has a red-proven arm: a promotion abandoned mid-`setWill` leaves the process
   holding the PER-PROCESS will, not the primary one.
3. Faces 3 and 4 have red-proven arms driven through `FakeBus`: our own retained `found`
   replayed to us moves nothing; an `(absent)` naming a third party drops no roster.
4. The A1 probe is run against the live island and its cost is a number, not an adjective.
5. A divergence-register entry exists for B1/B2 before they merge (#4306).
6. A single batched finding to Andy covers faces 1, 2, 6 and the token — **one** Discussion,
   not four, and only after the existing queue clears.

## 9. The question this design is least sure of

**Is bucket B actually ours?** The port's charter is that a difference from Python becomes a
FINDING rather than a bug we fix. B1 and B2 make our registrar ignore messages a Python
registrar would act on. That is a behavioural divergence on a shared island, and the
argument that it is "read-side only, so it breaks no parser" is an argument about *format*
answering a question about *semantics*.

The counter-argument is that faces 3 and 4 are **live defects we have already observed in
production**, and reproducing a defect faithfully is only virtuous while somebody is
counting on the reproduction.

This design does not resolve that. It is the thing most worth striking.

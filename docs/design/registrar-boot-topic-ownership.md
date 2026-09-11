# The boot topic needs an owner — recast against the round-1 strike

> **Status: RECAST (round 2 of ≤3). UNSTRUCK at THIS revision.**
>
> Round 1: 4/4 RECAST, 0 DISSOLVE — `TEMPER-boot-topic-ownership.md`. Two findings changed the
> conclusion rather than the detail, and both are folded here:
> **face 1 is port-local** (a clean stop can answer for itself while it is still alive), and
> **"read-side changes are ours" is wrong** (unanimous).
>
> This revision is built on the distinction that makes those two verdicts consistent — §3. It is
> SHORTER than the cast, and the candidate ladder is gone.

## 0. The frame, stated so it can be attacked

Aiko elects a leader using **a retained MQTT message as the election primitive**. A retained
message has no compare-and-swap, no fencing, no expiry and no owner. It is a value cell being
used as a lock.

Every face below is a consequence of that category error. This design does **not** propose
replacing the primitive — that is Andy's architecture — but nothing here should be read as
claiming the primitive is adequate. It is not. §5 says so to him.

## 1. The root: three questions, and which one the wire can answer

A process reading `{namespace}/service/registrar` must answer three questions. They are
independent, and the protocol answers them unequally:

| Question | Answered by | Status |
|---|---|---|
| **Who wrote this?** | `found` carries the announcer's path. **`absent` carries nothing.** | half-answered |
| **Is this the latest?** | nothing | unanswered |
| **Is the writer still alive?** | the will — and **only on an UNCLEAN death** | conditionally |

**The retraction channel is identity-free by construction.** `(primary absent)` is a two-token
S-expression with zero parameters; `RegistrarAnnouncement` is `{found, absent}`. The protocol can
say *"X is primary"* and can only say *"somebody stopped being primary"*.

That asymmetry — not "a cell with no owner" — is the root. The cast named it one level too high,
and the tell was that its favoured fix closed exactly the faces whose message carries a name and
none of the faces whose message does not. That was reported as a coincidence. It was the structure.

## 2. The six faces, by question

| # | Face | Question it fails | Evidence tier |
|---|---|---|---|
| 1 | A clean stop does not retract | **alive?** | **measured** (Dart AND the Python container: `docker stop`, 139s, `FINAL_ROLE=secondary`, zero registrars) |
| 2 | A demotion does not disarm the will | who? | code-reading (`registrar.py:189`, no `on_exit_primary`) |
| 3 | A registrar reads its OWN `found` as somebody else's | who? | code-reading + Dart-side reproduction |
| 4 | Acting on our own residue after a blip | who? | **measured on DART** — that Python does it too is a code-reading, not a measurement |
| 5 | The abandon path: a revoked promotion keeps the primary will | who? | **measured**, ours alone |
| 6 | The QoS 0 boot-topic clear rides a socket `_reopen` discards | latest? | code-reading |

Face 5 exists only because our `setWill` is asynchronous. Upstream's `on_enter_primary` is one
synchronous handler and structurally cannot abandon.

## 3. The cut that governs — and it is NOT format-vs-read-side

The cast's cut was "wire-format change (Andy's) vs read-side change (ours)". All four families
rejected it: *"breaks no parser"* is an argument about FORMAT answering a question about
SEMANTICS. They were right, and the cast had already named that as its weakest point.

The cut that survives is different, and it explains why face 1 and bucket B get **opposite**
answers from the same panel:

> **A change to what we WRITE, using the protocol's existing vocabulary, produces a state every
> peer already handles. A change to what we READ produces asymmetric belief — we ignore a message
> a peer obeys — which is a partition.**

- **Face 1's fix is write-side into existing vocabulary.** A clean stop publishes retained
  `(primary absent)` — *the exact payload the will already publishes on an unclean death*. A
  Python peer reading it does precisely what it does today when a registrar dies dirty: starts an
  election. **There is no state produced that the protocol does not already produce.** The only
  difference is the trigger.
- **A read-side veto is not that.** Ignoring an `(absent)` a Python registrar acts on leaves two
  processes with different beliefs about one cell. Kelvin: *"not a divergence-register entry — a
  bug class."*

So: **no read-side changes.** The cast's B1 and B2 are withdrawn entirely, including the parts
that looked free.

### B2 is withdrawn twice over, and the second reason is the sharper one

It could not be built: `absent` has no identity field to compare. And even granted the field, the
cast aimed it at the wrong predicate. Two distinct predicates were conflated:

- **P_own** — *does this payload name ME?* Closes face 4.
- **P_holder** — *does it name who I believe is primary?* Closes face 2.

Face 4's live crash was **our own will**, fired after a blip and read back on reconnect. We *were*
the announcer, so P_holder admits it and drops the roster — the bug wearing a filter. The cast
assigned face 4 to P_holder.

## 4. What the port does now

**N1 — a clean stop retracts (face 1).** Before `disconnect()` suppresses the will, a process that
is currently `primary` publishes retained `(primary absent)` to the boot topic. Write-side,
existing vocabulary, no new state.
*Fail-closed:* if the publish throws, the shutdown continues — we are no worse off than today, and
the retained `found` is exactly what today leaves anyway. The failure is reported, not swallowed.

**N2 — every exit from `primary` restores the per-process will (face 5, and faces 2's local half).**
`setWill` appears once in `registrar_process.dart` and restores nowhere; three exits leave the
primary will armed. Restore on all of them.
*Re-entrancy, which round 1 demanded and the cast did not answer:* **the restore's target does not
depend on the election state.** Every non-primary role wants the per-process will, so a nested
revocation during the restore does not invalidate it — the operation is idempotent under
interruption, which is why it is safe where the promotion it unwinds was not.
*Fail-closed:* if the restore fails, the process is a non-primary holding a primary will and
**cannot fix itself**. It must SAY so on an observable channel rather than continue silently. That
is a named degraded state with an owner, not an absorbed one.

Both are wire-observable, so both get a divergence-register entry (claude-tasks #4306) and both go
into the same message to Andy — shipped, registered, and disclosed in one breath, because the
alternative is knowingly shipping a registrar that takes an island down on a clean stop.

## 5. What we propose to Andy — leading with the recommendation

**We recommend leasing the primacy.** Not as one of three options: as the answer.

Only a lease closes the **alive?** question in the general case. Identity and freshness both
require somebody alive to act — a fence answers *is this latest*, and a corpse's token IS the
latest until someone increments it, which a joiner that stands down never does. Round 1 killed the
cast's three-rung ladder for exactly this: its middle rung does not reach the measured outage.

The batched message carries: the lease recommendation; `absent` needs an identity field (faces
2/3/4, and it is what makes P_own and P_holder expressible at all); face 6's QoS-0 clear; and the
incarnation-token finding already drafted as #4264 — which is the same field arriving from a
third direction.

**No self-assigned RFC number.** The registry owns them.

## 6. Deliberately not done

- **No read-side filtering of any kind** (§3).
- **No fix for face 6.** The obvious reorder puts the clear after the resubscribe that re-reads the
  tombstone it exists to erase. The order is load-bearing in the direction it has.
- **No local workaround for the token.** Tried twice (`_hasAnnounced`, RP-1); struck both times.

## 7. Done-test

1. A strike on **this** revision: 0 DISSOLVE from ≥2 families.
2. **N1 red-proven against the live island**, not the fake: start a registrar, let it announce,
   `disconnect()` it cleanly, and assert the boot topic reads `(primary absent)` — then assert a
   replacement registrar PROMOTES instead of standing down. The round-1 measurement is the red arm
   and it already exists (139s, `FINAL_ROLE=secondary`).
3. **N2 red-proven per exit**, all three, with the fail-closed arm driven by a forced `setWill`
   failure — the degraded state must be observable, not inferred.
4. A divergence-register entry exists for N1 and N2 before they merge.
5. **One** message to Andy, after the existing queue clears.

## 8. What this revision is least sure of

**§3's cut is load-bearing and it is one round old.** "Write-side into existing vocabulary cannot
partition" is clean, and cleanliness is exactly what the round-1 cast's cut also had before four
families took it apart.

The specific place to push: N1 makes a *clean stop* and an *unclean death* indistinguishable on the
wire. Today they differ — clean leaves `found`, dirty leaves `absent` — and something could be
relying on telling them apart. Nothing in `registrar.py` reads the difference, which is a
code-reading and not a measurement. **If that distinction is load-bearing anywhere, §3 is wrong and
N1 is a read-side change wearing a write-side coat.**

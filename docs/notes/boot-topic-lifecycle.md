# The boot topic has no owner — one defect with four faces

> **Status: a DESIGN finding, not a bug list.** Written because the cage-match on PR #24
> surfaced the same shape three times across two rounds, which is the stop signal for
> "enumerate the class yourself instead of discovering it one instance per round". It is
> deliberately NOT fixed here: every face is faithful parity with `registrar.py`, and the
> fix is a change to the election's contract rather than a patch.

## The shape

`{namespace}/service/registrar` is the only retained topic in Aiko. It is a **shared
mutable cell that a registrar both writes and reads, with no identity check, no ownership
model, and no lifecycle rules** — and every process on the island treats whatever it holds
as the truth about who is primary.

Each face below is a consequence of that one absence. None is an implementation slip; all
four are in the reference too, and our port reproduces them.

## Face 1 — a clean stop does not retract (measured)

`docker stop aiko-registrar-1` at 08:19:15. 139 seconds later the topic still read
`(primary found aiko/fddd654e4b5a/1/1 …)`. The broker's own log gives the mechanism:
`disconnected: connection closed by client` — a clean DISCONNECT, which SUPPRESSES the
will. The retained announcement therefore outlives the process indefinitely.

**Consequence, verified rather than reasoned:** a replacement registrar joining that island
reads the corpse and stands down to `secondary`. Run against a live island with NO
registrar container up: `FINAL_ROLE=secondary`. Zero registrars, and every replacement
declines the job. Clearing the topic by hand is the only exit.

## Face 2 — a demotion does not disarm (Carnot, round 1)

`set_last_will_and_testament` appears exactly once in `registrar.py` (`:189`, inside
`on_enter_primary`), and `StateMachineModel` has no `on_exit_primary`. A process demoted to
`secondary` or knocked back to `primary_search` is still holding a retained
`(primary absent)` aimed at the topic. Once a *different* registrar has announced itself,
an unclean death of the demoted process publishes that tombstone over a healthy
`(primary found …)` — a false absence from a process that has not been primary for hours.

**Faces 1 and 2 are opposite errors on one topic:** stopping cleanly fails to retract when
it should; being demoted retracts when it should not. Neither self-corrects.

## Face 3 — a registrar can read its OWN announcement as somebody else's (Carnot, round 2)

`_onAnnouncement` (and `registrar.py:_registrar_handler`) branch on the ACTION only. Neither
compares the announced `topic_path` against its own. The election is safe while the role is
`primary` — a `found` there is correctly "not news" — but the guard is the ROLE, not the
identity.

So: announce (role `primary`), get demoted by a peer's `(primary absent)` to
`primary_search`, then reconnect for any reason. `resubscribeOnAutoReconnect` re-subscribes,
the broker re-delivers OUR OWN retained `(primary found <us>)`, and `(found, primary_search)`
stands us down to `secondary`. The island's topic names us as primary while we sit inert
believing somebody else is.

## Face 4 — the same root, already observed in production (this session)

The live gate-A crash was this class before it had a name: our link dropped, the broker
published **our own** retained will, we auto-reconnected, re-read it, dropped the entire
roster and re-elected. A process acting on its own residue, because the topic does not
record who wrote what.

## A SECOND design finding, same session: the transport collapses five states into one null

> **SUPERSEDED 2026-09-12 — this section describes the transport as it was, not as it is.**
> The five-state collapse is exactly what the sealed `Reach` observation replaced
> (`docs/design/transport-lifecycle-intent-and-mechanism.md` revision 4, shipped on
> `feat/registrar-process` from `3a33e76`; 263 tests plus a 10/10 live-broker probe).
> `never-connected` / `live` / `failed-reopen` / `deliberately-closed` are now distinct and
> exhaustively switched, and the auto-reconnecting row no longer exists at all —
> `autoReconnect` is off and the supervisor is ours.
>
> Kept rather than deleted because the FINDING was real and the record of it is load-bearing.
> Marked because it was bundled unmarked into a `/design-temper` round and two of four families
> struck a premise that had already been fixed. A checked-in doc is not current intent.

Not a face of the boot topic — a separate shape, surfaced by the same cage-match and
recorded here because it has the identical structure and the identical wrong answer.

`AikoClient` represents its entire connection lifecycle as `_client == null`. At least five
distinct states share that encoding:

| state | `_client` | what a caller should do |
|---|---|---|
| never connected | null | `connect()` |
| live | non-null | publish |
| auto-reconnecting | non-null, not `connected` | wait |
| **failed reopen** (a `setWill` that tore the socket down and could not rebuild it) | **null** | **reconnect** |
| deliberately closed | null | nothing, ever |

**Every transport defect this cage-match found is a consequence of that collapse.** The
teardown that threw a null-check error over a `SocketException`; the null-guard whose subject
was never nulled; the corpse client left behind by a failed reopen; and Tesla's round-3
finding, which is the one that hurts: after a failed reopen, `setWill` takes the
`if (live == null) return` branch — the one that MEANS "not connected yet, `connect()` will
carry it" — so a registrar retrying promotion never reconnects, and arcs between
`primary_search` and a promotion it can never complete, deaf, indefinitely.

The first fix attempt guarded the value-equality short-circuit instead, which is the wrong
gate: the retry stops earlier than that. Guarding the right gate needs the states to be
distinguishable, which is the design change.

**Not attempted here.** Three review rounds produced four transport patches, and the fourth
generated this finding — which is the "my own last round's fix generated this finding" stop
signal, at the round cap. A fifth guard is the wrong move; naming the state machine is the
right one.

## What the fix is not

Not a guard per face. Three of the four have an obvious local patch (publish a retraction on
shutdown; relinquish the will on demotion; compare the path before acting), and adding them
one at a time is how this stayed invisible for three rounds — each patch closes one instance
and leaves the cell ownerless.

## The question a design pass has to answer

**Who owns the boot topic's value, and what is allowed to change it?** Candidate shapes,
none chosen here:

1. **Identity in the payload, enforced on read.** A registrar ignores any announcement
   naming its own path; a retraction is only honoured from the process that announced.
   Cheapest, and closes faces 2-4 without new messages.
2. **A session token / fencing value.** The announcement carries a monotonically increasing
   token; a lower token never overwrites a higher one. Closes face 1 as well, because a
   corpse's token is stale by construction. Interacts with the `time_started` question.
3. **Lease the primacy rather than announce it.** The retained value expires unless
   refreshed, so a corpse decays instead of persisting. Biggest change, and the only one
   that needs no cooperation from a dying process.

All three are wire changes and therefore Andy's to choose. Faces 1-3 are drafted in
`registrar-findings-for-upstream.md`; this note is the shape behind them.

---

## Appendix: a premise three cage-match rounds never questioned

Surfaced by a peer session working from another repo — which is the point, because it could
not have come from inside.

This repo cites **ADR-023** eight times as the authority for "the bus is unauthenticated, any
client may invoke any public method", and several hazards above are reproduced faithfully on
that basis. Two things are wrong with the citation:

1. **ADR-023 does not exist in this repo.** The highest ADR committed here is 0003. It lives
   in the Python `aiko_services` repo, at `constitution/adr/ADR-023_GuardedEvalDefaultDeny.md`.
   A cross-repo normative reference cited as though it were local is a dangling premise.

2. **We have been quoting its CONTEXT as though it were its DECISION.** The sentence we
   paraphrase is real and appears in the ADR — in the paragraph describing *the problem*.
   Decision 2 is the opposite: *"Default-deny method exposure. Every public API is deny-all
   by default, per method… it closes the arbitrary-invocation hole."* It mints **P12**. So
   the document we cite as authority for the hole being permanently open is the document that
   rules it shut.

Our factual statements stay true — the bus IS open today, and the enforcement is unshipped.
What was wrong is the ROLE the citation played: an open bus as an accepted end state rather
than an unfinished obligation. That changes "reproduced faithfully because diverging would be
an interop change" into a conformance question the port owes an answer to (see claude-tasks
#3760).

ADR-023 also explicitly separates two axes the word "ACL" conflates: what is *offered*
(exposure — ADR-023 itself) and who may *invoke* it (authority — candidate CP-C, still open,
and whose rationale rejects bolting ACLs onto an open dispatch bus). A broker-level
mTLS + mosquitto-ACL design is a THIRD axis again — topic-level reachability. Worth deciding
on purpose rather than by proximity.

**Why this matters beyond the citation:** three cage-match rounds, four model families, and
none of them questioned it — because every reviewer was handed the premise in the same
prompt. A panel interrogates claims within a premise bundle and is structurally incapable of
interrogating the bundle. The correction came from someone who was not in the thread.

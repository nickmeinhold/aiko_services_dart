# TEMPER.md — transport connection lifecycle as a sealed phase

**Overall verdict: DISSOLVE** — candidate invalidated (2 of 4 families, Maxwell counts).
**Struck:** 2026-09-11, four families seated (Maxwell, Kelvin, Carnot, Tesla). Wu disabled.
Bundle 15KB; sentinel-confirmed, no dark seats.

> Kelvin seated on `gemini-3-pro-preview` — the FALLBACK model, because `2.5-pro` did not
> answer the probe. That is the configuration measured to return zero-finding approvals in
> four separate controls, so its RECAST is the weakest vote on the table. Noted rather than
> discounted: its infinite-retry flaw was independently found by Tesla, which is what makes
> it credible here.

## Per-family verdicts

| Family | Verdict | One-line |
|---|---|---|
| Maxwell (Claude) | **DISSOLVE** | The frame is wrong: `setWill` exists for one caller, and that caller's need to mutate a will is itself removable. |
| Kelvin (Gemini, fallback model) | RECAST | The `Broken → Open` rule is thermal runaway; the cheap alternative is a trap. |
| Carnot (GPT) | **DISSOLVE** | Overspends. Split transport INTENT from socket EXISTENCE and the deadlock closes for two booleans. |
| Tesla (Grok) | RECAST | A sealed type with a nullable escape hatch is the old encoding in a new robe — and the reopen is an election input, which the design denies. |

**Two DISSOLVEs is decisive under this skill's rule. The candidate is invalidated.** It is
being recorded as an honest negative, not re-cast.

## Fatal flaws (deduped, most-severe first)

- **The design denies a coupling it creates.** It states "Not the boot-topic design… Andy's to
  choose". False: `setWill` on `Broken` reopens, a reopen re-subscribes, and the broker
  redelivers our OWN retained `(primary found …)` — which is face 3 of the boot-topic note.
  Shipping rule 1 alone turns the deadlock fix into a self-demotion oscillator. — **Tesla** —
  DISPOSITION: any replacement must treat reopen as an election input. Non-negotiable.
- **A quiet deadlock becomes an unbounded CONNECT storm.** Three reconnection policies would
  share one socket (`autoReconnect`, caller `connect()`, `setWill` on `Broken`) with no bound
  or backoff. "A quiet deadlock is a bug; an unbounded retry is an outage." — **Kelvin AND
  Tesla independently** — DISPOSITION: any replacement owns retry bounds explicitly. The
  strongest signal this panel produced.
- **The proposal fails its own falsifier.** `Broken` names ONE transition (a failed `setWill`
  reopen); that does not buy a sealed hierarchy across 24 call sites. — **Carnot and Maxwell,
  by different routes** — DISPOSITION: superseded by the replacement below.
- **Ceremony is not exhaustiveness.** A sealed phase that still exposes a nullable client
  getter is the old encoding in a new robe: every `if (live == null) return` still compiles and
  round 3 reincarnates at site 25. — **Tesla** — DISPOSITION: the replacement must make the
  collapsed branch unwritable, not merely renamed.
- **`Broken` is a parking state — the window the design was supposed to remove.** If the only
  writer that behaves differently is `setWill`, then `setWill` reopens or throws IN the
  transition; a parked `Broken` is a fifth guard wearing a type. — **Tesla** (this is
  remove-the-coupling-don't-guard-the-window, aimed at my design).
- **`Broken.intendedWill` gives the will two homes** — the same chord as round 2's corpse
  client with a new will. The will is durable intent and belongs on the client, once. —
  **Tesla and Carnot**.
- **`FakeBus` is in scope and the design excluded it.** Three defects in this PR hid behind a
  kinder double. A contract the fake does not implement is a production-only prophet: the
  tests stay green, the island does not. — **Maxwell AND Tesla**.
- **`Closed` under-counts identity.** A fresh `AikoClient` is a fresh MQTT identity on the
  island, not a private constructor detail. Reuse-vs-mint must be decided and written, not
  left to whichever a test happens to do. — **Tesla**.

## What holds

- **The diagnosis.** Four defects, one root, each patch locally correct, the fourth generated
  by the third. Every family accepted it. That survives the design's death.
- **The round-3 finding**: the deadlock cannot be fixed in the current encoding, because the
  branch needing to behave differently is the branch that cannot tell which state it is in.
- **Publish legality**: caller-error (no socket) must be distinguishable from transient
  (reconnecting). Right under any shape.

## The replacement, from Carnot's DISSOLVE

Not a smaller version of the same idea — a different decomposition:

> **`_client` means only "the current socket handle". Lifecycle INTENT lives in separate
> fields.** The will is durable intent; the MQTT client is disposable mechanism, and coupling
> them is what produced every defect.

- initial `setWill` records only, because `started == false`
- a failed `_open()` nulls the handle but leaves `started == true`, so the next promotion retry
  reconnects — round 3 closed
- after `disconnect()`, `closed == true` refuses — round 2 preserved
- teardown still tolerates an absent client and preserves the original exception — round 1
  preserved

Cost: two booleans and three targeted branch tests, against a sealed hierarchy and a 24-site
migration. **It must additionally satisfy Tesla's constraints**: bounded retry, no parking
state, one home for the will, reopen treated as an election input, `FakeBus` implementing the
same rules, and a written answer on identity-at-close.

## Maxwell's alternative, recorded and NOT pursued

Two MQTT connections per registrar — a process-level one carrying the process will, a
primary-level one opened on promotion — so no will ever mutates and no socket is rebuilt under
live subscriptions. The wire is unchanged. It is subsumed by Carnot's framing (if intent is
separated from mechanism you do not need a second connection to get it), costs two client IDs,
and diverges further from the reference. Kept because it dissolves the same coupling from the
other side, and because if the replacement leaks it is the next thing to price.

## Disposition

DISSOLVE at ≥2 families → **candidate invalidated; do not re-cast this document.** Write the
replacement as a new design against the constraint set above, and strike that.

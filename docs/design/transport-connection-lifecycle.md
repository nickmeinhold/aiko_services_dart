# Design — the transport's connection lifecycle as a sealed state, not a nullable field

> **Status: PROPOSED, untempered.** Written because three cage-match rounds on PR #24
> produced four transport patches and the fourth created a deadlock. Each patch was locally
> correct and the class kept regenerating, which is the signal that the defect is the shape
> rather than any instance.

## The problem, stated as an invariant that does not hold

`AikoClient` encodes its entire connection lifecycle in one nullable field, `_client`.
**Twenty-four sites** read or write it. At least five distinct states share that encoding,
and callers need different behaviour in each:

| state | `_client` | `connectionStatus` | what a caller must do | what the code does today |
|---|---|---|---|---|
| never connected | null | — | `connect()` | varies by call site |
| live | non-null | `connected` | publish | correct |
| auto-reconnecting | non-null | `connecting` | wait / refuse a publish | `_publishable` handles it |
| **failed reopen** | **null** | — | **reconnect** | treated as "never connected" |
| deliberately closed | null | — | nothing, ever | treated as "never connected" |

Rows 1, 4 and 5 are indistinguishable, and they need opposite responses. Every transport
defect this cage-match found is a consequence:

- **round 1** — teardown threw a null-check error over the `SocketException` that was the real
  news, because it could not tell "never opened" from "open".
- **round 2** — the null-guard whose subject was never nulled: `disconnect()` left `_client`
  pointing at a torn-down client, so `_client?.` passed and the call landed anyway.
- **round 2** — a failed `_open()` left `_client` naming a corpse while `will` reported the
  new value.
- **round 3 (the deadlock)** — after a failed reopen, `setWill` takes `if (live == null)
  return`, the branch that MEANS "not connected yet, `connect()` will carry it". Nothing
  calls `connect()` again. A registrar retrying promotion arcs between `primary_search` and a
  promotion it can never complete — deaf, indefinitely.

The fourth is the one that matters: **the fix for it cannot be written in the current
encoding**, because the branch it needs to take a different path in is the branch that cannot
tell which state it is in.

## Proposed shape

Replace the nullable field with a sealed type that names the states, and make the illegal
reads unrepresentable rather than guarded.

```dart
sealed class ConnectionPhase {
  const ConnectionPhase();
}

/// No socket has ever been opened. A will set here is simply recorded.
final class Unopened extends ConnectionPhase { const Unopened(); }

/// A socket exists. `client.connectionStatus` distinguishes live from
/// auto-reconnecting — that distinction belongs to mqtt_client and is not
/// duplicated here.
final class Open extends ConnectionPhase {
  const Open(this.client);
  final MqttServerClient client;
}

/// A socket WAS open and an attempt to rebuild it failed. Carries the failure
/// so a caller can report the real cause instead of inventing one, and the will
/// that was in flight so a retry knows what it was trying to arm.
final class Broken extends ConnectionPhase {
  const Broken(this.cause, this.intendedWill);
  final Object cause;
  final LastWill? intendedWill;
}

/// disconnect() ran. Terminal. Nothing reopens this.
final class Closed extends ConnectionPhase { const Closed(); }
```

The three rules that follow, each of which is a defect the rounds found:

1. **`setWill` on `Broken` REOPENS**; on `Unopened` it records; on `Closed` it refuses. Today
   all three are `return`. This is the deadlock, closed by construction rather than by a
   fifth guard.
2. **Publishing is legal only on `Open` + `connected`.** `Unopened` and `Broken` throw a
   `StateError` naming the phase (a caller error); `Closed` throws naming that it is
   terminal. An auto-reconnecting `Open` returns false — not an error, and the one case that
   must stay quiet.
3. **`disconnect()` moves to `Closed` and is idempotent.** No path leaves a torn-down client
   reachable, because `Closed` carries no client to reach.

## What this is NOT

- **Not a reconnection policy.** `autoReconnect` stays mqtt_client's job; `Open` deliberately
  does not duplicate `connectionStatus`. This models only what OUR code needs to branch on.
- **Not a `MessageBus` interface change.** The phase is internal to `AikoClient`. `FakeBus`
  keeps its own simpler model — though note that three separate defects in this PR were hidden
  by `FakeBus` being kinder than the real API, so whatever it models must be checked against
  these rules rather than against convenience.
- **Not the boot-topic design.** That is a wire change and Andy's to choose. This is entirely
  ours and needs nobody's agreement.

## Open questions the temper should hit

1. **Is `Broken` reachable in any way except a failed `setWill` reopen?** If not, is a whole
   phase justified for one transition, or does `setWill` owe a return value instead?
2. **Does `Broken` → `Open` need a bound?** A registrar retrying every 2 seconds against a
   dead broker reconnects forever. Today that is an accidental deadlock; under this design it
   becomes an intentional retry loop, which may be worse — a loud failure beats a quiet one.
3. **Should `Closed` really be terminal?** The controllers are closed, so reuse is already
   impossible — but encoding it as terminal makes that a decision rather than a consequence,
   and a caller that wants a fresh bus must construct one. Is that the contract we want?
4. **24 call sites.** Is a sealed phase the smallest change that fixes the deadlock, or is it
   the most satisfying one? The falsifier: name the cheapest change that closes round 3's
   defect WITHOUT reintroducing rounds 1-2, and price it honestly against this.

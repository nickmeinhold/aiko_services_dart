# The socket is a handle; the intent is the state

> **Status: PROPOSED, untempered.** Replacement for
> `transport-connection-lifecycle.md`, which was struck on 2026-09-11 and
> **DISSOLVED** at two families (see `TEMPER.md`). That document may not be
> re-cast; this one is written against its constraint set and must take its own
> strike.
>
> **Scope of the claim.** This closes the four transport defects PR #24's
> cage-match found, and it removes the self-demotion oscillator that made the
> transport fix unshippable on its own. It does **not** give the boot topic an
> owner. Faces 1 and 2 of `notes/boot-topic-lifecycle.md` survive this design
> untouched and are still Andy's to choose.

## The defect, restated once

`AikoClient` encodes its whole connection lifecycle as `_client == null`, and at
least five distinct situations share that encoding. Four review rounds produced
four patches; the fourth patch created the third round's worst finding. The
diagnosis survived the dead design's temper — every family accepted it — so it
is not re-argued here.

What the dead design got wrong was the *remedy*: it named the five situations as
a sealed `ConnectionPhase` and migrated 24 call sites to it, while still exposing
a nullable client getter. Tesla's verdict is the one to carry forward: **a sealed
type with a nullable escape hatch is the old encoding in a new robe.** Renaming
the branch does not make the branch unwritable.

## The move

Carnot's DISSOLVE named the decomposition, and Carnot's abstract crux named why
it works. They are the same sentence at two scales:

> *"Until we distinguish INTENT, MECHANISM, OBSERVATION and AUTHORITY, every
> local success is at risk of being a polished measurement of the wrong thing."*

So give each of the four its own construct, and let the language enforce the
separation instead of a convention:

| | lives as | who writes it |
|---|---|---|
| **INTENT** | two private `bool`s — `_started`, `_closed` — and `_will` | the three lifecycle methods, nobody else |
| **MECHANISM** | `MqttServerClient? _client`, meaning *only* "the current socket handle" | `_open` and the teardowns |
| **OBSERVATION** | a sealed `_Reach`, returned by one getter | every caller, exhaustively |
| **AUTHORITY** | "is this announcement ours?" — an identity check on the boot topic | the election (§6) |

The dead design sealed the **state**. This seals the **observation**. That is the
whole difference, and it is what makes the collapsed branch unwritable: no caller
is ever handed a nullable client, so no caller can write `if (c == null) return`.
The compiler requires four arms, and the four arms have four different right
answers.

## 1. The state

```dart
MqttServerClient? _client;   // the CURRENT socket handle, or none
bool _started = false;       // a caller asked for a connection and has not retired the bus
bool _closed  = false;       // disconnect() has run; this bus is retired, permanently
LastWill? _will;             // durable intent — the ONE home (Tesla, Carnot)
```

Four reachable combinations, and they are named rather than inferred:

| `_closed` | `_started` | `_client` | reach | what a caller should do |
|---|---|---|---|---|
| F | F | null | `NotStarted` | call `connect()` |
| F | T | non-null | `Attached` | publish (`autoReconnect` owns any dip; `transportUp` reports it) |
| F | T | null | `Detached` | **we want a socket and have none** — retry, or fail transiently |
| T | — | null | `Retired` | nothing, ever |

`Detached` is the state the old encoding could not express, and every one of the
four defects lived in the gap between it and `NotStarted`.

**`Detached` is not a parking state** (Tesla's constraint 2). Nothing sits in it
waiting for a privileged writer to notice. It is a fact about the world — intent
without mechanism — and the recovery driver is the caller's *existing* retry,
outside this class. The registrar already re-attempts promotion on a 2-second
timer; the transport's job is to stop lying to it, not to grow a scheduler.

## 2. The observation

```dart
sealed class _Reach {
  // A const super is required for the const leaf constructors below; without
  // it all three fail `const_constructor_with_non_const_super`. Found by
  // compiling this sketch rather than by reading it.
  const _Reach();
}

final class _Attached extends _Reach {
  _Attached(this.client);
  final MqttServerClient client;
}
final class _Detached   extends _Reach { const _Detached(); }
final class _NotStarted extends _Reach { const _NotStarted(); }
final class _Retired    extends _Reach { const _Retired(); }

_Reach get _reach {
  if (_closed) return const _Retired();
  final client = _client;
  if (client != null) return _Attached(client);
  return _started ? const _Detached() : const _NotStarted();
}
```

One reader of `_client` for decision purposes, in the whole class. Cost against
the dead design: no 24-site migration, no public type, no wire change.

## 3. Publish legality

`send` and `clearRetained` need a socket. Their four answers are not the same
answer, which is the point the panel agreed on under every verdict:

```dart
MqttServerClient _publishable(String what) => switch (_reach) {
  _Attached(:final client) => client,
  _Detached()   => throw TransportUnavailable(what),   // TRANSIENT — retry is legal
  _NotStarted() => throw StateError('cannot $what: connect() has not run'),
  _Retired()    => throw StateError('cannot $what: this bus is retired'),
};
```

`TransportUnavailable` is new and it is load-bearing. "Caller error" and
"the wire is down right now" have been indistinguishable, so an election could
not tell a bug from weather. A caller may retry the first; retrying the second
is a loop.

## 4. `setWill` — the round-3 fix, structurally

```dart
Future<void> setWill(LastWill? next) async {
  switch (_reach) {
    case _Retired():
      throw StateError('cannot set a will: this bus is retired');
    case _NotStarted():
      _will = next;                 // connect() will carry it; no socket to pay for
    case _Detached():
      _will = next;                 // record FIRST: intent survives failed mechanism
      await _open();                // ONE attempt. Throws; _will stays recorded.
    case _Attached(:final client):
      if (next == _will) return;    // already armed AND the socket carries it
      _will = next;
      await _reopen(client);        // tear down, then ONE _open()
  }
}
```

The old short-circuit was `if (next == _will && _client != null) return` — a
value comparison standing in for a liveness check, guarded by a second
condition someone had to remember. Here the short-circuit lives *inside the
`Attached` arm*, so it cannot fire while detached. Round 3's deadlock is not
guarded against; it is unrepresentable.

Note `_will` is written **before** the socket work and never rolled back. A will
is intent. Intent does not become false because a socket failed to carry it.
That is Tesla's and Carnot's "one home for the will", and it is also what makes
the `Detached` retry correct: the next attempt already knows what to arm.

## 5. Retry, and an honest bound

**The transport performs at most one `connect()` per caller call. It never
loops, never schedules, never backs off.** Two reconnection policies exist, and
they are disjoint *by construction*:

- `autoReconnect`, inside a live client, owns **Attached** — and only Attached,
  because it needs a client object to run in.
- the caller's own timer owns **Detached** — and only Detached, because there is
  no client object to run in.

Their preconditions partition on `_client == null`, so they can never both be
running. That is the answer to Kelvin's and Tesla's independently-found CONNECT
storm: not a backoff constant, a disjointness argument. The dead design had
*three* policies on one socket precisely because `setWill` could reopen from a
state where a client still existed.

**What this does NOT fix, measured from the package source rather than reasoned:**
`mqtt_client 10.11.11`'s own auto-reconnect is unbounded and backoff-free.
`MqttConnectionHandlerBase.autoReconnect` ends with
`clientEventBus!.fire(AutoReconnect())` on failure — it re-arms itself forever,
paced only by `maxConnectionAttempts` (default **3**, `MqttClientConstants:32`)
connect attempts per round. That is true of the code shipped today and is
independent of this design. It is named here, not fixed here, and filed.

## 6. Reopen is an election input — the coupling this design may not deny

The dead design asserted independence from the boot topic. Tesla proved it false
and that finding is non-negotiable: `setWill` on a detached bus reopens, a reopen
re-subscribes, and the broker redelivers **our own retained
`(primary found <us>)`** — face 3 of the boot-topic note. In `primary_search`
that stands us down to `secondary`. Ship §4 alone and the deadlock fix becomes a
self-demotion oscillator: the bug moves from #24 into #25 and mTLS.

So the two ship together. `registrar_process.dart:274` currently discards the
announced path:

```dart
['found', final String _, _, _] => RegistrarAnnouncement.found,
```

The path is already on the wire (`registrar_process.dart:358` publishes
`topicPath.path`). Read it, and refuse our own residue:

```dart
['found', final String path, _, _] =>
    path == topicPath.path ? null : RegistrarAnnouncement.found,
```

**Why this cannot suppress real news.** A service path carries namespace, host,
pid and service id. A *different* incarnation of this process — a restart, a
replacement container — has a different pid and therefore a different path. The
only announcement that can ever equal our own path is one we published
ourselves. There is no case in which acting on your own announcement as though
it were somebody else's is correct.

**What it does not close, said plainly.** `(primary absent)` is arity-1 and
carries no path, so face 2 — a demoted peer's tombstone landing on a healthy
`found` — has nothing to compare and is untouched. Face 1, a clean stop leaving
a corpse, is untouched. Both need a wire change (a session token, or a lease)
and both remain Andy's to choose. This design's claim is exactly: *the transport
rule no longer creates an oscillator.* It is not: *the boot topic now has an
owner.*

## 7. `_open` owns its client on every failure path

Not from the panel — from reading `mqtt_client`'s source while checking the
storm claim.

Today `_open()` builds a client, awaits `connect()`, and only then assigns
`_client`, listens to updates and restores subscriptions. If `connect()` throws,
the orphan is inert: `initialConnectionComplete` is set at the very end of
`SynchronousMqttServerConnectionHandler.internalConnect` and a thrown
`NoConnectionException` never reaches it, so `internalDisconnect` will not fire
auto-reconnect. That half is safe.

But if `connect()` **succeeds** and any line after it throws, today's code drops
a fully-live client — `autoReconnect = true`, `initialConnectionComplete = true`,
holding our will and **our client id** — on the floor with no reference to it.
The next `_open()` connects with the same client id, the broker evicts the
orphan's session, and the orphan's auto-reconnect fights back. Two client objects
flapping over one MQTT identity, invisible to every log we own.

```dart
await client.connect();
try {
  _client = client;
  _updates = client.updates?.listen(_onData);
  for (final topic in _subscriptions) {
    client.subscribe(topic, MqttQos.atMostOnce);
  }
} on Object {
  _client = null;
  client.onDisconnected = null;
  client.onAutoReconnect = null;
  client.onAutoReconnected = null;
  client.disconnect();
  rethrow;                      // leaves us Detached, which is true
}
```

## 8. Identity at close

Tesla's constraint 6, answered rather than left to whichever a test happens to do.

**A retired bus is never reopened.** `connect()` on `Retired` throws.
`disconnect()` is idempotent. A caller that wants a connection again constructs a
new `AikoClient`, which mints a new client id.

The reason is not tidiness. The client id is the island's notion of *who we are*
— it is what the broker fences sessions on, and what our own will is attached to.
Silently re-minting an identity inside a method called `connect()` would make a
process's wire identity depend on which method a caller happened to reach for.
If reuse is ever wanted, it gets a named constructor and a written reason.

A failed *first* `connect()` sets `_started = true` before `_open()`, so it lands
in `Detached`, not `NotStarted`. This is deliberate and Carnot did not say it: a
failed first connect and a failed reopen have the same truth (we want a socket,
we have none) and the same recovery, so they get the same state. It follows that
`send` after a failed `connect()` reports transient rather than caller error —
which is the honest answer, because the caller did ask.

## 9. `FakeBus` implements the same rules

Tesla's constraint 5, and Maxwell's. Three defects in PR #24 hid behind a fake
kinder than the API; a contract the double does not implement is a
production-only prophet.

`FakeBus` gets the same four reaches, the same two exception types, the same
short-circuit-only-while-attached rule, and the same refusal of `connect()`
after `disconnect()`. Its `failSetWillWith` must land it in **Detached**
(`started`, no socket) rather than today's ambiguous `connected = false`, because
Detached is what the real client produces.

## 10. Done-test

Two arms, both required:

1. A fresh `/design-temper` strike on this document scores **0 DISSOLVE** from
   at least three seated families (≤1 RECAST tolerable).
2. A **must-fail arm** drives the round-3 scenario end to end — a failed reopen,
   then a promotion retry — and is watched going **red** with §4's `Detached`
   arm removed, and green with it. A test that has never been seen red is not
   evidence.

### Already verified, at design time

The central mechanism — *"no caller can write the collapsed branch, because the
compiler requires four arms"* — is a claim about a compiler, so it was compiled
rather than argued. Dart 3.13.0, both arms run:

- **Null arm.** The §2 and §3 sketches analyze clean (`No issues found!`) and
  run. This caught a real defect in the first draft: `sealed class _Reach {}`
  gives the three `const` leaf constructors a non-const super, and all three
  fail to compile. The published sketch is the fixed one.
- **Must-fail arm.** Deleting the single `_Detached()` arm from the `_publishable`
  switch must be rejected, and is:
  `error - The type '_Reach' isn't exhaustively matched by the switch cases
  since it doesn't match the pattern '_Detached()' - non_exhaustive_switch_expression`.

The analyzer passing is equally consistent with the analyzer not checking. The
second arm is what separates those, and it names the missing state by name.

## Appendix: what was considered and not taken

**Two MQTT connections per registrar** (Maxwell's alternative, recorded in
`TEMPER.md`): a process-level connection carrying the process will, a
primary-level one opened on promotion, so no will ever mutates. It dissolves the
same coupling from the other side and the wire is unchanged. Not taken: it is
subsumed — once intent is separated from mechanism you do not need a second
socket to get it — and it costs two client ids and a further divergence from the
reference. It is the next thing to price if this design leaks.

**A backoff constant in the transport.** Not taken: §5's disjointness is the
argument, and a backoff here would be a second scheduler competing with the
caller's. The unbounded retry that genuinely exists is the package's, one layer
down, and a constant in our class would not reach it.

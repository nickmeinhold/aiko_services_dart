# The socket is a handle; the intent is the state

> **Status: RECAST round 3, untempered at this revision.** Round 1: 0 DISSOLVE / 4
> RECAST. Round 2: 0 DISSOLVE / 4 RECAST, with six of eight round-1 folds audited
> REAL by the adversaries. All sixteen findings are folded here.
> Record: `TEMPER-intent-and-mechanism.md`.
>
> Replaces `transport-connection-lifecycle.md`, DISSOLVED 2026-09-11 at two
> families. That document may not be re-cast.
>
> **Scope of the claim.** This closes the four transport defects PR #24's
> cage-match found and removes the self-demotion oscillator that made the
> transport fix unshippable alone. It does **not** give the boot topic an owner:
> faces 1 and 2 of `notes/boot-topic-lifecycle.md` survive untouched and remain
> Andy's. It does **not** bound the island's promotion-retry cadence (§5b).

## The defect — and the reason it took three rounds

`AikoClient` encodes its connection lifecycle as `_client == null`, and at least
five distinct situations share that encoding. Every family accepted that
diagnosis under every verdict.

What took three rounds is that **each fix committed the same error one level in**:

| round | what was compared | what it was standing in for | found by |
|---|---|---|---|
| cage-match r3 | `_client == null` | is this bus reachable | Tesla |
| temper r1 | `_client != null` | is the socket *connected* | Tesla |
| temper r2 | `_will == next` | does the socket *carry* this will | Tesla + Carnot |

Every one is **a locally-held value used as a proxy for a state of the wire** —
and the third was committed inside the design written to cure the first two, with
a comment beside it stating the correct rule in prose.

So this revision is governed by a rule rather than a patch:

> **A MECHANISM fact is recorded by the MECHANISM, at the moment it becomes
> true. It is never inferred from INTENT.**

`Dipped` (§1) obeys it by reading `connectionStatus` instead of inferring from
`_client`. `_willOnWire` (§1) obeys it by recording, inside `_open()`, which will
the CONNECT packet actually carried. Both are the same move, and between them
they close the class rather than its third instance.

## The frame

Carnot's crux, which is the same sentence at two scales:

> *"Until we distinguish INTENT, MECHANISM, OBSERVATION and AUTHORITY, every
> local success is at risk of being a polished measurement of the wrong thing."*

| | lives as | who writes it |
|---|---|---|
| **INTENT** | `_will`, `_started`, `_closed` | the lifecycle methods, nobody else |
| **MECHANISM** | `_client`, `_willOnWire`, `connectionStatus` | `_open` and the teardowns, at the moment each becomes true |
| **OBSERVATION** | a sealed `Reach`, one getter, no payload | every caller, exhaustively |
| **AUTHORITY** | "is this announcement ours?" | the election (§6) |

Round 2 put will-on-wire on the INTENT side. That single misfiling is the whole
of finding 3 — which is the frame catching its own violation, and the reason to
keep it.

## 0. Lifecycle ordering — and why `disconnect` deliberately escapes the gate

Round 2 proposed a single-entrant gate **plus** an epoch and asserted both were
needed without naming what bypassed the gate. Maxwell and Carnot both struck the
circularity; Maxwell added that the gate turned a race into a **hang** (a
`disconnect()` during `_reopen` waits out up to 3 connect attempts on a dead
broker) and, worse, made §10's own must-fail arm **unreachable** — the
interleaving it tests cannot be constructed under a total gate.

One decision resolves all three:

1. **`connect()` and `setWill()` are serialised** by one `Future` chain. They are
   the two methods that may *mint* a socket, and two mints on one client id is
   §7's flap.
2. **`disconnect()` does NOT queue.** It sets `_closed = true` and increments
   `_epoch` **synchronously, before any await**, then tears down. A teardown
   whose whole purpose is promptness must never wait on a connect to a broker
   that is not answering.
3. **The epoch is therefore load-bearing, not a charm.** `_open()` captures
   `_epoch` before its first await and may install its candidate only if the
   epoch is unchanged and `_closed` is still false. `disconnect` is *exactly* the
   bypass Carnot asked us to name, and it is a bypass on purpose.

**The boundary is about WRITERS of `_client`, not readers of it** — round 3's
first draft said *"nothing else reaches `_client`"*, which Carnot and Maxwell both
falsified from code in the same bundle. Stated correctly:

- **Only** gated `connect`/`setWill` and bypassing `disconnect` may CHANGE
  `_client`, `_willOnWire` or `_closed`. That list is exhaustive.
- Everyone else — `send`, `clearRetained`, `subscribe`, `unsubscribe`, `_onData`
  — may only OBSERVE, through `reach`, and use the handle through `_live` inside
  an arm `reach` has already proved.
- `_reportTransport` publishes to a broadcast controller, which delivers
  asynchronously, so a listener that calls `setWill` *queues* on the gate rather
  than re-entering it. Its downstream is election work, which is exactly why that
  asynchrony is load-bearing rather than incidental (Tesla flagged the stack:
  `unawaited(_apply(...))` can reach `await setWill` on the same trace).

## 1. The state

```dart
// INTENT
LastWill? _will;             // durable; the ONE home for what we WANT announced
bool _started = false;       // a caller asked for a connection and has not retired the bus
bool _closed  = false;       // disconnect() has run; retired, permanently

// MECHANISM
MqttServerClient? _client;   // the CURRENT socket handle, or none
LastWill? _willOnWire;       // the will the CURRENT socket's CONNECT actually carried
int _epoch = 0;              // fences an _open() whose await outlived its world
```

`_willOnWire` is written **only** inside `_open()`, immediately after a
successful `connect()`, from the value that was put in the CONNECT packet. It is
cleared wherever `_client` is cleared. It is never written by `setWill`.

Five reachable situations:

| `_closed` | `_started` | `_client` | `state` | reach | what a caller should do |
|---|---|---|---|---|---|
| F | F | null | — | `NotStarted` | call `connect()` |
| F | T | non-null | `connected` | `Attached` | publish |
| F | T | non-null | ≠ `connected` | `Dipped` | wait — `autoReconnect` owns this |
| F | T | null | — | `Detached` | retry — you own this |
| T | — | null | — | `Retired` | nothing, ever |

**Who takes `Dipped` to `Detached`: nobody, and that is a property with
evidence, not an oversight** (Tesla asked; §5b establishes it).
`MqttClient.internalDisconnect` fires an auto-reconnect whenever
`autoReconnect && initialConnectionComplete`, and `autoReconnect()` re-arms
itself on failure forever (`mqtt_connection_handler_base.dart:172-174`). Both
conditions hold for any client that ever connected. So a `Dipped` bus stays
`Dipped` until the broker returns — which is the **wanted** behaviour for an
island process, and is why §5b argues against Kelvin's ceiling. The cost is that
`Dipped` has exactly one door, and it is the broker's.

## 2. The observation — and why it carries nothing

```dart
sealed class Reach {
  // A const super: without it the const leaves below all fail
  // `const_constructor_with_non_const_super`. Found by compiling, not reading.
  const Reach();
}

final class Attached   extends Reach { const Attached(); }
final class Dipped     extends Reach { const Dipped(); }
final class Detached   extends Reach { const Detached(); }
final class NotStarted extends Reach { const NotStarted(); }
final class Retired    extends Reach { const Retired(); }
```

Round 2 made `Reach` public so the compiler could hold `FakeBus` to the same
contract, and then gave `Attached` an `MqttServerClient` field — **a type the
fake cannot construct.** Round 1's §9 promised parity the fake did not have;
round 2 promised parity the type system forbade. Three families struck it.

So the observation carries **no payload**. The exhaustiveness force is in the
arms, not the cargo, and `AikoClient` fetches its handle separately:

```dart
Reach get reach {
  if (_closed) return const Retired();
  final client = _client;
  if (client == null) return _started ? const Detached() : const NotStarted();
  return client.connectionStatus?.state == MqttConnectionState.connected
      ? const Attached()
      : const Dipped();
}

/// Only legal in an `Attached` arm; `reach` is what proves that.
MqttServerClient get _live => _client!;
```

The `!` is confined to one line whose precondition the sealed switch has already
established — and it is the *only* one in the class, which is checkable.

## 3. Publish legality, and who catches what

```dart
void send(...) {
  switch (reach) {
    case Attached():   _live.publishMessage(...);
    case Dipped():     throw TransportUnavailable('send to $topic');
    case Detached():   throw TransportUnavailable('send to $topic');
    case NotStarted(): throw StateError('cannot send: connect() has not run');
    case Retired():    throw StateError('cannot send: this bus is retired');
  }
}
```

`Dipped` and `Detached` agree here and diverge in §4 — which is the test for
whether a state is a state or merely a row.

**Every mechanism-open failure is wrapped** (Tesla, Carnot: §3's election arm was
dead in front of `on Object`). `_open`, `_reopen`, `connect` and `setWill` wrap
raw connect failures, stale-epoch disposals and post-connect setup failures in
`TransportUnavailable`. A caller-error stays a `StateError`. There is no third
shape.

**Call-site disposition:**

| call site | after | why |
|---|---|---|
| `registrar_process` `AnnouncePrimary` (`:350-370`) | `on TransportUnavailable` arm **before** `on Object` | this is the election instrument §3 claims to be |
| `registrar_process` `ClearBootTopic` (`:347`) | uncaught, documented | outside the try; a transient here fails the promotion at the next step regardless |
| `services_cache`, `ec_consumer`, `bus_process` | uncaught, type changed only | both crashed before; the new type is better news in the stack trace |

## 3b. `subscribe` / `unsubscribe` — the two members that were still `_client?.`

Found by running this revision's own rule back over this revision. `send`,
`clearRetained`, `setWill`, `connect` and `disconnect` are specified across all
five reaches; `subscribe` and `unsubscribe` were left as
`_client?.subscribe(topic, …)` — **the null-guard-whose-subject-is-never-nulled
that was round 1 of the original cage-match**, still in the file. On `Dipped`
that call lands on a client whose socket is down, returns normally, and leaves
the caller believing it is subscribed: a local call standing in for a broker
subscription, which is the same sentence as `_will == next` standing in for
the-socket-carries-it.

The split follows from what each half is:

```dart
void subscribe(String topic) {
  if (reach case Retired()) {
    throw StateError('cannot subscribe: this bus is retired');
  }
  _subscriptions.add(topic);          // INTENT — the set IS the memory, and
                                      // _open restores it in every reach
  if (reach case Attached()) {
    _live.subscribe(topic, MqttQos.atMostOnce);   // MECHANISM — only when live
  }
}
```

On `Dipped` the record alone is correct: `resubscribeOnAutoReconnect` carries it
when the link returns. On `Detached` and `NotStarted` the next `_open()` carries
it. Neither throws, because a subscription is an interest rather than an act —
and that sentence is one the design owes rather than a behaviour to infer.
`unsubscribe` mirrors it.

## 4. `setWill` — the short-circuit tests the wire, not the wish

```dart
Future<void> setWill(LastWill? next) => _gate(() async {
  switch (reach) {
    case Retired():
      throw StateError('cannot set a will: this bus is retired');
    case NotStarted():
      _will = next;                       // connect() will carry it
    case Detached():
      _will = next;                       // intent survives failed mechanism
      await _open();                      // ONE attempt; wraps and throws
    case Dipped():
      _will = next;                       // recorded; _willOnWire stays A, truthfully
      throw TransportUnavailable('set a will while the link is down');
    case Attached():
      _will = next;                       // intent lands FIRST, even when the
                                          // socket already carries it (Tesla, r3)
      if (next == _willOnWire) return;    // the SOCKET carries it — the real conjunct
      await _reopen(_live);
  }
});
```

**The one-token change that closes the class.** Round 2 tested `next == _will`
and its own comment said *"already armed AND the socket carries it"*. Those are
different propositions, and the package makes them diverge:
`MqttConnectionHandlerBase.autoReconnect` calls
`connect(server!, port!, connectionMessage)` with the **stored** CONNECT message
(saved at `:104`, *"Save the parameters for auto reconnect"*). So after
dip → `setWill(B)` → auto-reconnect, the socket carries **A** while `_will` is
**B**, and `next == _will` short-circuits a promotion that must reopen. The
registrar then believes it holds a retained `(primary absent)` while the broker
holds the per-process `(absent)` — and on an unclean death the island is never
told its primary is gone.

Testing `_willOnWire` cannot diverge, because only `_open()` writes it and only
from what it actually put in the packet. **Tesla's sequel is now a must-fail arm**
(§10): dip → `setWill(B)` refuses → auto-reconnect → `setWill(B)` must *reopen*,
not return.

`_will` is written before the socket work and never rolled back. Intent does not
become false because a socket failed to carry it.

## 4b. `connect()` and `_reopen()` — every writer of `_client`

```dart
Future<void> connect() => _gate(() async {
  switch (reach) {
    case Retired():
      throw StateError('cannot connect: this bus is retired — construct a new one');
    case Attached():
      return;                             // you already have what you asked for
    case Dipped():
      throw TransportUnavailable('connect');   // the wire is DOWN; saying otherwise
                                               // is the lying rung
    case NotStarted():
    case Detached():
      _started = true;                    // BEFORE _open: a failed first connect
      await _open();                      // is Detached, not NotStarted (§8)
  }
});

Future<void> _reopen(MqttServerClient live) async {
  _retire(live);                          // disarm, disconnect, clear mechanism
  await _open();                          // ONE attempt; wraps and throws
}

void _retire(MqttServerClient live) {
  live.autoReconnect = false;             // disarm BEFORE disconnect, or the package
  live.onDisconnected = null;             // may already have queued reconnect work
  live.onAutoReconnect = null;
  live.onAutoReconnected = null;
  live.disconnect();
  _client = null;
  _willOnWire = null;                     // cleared WITH the socket it describes
}
```

Round 2 had `connect()` on `Dipped` return void over a down wire *and then call
`_reportTransport(up: true)`*. Three families struck it; Carnot caught the second
half. This repo already has a name for that — the lying rung, the failure
`transportUp` exists to prevent. `send` was made honest about `Dipped` in the
same revision that left `connect()` dishonest about it.

**`_reportTransport` is now callback-driven only.** No lifecycle method asserts
`up: true`; the link's own `onConnected` / `onAutoReconnected` do. A caller's
intent is not evidence about a wire (Carnot).

`_retire` is shared by `_reopen` and `disconnect`, which is what stops the two
teardown paths drifting apart — the asymmetry between them was two of PR #24's
four defects.

## 5. Retry

### 5a. What is provable

**`AikoClient` performs at most one `connect()` per caller call. It never loops,
never schedules, never backs off.** Two reconnection policies exist and are
disjoint *by construction*:

- `autoReconnect`, inside a live client, owns `Dipped` — and only `Dipped`.
- the caller owns `Detached` — and only `Detached`.

`Attached` needs neither. The partition is a property of the sketch, because §4
and §4b are now written for all five reaches: no caller-driven path mints a
socket while `autoReconnect` holds one. Round 1 asserted this while `setWill` on
a dipped client still reopened; round 2 wrote the `Dipped` arms that made it true.

### 5b. What is open, with a named owner

**This design does not bound the island's promotion-retry cadence.** Traced
against the real code: `AnnouncePrimary` (`registrar_process.dart:350`) calls
`setWill`, catches, runs `onPrimaryFailed()` → at role `primary`,
`_enterPrimarySearch()` → `_epoch++` and a fresh `StartSearchTimer` → fires →
re-promotes → `setWill` again. Against a down broker: one `_open()` — up to 3
CONNECTs — **every ~2 seconds, per registrar, indefinitely, no backoff.**

> **OWNER:** the election's `StartSearchTimer`, not the transport.
> **COST:** ~0.5 CONNECT/s per registrar while a broker is down. Noise at island
> scale; not noise at fleet scale, and not noise if a broker is *up and
> rejecting* — which is what `feat/mtls-transport-spike` introduces.
> **MITIGATION, not taken here:** backoff belongs on the election timer, where
> the period is chosen. Changing it is an election-semantics decision wanting
> Andy's parity view. Filed.

**Where this disagrees with Kelvin, deliberately** — and he conceded it in round
2 (*"my own proposal is refuted with a superior argument"*). Bounding
`maxConnectionAttempts` conflates a **ceiling** with **backoff**. Unbounded
reconnection is what we want: a broker restarting overnight must not need a
human. A lower ceiling shortens each round and makes the storm *faster*.
Disabling `autoReconnect` moves resubscription onto us, and
`resubscribeOnAutoReconnect` is load-bearing for the election ladder. What
Kelvin's finding correctly establishes is that naming is not containment — so the
containment taken is narrow and real: `_retire` disarms `autoReconnect` on any
client we abandon, before disconnecting it.

### 5c. Who leaves each state

| reach | exit | owner | covered? |
|---|---|---|---|
| `NotStarted` | `connect()` | caller | yes |
| `Detached` | `connect()` or `setWill()` | caller | registrar yes; observer / `ECConsumer` / `ServicesCache` **NO** |
| `Dipped` | the broker returning | `autoReconnect` | yes, unboundedly (§1) |
| `Retired` | — | — | terminal by design (§8) |

The third row is the one round 2 omitted (Tesla). The second row's gap is real
and named: an observer that lands in `Detached` on a first `connect()` against a
down broker stays there. Kelvin's bounded-internal-retry is the candidate fix and
is **not** adopted here, because it would be a second scheduler racing §5b's. It
is priced and filed so the choice is made once, for both.

## 6. Reopen is an election input — and the residue filter needs two conjuncts

`setWill` on a detached bus reopens, a reopen re-subscribes, and the broker
redelivers our own retained `(primary found <us>)` — face 3 of the boot-topic
note. In `primary_search` that stands us down to `secondary`, deaf.

```dart
['found', final String path, _, final String started] =>
    (path == topicPath.path && started == timeStarted)
        ? RegistrarAnnouncement.ownResidue
        : RegistrarAnnouncement.found,
```

**Round 3's first attempt was a fourth instance of the class, and all three
adversaries said so.** It filtered on `path == ours && _hasAnnounced` — and
`_hasAnnounced` is a **local boolean proxying a state of the wire**: it records
that we called `send`, at QoS 0 with no ack, and is then read as though it meant
*we are the author of the retained value*. Carnot's scenario, which does not drop
the conjunct: B announces, stands down, keeps the flag; A — sharing B's path —
announces; B reads A's `found` as its own residue and both promote. Kelvin's
verdict was the same, and his prescription was the right instinct — *"the fix is
not another layer of local state; it is a measurement of the wire itself."*

**The measurement already exists.** `timeStarted` is parameter 3 of the
announcement, published at `registrar_process.dart:360` and discarded on read at
`:274`. It is microsecond-resolution (`:206`). So `(path, timeStarted)` is an
**incarnation identity**, carried on the wire today, requiring no new message, no
wire change, and no cooperation from anyone:

- an announcement matching both fields was published **by this incarnation**, and
  by nothing else — a colliding path with a different start time is a different
  process, and a same-microsecond collision on the same path is not reachable;
- a process that never announced has never published its pair, so nothing can
  match it. **`_hasAnnounced` is therefore deleted, not fixed.** Subtract the
  coupling rather than guard the window.

| | today | round 3 first attempt (`_hasAnnounced`) | round 3 final (`timeStarted`) |
|---|---|---|---|
| the oscillator (our own residue after a demotion) | stands us down — **the bug** | closed | closed |
| two registrars share a path, neither announced | one primary | one primary | one primary |
| two registrars share a path, both announced | one primary | **both promote, silently** | one primary |

**RP-1 is no longer load-bearing for safety in any arm**, and unlike the previous
revision's version of that sentence, this one is true for the both-announced case
too. RP-1 survives only as a note: a shared topic path is a confusing island.

`ownResidue` is its own case rather than `null` beside malformed, so the filter's
success is observable instead of silent.

**What this does not close, plainly.** `(primary absent)` is arity-1 and carries
no path, so face 2 has nothing to compare. Face 1 is untouched. Both need a wire
change — a session token, or a lease — and both remain Andy's. The claim is
exactly: *the transport rule no longer creates an oscillator, and does not create
a dual primary either.*

## 7. `_open` owns its client, and installs it last

Found by reading `mqtt_client` while checking the storm claim; both Carnot and
Tesla accepted it as a real missing failure mode.

A thrown `connect()` leaves an inert orphan: `initialConnectionComplete` is set at
the very end of `internalConnect` and a thrown `NoConnectionException` never
reaches it. But a **successful** `connect()` followed by any later throw drops a
fully-live client — `autoReconnect` armed, holding our will and our client id —
unreferenced. The next `_open()` connects with the same id, the broker evicts the
orphan, and the orphan fights back: two objects flapping over one MQTT identity.

```dart
Future<void> _open() async {
  final epoch = _epoch;                   // §0 rule 3: captured before any await
  final will = _will;                     // the value that will go IN the packet
  final client = _build(will);
  try {
    await client.connect();
    if (epoch != _epoch || _closed) {
      throw TransportUnavailable('open: the bus was retired while connecting');
    }
    final updates = client.updates?.listen(_onData);
    for (final topic in _subscriptions) {
      client.subscribe(topic, MqttQos.atMostOnce);
    }
    // INSTALLED LAST, once the candidate is fully armed. Carnot: assigning
    // _client before the listener and the subscriptions are up leaves a window
    // in which the bus reports Attached with nothing listening — and the gate
    // serialises lifecycle callers, not arbitrary publishers.
    _updates = updates;
    _client = client;
    _willOnWire = will;                   // MECHANISM records what MECHANISM did
  } on Object catch (error) {
    _retire(client);                      // same teardown as everywhere else
    throw error is TransportUnavailable
        ? error
        : TransportUnavailable('open: $error');
  }
}
```

`_willOnWire = will` sits on the line after `_client = client` and describes the
same socket, so the two cannot disagree. `_retire` clears both.

## 8. Identity at close

**A retired bus is never reopened.** `connect()` on `Retired` throws.
`disconnect()` is idempotent, sets `_closed` and bumps `_epoch` synchronously
before any await (§0 rule 2), then `_retire`s any client and closes the streams.

The client id is the island's notion of *who we are* — what the broker fences
sessions on and what our will is attached to. Silently re-minting an identity
inside a method called `connect()` would make a process's wire identity depend on
which method a caller reached for. A caller wanting a connection again constructs
a new `AikoClient`. If reuse is ever wanted it gets a named constructor and a
written reason.

A failed *first* `connect()` lands in `Detached`, not `NotStarted`: a failed first
connect and a failed reopen have the same truth and the same recovery. So `send`
after a failed `connect()` reports transient rather than caller error — honest,
since the caller did ask.

## 9. `FakeBus` — the sketch, because two rounds of prose failed

Round 1 promised parity the fake did not have. Round 2 promised parity the type
system forbade. Three families struck it both times, and Tesla's line stands:
*"A fold that describes a fix is not a fix."* So here is the double, not a
shopping list. With `Reach` carrying no payload (§2) it is expressible:

```dart
class FakeBus implements MessageBus {
  bool _started = false, _closed = false;
  bool _socket = false;                   // MECHANISM: is there a handle
  bool _wireUp = true;                    // MECHANISM: is that handle carrying
  LastWill? _will, _willOnWire;

  /// Default is NotStarted. Round 1's fake started LIVE, which is what let a
  /// promotion keep publishing at a torn-down bus.
  FakeBus();

  /// The fourteen ECConsumer/registrar tests that are handed a connected wire.
  /// A NAMED constructor with a written reason, the same medicine §8 prescribes
  /// for identity reuse — the shortcut is visible in the test, not baked in.
  FakeBus.alreadyAttached() { _started = true; _socket = true; }

  @override
  Reach get reach {
    if (_closed) return const Retired();
    if (!_socket) return _started ? const Detached() : const NotStarted();
    return _wireUp ? const Attached() : const Dipped();
  }

  /// Drops or restores the link as a broker outage would — and now actually
  /// produces `Dipped`, so `send` refuses. Round 2's version flipped a stream
  /// and left `connected == true`: more forgiving than the API on the exact row
  /// the design had just minted.
  Future<void> setTransport({required bool up}) async { _wireUp = up; ... }

  @override
  Future<void> setWill(LastWill? next) async {
    switch (reach) {
      case Retired():    throw StateError('...');
      case NotStarted(): _will = next;
      case Detached():   _will = next; await _openOrFail();
      case Dipped():     _will = next; throw TransportUnavailable('...');
      case Attached():
        if (next == _willOnWire) return;
        _will = next;
        await _openOrFail();              // failSetWillWith lands in DETACHED
    }
  }
}
```

`failSetWillWith` leaves `_started = true, _socket = false` with `_will` already
written — which is `Detached`, what the real client produces.

**The enforcement is a shared contract suite**, not this sketch: one
parameterised test taking a `MessageBus` factory and asserting every §3/§4/§4b/§8
refusal, run against both implementations. Both switch over the same public
`Reach`, so both take the exhaustiveness error when a state is added. That is the
fold; the prose is not.

## 10. Done-test

1. A fresh strike scores **0 DISSOLVE** from ≥3 seated families and **≤1 RECAST**.
2. **Must-fail arms**, each watched red before green, each run **through the
   contract suite so it exercises the fake too** — round 3 hid in the fake:
   - the cage-match round-3 deadlock: failed reopen, then a promotion retry;
   - **Tesla's sequel**: dip → `setWill(B)` refuses → auto-reconnect → `setWill(B)`
     must **reopen**, not return. This is the arm round 2 could not see, and it is
     the one that proves `_willOnWire` rather than `_will`;
   - **`disconnect()` during `setWill`'s reopen** — reachable *because* §0 rule 2
     lets `disconnect` bypass the gate. Must not leave `_closed` with a live
     client, and must not block on the connect;
   - **a post-`connect()` subscription failure** — must leave `Detached`, no
     orphan, and throw `TransportUnavailable`;
   - **a promotion while `Dipped`** — must refuse, not reopen;
   - **two registrars sharing a topic path, NEITHER having announced** — exactly
     one primary;
   - **two registrars sharing a topic path, BOTH having announced** — exactly one
     primary. This is the arm round 3's first attempt failed, and it is the one
     that proves `timeStarted` rather than a local flag. It must be watched red
     with the `started == timeStarted` conjunct removed;
   - **`subscribe` while `Dipped`** — records the interest, does not call the
     broker, and the topic is live again after the link returns (§3b).

### Verified at design time

The mechanism is a claim about a compiler, so it was compiled. Dart 3.13.0:

- **Null arm.** The §2/§3 sketches analyze clean and run. This caught a real
  defect in the first draft: a bare `sealed class Reach {}` gives the `const`
  leaves a non-const super and none of them compile.
- **Must-fail arms.** Deleting the `Dipped()` arm is rejected by name in **both**
  forms the design uses — `non_exhaustive_switch_expression` and
  `non_exhaustive_switch_statement`. The statement form matters on its own: §3,
  §4, §4b and §9 are statements.
- **The fifth situation is observable**, checked before being relied on:
  `MqttClient.connectionStatus` is public and `MqttConnectionState` has a distinct
  `connected` member (`mqtt_client.dart:211`,
  `mqtt_client_connection_state.dart:25-36`).
- **The will-divergence is real**, checked before being accepted: auto-reconnect
  calls `connect(server!, port!, connectionMessage)` with the stored packet
  (`mqtt_connection_handler_base.dart:104`, `:156`).
- **§9's fold is DEMONSTRATED, not promised** — the failure mode of rounds 1 and
  2. A scratch harness declares the payload-free `Reach`, implements it in *both*
  an `AikoClient` holding a real client handle and a `FakeBus` holding none, and
  runs one contract function over both. Both compile, both inhabit `Attached()`,
  and both refuse `send` identically on a fresh bus. That is the claim §9 makes,
  executed rather than asserted.
- **§10 arm 2 (Tesla's sequel) has a RED/GREEN pair, at design time.** Driven
  through the fake: `Attached` with will A on the wire → dip → `setWill(B)`
  refuses → the wire returns carrying A (auto-reconnect's stored packet) →
  `setWill(B)`.
  - with round 3's `next == _willOnWire`: **`willOnWire = B`** — it reopened.
  - with round 2's `next == _will` restored: **`willOnWire = A`** — it
    short-circuited, and the socket is still armed with the old testament.

  The arm goes red for exactly the proposition it names, which is the difference
  between a test and a decoration. It was built before the implementation, so the
  implementation cannot be written to fit it.

An analyzer passing is equally consistent with an analyzer not checking; the
must-fail arms separate those, and name the missing state.

- **§6's incarnation filter has a red/green pair plus a positive control.**
  Carnot's exact scenario, built as a harness: two registrars sharing a topic
  path (RP-1 violated), different start times, **both having announced**, B
  reading A's retained `found`.
  - with `path && _hasAnnounced`: **2 primaries** — the regression, reproduced.
  - with `path && started == timeStarted`: **1 primary** — closed.

  And the positive control, because "1 primary" is also what a filter that never
  fires would produce: our own residue after a demotion is still classified
  `ownResidue` and still ignored. The filter fires where it must and not where it
  must not, which is two propositions and needed two arms.

## Appendix: considered and not taken

**Two MQTT connections per registrar** (recorded in `TEMPER.md`): a process-level
connection carrying the process will, a primary-level one opened on promotion, so
no will ever mutates and no socket is rebuilt under live subscriptions. Not
taken — once intent is separated from mechanism you do not need a second socket —
but it is **parked, not subsumed**, and Carnot raised it again in round 2 as the
thing that dissolves `_reopen`'s will-change-costs-an-outage entirely. If this
design leaks a fourth time, price it before shipping rather than after.

**A backoff constant inside `AikoClient`** — a second scheduler racing §5b's.

**Bounding `maxConnectionAttempts`** (Kelvin, round 1; conceded round 2) — a
ceiling is not backoff, and a lower one makes the storm faster.

**Invariant RP-1 as a safety mechanism** (rounds 1–2), and **`_hasAnnounced`**
(round 3, first attempt). Both superseded by reading `timeStarted` off the wire.
RP-1 was an unenforced invariant the design leaned on; `_hasAnnounced` was a
local boolean proxying authorship of a remote retained value — the fourth
instance of this document's own named class, caught by all three adversaries.
The replacement adds nothing: `(path, timeStarted)` is already in the payload.
Carnot's fold-back asked for an owner token in the message; the token was
already there.

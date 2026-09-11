# The socket is a handle; the intent is the state

> **Status: REVISION 4, round-6 folded. IMPLEMENTING.**
>
> **The round-6 delta was NOT struck again, and that is a recorded choice.**
> `_enterDetached()`, R1, R2 and R3 were folded in after round 6 and never went
> back through `/design-temper`. The call: **proceed to implementation and let
> `/cage-match` catch residuals.** Three reasons, none of them "we were tired".
> The delta is three small mechanisms authored *in response to* findings all four
> families already agreed on, so a seventh round would re-litigate a settled
> premise. A design temper strikes a sketch; a code cage-match strikes bytes, and
> every remaining question here — does the lock actually hold across the await,
> does the door actually get walked — is a question about bytes. And Carnot's own
> crux says it outright: *review documents name closure; probes and tests own
> closure.* Striking the sketch again would be the one move that cannot close
> anything.
>
> Round 6 struck revision 4's first draft: **0 DISSOLVE, 4 RECAST**, all four
> deletions audited **SAFE by every family**, and three findings — instance 6
> (`Detached` proxying a control loop), a false one-opener rule, and a supervisor
> that could race itself. All three are folded here.
>
> Rounds 1–4 hardened a five-state model on a premise nobody had chosen:
> `autoReconnect = true`, so the MQTT package owns socket recovery. Round 5 put
> that premise up for demolition and **all four families voted to remove it**
> (`TEMPER-intent-and-mechanism.md`, round 5). This revision is the result.
>
> **It is SHORTER than revision 3, and that is the point.** Four reaches instead
> of five; `_willOnWire` gone; §3b's two-list reconcile gone; §5's disjointness
> argument gone; two competing retry loops collapsed into one. Nothing was added
> to get here except a supervisor the design already owed.
>
> **Scope of the claim.** This closes the four transport defects PR #24's
> cage-match found and removes the self-demotion oscillator. It does **not** give
> the boot topic an owner — faces 1 and 2 of `notes/boot-topic-lifecycle.md`
> remain Andy's. It does **not** close the same-`timeStarted` residual (§6).

## What changed, and why the change deletes rather than adds

The port kept `autoReconnect = true` because it is the `mqtt_client` default and
because the reference uses paho's `loop_start()`, which reconnects. That looked
like parity. **It was the opposite**, and the fact that settles it was measured
rather than argued:

> **paho backs off. `mqtt_client` does not.** `_reconnect_wait` doubles from
> `_reconnect_min_delay = 1` to `_reconnect_max_delay = 120` seconds, by default
> (`paho/mqtt/client.py:3593-3605`, `:576-577`). The Dart package's
> `autoReconnect` re-fires `AutoReconnect()` with no wait at all
> (`mqtt_connection_handler_base.dart:172-174`).

So the status quo diverged from the reference on the one axis where the reference
has a considered answer and the package offers no knob. And the **parity licence
is the reference's INVARIANT, not its mechanism** — `_on_connect` fires on every
paho connect including reconnects and calls
`_subscribe_if_connected(self.topics_subscribe)` (`mqtt.py:160`), replaying the
**application's** list. One install site, the app's memory, every connect. Dart's
`autoReconnect` cannot carry that invariant, because it replays the *package's*
maps. Matching a mechanism that is not paho's, while breaking the invariant that
is, is costume.

**A note on what does NOT license this.** The reference's own TODO at `mqtt.py:37`
says reconnection is unfinished. That is **not** grounds for us to finish it. A
port that unilaterally completes an upstream TODO turns a difference into a fix
we invented rather than a finding we can report. The licence is fact 7, not the
TODO.

## The frame

Carnot's crux, unchanged and now applied with one fewer moving part:

| | lives as | who writes it |
|---|---|---|
| **INTENT** | `_will`, `_started`, `_closed` | the lifecycle methods |
| **MECHANISM** | `_client`, `connectionStatus` | `_open` and the teardowns |
| **OBSERVATION** | a sealed, payload-free `Reach` | every caller, exhaustively |
| **AUTHORITY** | "is this announcement ours?" | the election (§6) |
| **POLICY** | `_retry`, `_backoff` | the supervisor (§5) — **and it models US, not the wire** |

The fifth row is new and it carries round 5's sharpest warning. Tesla and Carnot
both refused the claim that Option B *deletes* the defect class:

> *"Reconnecting must not mean 'we have a socket that might secretly become
> valid.' It should mean 'we have no client handle; we have a desired connection
> and a scheduled attempt.' That is an owned control state, not a wire-state
> proxy."* — Carnot
>
> *"Keep it a model of us."* — Tesla

What Option B removes is the **ungovernable** form of the class: a handle held
while recovery runs in a process we cannot pace, cancel, or observe. Supervisor
state is still local state — it is safe only because it describes our own policy,
which cannot diverge from itself.

## 1. The state — four reaches

```dart
// INTENT
LastWill? _will;
bool _started = false;
bool _closed  = false;

// MECHANISM
MqttServerClient? _client;
int _epoch = 0;

// POLICY (§5)
Timer? _retry;
Duration _backoff = _backoffMin;
```

| `_closed` | `_started` | usable socket? | reach | what a caller should do |
|---|---|---|---|---|
| F | F | — | `NotStarted` | call `connect()` |
| F | T | yes | `Attached` | publish |
| F | T | no | `Detached` | **nothing — recovery is already armed (§5 R2)** |
| T | — | — | `Retired` | nothing, ever |

**`Dipped` is gone.** It existed to name a live handle whose wire was down while
the package repaired it behind us. With no package recovery, a non-connected
handle is not a state — it is a corpse we have not swept yet, and the sweep is a
cleanup detail, not something callers must model.

**`_willOnWire` is gone too**, and this is the satisfying part: it existed only
because auto-reconnect could replay a stale stored CONNECT and put a will on the
wire we did not choose. Under Option B **`_open()` is the only thing that ever
connects**, and it always builds its CONNECT from `_will`. So on `Attached` the
socket necessarily carries `_will`, and `next == _will` is sound again. *The fix
for defect instance 3 is unnecessary once its cause is removed.*

## 2. The observation

```dart
sealed class Reach {
  const Reach();     // a const super, or the const leaves below fail to compile
}
final class Attached   extends Reach { const Attached(); }
final class Detached   extends Reach { const Detached(); }
final class NotStarted extends Reach { const NotStarted(); }
final class Retired    extends Reach { const Retired(); }

Reach get reach {
  if (_closed) return const Retired();
  final client = _client;
  // BOTH conditions. `_client != null` alone is defect instance 2 — a handle
  // standing in for a wire. The status is the mechanism's own report.
  if (client != null &&
      client.connectionStatus?.state == MqttConnectionState.connected) {
    return const Attached();
  }
  return _started ? const Detached() : const NotStarted();
}

/// Only legal inside an `Attached` arm; `reach` is what proves that. The one
/// `!` in this class.
MqttServerClient get _live => _client!;
```

Payload-free, so `FakeBus` can inhabit every arm including `Attached` — round 2
gave `Attached` an `MqttServerClient` field and made parity a type error.

**The window Tesla named remains, and it is named rather than modelled.** Between
a socket dying and the mechanism noticing, `reach` reports `Attached` and a
publish fails at the broker. `connectionStatus` narrows it — it flips before our
callback runs — but cannot close it, and no client can: detection is bounded by
`keepAlivePeriod` (60s, so 90s worst case for a half-open TCP). **This is a
property of MQTT, not of either option**, and a `send` that fails there is
wrapped as transient like any other (§3).

## 3. Publish legality

```dart
void send(String topic, String command, Object? params, {bool retain = false}) {
  switch (reach) {
    case Attached():   _live.publishMessage(/* … */);
    case Detached():   throw TransportUnavailable('send to $topic');   // TRANSIENT
    case NotStarted(): throw StateError('cannot send: connect() has not run');
    case Retired():    throw StateError('cannot send: this bus is retired');
  }
}
```

Every **mechanism-open** failure is wrapped in `TransportUnavailable` — raw
connect failures, stale-epoch disposals, post-connect setup failures. A caller
error stays a `StateError`. There is no third shape, so the election can tell a
bug from weather.

| call site | after | why |
|---|---|---|
| `registrar_process` `AnnouncePrimary` (`:350-370`) | `on TransportUnavailable` **before** `on Object` | the election instrument this type exists for |
| `registrar_process` the boot-topic clear | **inside** `AnnouncePrimary`'s try | see the finding below — this row used to say "uncaught, outside the try" and it was wrong |
| `services_cache`, `ec_consumer`, `bus_process` | uncaught, type changed only | all crashed before; the new type reads better in a stack trace |

### FINDING AGAINST THIS REVISION, found by implementing it

Revision 4 left the boot-topic clear outside the promotion's try and justified it
in one sentence: *"a transient fails the promotion one step later anyway."*
**There is no step later.** The throw propagates out of `_perform`, out of
`_drainPending`'s loop, and out of `_apply` — which every caller invokes through
`unawaited`. So `AnnouncePrimary` never runs, nothing calls `onPrimaryFailed`,
and the only handler that can stand the role back down is never reached.

Measured on a `Detached` bus rather than argued: **`role = primary`,
`actions = []`.** A registrar that believes it is primary having published
nothing — no clear, no will, no announcement — with an unhandled async error
beside it. That is a state declared true by something other than the mechanism
that makes it true, which is the class this document is named for, arriving in
the one place six rounds never looked: the *caller* of the transport, not the
transport.

**The fix is the split, not the guard.** Catching inside a `ClearBootTopic` arm
does not work — `AnnouncePrimary` is still sitting in `_pending` and the drain
announces anyway, so the cheap fix needs an unwind step, which is the tell that
the boundary is in the wrong place. `ClearBootTopic` had exactly one emitter and
no independent meaning; it is now folded into `AnnouncePrimary`, so the
transaction boundary and the catch boundary are the same boundary and a future
fourth step cannot be added outside the handler by accident. The type is deleted,
which keeps this revision's own template: remove the cause rather than guard it.

The ordering assertion did not weaken. `registrar_election_test`'s version could
only see two effects' indices; `registrar_process_test`'s "takes the retained
will BEFORE it announces" reads clear → will → announce off one ordered list
across kinds, and was always the stronger of the two.

## 3b. `subscribe` / `unsubscribe` — one list again

Revision 3 discovered these were still `_client?.subscribe(…)`; its fix then
became defect instance 5, because `resubscribeOnAutoReconnect` replays the
**package's** maps and not ours — two lists, and a topic recorded while the link
was down reached neither.

**Option B deletes the second list.** `_open()` is the only thing that ever
connects, so it is the only subscription install site, and it walks
`_subscriptions`. That is the reference's invariant exactly (`mqtt.py:160`).

```dart
void subscribe(String topic) {
  if (reach case Retired()) throw StateError('cannot subscribe: bus is retired');
  _subscriptions.add(topic);                                    // INTENT
  if (reach case Attached()) _live.subscribe(topic, MqttQos.atMostOnce);
}
```

On `Detached` or `NotStarted` the record alone is correct **and this time that
sentence is true**, because the supervisor's next `_open()` walks the set. No
reconcile, no second install site, no `_packageHeld`.

`resubscribeOnAutoReconnect` is set **`false`** explicitly. With `autoReconnect`
off nothing fires `Resubscribe` today, so it is already moot — stated anyway,
because a default nobody chose is exactly what this revision exists to correct.

`subscribe` on a down link must not call the client at all: `MqttClient.subscribe`
throws `ConnectionException` when not connected (`mqtt_client.dart:448-452`).
Recording without calling is the reason the guard is on `Attached` and not on
`_client != null`.

## 4. `setWill`

```dart
Future<void> setWill(LastWill? next) => _gate(() async {
  switch (reach) {
    case Retired():
      throw StateError('cannot set a will: this bus is retired');
    case NotStarted():
      _will = next;                      // connect() will carry it
    case Detached():
      _will = next;                      // the supervisor's next _open carries it
      throw TransportUnavailable('set a will while the link is down');
    case Attached():
      if (next == _will) return;         // the socket was built from _will (§1)
      _will = next;
      await _reopen(_live);
  }
});
```

The `Detached` arm **records and refuses; it does not open.** That is §5's single
rule and the reason two retry loops became one.

`_will` is written before any socket work and never rolled back: intent does not
become false because a socket failed to carry it.

## 4b. `connect()` and `_reopen()`

```dart
Future<void> connect() => _gate(() async {
  switch (reach) {
    case Retired():
      throw StateError('cannot connect: retired — construct a new AikoClient');
    case Attached():
      return;                            // you already have what you asked for
    case Detached():
      throw TransportUnavailable('connect');   // the supervisor owns this
    case NotStarted():
      _started = true;                   // BEFORE _open: a failed first connect
      await _open();                     // is Detached, not NotStarted (§8)
  }
});

Future<void> _reopen(MqttServerClient live) async {
  _discard(live);
  _client = null;
  await _open();                         // ONE attempt; _open's catch arms the
                                         // supervisor through §5's single door
}

/// Disarm and drop ONE client object. Deliberately does NOT touch `_client` or
/// arm recovery — those are `_enterDetached`'s job (§5, R2), and keeping them
/// apart is what lets `_open` discard a failed *candidate* without pretending
/// the installed socket died.
void _discard(MqttServerClient client) {
  client.onDisconnected = null;          // disarm before disconnect, or our own
  client.onConnected = null;             // teardown reports as an island event
  client.disconnect();
}

void _onLinkLost() {                     // wired to onDisconnected
  final live = _client;
  if (live != null) _discard(live);
  _enterDetached();                      // the same single door
}
```

`connect()` on `Detached` **throws** rather than opening. Revision 3 had it open,
which under Option B would be a second opener racing the supervisor. It is the
same rule as `setWill`: **callers state intent; the supervisor performs.**

## 5. The supervisor — one loop, and it is ours

> **TWO RULES, both true as written. Revision 4's first draft printed one rule
> that was false, and all four families counted the call sites and caught it.**
>
> **R1 — ONE OPENER FUNCTION.** `_open()` is the only function that ever builds a
> socket. It has **three** call sites — the first `connect()`, `_reopen()` from a
> will change, and the supervisor — and it runs **only inside the gate**, so at
> most one open is ever in flight. `_reopen` retires before it opens, so no two
> sockets coexist.
>
> **R2 — ONE RECOVERY OWNER.** `Detached` **implies** an armed recovery, always,
> and that is enforced at the single door below rather than asserted in a table.

Revision 4's first draft claimed *"`_open()` is called from exactly two places"*
and it has three. That false sentence is what hid the next finding from its own
author: **counting stopped because the rule said the count was done.**

### Instance 6, and the door that kills it

Tesla, round 6: ***"A comment is not a timer."*** The first draft's §5c table said
`Detached`'s owner was *"the supervisor, always"* and §8 said a failed first
`connect()` *"starts the supervisor"* — and **no code did either**.
`_scheduleReconnect` was reachable only from `onDisconnected`, which `_retire`
disarms before its own teardowns.

That is **the sixth instance of this design's named class**, and Tesla located it
exactly: `reach == Detached` is `_started && !connected`, which is **not**
`_retry != null`. *A local value proxying a control loop.*

**And nothing rescues it, measured rather than hoped**
(`spike/autoreconnect-off/probe_failed_connect.dart`): `onDisconnected` **does not
fire on a failed `connect()`** — the attempt throws `SocketException`, the state
goes to `faulted`, and the callback stays silent. Round 5's probe measured the
drop of a *live* socket and revision 4 leaned it on an adjacent proposition. So
after a failed first connect or a failed will-change reopen, **nothing anywhere
arms recovery** and the bus is deaf forever: the round-3 deadlock, with a timer
that was never armed in place of `_will == next`.

The fix is the same move that killed the other five — **make the state a
recording of what the mechanism did**, through one door:

```dart
static const _backoffMin = Duration(seconds: 1);
static const _backoffMax = Duration(seconds: 120);

Timer? _retry;
bool _attempting = false;
Duration _backoff = _backoffMin;

/// Recovery is OWNED while a timer is pending or an attempt is in flight.
/// Both halves matter — see R3 below.
bool get _recoveryOwned => _retry != null || _attempting;

/// THE SINGLE DOOR INTO `Detached`. Every path that loses or fails to build a
/// socket comes through here, so `Detached` cannot exist without an owner.
void _enterDetached() {
  _client = null;
  _reportTransport(up: false);          // every path, not just the callback
  if (!_closed && _started) _scheduleReconnect();
}

void _scheduleReconnect() {
  if (_closed || _recoveryOwned) return;
  _retry = Timer(_backoff, () async {
    // R3: take the in-flight lock BEFORE releasing the timer slot. Clearing
    // `_retry` first releases the one-owner invariant for the whole await.
    _attempting = true;
    _retry = null;
    try {
      await _gate(_open);
      _backoff = _backoffMin;           // reset ONLY on success
    } on Object {
      final doubled = _backoff * 2;
      _backoff = doubled > _backoffMax ? _backoffMax : doubled;
    } finally {
      _attempting = false;
      // Still down? Own it again. Covers both "the open failed" and "the open
      // succeeded and the link dropped during it".
      if (!_closed && reach is Detached) _scheduleReconnect();
    }
  });
}
```

> **R3 — THE OWNER LOCK COVERS THE WHOLE ATTEMPT.** Kelvin found this alone and
> it is his sharpest work in six rounds: the first draft nulled `_retry` at
> timer-fire, *before* `await _gate(_open)`. An `onDisconnected` arriving during
> that await finds `_retry == null`, calls `_scheduleReconnect` again, and
> **the supervisor races itself** — N loops for N flaps during one attempt.
> *"The system returns to two racing loops, only this time we wrote both."*
> `_attempting` holds the lock across the await; `_recoveryOwned` is the
> conjunction.

**The generation question is closed by the gate and the epoch, not by a third
mechanism** (Carnot asked for a proof rather than an assertion). A fired timer
awaiting the gate cannot be overtaken by `_reopen` or `connect`, because those
are gated too and the gate is FIFO. It can be overtaken by `disconnect`, which
bypasses the gate — and that is exactly what `_epoch` fences: `_open` captures
the epoch before its first await and refuses to install if it moved.

**Subscription snapshot semantics** (Carnot asked; Tesla answered): `_open()`
walks `_subscriptions` and installs `_client` with **no `await` in that span**, so
an ungated `subscribe` cannot interleave. A topic added while the connect is in
flight lands in the set before the walk and is therefore included in *this*
connect. That is determinate, and it is stated rather than inferred.

**1s doubling to 120s, because that is the number the reference already chose**
(`paho/mqtt/client.py:576-577`). Not a number we invented. Verified to produce
`[1, 2, 4, 8, 16, 32, 64, 120, 120, 120]`.

> **R3 verified, red and green.** A harness fires the timer, holds `_open` in
> flight, and delivers two `onDisconnected` events during the await:
> **with `_attempting` → 1 recovery loop; without it → 2.** Kelvin's race is real
> and reproduces on demand.
>
> **One correction to the finding, on evidence:** Kelvin predicted *"N, where N is
> the number of link-flaps during a single `_open` attempt."* It is bounded at
> **2**, not N — the second spurious `_scheduleReconnect` finds `_retry` occupied
> by the first. The defect is real; the multiplicity is not.

**No jitter, deliberately.** N registrars reconnecting in lockstep after a broker
restart is a real thundering herd, and paho does not jitter either. Adding it
would be a silent timing divergence — so it is **filed as an upstream finding for
Andy** (claude-tasks #7) rather than taken.

**IDLE LIVENESS — the cost round 5 named.** paho's background thread restores
reachability *with no application poll*, and caller-driven recovery is not that.
The timer is the answer, and R2 is what makes it total: revision 4's first draft
had the timer and reached it from one of three entrances.

### What one opener buys, beyond correctness

Revision 3's §5b named an open storm: `AnnouncePrimary` fails → `onPrimaryFailed`
→ `_enterPrimarySearch` → a fresh 2-second timer → re-promote → `setWill` →
another `_open()`. Against a down broker that was **one `_open()` (up to 3
CONNECTs) every ~2 seconds, per registrar, forever.**

Under §5's rule, `setWill` on `Detached` **refuses without opening**. So the
election's 2-second retry now produces a cheap local throw and **no CONNECT at
all**; the only CONNECTs on the wire are the supervisor's, on a 1→120s backoff.
**The storm is not mitigated, it is structurally absent** — and claude-tasks #6,
which exists to decide whether the election timer needs backoff, is answered:
it does not, because it no longer reaches the broker.

### Exit table

| reach | exit | owner |
|---|---|---|
| `NotStarted` | `connect()` | caller |
| `Attached` | link loss → `onDisconnected` | mechanism |
| `Detached` | the supervisor's next successful `_open()` | **the supervisor — enforced by §5 R2's single door, not asserted here** |
| `Retired` | — | terminal (§8) |

Every row has an owner. Revision 3's uncovered-observer gap is closed: an
observer that lands in `Detached` on a first failed `connect()` is recovered by
the same timer as everything else, without knowing it exists.

## 6. Reopen is an election input

Unchanged from revision 3 and independent of this fork. `registrar_process.dart`
discards the announced path and timestamp at `:274`; both are published at `:360`:

```dart
['found', final String path, _, final String started] =>
    (path == topicPath.path && started == timeStarted)
        ? RegistrarAnnouncement.ownResidue
        : RegistrarAnnouncement.found,
```

> **PROPERTY RI-1.** Own-residue detection is exact whenever two registrars
> sharing a `topicPath` have distinct `timeStarted`. It is a **collision-resistant
> discriminator, not an authority token** — nothing in the broker, the session or
> a lease backs it (Carnot).
>
> **Resolution is per target, measured:** two consecutive
> `DateTime.now().microsecondsSinceEpoch` give `…702114`/`…702143` on the Dart VM
> and **`…496000`/`…496000` on dart2js** — millisecond-granular, ~1000× weaker.
> claude-tasks **#3240** and **#3497** both put this code in a browser.
>
> **Residual:** same path AND same `timeStarted` is still a silent dual primary.
> The real fix is a minted per-incarnation token in the `found` payload, which
> changes the announcement's arity and is therefore **Andy's** (claude-tasks #7).

`ownResidue` is its own case, not `null` beside malformed, so the filter's success
is observable. Faces 1 and 2 of the boot-topic note are untouched.

**This fork does interact with the election in one way worth naming (Tesla):
political time.** A 120s backoff means an island can be without a primary for up
to two minutes. That is not new — paho's backoff reaches 120s too — but it is now
*ours*, and the will is not armed while `Detached`, because a will lives in a
CONNECT packet and there is no connection. During a long backoff a registrar is
indistinguishable from a dead one, which is honest and is what the island already
assumes.

## 7. `_open` owns its client, installs last, and is the only opener

```dart
Future<void> _open() async {
  final epoch = _epoch;                       // captured before any await
  final will = _will;
  final client = _build(will)                 // 3.1.1, startClean, keepAlive 60
    ..autoReconnect = false                   // THE CHANGE
    ..resubscribeOnAutoReconnect = false      // moot, stated anyway
    ..onDisconnected = _onLinkLost;           // the live signal, measured
  try {
    await client.connect();
    if (epoch != _epoch || _closed) {
      throw TransportUnavailable('open: the bus was retired while connecting');
    }
    final updates = client.updates?.listen(_onData);
    for (final topic in _subscriptions) {
      client.subscribe(topic, MqttQos.atMostOnce);   // the ONE install site
    }
    _updates = updates;
    _client = client;                         // installed LAST, fully armed
    _reportTransport(up: true);
  } on Object catch (error) {
    _discard(client);      // disarm + disconnect the candidate
    _enterDetached();      // R2: the single door — arms recovery, reports down
    throw error is TransportUnavailable
        ? error
        : TransportUnavailable('open: $error');
  }
}
```

`_client` is installed after the listener and the subscriptions, so the bus is
never externally `Attached` with nothing listening (Carnot, round 2).

The orphan hazard revision 3 found stays closed: a thrown `connect()` leaves an
inert client (`initialConnectionComplete` is never reached), and a post-connect
throw goes through `_discard` **and `_enterDetached`**. With `autoReconnect = false`
an abandoned client
cannot storm at all, which is strictly safer than the version that needed
disarming.

## 8. Identity at close

`disconnect()` does **not** queue behind the gate. It sets `_closed`, increments
`_epoch` and cancels `_retry` **synchronously before any await**, then retires any
client and closes the streams. A teardown whose purpose is promptness must never
wait on a connect to a broker that is not answering; the epoch is what fences an
`_open()` whose await outlives that decision.

The escape-route boundary is about **writers**: only gated `connect`/`setWill`,
the supervisor, and bypassing `disconnect` may change `_client`, `_closed` or
`_epoch`. Everyone else observes through `reach` and uses `_live` inside an arm
`reach` has proved.

**A retired bus is never reopened.** `connect()` on `Retired` throws; a caller
wanting a connection again constructs a new `AikoClient`, minting a new client id.
The client id is the island's notion of who we are and what our will is attached
to; re-minting it inside a method called `connect()` would make wire identity
depend on which method a caller reached for.

A failed *first* `connect()` lands in `Detached` **through §5's single door**, so
the supervisor is armed by the same code that made us `Detached` rather than by a
sentence in this paragraph. `send` then reports transient rather than caller
error — honest, since the caller did ask, and something is actually working on it.

This is the paragraph revision 4's first draft got wrong: it asserted the
supervisor started, and nothing started it. The measurement that settles it is
that the package does not rescue us either — `onDisconnected` never fires on a
failed `connect()` (`spike/autoreconnect-off/probe_failed_connect.dart`).

**Session semantics are unchanged by this fork** (Tesla asked). Our
`connectionMessage` has always carried `startClean()`, so a package auto-reconnect
opened a clean session too. Null-and-recreate is the same session behaviour with
a visible owner.

## 9. `FakeBus`

Four reaches, payload-free `Reach`, the same refusals, `connect()` after
`disconnect()` refused, default `NotStarted`, and `FakeBus.alreadyAttached()` as a
named constructor for the fourteen tests that are handed a live wire.

**The fake models the supervisor as a method, not a timer:** `setTransport(up:
false)` lands it in `Detached`; `restoreLink()` performs what `_open()` would —
walk `_subscriptions`, arm `_will`. A test drives recovery explicitly instead of
waiting on wall-clock backoff.

**The enforcement is one shared contract suite** run against both implementations,
asserting every §3/§4/§4b/§8 refusal. Both switch over the same public `Reach`, so
both take the exhaustiveness error when a state is added. Two revisions promised
parity in prose and were struck for it; the suite is the fold.

## 10. Done-test

1. A `/design-temper` strike on **this** revision scores 0 DISSOLVE from ≥3
   families and ≤1 RECAST.
2. **Must-fail arms**, each watched red before green, each run on `AikoClient`
   and through the contract suite:
   - **idle liveness** — broker dies with no caller activity, nothing calls
     `connect()`, and the bus is `Attached` again after the backoff. Red with the
     supervisor timer deleted. *This is the arm for the cost round 5 named.*
   - **one opener** — broker down, drive the election's promotion retry N times,
     and assert **zero** CONNECTs beyond the supervisor's schedule. Red if
     `setWill`/`connect` on `Detached` open instead of refusing.
   - **backoff shape** — successive failures at 1, 2, 4, 8… capped at 120s, and
     **reset to 1s only on success**.
   - **subscribe while `Detached`, then the link returns** — a message on that
     topic arrives. Red with `_open()`'s restore loop deleted.
   - **`disconnect()` during an in-flight `_open()`** — reachable because
     `disconnect` bypasses the gate; must not leave `_closed` with a live client,
     and must not block on the connect.
   - **first `connect()` against a dead broker, then bring the broker up, and
     NOBODY calls anything** — the bus must reach `Attached`. **Red without §5
     R2's door**, and blind in the first draft's §10, which only tested the
     callback path. This is instance 6's arm.
   - **`setWill` on `Attached` while the broker is down**, same idle assertion —
     the second entrance that never armed a timer.
   - **two `onDisconnected` events during one in-flight `_open()`** — exactly one
     recovery owner afterwards. Red without R3's `_attempting` lock (Kelvin).
   - **two registrars sharing `path` and `timeStarted`** — documents the §6
     residual rather than asserting it away.

### Verified at design time

- **`onDisconnected` is a live signal under `autoReconnect = false`** — the one
  premise Option B rests on that four rounds never checked. Measured both arms
  (`spike/autoreconnect-off/probe_disconnect_signal.dart`): fires 65ms after the
  broker stops, `onAutoReconnect` correctly silent, client stays down rather than
  resurrecting.
- **paho backs off 1→120s and `mqtt_client` does not** — read from both sources,
  and the number in §5 is taken from the reference rather than invented.
- **The four-reach model compiles and behaves**, re-run against THIS revision
  rather than cited from the five-reach one — evidence does not transfer across a
  type change. `NotStarted` → `record` / `start+open`; `Detached` →
  `record+refuse` / `refuse-transient`; and **a handle that exists but is not
  connected reads `Detached`, not `Attached`.**
- **Two must-fail arms, both red:**
  - deleting the `Detached()` arm is rejected by name —
    `non_exhaustive_switch_statement … doesn't match the pattern 'Detached()'`;
  - **reverting `reach` to `_client != null` alone makes the corpse handle read
    `Attached`** — defect instance 2, reproduced on demand. That is what proves
    the `connectionStatus` conjunct is load-bearing rather than decoration.
- **The backoff produces the reference's shape**, run rather than reasoned:
  `[1, 2, 4, 8, 16, 32, 64, 120, 120, 120]` seconds — identical to paho's
  `min(delay * 2, max)` from 1 to 120.
- **§6's filter has a red/green pair plus a positive control**: `_hasAnnounced`
  → 2 primaries, `(path, timeStarted)` → 1, and own-residue after a demotion is
  still ignored, so the green is not a filter that never fires.

## Appendix: considered and not taken

**`autoReconnect = true`** (revisions 1–3). Removed by unanimous round-5 verdict;
the full argument is in `TEMPER-intent-and-mechanism.md` round 5.

**Jitter on the backoff.** Correct for a thundering herd, absent from paho, and
therefore a silent timing divergence. Filed for Andy instead.

**Two MQTT connections per registrar.** Round 5 noted this fork *changes its
price* — if we own reconnection, the objection that it means two reconnect
policies on two sockets largely evaporates. Still not proposed; recorded a third
time as parked rather than subsumed.

**A ceiling on retries.** Unbounded reconnection is wanted: a broker restarting
overnight must not need a human. The defect was never the absence of a ceiling,
it was the absence of backoff — and §5 has it.

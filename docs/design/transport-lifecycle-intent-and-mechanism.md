# The socket is a handle; the intent is the state

> **Status: RECAST round 2, untempered at this revision.** Round 1 took
> **0 DISSOLVE / 4 RECAST** from four seated families
> (`TEMPER-intent-and-mechanism.md`). The candidate survived where its
> predecessor did not; it did not meet its own `≤1 RECAST` bar. All eight
> deduped findings are folded here. This revision must take its own strike.
>
> Replaces `transport-connection-lifecycle.md`, DISSOLVED 2026-09-11 at two
> families (`TEMPER.md`). That document may not be re-cast.
>
> **Scope of the claim.** This closes the four transport defects PR #24's
> cage-match found, and removes the self-demotion oscillator that made the
> transport fix unshippable alone. It does **not** give the boot topic an owner:
> faces 1 and 2 of `notes/boot-topic-lifecycle.md` survive untouched and remain
> Andy's. It does **not** bound the island's promotion-retry cadence (§5b).

## The defect, restated once

`AikoClient` encodes its whole connection lifecycle as `_client == null`, and at
least five distinct situations share that encoding. Four review rounds produced
four patches; the fourth created the third round's worst finding. Every family
accepted the diagnosis under every verdict, so it is not re-argued.

The dead design's remedy was wrong, not its diagnosis: it sealed the
connection's **state** as a public `ConnectionPhase`, migrated 24 call sites, and
still exposed a nullable client getter. Tesla's verdict carries forward — **a
sealed type with a nullable escape hatch is the old encoding in a new robe.**

## The move

Carnot's DISSOLVE named the decomposition and Carnot's abstract crux named why
it works; they are one sentence at two scales:

> *"Until we distinguish INTENT, MECHANISM, OBSERVATION and AUTHORITY, every
> local success is at risk of being a polished measurement of the wrong thing."*

Give each its own construct:

| | lives as | who writes it |
|---|---|---|
| **INTENT** | `_started`, `_closed`, `_will` | the lifecycle methods, under the §0 gate, nobody else |
| **MECHANISM** | `MqttServerClient? _client` — *only* "the current socket handle" | `_open` and the teardowns |
| **OBSERVATION** | a sealed `Reach`, returned by one getter | every caller, exhaustively |
| **AUTHORITY** | "is this announcement ours?" | the election (§6) |

The dead design sealed the **state**; this seals the **observation**. No caller
is ever handed a nullable client, so `if (c == null) return` cannot be typed —
the compiler demands every arm, and the arms have different right answers.

### What round 1 broke, and the repair that unified three findings

Tesla, alone: *the boot-topic note lists FIVE encodings and round 1's table had
FOUR.* Auto-reconnecting — handle present, wire down — was filed under `Attached`
with "publish" as its answer. So the observation **measured handle PRESENCE and
answered as though it measured REACHABILITY**: this document's own diagnosis,
committed by the document.

The repair is to name the fifth situation, and it is not merely a fifth row. It
is what makes §5's partition true and what keeps a promotion during a broker blip
off the reopen path. `MqttClientConnectionStatus.state` distinguishes `connected`
from `connecting` (`mqtt_client_connection_state.dart:25-36`), so the fifth
situation is **observable** — checked before relying on it.

## 0. The lifecycle gate (folded: Carnot, Kelvin, Tesla)

Round 1 had no happens-before rule, so the corpse-client class returned through
**time** rather than nullability: a `disconnect()` landing inside `setWill`'s
reopen window retires the bus while an in-flight `_open()` later installs a new
client, producing `_closed && _client != null` — which §1's own table calls
unreachable.

Two rules, both required:

1. **Single-entrant.** `connect`, `setWill` and `disconnect` run through one
   `Future` chain: each awaits the previous before it reads `_reach`. A lifecycle
   method never observes state another lifecycle method is mid-way through
   changing.
2. **Epoch-fenced install.** `_open()` captures `_epoch` before its first
   `await`, and may install `_client` only if `_epoch` is unchanged **and**
   `_closed` is still false. Otherwise it disposes of its candidate (§7's
   catch-and-kill) and returns without publishing it. `disconnect()` increments
   `_epoch` and sets `_closed` **before** any await.

Rule 2 is not redundant with rule 1: the gate serialises *our* callers, and the
epoch fences an `_open()` whose await resumed after the world changed underneath
it. `_closed = true` before awaiting is what makes teardown irreversible
(Carnot), and `client.disconnect()` is **awaited to the extent the package
allows** — it returns `void`, which is itself a dependency limitation and is
named here rather than papered over (Kelvin). The epoch is what makes correctness
not depend on that await existing.

## 1. The state

```dart
MqttServerClient? _client;   // the CURRENT socket handle, or none
bool _started = false;       // a caller asked for a connection and has not retired the bus
bool _closed  = false;       // disconnect() has run; retired, permanently
int  _epoch   = 0;           // fences an _open() whose await outlived its world
LastWill? _will;             // durable intent — the ONE home
```

Five reachable situations, named rather than inferred:

| `_closed` | `_started` | `_client` | `state` | reach | what a caller should do |
|---|---|---|---|---|---|
| F | F | null | — | `NotStarted` | call `connect()` |
| F | T | non-null | `connected` | `Attached` | publish |
| F | T | non-null | ≠ `connected` | **`Dipped`** | **wait — `autoReconnect` owns this** |
| F | T | null | — | `Detached` | **retry — you own this** |
| T | — | null | — | `Retired` | nothing, ever |

`Detached` is what the old encoding could not express, and every one of the four
defects lived in the gap between it and `NotStarted`. `Dipped` is what **round 1**
could not express, and Tesla's blip scenario lived in the gap between it and
`Attached`.

**`Detached` is not a parking state** (Tesla's constraint 2, granted in round 1
and unchanged). Nothing waits for a privileged writer; it is intent without
mechanism, and the transition out of it happens *in* `setWill`/`connect`, not in
a guard. Who drives those is §5c.

## 2. The observation

Lifted to `lib/src` and **public**, not private to `AikoClient`. Round 1 kept it
private, which is exactly why §9's parity promise was unenforceable — the
compiler that makes the collapsed branch unwritable could not see the test double
at all (Tesla, Carnot).

```dart
sealed class Reach {
  // A const super: without it the const leaves below all fail
  // `const_constructor_with_non_const_super`. Found by compiling, not reading.
  const Reach();
}

final class Attached extends Reach {
  const Attached(this.client);
  final MqttServerClient client;
}
final class Dipped     extends Reach { const Dipped(); }
final class Detached   extends Reach { const Detached(); }
final class NotStarted extends Reach { const NotStarted(); }
final class Retired    extends Reach { const Retired(); }

Reach get _reach {
  if (_closed) return const Retired();
  final client = _client;
  if (client == null) return _started ? const Detached() : const NotStarted();
  return client.connectionStatus?.state == MqttConnectionState.connected
      ? Attached(client)
      : const Dipped();
}
```

`Attached` carries an `MqttServerClient`, which the fake cannot produce. So the
**shared contract is the sealed `Reach` plus the refusal rules (§3, §4, §8)**,
and the fake implements a `Reach` whose `Attached` arm is unreachable for it —
see §9, where this is made a compiler-visible obligation rather than a promise.

One reader of `_client` for decision purposes in the whole class.

## 3. Publish legality — and who catches what

```dart
MqttServerClient _publishable(String what) => switch (_reach) {
  Attached(:final client) => client,
  Dipped()      => throw TransportUnavailable(what),   // TRANSIENT
  Detached()    => throw TransportUnavailable(what),   // TRANSIENT
  NotStarted()  => throw StateError('cannot $what: connect() has not run'),
  Retired()     => throw StateError('cannot $what: this bus is retired'),
};
```

`Dipped` and `Detached` give the same answer *here* and different answers in §4.
That is the point: a caller asking "can I publish?" needs **reachability**; a
caller asking "can I re-arm my will?" needs to know **who owns the recovery**.

**Call-site disposition** (folded: Maxwell, Tesla — round 1 minted the type
without naming a catcher):

| call site | today | after | why |
|---|---|---|---|
| `registrar_process` `AnnouncePrimary` (`:350-370`) | `on Object catch` | **matches `TransportUnavailable` explicitly**, then falls through to `on Object` | this is the election instrument §3 claims to be; without the explicit arm the new type is `send`-honesty only |
| `registrar_process` `ClearBootTopic` (`:347`) | uncaught | uncaught, **documented** | sits outside the try; a transient here fails the promotion at the next step anyway |
| `services_cache`, `ec_consumer`, `bus_process` | uncaught `StateError` | uncaught `TransportUnavailable` | no behaviour change — both crash; the type is better news for whoever reads the stack |

`_open` and `setWill` must also wrap raw connect failures in
`TransportUnavailable`, or the election never sees the type it is being asked to
match (Tesla).

## 4. `setWill` — round 3's fix, structurally

```dart
Future<void> setWill(LastWill? next) => _gate(() async {
  switch (_reach) {
    case Retired():
      throw StateError('cannot set a will: this bus is retired');
    case NotStarted():
      _will = next;                      // connect() will carry it
    case Detached():
      _will = next;                      // record FIRST: intent survives failed mechanism
      await _open();                     // ONE attempt. Throws; _will stays recorded.
    case Dipped():
      _will = next;                      // recorded, so the retry knows what to arm
      throw TransportUnavailable('set a will while the link is down');
    case Attached(:final client):
      if (next == _will) return;         // already armed AND the socket carries it
      _will = next;
      await _reopen(client);
  }
});
```

The `Dipped` arm is the round-2 repair and it is load-bearing. Round 1 would have
taken the `Attached` arm here and called `_reopen` on a client already
auto-reconnecting — *"the third policy §5 claimed to have abolished"* (Tesla).
Refusing instead is correct and cheap: the promotion fails, `onPrimaryFailed`
stands the registrar down, the search timer re-arms, and by the next attempt the
bus is either `Attached` or `Detached` — both of which have a right answer.

The short-circuit lives **inside** the `Attached` arm, so it cannot fire while
detached. Round 3's deadlock is not guarded against; it is unrepresentable.

`_will` is written before the socket work and never rolled back. A will is
intent, and intent does not become false because a socket failed to carry it.

## 4b. `connect()` and `_reopen()` — every writer of `_client`, in the sketch

Folded: Maxwell, Tesla, Carnot. Round 1 specified the exotic path and left the
ordinary one undefined — *"disjointness is true only if every writer of `_client`
is in the sketch; two of the three are not."*

```dart
Future<void> connect() => _gate(() async {
  switch (_reach) {
    case Retired():
      throw StateError('cannot connect: this bus is retired — construct a new one');
    case Attached():
      return;                            // already have what you asked for; pay nothing
    case Dipped():
      return;                            // autoReconnect owns it; a second socket
                                         // on one client id is the §7 storm
    case NotStarted():
    case Detached():
      _started = true;                   // set BEFORE _open: a failed first connect
      await _open();                     // is Detached, not NotStarted (§8)
  }
  _reportTransport(up: true);
});

Future<void> _reopen(MqttServerClient live) async {
  _reportTransport(up: false);           // the link DID go down; say so
  live.autoReconnect = false;            // disarm BEFORE disconnect, or the package
  live.onDisconnected = null;            // may already have queued reconnect work
  live.onAutoReconnect = null;           // (Carnot)
  live.onAutoReconnected = null;
  await _updates?.cancel();
  _updates = null;
  live.disconnect();
  _client = null;                        // leave nothing usable behind
  await _open();                         // ONE attempt; throws to the caller
}
```

`connect()` on `Attached`/`Dipped` returning rather than throwing is the same
rule §4 gives `setWill`: **a caller re-asserting a connection it already has must
not pay for a socket.** `Dipped` in particular must not mint a second client
under the same id — that is §7's flap, entered through the front door.

## 5. Retry — split into what is provable and what is open

Round 1 compressed these into one paragraph and three families called the
overclaim. They are separated here.

### 5a. What is provable

**`AikoClient` performs at most one `connect()` per caller call. It never loops,
never schedules, never backs off.** Two reconnection policies exist and they are
disjoint *by construction*:

- `autoReconnect`, inside a live client, owns **`Dipped`** — and only `Dipped`.
- the caller owns **`Detached`** — and only `Detached`.

`Attached` needs neither. Round 1 asserted this partition while `setWill` on a
dipped client still reopened and `connect()` was unwritten, which is precisely
why it was a hymn. With §4's `Dipped` arm refusing and §4b's `connect()`
returning, no caller-driven path can mint a socket while `autoReconnect` holds
one. **That** is the disjointness, and it is a property of the sketch rather than
a claim about it.

### 5b. What is open, with a named owner

**This design does not bound the island's promotion-retry cadence, and round 1
was wrong to imply it did.** Traced against the real code: `AnnouncePrimary`
(`registrar_process.dart:350`) calls `setWill`, catches, and runs
`onPrimaryFailed()` → at role `primary`, `_enterPrimarySearch()` → `_epoch++` and
a fresh `StartSearchTimer(searchTimeout)` → fires → re-promotes → `setWill`
again. Against a down broker: one `_open()` — up to 3 CONNECTs
(`MqttClientConstants.defaultMaxConnectionAttempts`) — **every ~2 seconds, per
registrar, indefinitely, with no backoff.**

§1 also *leans* on that loop to argue `Detached` is not a parking state. Both
things cannot be free. Stated as a tradeoff rather than resolved here:

> **OWNER:** the election's `StartSearchTimer`, not the transport.
> **COST:** an island whose broker is down sees ~0.5 CONNECT/s per registrar,
> forever. At the island scale Aiko runs at, that is noise; it is not noise at
> fleet scale, and it is not noise if a broker is *up and rejecting* — which is
> exactly what `feat/mtls-transport-spike` is about to introduce.
> **MITIGATION, not taken here:** backoff belongs on the election timer, where
> the period is chosen, and changing it is an election-semantics decision that
> wants Andy's parity view. Filed.

**Where this design disagrees with Kelvin, deliberately.** Kelvin's fold-back
asks us to *contain* the dependency's infinite loop — *"a transport that
knowingly permits a denial-of-service loop in its own dependency has not finished
its job"* — and proposes bounding `maxConnectionAttempts` or disabling
`autoReconnect`. That conflates two things. **Unbounded reconnection is what we
WANT**: an island process whose broker restarts overnight must come back without
a human. The defect is the absence of **backoff**, not the absence of a
**ceiling**. Bounding `maxConnectionAttempts` shortens each round and makes the
storm *faster*; disabling `autoReconnect` moves resubscription onto us, and
`resubscribeOnAutoReconnect` is load-bearing for the election ladder
(`mqtt_transport.dart:340`). What Kelvin's finding does correctly establish is
that naming is not containment — so the containment that *is* taken here is
narrow and real: **`_reopen` sets `autoReconnect = false` before disconnecting**,
so a client we are retiring cannot storm on our behalf (§4b, §7).

### 5c. Who leaves `Detached` (folded: Kelvin, Carnot)

`AikoClient` is general-purpose; round 1 exported recovery to every caller
forever on the strength of one caller's timer.

**The recovery triggers are `connect()` and `setWill()`, and nothing else.** A
caller that never invokes either will report `TransportUnavailable` from `send`
indefinitely, and that is a contract, not an accident:

| caller | trigger it already has | status |
|---|---|---|
| `RegistrarProcess` | `AnnouncePrimary` → `setWill`, re-armed by `StartSearchTimer` | covered |
| observer / `ECConsumer` / `ServicesCache` | **none** | **NOT covered** |

The second row is an open gap and is named as one. An observer that lands in
`Detached` — a first `connect()` against a down broker — stays there. Kelvin's
alternative, a bounded internal retry with backoff inside `AikoClient`, is the
candidate fix and is **not** adopted in this revision because it would be a
second scheduler racing §5b's; it is priced and filed so the choice is made once,
for both, rather than twice.

## 6. Reopen is an election input — mechanism, and an invariant that is not a law

The coupling this design may not deny. `setWill` on a detached bus reopens, a
reopen re-subscribes, and the broker redelivers our own retained
`(primary found <us>)` — face 3 of the boot-topic note. In `primary_search` that
stands us down to `secondary`, deaf. Ship §4 alone and the deadlock fix becomes a
self-demotion oscillator, moving the bug from #24 into #25 and mTLS.

`registrar_process.dart:274` currently discards the announced path; the path is
already on the wire (`:358` publishes `topicPath.path`). Read it:

```dart
['found', final String path, _, _] =>
    path == topicPath.path
        ? RegistrarAnnouncement.ownResidue      // NOT null — see below
        : RegistrarAnnouncement.found,
```

**`ownResidue` is its own case, not folded into the malformed arm.** Round 1
returned `null`, which made the filter's success indistinguishable from a
rejected malformed payload — a silent mechanism (Tesla). `ownResidue` is ignored
by the election and logged, so the filter can be observed working.

### The invariant, stated as an invariant

Round 1 wrote *"a different incarnation necessarily has a different pid"* as a
proof. Three families rejected it and Tesla named the consequence none of the
rest of us reached.

> **INVARIANT (RP-1).** A registrar's `topicPath` — `{namespace}/{host}/{pid}/{id}`
> — must be unique across every registrar simultaneously live on one island.
>
> **This design REQUIRES it and does not ENFORCE it.** Nothing in Aiko checks it.
>
> **FAILURE IF VIOLATED — and it is worse than the bug being fixed.** Two
> replicas sharing the tuple do not ignore their own residue; **they ignore each
> other, and both promote. Dual primary, silent, with no oscillation to make it
> visible.** Reachable wherever `host` is a logical name and `pid` is 1 — which
> is to say, in containers.
>
> **What actually carries it today:** `host`, not `pid`. Under Docker with
> default networking each container has its own hostname; the live island's three
> containers satisfy RP-1 by that route alone. Under a shared network namespace,
> or a logical host name, it can fail.

The surrounding principle — *there is no case in which acting on your own
announcement is correct* — is larger than the mechanism, because
`(primary absent)` is arity-1 and carries no path. Face 2 has nothing to compare
and is untouched; face 1 is untouched. Both need a wire change (a session token,
or a lease) and both remain Andy's. **The claim of this section is exactly: the
transport rule no longer creates an oscillator, provided RP-1 holds.**

## 7. `_open` owns its client on every failure path

Not from the panel — from reading `mqtt_client`'s source while checking the storm
claim. Both Carnot and Tesla accepted it as a real missing failure mode.

If `connect()` throws, the orphan is inert: `initialConnectionComplete` is set at
the very end of `SynchronousMqttServerConnectionHandler.internalConnect` and a
thrown `NoConnectionException` never reaches it, so `internalDisconnect` will not
fire auto-reconnect. That half is safe today.

If `connect()` **succeeds** and anything after it throws, today's code drops a
fully-live client — `autoReconnect = true`, `initialConnectionComplete = true`,
holding our will and **our client id** — with no reference to it. The next
`_open()` connects with the same id, the broker evicts the orphan's session, and
the orphan's auto-reconnect fights back. Two client objects flapping over one MQTT
identity, invisible to every log we own.

```dart
Future<void> _open() async {
  final epoch = _epoch;                       // §0 rule 2: captured before any await
  final client = _build();                    // will, 3.1.1, callbacks, autoReconnect
  await client.connect();
  try {
    if (epoch != _epoch || _closed) {
      throw StateError('the world moved while this socket was opening');
    }
    _client = client;
    _updates = client.updates?.listen(_onData);
    for (final topic in _subscriptions) {
      client.subscribe(topic, MqttQos.atMostOnce);
    }
  } on Object {
    _client = null;
    client.autoReconnect = false;             // disarm BEFORE disconnect (Carnot)
    client.onDisconnected = null;
    client.onAutoReconnect = null;
    client.onAutoReconnected = null;
    client.disconnect();
    rethrow;                                  // leaves us Detached, which is true
  }
}
```

The epoch check sits **inside** the try precisely so a stale-open disposes of its
candidate through the same path as any other failure.

## 8. Identity at close

Tesla's constraint 6, answered rather than left to whichever a test happens to do.

**A retired bus is never reopened.** `connect()` on `Retired` throws.
`disconnect()` is idempotent, sets `_closed` and bumps `_epoch` before any await
(§0). A caller wanting a connection again constructs a new `AikoClient`, minting
a new client id.

The reason is not tidiness: the client id is the island's notion of *who we are*
— what the broker fences sessions on, and what our will is attached to. Silently
re-minting an identity inside a method called `connect()` would make a process's
wire identity depend on which method a caller reached for. If reuse is ever
wanted it gets a named constructor and a written reason.

A failed *first* `connect()` lands in `Detached`, not `NotStarted`, because a
failed first connect and a failed reopen have the same truth and the same
recovery. It follows that `send` after a failed `connect()` reports transient
rather than caller error — the honest answer, since the caller did ask.

## 9. `FakeBus` implements the same rules — enforced, not promised

Round 1 wrote this as a vow and both Tesla and Carnot struck it as
self-contradicting: the bundled fake is one `connected` bool, starts live, lets
`connect()` resurrect after `disconnect()`, and throws `StateError` for
everything. Worse, `Reach` was private, *so the compiler could not see the double
at all* — §10's must-fail arm could go red on `AikoClient` and stay green on
every registrar test. That is the production-only prophet the section exists to
prevent.

What changes, concretely:

- **`Reach` is public and shared** (§2), so both implementations switch over the
  same sealed type and both get the exhaustiveness error.
- **One contract suite, run against both.** A parameterised test taking a
  `MessageBus` factory, asserting the §3/§4/§4b/§8 refusals. This is the
  enforcement; the prose is not.
- **`FakeBus` defaults to `NotStarted`**, models `Dipped` (which `setTransport`
  already half-does), throws `TransportUnavailable` vs `StateError` per §3, and
  refuses `connect()` after `disconnect()`.
- **`failSetWillWith` lands in `Detached`** with `_will` already written — what
  the real client produces.
- **The fourteen start-live tests get `FakeBus.alreadyAttached()`** — a named
  constructor with a written reason, the same medicine §8 prescribes for identity
  reuse. This is the blast radius round 1 did not count: fourteen call sites,
  mechanical, in one commit.

`Attached` carries a real `MqttServerClient` the fake cannot make, so the fake's
`Attached` arm is unreachable and its contract obligation is the **refusals**,
which is where all three PR #24 defects hid.

## 10. Done-test

1. A fresh `/design-temper` strike on this revision scores **0 DISSOLVE** from
   ≥3 seated families and **≤1 RECAST**.
2. **Must-fail arms**, each watched red before green, and each run **through the
   contract suite so it exercises the fake too** (Tesla: round 3 hid in the fake):
   - the round-3 deadlock — failed reopen, then a promotion retry;
   - **`disconnect()` during `setWill`'s reopen window** — must not leave
     `_closed && _client != null` (§0 rule 2's reason for existing);
   - **`connect()` racing `setWill`** — must not mint two sockets on one id;
   - **a post-`connect()` subscription failure** — must leave `Detached` with no
     orphan (§7);
   - **a promotion while `Dipped`** — must refuse, not reopen (§4's repair).

### Already verified, at design time

The central mechanism is a claim about a compiler, so it was compiled. Dart
3.13.0, both arms:

- **Null arm.** The §2/§3 sketches analyze clean and run. This caught a real
  defect in the first draft: a bare `sealed class Reach {}` gives the `const`
  leaves a non-const super and all of them fail to compile.
- **Must-fail arms, re-run against THIS revision.** Round 1's evidence covered a
  four-arm type and does not transfer to a five-arm one, so it was re-run rather
  than cited. Deleting the `Dipped()` arm is rejected by name in **both** forms
  the design actually uses:
  - from `_publishable`'s switch *expression* (§3) —
    `The type 'Reach' isn't exhaustively matched by the switch cases since it
    doesn't match the pattern 'Dipped()' — non_exhaustive_switch_expression`
  - from `setWill`'s switch *statement* (§4) —
    `… — non_exhaustive_switch_statement`

  The statement form matters on its own: §4, §4b and §8 are statements, and a
  proof that only covered expressions would have been evidence about a
  construct this design barely uses.

An analyzer passing is equally consistent with an analyzer not checking; the
must-fail arms separate those, and name the missing state.

**The fifth situation's observability** was checked the same way rather than
assumed: `MqttClient.connectionStatus` is a public getter and
`MqttConnectionState` has a distinct `connected` member
(`mqtt_client.dart:211`, `mqtt_client_connection_state.dart:25-36`). §1's
`Dipped` row is therefore a state we can actually read, not one we wish existed.

## Appendix: considered and not taken

**Two MQTT connections per registrar** (Maxwell's, recorded in `TEMPER.md`): a
process-level connection carrying the process will, a primary-level one opened on
promotion, so no will ever mutates. Not taken — once intent is separated from
mechanism you do not need a second socket — but Tesla is right that it is
*parked*, not subsumed: **if RP-1 turns out not to hold, this is the next thing
to price, before shipping rather than after.**

**A backoff constant inside `AikoClient`.** Not taken: it would be a second
scheduler racing the election timer that §5b hands ownership to. The backoff that
is genuinely wanted belongs on the timer whose period was chosen.

**Bounding `maxConnectionAttempts` to contain the package's loop** (Kelvin's
proposal). Not taken, for the reason argued in §5b: it shortens each round and
makes the storm faster. The narrow containment that *is* taken is disarming
`autoReconnect` on any client we retire.

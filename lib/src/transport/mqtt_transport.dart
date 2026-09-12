import 'dart:async';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../codec/s_expression.dart';
import '../time/create_timer.dart';

/// The arguments of a decoded call: positional or keyword, never both.
///
/// [parse] returns its `cdr` as exactly one of these two shapes — a
/// `List<Object?>` of positional arguments, or a `Map<String, Object?>` built
/// by `_listToDict` from `k: v` pairs. That set used to be written in a
/// comment on an `Object?` field, which gave the compiler nothing and left
/// every future reader to rediscover it with an `is` check.
///
/// Discriminating here rather than at the use site puts the decision at the
/// wire boundary, where the untrusted input actually arrives.
sealed class const CallArguments();

final class const PositionalArguments(final List<Object?> values)
    extends CallArguments {
  @override
  String toString() => values.toString();
}

final class const KeywordArguments(final Map<String, Object?> values)
    extends CallArguments {
  @override
  String toString() => values.toString();
}

/// Classify the `cdr` half of a [parse] result.
///
/// Throws [FormatException] on any other shape. `parse` cannot currently
/// produce one — `cdr` is only ever the empty list or `head.sublist(1)`, both
/// `List<Object?>`, passed through `_listToDict` which returns that list or a
/// `Map<String, Object?>`. The throw is the arm that would fire if that
/// invariant ever moved, rather than a silent widening.
CallArguments classifyArguments(Object? cdr) => switch (cdr) {
  final Map<String, Object?> map => KeywordArguments(map),
  final List<Object?> list => PositionalArguments(list),
  _ => throw FormatException(
    'call arguments must be a list or a keyword map, got '
    '${cdr == null ? 'null' : cdr.runtimeType}',
  ),
};

/// A decoded Aiko message: a function call received on an MQTT [topic].
class const AikoMessage(
  final String topic,
  final String command,
  final CallArguments arguments,
) {
  @override
  String toString() => 'AikoMessage($topic: $command $arguments)';
}

/// A process's death announcement, published by the BROKER when the connection
/// drops without a clean disconnect.
///
/// Aiko has two of these and they differ in every field, which is why this is a
/// value rather than a pair of hardcoded constants:
///
/// | | topic | payload | retain |
/// |---|---|---|---|
/// | every process, at startup | `{ns}/{host}/{pid}/0/state` | `(absent)` | **false** (`process.py:169`) |
/// | a registrar, on promotion | `{ns}/service/registrar` | `(primary absent)` | **true** (`registrar.py:189-190`) |
///
/// The retain flag is not decoration. An un-retained `(absent)` is seen only by
/// peers already subscribed at the moment of death, so a late joiner learns
/// nothing and asks the registrar instead. Primacy IS retained, precisely so a
/// late joiner can discover it without asking anyone.
final class LastWill {
  const LastWill({
    required this.topic,
    required this.payload,
    this.retain = false,
  });

  /// The per-process `(absent)` on `{process path}/0/state`, un-retained.
  ///
  /// `retain: false` is the reference's choice (`process.py:169` passes `False`
  /// as position 5 of `MQTT.__init__`), not an oversight of ours — three of
  /// this repo's own documents claimed it was retained before that was checked.
  factory LastWill.processAbsent(String processPath) =>
      LastWill(topic: '$processPath/0/state', payload: '(absent)');

  final String topic;
  final String payload;
  final bool retain;

  // Value equality, because a will is COMPARED before it is acted on.
  // Changing one costs a reconnect (see [MessageBus.setWill]); with identity
  // equality a driver that re-asserted the will it already holds would drop the
  // socket — and every subscription with it — for no change at all.
  @override
  bool operator ==(Object other) =>
      other is LastWill &&
      other.topic == topic &&
      other.payload == payload &&
      other.retain == retain;

  @override
  int get hashCode => Object.hash(topic, payload, retain);

  @override
  String toString() =>
      'LastWill($topic: $payload${retain ? ', retained' : ''})';
}

/// Whether the bus can carry traffic, and if not, whose problem that is.
///
/// Payload-free ON PURPOSE. Round 2 of this design gave [Attached] an
/// `MqttServerClient` field, which made a fake's parity a type error — the fake
/// could never inhabit the one state that matters. A caller switches on the
/// reach and reaches for the socket only inside the arm that proved it.
sealed class Reach {
  // A const super, or the const leaves below do not compile.
  const Reach();
}

/// A usable socket: the handle exists AND the mechanism reports connected.
final class Attached extends Reach {
  const Attached();
  @override
  String toString() => 'Attached';
}

/// Started, and currently without a socket. **Recovery is already armed** — see
/// [AikoClient] §5: this state cannot exist without an owner.
final class Detached extends Reach {
  const Detached();
  @override
  String toString() => 'Detached';
}

/// `connect()` has not run.
final class NotStarted extends Reach {
  const NotStarted();
  @override
  String toString() => 'NotStarted';
}

/// `disconnect()` has run. Terminal — a caller wanting a connection again
/// constructs a new bus, which mints a new client id.
final class Retired extends Reach {
  const Retired();
  @override
  String toString() => 'Retired';
}

/// The link is down and something is working on it: TRY AGAIN LATER.
///
/// Every mechanism-open failure wears this type and every caller error stays a
/// [StateError], so there is no third shape and the election can tell a bug from
/// weather.
class TransportUnavailable implements Exception {
  const TransportUnavailable(this.action);

  /// What was being attempted, for a stack trace that names the state.
  final String action;

  @override
  String toString() =>
      'TransportUnavailable: cannot $action — the link is down';
}

/// The bus, as everything above the transport needs it.
///
/// The interface exists so the layers that hold the protocol state machines (an
/// ECConsumer's snapshot framing, a services cache's two-topic completion rule)
/// can be exercised without a broker. Those machines have states a live island
/// will not produce on demand: an `add` outside a frame, a `(sync ...)` naming
/// someone else's topic, a snapshot arriving twice. A test that cannot create
/// the failure cannot clear it.
abstract interface class MessageBus {
  /// Decoded messages on subscribed topics.
  Stream<AikoMessage> get messages;

  /// Whether the transport is carrying traffic — `true` on connect, `false`
  /// when the link drops, `true` again when it comes back.
  ///
  /// **Edge-triggered: a repeat of the value already reported is not emitted.**
  /// That became load-bearing when we took ownership of reconnection. The
  /// supervisor retries forever against a down broker, and every failed attempt
  /// walks the same door that reports the link down — so a level-triggered
  /// stream would re-announce the outage at 1s, 2s, 4s … forever, and
  /// `BusProcess` answers each one by dropping the registrar and resetting the
  /// ladder it has already reset.
  Stream<bool> get transportUp;

  /// What a caller may do right now, and who owns getting out of it.
  Reach get reach;

  Future<void> connect();

  void subscribe(String topic);

  void unsubscribe(String topic);

  /// What the broker announces if this process dies without saying goodbye,
  /// or null if nothing is watching for us.
  LastWill? get will;

  /// Publish a function call as an S-expression.
  ///
  /// [retain] asks the broker to KEEP this payload and hand it to every future
  /// subscriber of [topic]. It is not a delivery guarantee — that is QoS — it
  /// is a claim that the message describes a lasting STATE rather than an
  /// event. Aiko retains exactly one thing, `(primary found ...)` on the boot
  /// topic, and retains it precisely so a process joining an hour later learns
  /// who the registrar is without asking anybody.
  ///
  /// Throws [TransportUnavailable] while the link is down, and [StateError] if
  /// the caller never connected or has retired the bus.
  void send(
    String topic,
    String command,
    Object? params, {
    bool retain = false,
  });

  /// Delete the retained payload on [topic].
  ///
  /// A zero-length retained publish is MQTT's *only* way to say this
  /// (3.1.1 SS3.3.1.3), which is why it needs a member of its own instead of
  /// falling out of [send]: [send] runs `generate`, and no command name encodes
  /// to no bytes.
  ///
  /// `registrar.py:186` does this on promotion and its comment says why —
  /// *"Clear LWT, so this registrar doesn't receive another LWT on reconnect"*.
  /// A predecessor's retained `(primary absent)` is still sitting on the topic,
  /// and a new primary that does not clear it reads its own predecessor's death
  /// as news about itself.
  void clearRetained(String topic);

  /// Change what the broker will announce if this process dies.
  ///
  /// **This RECONNECTS.** MQTT carries the will in the CONNECT packet and
  /// nowhere else, so assignment on a live connection is silently ignored. The
  /// registrar is the reason this exists at all: it connects holding the
  /// per-process `(absent)`, and must already be holding a retained
  /// `(primary absent)` at the moment it announces itself primary.
  /// `message/mqtt.py:200-209` is the same three steps for the same reason.
  ///
  /// **The reconnect must be invisible to subscriptions.** The implementation
  /// restores every topic it held, from the one list that IS the memory. That is
  /// load-bearing rather than tidy: a registrar deafened by its own promotion
  /// would never hear the `(primary absent)` that is supposed to stand it back
  /// down.
  ///
  /// **On a down link this RECORDS AND REFUSES.** It throws
  /// [TransportUnavailable] having already stored the will, and does NOT open —
  /// the supervisor owns opening, and a second opener here is what turned a
  /// failing promotion into an unbounded CONNECT storm.
  Future<void> setWill(LastWill? will);

  Future<void> disconnect();
}

/// A minimal Dart client for the Aiko bus: connect to MQTT, publish function
/// calls as S-expressions, and receive/decode them. This is the transport layer
/// on top of the [generate]/[parse] codec.
///
/// **The socket is a handle; the intent is the state.** Five lifecycle states
/// used to collapse into `_client == null`, and every transport defect PR #24's
/// cage-match found was a consequence of that. What replaced it, in one line
/// each — the full argument is
/// `docs/design/transport-lifecycle-intent-and-mechanism.md`:
///
/// - INTENT (`_will`, `_started`, `_closed`) is written by the lifecycle methods;
/// - MECHANISM (`_client`, `connectionStatus`) is written by [_open] and the
///   teardowns, and **a mechanism fact is recorded by the mechanism at the moment
///   it becomes true, never inferred from a locally-held proxy**;
/// - OBSERVATION is the payload-free [Reach], switched over exhaustively;
/// - POLICY (`_retry`, `_backoff`) belongs to the supervisor, and models US
///   rather than the wire.
class AikoClient implements MessageBus {
  AikoClient({
    this.host = 'localhost',
    this.port = 1883,
    String? clientId,
    LastWill? will,
    this.createTimer = Timer.new,
  }) : clientId =
           clientId ?? 'aiko_dart_${DateTime.now().microsecondsSinceEpoch}' {
    // In the body rather than the initializer list: the field is private and
    // the parameter is not, because a PUBLIC settable `will` would invite
    // exactly the bug this class documents — an assignment that reads back as
    // though it took and is silently ignored by the wire.
    _will = will;
  }

  final String host;
  final int port;
  final String clientId;

  /// paho's own numbers (`paho/mqtt/client.py:576-577`), not ours.
  ///
  /// Taking the reference's constants is the whole reason this is parity rather
  /// than a reconnect policy we invented. **No jitter, deliberately** — paho has
  /// none, and adding it would be a silent timing divergence; it is filed
  /// upstream for Andy instead.
  static const backoffMin = Duration(seconds: 1);
  static const backoffMax = Duration(seconds: 120);

  // ---------------------------------------------------------------- INTENT

  /// What the broker publishes if this process dies without saying goodbye.
  ///
  /// Null for a process nothing is watching for — an observer needs none. It is
  /// load-bearing the moment a peer's roster depends on hearing that we are gone.
  ///
  /// **Carried in the CONNECT packet, and changeable only by [setWill].** MQTT
  /// offers no other way: assigning `connectionMessage` after `connect()` reads
  /// back as though it took and never reaches the wire.
  ///
  /// That recovery has a race worth knowing before anything depends on it. The
  /// broker publishes the will when IT notices the drop, which for a frozen
  /// process is 1.5 × keepalive later — the measured 60-90s band. A client that
  /// reconnects in seconds re-registers FIRST, and the late `(absent)` then
  /// evicts a service that is alive and freshly registered, with nothing to undo
  /// it. A live island was found in exactly that state: a healthy ChatServer,
  /// running and absent from its own registrar's roster for 23 hours
  /// (`docs/notes/registrar-scope.md`). Nothing here fixes it, deliberately —
  /// re-announcing liveness would invent a wire message the Python side does not
  /// send.
  @override
  LastWill? get will => _will;
  LastWill? _will;

  /// [connect] has been called and [disconnect] has not.
  ///
  /// This is what separates [NotStarted] from [Detached], and it is set BEFORE
  /// the first open so that a first connect which FAILS lands in [Detached] —
  /// where the supervisor owns it — rather than reading as though nobody ever
  /// asked.
  var _started = false;

  /// [disconnect] has run. Terminal.
  var _closed = false;

  // ------------------------------------------------------------- MECHANISM

  MqttServerClient? _client;

  /// Bumped by [disconnect], which BYPASSES the gate.
  ///
  /// The gate is FIFO, so nothing gated can overtake anything else gated. The
  /// one thing that can overtake an in-flight [_open] is a teardown, precisely
  /// because a teardown whose purpose is promptness must never wait on a connect
  /// to a broker that is not answering. This is what fences that: [_open]
  /// captures the epoch before its first await and refuses to install a socket
  /// into a bus that has since been retired.
  var _epoch = 0;

  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;

  /// Every topic currently subscribed. **This set IS the memory.**
  ///
  /// The broker cannot tell us what we were interested in, and every CONNECT we
  /// make carries `startClean`, so the session is thrown away each time. [_open]
  /// is the only thing that ever connects and therefore the ONE subscription
  /// install site, walking this set — which is the reference's invariant exactly
  /// (`mqtt.py:160` replays the application's list on every connect, including
  /// reconnects).
  final Set<String> _subscriptions = {};

  // ---------------------------------------------------------------- POLICY

  /// How the retry timer is made. See [CreateTimer] for why this is a seam.
  final CreateTimer createTimer;

  Timer? _retry;

  /// An attempt is in flight. Held across the WHOLE attempt — see
  /// [_scheduleReconnect].
  var _attempting = false;

  Duration _backoff = backoffMin;

  /// Recovery is OWNED while a timer is pending or an attempt is in flight.
  bool get _recoveryOwned => _retry != null || _attempting;

  // ----------------------------------------------------------------- gate

  /// Serialises everything that may build or replace a socket.
  ///
  /// FIFO by construction, which is what closes the generation question without
  /// a third mechanism: a fired retry awaiting the gate cannot be overtaken by
  /// [_reopen] or [connect], because those are gated too.
  Future<void> _gateChain = Future<void>.value();

  Future<T> _gate<T>(Future<T> Function() action) {
    final result = _gateChain.then((_) => action());
    // The chain must survive a failed action, or one thrown open deadlocks every
    // later caller. The error is swallowed HERE only — `result` still carries it
    // to whoever asked.
    _gateChain = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  // --------------------------------------------------------------- streams

  final _controller = StreamController<AikoMessage>.broadcast();
  final _transport = StreamController<bool>.broadcast();

  @override
  Stream<bool> get transportUp => _transport.stream;

  /// Null until the first report, so the FIRST value of either polarity is
  /// always news.
  bool? _reported;

  void _reportTransport({required bool up}) {
    if (_transport.isClosed || _reported == up) return;
    _reported = up;
    _transport.add(up);
  }

  @override
  Stream<AikoMessage> get messages => _controller.stream;

  // ----------------------------------------------------------- observation

  @override
  Reach get reach {
    if (_closed) return const Retired();
    final client = _client;
    // BOTH conditions. `_client != null` alone is the defect this design is
    // named for — a handle standing in for a wire, so a corpse reads Attached.
    // The status is the mechanism's own report of its own state.
    if (client != null &&
        client.connectionStatus?.state == MqttConnectionState.connected) {
      return const Attached();
    }
    return _started ? const Detached() : const NotStarted();
  }

  /// The live client. **Only legal inside an [Attached] arm**; `reach` is what
  /// proves that, and this is the one `!` in the class.
  MqttServerClient get _live => _client!;

  // ------------------------------------------------------------- lifecycle

  @override
  Future<void> connect() => _gate(() async {
    switch (reach) {
      case Retired():
        throw StateError(
          'cannot connect: this bus is retired — construct a new AikoClient',
        );
      case Attached():
        return; // you already have what you asked for
      case Detached():
        // The supervisor owns this, and a second opener here is exactly the
        // storm §5 removed.
        throw const TransportUnavailable('connect');
      case NotStarted():
        _started = true; // BEFORE _open, so a failed first connect is Detached
        await _open();
    }
  });

  @override
  void subscribe(String topic) {
    if (reach case Retired()) {
      throw StateError('cannot subscribe: this bus is retired');
    }
    // Recorded whether or not a socket exists. On a down link the record ALONE
    // is correct, because the supervisor's next [_open] walks the set.
    _subscriptions.add(topic);
    // Guarded on Attached rather than on a non-null handle: MqttClient.subscribe
    // THROWS ConnectionException when not connected (`mqtt_client.dart:448-452`).
    if (reach case Attached()) _live.subscribe(topic, MqttQos.atMostOnce);
  }

  /// Stop receiving [topic]. Paired with [subscribe] by `TopicRouter`, which
  /// owns the reference counting — the broker has no notion of "one of my
  /// several interests", so unsubscribing while another handler still wants the
  /// topic silently blinds it.
  @override
  void unsubscribe(String topic) {
    // DELIBERATELY ASYMMETRIC WITH [subscribe], which DOES refuse on Retired.
    // `subscribe` on a retired bus asks for something it cannot have;
    // `unsubscribe` asks us to FORGET, and forgetting is always satisfiable.
    //
    // The caller here is a teardown: `ECConsumer.terminate` reaches
    // `TopicRouter.removeHandler`, which unsubscribes a topic when its last
    // handler goes. An earlier draft of this class threw here for symmetry with
    // `subscribe`, which turned an idempotent cleanup into an unhandled
    // StateError out of an async drain — the same "a teardown path may not
    // assume its setup ran" defect this file already carries a test for.
    _subscriptions.remove(topic);
    if (reach case Attached()) _live.unsubscribe(topic);
  }

  @override
  void send(
    String topic,
    String command,
    Object? params, {
    bool retain = false,
  }) {
    switch (reach) {
      case Attached():
        final payload = generate(command, params ?? const <Object?>[]);
        final builder = MqttClientPayloadBuilder()..addString(payload);
        _live.publishMessage(
          topic,
          MqttQos.atMostOnce,
          builder.payload!,
          retain: retain,
        );
      case Detached():
        throw TransportUnavailable('send to $topic');
      case NotStarted():
        throw StateError('cannot send to $topic: connect() has not run');
      case Retired():
        throw StateError('cannot send to $topic: this bus is retired');
    }
  }

  @override
  void clearRetained(String topic) {
    switch (reach) {
      case Attached():
        // An empty builder's payload is a zero-length buffer, which is the exact
        // wire form that DELETES a retained message. Going through `generate`
        // with an empty command would not: that produces `()`, two bytes, which
        // REPLACES the retained payload rather than removing it.
        _live.publishMessage(
          topic,
          MqttQos.atMostOnce,
          MqttClientPayloadBuilder().payload!,
          retain: true,
        );
      case Detached():
        throw TransportUnavailable('clear the retained payload on $topic');
      case NotStarted():
        throw StateError('cannot clear $topic: connect() has not run');
      case Retired():
        throw StateError('cannot clear $topic: this bus is retired');
    }
  }

  @override
  Future<void> setWill(LastWill? next) => _gate(() async {
    switch (reach) {
      case Retired():
        throw StateError('cannot set a will: this bus is retired');
      case NotStarted():
        // connect() will carry it.
        _will = next;
      case Detached():
        // RECORD AND REFUSE. The supervisor's next open carries it; opening
        // here would be a second opener racing the one that already owns this.
        _will = next;
        throw const TransportUnavailable('set a will while the link is down');
      case Attached():
        // Sound again, and only because `autoReconnect` is off: [_open] is the
        // only thing that ever connects and it always builds its CONNECT from
        // `_will`, so on Attached the socket necessarily carries `_will`. Under
        // auto-reconnect this comparison was a proxy for a liveness check and
        // left a registrar deaf forever.
        if (next == _will) return;
        // Written before any socket work and never rolled back: intent does not
        // become false because a socket failed to carry it.
        _will = next;
        await _reopen(_live);
    }
  });

  @override
  Future<void> disconnect() async {
    // SYNCHRONOUSLY, and WITHOUT the gate. A teardown whose purpose is
    // promptness must never queue behind a connect to a broker that is not
    // answering; `_epoch` is what fences an [_open] whose await outlives this.
    _closed = true;
    _epoch++;
    _retry?.cancel();
    _retry = null;

    final live = _client;
    _client = null;
    await _dropUpdates();
    if (live != null) _discard(live);
    await _controller.close();
    await _transport.close();
  }

  // -------------------------------------------------------- the mechanism

  /// Build a socket carrying the CURRENT will, install it LAST, and restore
  /// every subscription. **The only function that ever connects.**
  ///
  /// Three call sites — the first [connect], [_reopen] for a will change, and
  /// the supervisor — and it runs only inside the gate, so at most one open is
  /// ever in flight. (`test/transport/one_opener_test.dart` counts them
  /// mechanically: the last revision of this design asserted "exactly two" in
  /// prose, was wrong, and the false count hid a real bug from its own author.)
  Future<void> _open() async {
    final epoch = _epoch; // captured before any await
    final client = _build(_will);
    StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? updates;
    try {
      await client.connect();
      if (epoch != _epoch || _closed) {
        throw const TransportUnavailable(
          'open: the bus was retired while connecting',
        );
      }
      updates = client.updates?.listen(_onData);
      // No `await` between here and the install, so an ungated `subscribe`
      // cannot interleave: a topic added while the connect was in flight is
      // already in the set and is therefore included in THIS connect.
      for (final topic in _subscriptions) {
        client.subscribe(topic, MqttQos.atMostOnce);
      }
      _updates = updates;
      // Installed LAST, fully armed: the bus is never externally Attached with
      // nothing listening.
      _client = client;
      // THE DUAL OF [_enterDetached], and the reason it is here rather than in
      // the supervisor's timer body. That door makes `Detached` imply an armed
      // recovery; this one makes `Attached` imply NO armed recovery. Without it
      // the second half of the invariant held only because there happens to be
      // no `await` between the subscribe loop and this install — a reachability
      // argument, not a guarantee, and reachability arguments are what a future
      // edit breaks silently. A stale timer firing against a live socket would
      // open a SECOND connection under the same client id, and a broker takeover
      // closes the first WITHOUT a DISCONNECT packet, which is precisely the
      // condition that publishes our will. Tesla, /cage-match round 3: the
      // mechanism was not reproducible on today's code and the invariant it
      // names was genuinely open.
      _retry?.cancel();
      _retry = null;
      _backoff = backoffMin;
      _reportTransport(up: true);
    } on Object catch (error) {
      await updates?.cancel();
      _discard(client);
      // R2: the single door. Arms recovery and reports down on EVERY failure
      // path, so Detached cannot exist without an owner.
      _enterDetached();
      throw error is TransportUnavailable
          ? error
          : TransportUnavailable('open: $error');
    }
  }

  MqttServerClient _build(LastWill? will) {
    final client = MqttServerClient.withPort(host, clientId, port)
      ..logging(on: false)
      ..keepAlivePeriod = 60
      // THE CHANGE. The package would otherwise own socket recovery, in a
      // process we cannot pace, cancel or observe — and it does not back off at
      // all, where paho backs off 1s→120s. Matching the reference's MECHANISM
      // here would have broken the reference's INVARIANT: `_on_connect` replays
      // the APPLICATION's subscription list on every connect (`mqtt.py:160`),
      // and `resubscribeOnAutoReconnect` replays the PACKAGE's maps.
      ..autoReconnect = false
      // Moot with autoReconnect off, and stated anyway: a default nobody chose
      // is precisely what this revision exists to correct.
      ..resubscribeOnAutoReconnect = false
      // MQTT 3.1.1, not the package default of 3.1 — a wire conformance
      // decision, not a preference. The divergence is invisible for CONNECT,
      // PUBLISH and SUBSCRIBE, which is why it survived: it only bites on
      // UNSUBSCRIBE, whose reserved fixed-header bits `MqttUnsubscribeMessage`
      // only sets under 3.1.1. Under the default, mosquitto 2 answers every
      // unsubscribe with "malformed packet" and DROPS THE CONNECTION. Measured
      // on a live island (spike/unsubscribe/probe_unsubscribe.dart): with
      // unsubscribe, 1 malformed disconnect; without, 0.
      ..setProtocolV311()
      // The live down signal, measured rather than assumed. Under
      // `autoReconnect = false` this fires 65ms after the broker stops and the
      // client stays down (spike/autoreconnect-off/probe_disconnect_signal.dart).
      // It does NOT fire on a FAILED connect — that throws instead
      // (probe_failed_connect.dart) — which is why [_open]'s catch must walk the
      // same door rather than trusting this callback to cover it.
      ..onDisconnected = _onLinkLost;

    if (will != null) {
      // Supplying our own connect message REPLACES the package default
      // (`mqtt_client.dart:414` is `connectionMessage ??= …`), and that default
      // is the ONLY thing that calls `.startClean()` (`:419`).
      // `MqttConnectFlags.cleanStart` is false by default, so omitting it here
      // would silently switch every Aiko process to a persistent session: the
      // broker would queue messages for a dead client id and redeliver a backlog
      // on reconnect. Nothing in our code would report that.
      //
      // The client id and keep-alive do NOT need repeating: `connect()` patches
      // both onto a user-supplied message (`:399-404`).
      var message = MqttConnectMessage()
          .startClean()
          // Topic AND message are what set the will FLAG. `withWillQos` and
          // `withWillRetain` alone do not, and a topic with no message throws
          // when the CONNECT is serialised — so these two always travel together.
          .withWillTopic(will.topic)
          .withWillMessage(will.payload)
          // QoS 0: the reference never passes a will QoS, so paho's default of 0
          // is what every island peer already expects.
          .withWillQos(MqttQos.atMostOnce);
      if (will.retain) message = message.withWillRetain();
      client.connectionMessage = message;
    }
    return client;
  }

  /// Replace the live socket with one carrying the current will.
  ///
  /// ONE attempt. If it fails, [_open]'s catch arms the supervisor through the
  /// single door — this does not retry on its own, because two retry loops is
  /// the shape this revision deleted.
  Future<void> _reopen(MqttServerClient live) async {
    _discard(live);
    _client = null;
    await _dropUpdates();
    // Say the link went down, because it DID: a layer keyed on `transportUp`
    // would otherwise see an unbroken wire across a window in which nothing
    // could be published or received.
    _reportTransport(up: false);
    await _open();
  }

  /// Disarm and drop ONE client object.
  ///
  /// Deliberately does NOT touch `_client` or arm recovery — those are
  /// [_enterDetached]'s job, and keeping them apart is what lets [_open] discard
  /// a failed CANDIDATE without pretending the installed socket died.
  void _discard(MqttServerClient client) {
    // Disarm before disconnecting, or our own teardown reports as an island
    // event and the ladder above reacts to its own shutdown.
    client.onDisconnected = null;
    client.onConnected = null;
    client.disconnect();
  }

  Future<void> _dropUpdates() async {
    final updates = _updates;
    _updates = null;
    await updates?.cancel();
  }

  /// Wired to `onDisconnected`: the mechanism telling us the socket died.
  void _onLinkLost() {
    final live = _client;
    if (live != null) _discard(live);
    unawaited(_dropUpdates());
    _enterDetached();
  }

  /// **THE SINGLE DOOR INTO [Detached].**
  ///
  /// Every path that loses or fails to build a socket comes through here, so
  /// `Detached` cannot exist without an owner. The design revision before this
  /// one had a table SAYING the supervisor owned `Detached` and no code that
  /// armed it on two of three entrances: *a comment is not a timer*.
  void _enterDetached() {
    _client = null;
    _reportTransport(up: false);
    if (!_closed && _started) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _recoveryOwned) return;
    _retry = createTimer(_backoff, () async {
      // Take the in-flight lock BEFORE releasing the timer slot. Clearing
      // `_retry` first would release the one-owner invariant for the whole
      // await, and an `onDisconnected` arriving during it would start a second
      // loop — the two racing loops this revision deleted, only written by us.
      _attempting = true;
      _retry = null;
      try {
        await _gate(_open);
        _backoff = backoffMin; // reset ONLY on success
      } on Object {
        final doubled = _backoff * 2;
        _backoff = doubled > backoffMax ? backoffMax : doubled;
      } finally {
        _attempting = false;
        // Still down? Own it again. Covers both "the open failed" and "the open
        // succeeded and the link dropped during it".
        if (!_closed && reach is Detached) _scheduleReconnect();
      }
    });
  }

  void _onData(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final message = event.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
        message.payload.message,
      );
      try {
        final (command, cdr) = parse(text);
        _controller.add(
          AikoMessage(event.topic, command, classifyArguments(cdr)),
        );
      } catch (_) {
        // Not a well-formed S-expression; ignore on this layer.
      }
    }
  }
}

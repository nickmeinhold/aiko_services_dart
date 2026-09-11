import 'dart:async';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../codec/s_expression.dart';

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

/// The bus, as everything above the transport needs it.
///
/// Five members, which is the whole of what [AikoClient] offers — the interface
/// exists so the layers that hold the protocol state machines (an ECConsumer's
/// snapshot framing, a services cache's two-topic completion rule) can be
/// exercised without a broker. Those machines have states a live island will
/// not produce on demand: an `add` outside a frame, a `(sync ...)` naming
/// someone else's topic, a snapshot arriving twice. A test that cannot create
/// the failure cannot clear it.
abstract interface class MessageBus {
  /// Decoded messages on subscribed topics.
  Stream<AikoMessage> get messages;

  /// Whether the transport is carrying traffic — `true` on connect, `false`
  /// when the link drops, `true` again when it comes back.
  ///
  /// Without this the layers above cannot tell a quiet island from a dead
  /// socket. `autoReconnect` heals the connection and says nothing, so a
  /// connection ladder built only from protocol messages climbs once and then
  /// describes a wire it can no longer hear.
  Stream<bool> get transportUp;

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
  /// **The reconnect must be invisible to subscriptions.** An implementation
  /// restores every topic it held. That is load-bearing rather than tidy: a
  /// registrar deafened by its own promotion would never hear the
  /// `(primary absent)` that is supposed to stand it back down.
  ///
  /// A no-op when the will is already [will], so a driver may assert it
  /// defensively without paying for a socket.
  Future<void> setWill(LastWill? will);

  Future<void> disconnect();
}

/// A minimal Dart client for the Aiko bus: connect to MQTT, publish function
/// calls as S-expressions, and receive/decode them. This is the transport layer
/// on top of the [generate]/[parse] codec.
///
/// Registration + Registrar discovery build on this (next layer); the wire
/// protocol itself — "a function call, serialized, over MQTT" — is fully here.
class AikoClient implements MessageBus {
  AikoClient({
    this.host = 'localhost',
    this.port = 1883,
    String? clientId,
    LastWill? will,
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

  /// What the broker publishes if this process dies without saying goodbye.
  ///
  /// Null for a process nothing is watching for — an observer needs none, which
  /// is why the transport went this long without one. It is load-bearing the
  /// moment a peer's roster depends on hearing that we are gone.
  ///
  /// **Carried in the CONNECT packet, and changeable only by [setWill], which
  /// reconnects.** MQTT offers no other way: assigning
  /// `connectionMessage` after `connect()` is silently ignored by the reconnect
  /// path while reading back as though it took. A process that must CHANGE its
  /// will — a registrar being promoted to primary swaps a per-process
  /// `(absent)` for a retained `(primary absent)` — has to reconnect, which is
  /// exactly what the reference does (`message/mqtt.py:200-209` is
  /// `_disconnect(); wait_disconnected(); _connect(…)`). That is MQTT's law,
  /// not paho clumsiness, and the Dart side does not get to skip it.
  ///
  /// **A will and `autoReconnect` are two mechanisms on one connection with
  /// opposite jobs.** One refuses to die; the other exists to announce death.
  /// An unclean drop makes the broker publish `(absent)` to every live
  /// subscriber, and then this client resurrects with the stored CONNECT and
  /// carries on — having already told the island it was gone. That the will
  /// SURVIVES the reconnect is a fact about the arming, not about the truth of
  /// what it announced.
  ///
  /// The reference has the same pairing and heals a different way: it never
  /// re-announces liveness on the state topic — there is no `(ready)` — but
  /// `process.py:353-358` re-pushes every service to the registrar whenever the
  /// boot topic says `found`, which a reconnect re-reads. The roster recovers
  /// through RE-REGISTRATION, not by contradicting the death note.
  ///
  /// That recovery has a race worth knowing before anything depends on it. The
  /// broker publishes the will when IT notices the drop, which for a frozen
  /// process is 1.5 × keepalive later — the measured 60-90s band. A client that
  /// reconnects in seconds re-registers FIRST, and the late `(absent)` then
  /// evicts a service that is alive and freshly registered, with nothing to
  /// undo it. A live island was found in exactly that state: a healthy
  /// ChatServer, running and absent from its own registrar's roster for 23
  /// hours (`docs/notes/registrar-scope.md`).
  ///
  /// Nothing here fixes it, deliberately. Re-announcing liveness would invent a
  /// wire message the Python side does not send, and this transport has no
  /// registration to re-push yet. Named so the registrar increment inherits the
  /// hazard rather than rediscovering it.
  /// Mutable through [setWill] only, which reconnects — see there for why a
  /// plain assignment cannot do the job.
  @override
  LastWill? get will => _will;
  LastWill? _will;

  /// Null until [connect], and REPLACED by [setWill] — a will change builds a
  /// new socket rather than mutating the old one, because `disconnect()` nulls
  /// the client's connection handler, publishing manager and event bus on the
  /// way out. Reusing the corpse would depend on `connect()` rebuilding every
  /// one of them; a fresh client depends on nothing.
  MqttServerClient? _client;
  MqttServerClient get _mqtt => _client!;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;

  /// Every topic currently subscribed, so a will change can restore them.
  ///
  /// The broker cannot tell us what we were interested in, and a reconnect with
  /// `startClean` throws the session away — so this set IS the memory. It lives
  /// at the socket because the socket is the only layer that knows it was
  /// replaced.
  final Set<String> _subscriptions = {};

  final _controller = StreamController<AikoMessage>.broadcast();
  final _transport = StreamController<bool>.broadcast();

  @override
  Stream<bool> get transportUp => _transport.stream;

  void _reportTransport({required bool up}) {
    if (!_transport.isClosed) _transport.add(up);
  }

  /// Decoded Aiko messages received on subscribed topics.
  @override
  Stream<AikoMessage> get messages => _controller.stream;

  @override
  Future<void> connect() async {
    await _open();
    _reportTransport(up: true);
  }

  /// Build a socket carrying the CURRENT will, and restore what we were hearing.
  ///
  /// Split out of [connect] for [setWill], which needs exactly this and must
  /// not re-run what [connect] does around it.
  Future<void> _open() async {
    final client = MqttServerClient.withPort(host, clientId, port)
      ..logging(on: false)
      ..keepAlivePeriod = 60
      ..autoReconnect = true
      // Stated, not inherited. The whole recovery path rests on this: after an
      // auto-reconnect the retained `(primary found …)` only comes back because
      // the client re-subscribes, and that is what re-promotes the ladder and
      // re-drives the roster. It happens to be the package default — which is
      // precisely the problem, because a default is a property nobody chose. If
      // it ever flipped, the observer would sit at TRANSPORT forever holding no
      // subscriptions, raising nothing.
      ..resubscribeOnAutoReconnect = true
      // MQTT 3.1.1, not the package default of 3.1 — and this is a wire
      // conformance decision, not a preference.
      //
      // The reference implementation connects as 3.1.1 (paho's default;
      // mosquitto logs it as `p4`, and every Python aiko service on the island
      // shows `p4` while an unfixed Dart client shows `p3`). The divergence is
      // invisible for CONNECT, PUBLISH and SUBSCRIBE, which is why it survived:
      // it only bites on UNSUBSCRIBE. Those fixed-header bits are reserved and
      // MUST be 0b0010, and `MqttUnsubscribeMessage.writeTo` only sets them
      // under 3.1.1 — so under the default, mosquitto 2 answers every
      // unsubscribe with "malformed packet" and DROPS THE CONNECTION.
      //
      // Measured on a live island, two arms: with unsubscribe, 1 malformed
      // disconnect; without, 0 (spike/unsubscribe/probe_unsubscribe.dart).
      // Nothing on our side reported it — `autoReconnect` reconnected, our own
      // logs stayed clean, and the only witness was the broker's log.
      ..setProtocolV311()
      // The link's own liveness, surfaced rather than swallowed. `autoReconnect`
      // repairs the socket silently, which is precisely why the layers above
      // need to be told: a ladder that only ever climbs reports REGISTRAR over a
      // dead wire, and the resulting quiet is indistinguishable from an island
      // with nothing to say. Same failure shape as the 3.1 defect above, one
      // layer up.
      // `onAutoReconnect`, NOT `onDisconnected`, is the down signal — measured,
      // not assumed. With `autoReconnect` set, a broker restart never calls
      // `onDisconnected`: the client goes straight to reconnecting. A probe
      // across a real broker restart saw `true, true` and no `false` at all
      // (spike/reconnect/probe_reconnect.dart), so an implementation hung on
      // `onDisconnected` is a mechanism whose triggering condition never occurs
      // — working code for an event that is never delivered.
      //
      // `onDisconnected` is kept for the case auto-reconnect cannot cover: a
      // disconnect with no reconnection to follow.
      ..onAutoReconnect = (() => _reportTransport(up: false))
      ..onDisconnected = (() => _reportTransport(up: false))
      ..onAutoReconnected = (() => _reportTransport(up: true))
      ..onConnected = (() => _reportTransport(up: true));

    final will = _will;
    if (will != null) {
      // Supplying our own connect message REPLACES the package default —
      // `mqtt_client.dart:414` is `connectionMessage ??= …` — and that default
      // is the ONLY thing that calls `.startClean()` (`:419`).
      // `MqttConnectFlags.cleanStart` is false by default, so omitting it here
      // would silently switch every Aiko process to a persistent session: the
      // broker would queue messages for a dead client id and redeliver a
      // backlog on reconnect. Nothing in our code would report that.
      //
      // The client id and keep-alive do NOT need repeating: `connect()` patches
      // both onto a user-supplied message (`:399-404`). `startClean` is the sole
      // omission, which is why it is the only one restored here.
      client.connectionMessage = MqttConnectMessage()
          .startClean()
          // Topic AND message are what set the will FLAG. `withWillQos` and
          // `withWillRetain` alone do not, and a topic with no message throws
          // when the CONNECT is serialised — so these two always travel
          // together.
          .withWillTopic(will.topic)
          .withWillMessage(will.payload)
          // QoS 0: the reference never passes a will QoS, so paho's default of
          // 0 is what every island peer already expects.
          .withWillQos(MqttQos.atMostOnce);
      if (will.retain) {
        client.connectionMessage = client.connectionMessage!.withWillRetain();
      }
    }

    await client.connect();
    // Published only once the socket is UP. Assigning before the connect would
    // leave `_client` naming a client that never connected if this throws —
    // non-null, so every reader passes the null check and then fails at the
    // broker instead. A failed open leaves the previous state, which is either
    // null (nothing to lie about) or the old client the caller is replacing.
    _client = client;
    _updates = client.updates?.listen(_onData);
    // A fresh CONNECT with `startClean` opens an EMPTY session, so every
    // subscription this client held is gone as far as the broker is concerned.
    // On a first [connect] the set is empty and this loop does nothing; after a
    // [setWill] it is the entire reason the process can still hear the island.
    for (final topic in _subscriptions) {
      client.subscribe(topic, MqttQos.atMostOnce);
    }
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

  /// Subscribe to an MQTT topic (Aiko topics look like
  /// `{namespace}/{host}/{pid}/{service_id}/{in|out}`).
  @override
  void subscribe(String topic) {
    // Recorded even when there is no socket yet: the set is the memory, and a
    // subscription taken before connect must survive into the first [_open].
    _subscriptions.add(topic);
    _client?.subscribe(topic, MqttQos.atMostOnce);
  }

  /// Stop receiving [topic]. Paired with [subscribe] by `TopicRouter`, which
  /// owns the reference counting — the broker has no notion of "one of my
  /// several interests", so unsubscribing while another handler still wants the
  /// topic silently blinds it.
  @override
  void unsubscribe(String topic) {
    _subscriptions.remove(topic);
    _client?.unsubscribe(topic);
  }

  /// Publish a function call as an Aiko S-expression to [topic].
  ///
  /// [params] is a `List` of positional args or a `Map` of keyword args; `null`
  /// is treated as an empty argument list.
  @override
  void send(
    String topic,
    String command,
    Object? params, {
    bool retain = false,
  }) {
    final payload = generate(command, params ?? const <Object?>[]);
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _mqtt.publishMessage(
      topic,
      MqttQos.atMostOnce,
      builder.payload!,
      retain: retain,
    );
  }

  @override
  void clearRetained(String topic) {
    // An empty builder's payload is a zero-length buffer, which is the exact
    // wire form that DELETES a retained message. Going through `generate` with
    // an empty command would not do it: that produces `()`, two bytes, which
    // replaces the retained payload with a new one rather than removing it.
    _mqtt.publishMessage(
      topic,
      MqttQos.atMostOnce,
      MqttClientPayloadBuilder().payload!,
      retain: true,
    );
  }

  @override
  Future<void> setWill(LastWill? next) async {
    if (next == _will) return;
    _will = next;
    final live = _client;
    // Not connected yet: the new will is what [connect] will carry, and there
    // is no socket to pay for.
    if (live == null) return;

    // Say the link went down, because it DID. A layer keyed on `transportUp`
    // would otherwise see an unbroken wire across a window in which nothing
    // could be published or received — the same lying-rung failure the ladder
    // above was built to avoid.
    _reportTransport(up: false);
    // This drop is our own doing, and it has already been announced once on the
    // line above. Leaving the callbacks armed would announce it again, as
    // though the island had gone.
    live.onDisconnected = null;
    live.onAutoReconnect = null;
    live.onAutoReconnected = null;
    await _updates?.cancel();
    _updates = null;
    live.disconnect();
    await _open();
    _reportTransport(up: true);
  }

  @override
  Future<void> disconnect() async {
    // Stop reporting BEFORE disconnecting: the disconnect callback would
    // otherwise announce a drop that is our own doing, and the ladder above
    // would react to its own shutdown as though the island had gone.
    await _updates?.cancel();
    _updates = null;
    // TOLERATE A SETUP THAT NEVER SUCCEEDED. `_client` is assigned only after a
    // successful connect, so `try { await connect(); } finally { await
    // disconnect(); }` against a dead broker used to raise
    // `Null check operator used on a null value` from here — MASKING the
    // SocketException that is the actual news. Measured, not theorised: against
    // a closed port it printed exactly that, and the operator learns nothing
    // from it. A teardown path may not assume its setup ran.
    final live = _client;
    if (live != null) {
      live.onDisconnected = null;
      live.disconnect();
    }
    await _controller.close();
    await _transport.close();
  }
}

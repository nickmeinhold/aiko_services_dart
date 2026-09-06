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

  Future<void> connect();

  void subscribe(String topic);

  void unsubscribe(String topic);

  /// Publish a function call as an S-expression.
  void send(String topic, String command, Object? params);

  Future<void> disconnect();
}

/// A minimal Dart client for the Aiko bus: connect to MQTT, publish function
/// calls as S-expressions, and receive/decode them. This is the transport layer
/// on top of the [generate]/[parse] codec.
///
/// Registration + Registrar discovery build on this (next layer); the wire
/// protocol itself — "a function call, serialized, over MQTT" — is fully here.
class AikoClient implements MessageBus {
  AikoClient({this.host = 'localhost', this.port = 1883, String? clientId})
    : clientId =
          clientId ?? 'aiko_dart_${DateTime.now().microsecondsSinceEpoch}';

  final String host;
  final int port;
  final String clientId;

  late final MqttServerClient _mqtt;
  final _controller = StreamController<AikoMessage>.broadcast();

  /// Decoded Aiko messages received on subscribed topics.
  @override
  Stream<AikoMessage> get messages => _controller.stream;

  @override
  Future<void> connect() async {
    _mqtt = MqttServerClient.withPort(host, clientId, port)
      ..logging(on: false)
      ..keepAlivePeriod = 60
      ..autoReconnect = true
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
      ..setProtocolV311();
    await _mqtt.connect();
    _mqtt.updates?.listen(_onData);
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
  void subscribe(String topic) => _mqtt.subscribe(topic, MqttQos.atMostOnce);

  /// Stop receiving [topic]. Paired with [subscribe] by `TopicRouter`, which
  /// owns the reference counting — the broker has no notion of "one of my
  /// several interests", so unsubscribing while another handler still wants the
  /// topic silently blinds it.
  @override
  void unsubscribe(String topic) => _mqtt.unsubscribe(topic);

  /// Publish a function call as an Aiko S-expression to [topic].
  ///
  /// [params] is a `List` of positional args or a `Map` of keyword args; `null`
  /// is treated as an empty argument list.
  @override
  void send(String topic, String command, Object? params) {
    final payload = generate(command, params ?? const <Object?>[]);
    final builder = MqttClientPayloadBuilder()..addString(payload);
    _mqtt.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
  }

  @override
  Future<void> disconnect() async {
    _mqtt.disconnect();
    await _controller.close();
  }
}

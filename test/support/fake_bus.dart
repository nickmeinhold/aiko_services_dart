/// A [MessageBus] with no broker: publishes go into a list, and a test injects
/// inbound payloads directly.
library;

import 'dart:async';

import 'package:aiko_services/aiko_services.dart';

/// One thing this bus was asked to publish.
final class const SentMessage(
  final String topic,
  final String command,
  final Object? params,
) {
  @override
  String toString() => 'SentMessage($topic, $command, $params)';
}

class FakeBus implements MessageBus {
  final _controller = StreamController<AikoMessage>.broadcast();

  /// Everything published, in order.
  final List<SentMessage> sent = [];

  /// Topics currently subscribed, in registration order.
  final List<String> subscribed = [];

  /// Topics that were unsubscribed.
  final List<String> unsubscribed = [];

  var connected = false;

  final _transport = StreamController<bool>.broadcast();

  @override
  Stream<AikoMessage> get messages => _controller.stream;

  @override
  Stream<bool> get transportUp => _transport.stream;

  /// Drops or restores the link, as a broker outage would.
  Future<void> setTransport({required bool up}) async {
    _transport.add(up);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> connect() async => connected = true;

  final Map<String, Completer<void>> _awaited = {};

  @override
  void subscribe(String topic) {
    subscribed.add(topic);
    final waiter = _awaited.remove(topic);
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// Completes once [topic] has been subscribed.
  ///
  /// A broadcast stream drops events that arrive with no listener, so a test
  /// that delivers before the code under test has subscribed is testing the
  /// scheduler. This makes the ordering explicit instead of hoping for it.
  Future<void> whenSubscribed(String topic) {
    if (subscribed.contains(topic)) return Future.value();
    return (_awaited[topic] ??= Completer<void>()).future;
  }

  @override
  void unsubscribe(String topic) {
    unsubscribed.add(topic);
    subscribed.remove(topic);
  }

  @override
  void send(String topic, String command, Object? params) =>
      sent.add(SentMessage(topic, command, params));

  @override
  Future<void> disconnect() async {
    connected = false;
    await _controller.close();
  }

  /// Delivers an inbound message as if the broker had.
  ///
  /// Returns a future that completes once listeners have run, because the
  /// stream is asynchronous — asserting immediately after `deliver` would test
  /// the scheduler, not the code.
  Future<void> deliver(
    String topic,
    String command, [
    List<Object?> parameters = const [],
  ]) async {
    _controller.add(
      AikoMessage(topic, command, PositionalArguments(parameters)),
    );
    await Future<void>.delayed(Duration.zero);
  }
}

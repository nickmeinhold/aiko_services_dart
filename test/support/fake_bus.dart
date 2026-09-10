/// A [MessageBus] with no broker: publishes go into a list, and a test injects
/// inbound payloads directly.
library;

import 'dart:async';

import 'package:aiko_services/aiko_services.dart';

/// One thing this bus was asked to DO, whatever kind of thing it was.
///
/// A single ordered list rather than one list per kind, because the ordering
/// that matters most here is ACROSS kinds: the registrar's promotion is "take
/// the retained will, THEN announce", and a test holding sends and will-changes
/// in separate lists cannot tell that apart from its reverse — which is the one
/// ordering the protocol actually cares about.
sealed class BusAction {
  const BusAction();
}

/// One thing this bus was asked to publish.
final class const SentMessage(
  final String topic,
  final String command,
  final Object? params, {
  final bool retain = false,
}) extends BusAction {
  @override
  String toString() =>
      'SentMessage($topic, $command, $params${retain ? ', retained' : ''})';
}

/// A retained payload the bus was asked to delete.
final class const RetainedCleared(final String topic) extends BusAction {
  @override
  String toString() => 'RetainedCleared($topic)';
}

/// A will change, which on a real bus costs a reconnect.
final class const WillChanged(final LastWill? will) extends BusAction {
  @override
  String toString() => 'WillChanged($will)';
}

class FakeBus implements MessageBus {
  final _controller = StreamController<AikoMessage>.broadcast();

  /// Everything the bus was asked to do, in order and across kinds.
  final List<BusAction> actions = [];

  /// Everything published, in order. A narrower view of [actions] for the
  /// tests that only care about publishes.
  final List<SentMessage> sent = [];

  /// Forget everything recorded so far.
  ///
  /// One method owning BOTH lists. Clearing them separately is the drift this
  /// repo has already paid for three times — a property fixed in one copy and
  /// left standing in its twin.
  void clear() {
    actions.clear();
    sent.clear();
  }

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

  LastWill? _will;

  @override
  LastWill? get will => _will;

  @override
  void send(
    String topic,
    String command,
    Object? params, {
    bool retain = false,
  }) {
    final message = SentMessage(topic, command, params, retain: retain);
    actions.add(message);
    sent.add(message);
  }

  @override
  void clearRetained(String topic) => actions.add(RetainedCleared(topic));

  /// Thrown by the next [setWill], if set.
  ///
  /// A real will change reconnects, and `registrar.py:198` exists because that
  /// can fail — its own comment guesses *"Probably MQTT server not running"*.
  /// A fake that cannot produce the failure cannot clear the handling of it.
  Object? failSetWillWith;

  /// Records the change. The reconnect a real bus pays for is modelled by
  /// [setTransport], so a test can drive the two independently — the point of
  /// the fake is to produce states a live island will not give on demand.
  @override
  Future<void> setWill(LastWill? next) async {
    final failure = failSetWillWith;
    if (failure != null) {
      failSetWillWith = null;
      throw failure;
    }
    if (next == _will) return;
    _will = next;
    actions.add(WillChanged(next));
  }

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

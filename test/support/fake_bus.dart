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

  /// Starts LIVE, because that is what every caller means by handing a bus to a
  /// consumer: you are given a connected wire. Fourteen tests drive an
  /// ECConsumer through `attach()`, which publishes, and none of them models a
  /// connection — requiring one would be ceremony that tests the fake.
  ///
  /// Strict where it counts and lenient where it does not: this fake refuses
  /// publishes AFTER [disconnect] and says nothing about the pre-connect
  /// window. Use-after-teardown is the class that actually bit (a promotion
  /// still publishing at a bus already torn down); publish-before-connect has
  /// never hidden anything here, and a real caller cannot reach it — a process
  /// awaits `connect()` before anything can attach.
  var connected = true;

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

  /// A real client throws `ConnectionException` from `publishMessage` when the
  /// socket is not up. A fake that silently accepts the publish is MORE
  /// FORGIVING THAN THE REAL API, and a fake that is more forgiving hides
  /// exactly the bugs it exists to catch — this one hid a promotion that kept
  /// publishing at a bus `disconnect()` had already torn down.
  void _requireConnected(String what) {
    if (!connected) {
      throw StateError('$what on a bus that is not connected');
    }
  }

  @override
  void send(
    String topic,
    String command,
    Object? params, {
    bool retain = false,
  }) {
    _requireConnected('send($topic)');
    final message = SentMessage(topic, command, params, retain: retain);
    actions.add(message);
    sent.add(message);
  }

  @override
  void clearRetained(String topic) {
    _requireConnected('clearRetained($topic)');
    actions.add(RetainedCleared(topic));
  }

  /// How long [setWill] takes. Zero by default; a real one costs a reconnect,
  /// and the window it opens is where a concurrent [disconnect] lands.
  Duration setWillDelay = Duration.zero;

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
    // The DELAY applies to a failing change too: a real reopen takes time and
    // THEN fails, and throwing instantly makes the mid-promotion window
    // unreachable — which is why a test written against the old fake could not
    // construct the state it claimed to cover.
    if (setWillDelay > Duration.zero) await Future<void>.delayed(setWillDelay);
    final failure = failSetWillWith;
    if (failure != null) {
      failSetWillWith = null;
      // MODEL THE REAL SEQUENCE, not a convenient one. AikoClient assigns the
      // new will, tears the old socket down, and only THEN tries to reopen — so
      // a failure leaves the will ALREADY SET and the connection GONE. This fake
      // used to throw with `connected` still true and `_will` untouched, which
      // is a failure state the real client cannot produce, and it is why the
      // round-2 "stands back down" test stayed green over a defect that left a
      // live registrar permanently deaf (Tesla, round 3). Third time a fake
      // being kinder than the API hid a real bug in this PR.
      _will = next;
      connected = false;
      throw failure;
    }
    // Mirrors AikoClient exactly: the short-circuit is about not paying a
    // reconnect for an ALREADY-ARMED will, so it may only fire when something is
    // armed. Keeping the fake's rule looser than the real one is how the driver
    // test passed over a defect that leaves a live registrar deaf forever.
    if (next == _will && connected) return;
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

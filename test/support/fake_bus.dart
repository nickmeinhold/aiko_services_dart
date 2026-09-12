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
  FakeBus();

  /// A bus handed over already connected.
  ///
  /// For the consumers whose subject is a protocol state machine rather than a
  /// lifecycle — an ECConsumer's snapshot framing, a services cache's two-topic
  /// completion rule. Requiring those to drive a connection would be ceremony
  /// that tests the fake; naming it here keeps the DEFAULT honest.
  FakeBus.alreadyAttached() : _reach = const Attached();

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

  /// Topics the BROKER currently holds for us, in registration order.
  ///
  /// Distinct from [_intended] on purpose. Every CONNECT this port makes carries
  /// `startClean`, so a dropped link throws the broker-side session away while
  /// the application's memory survives — and `_open()`'s restore loop is what
  /// puts them back. A fake with ONE list cannot lose a subscription, so a test
  /// asserting "a subscription survives a reconnect" passes against it even with
  /// the real restore loop deleted: a check whose success value equals its
  /// disabled value.
  final List<String> subscribed = [];

  /// The application's memory — what we WANT subscribed, surviving any outage.
  /// Mirrors `AikoClient._subscriptions`.
  final Set<String> _intended = {};

  /// Topics that were unsubscribed.
  final List<String> unsubscribed = [];

  /// Starts [NotStarted], like a real bus.
  ///
  /// It did not used to. A fake that hands out a live wire nobody asked for is
  /// MORE FORGIVING THAN THE REAL API, and a fake that is more forgiving hides
  /// exactly the bugs it exists to catch — three times in this subsystem
  /// already. Tests that legitimately begin with a connected bus say so, with
  /// [FakeBus.alreadyAttached].
  Reach _reach = const NotStarted();

  @override
  Reach get reach => _reach;

  final _transport = StreamController<bool>.broadcast();

  @override
  Stream<AikoMessage> get messages => _controller.stream;

  @override
  Stream<bool> get transportUp => _transport.stream;

  bool? _reported;

  void _report({required bool up}) {
    if (_transport.isClosed || _reported == up) return;
    _reported = up;
    _transport.add(up);
  }

  /// Drop the link, as a broker outage would. Lands in [Detached].
  ///
  /// The real bus arms a timer here. This fake models the supervisor as a
  /// METHOD instead — [restoreLink] — so a test drives recovery explicitly
  /// rather than waiting out a backoff.
  Future<void> setTransport({required bool up}) async {
    if (up) {
      await restoreLink();
    } else {
      _reach = const Detached();
      // The broker-side session goes with the link. The memory does not.
      subscribed.clear();
      _report(up: false);
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Perform what the supervisor's next `_open()` would: re-attach carrying the
  /// current will, with every recorded subscription restored.
  Future<void> restoreLink() async {
    _reach = const Attached();
    // PERFORM WHAT `_open()` WOULD: walk the memory and reinstall every topic.
    // Deleting this loop must break a test, which is the whole reason the two
    // lists are separate.
    subscribed
      ..clear()
      ..addAll(_intended);
    for (final topic in _intended) {
      final waiter = _awaited.remove(topic);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
    _report(up: true);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> connect() async {
    switch (_reach) {
      case Retired():
        throw StateError(
          'cannot connect: this bus is retired — construct a new AikoClient',
        );
      case Attached():
        return;
      case Detached():
        throw const TransportUnavailable('connect');
      case NotStarted():
        _reach = const Attached();
        // Walk the memory, exactly as `_open()` does. `subscribe` before
        // `connect` is a documented, load-bearing path in AikoClient — the set
        // IS the memory — and a fake that attached with an empty broker list
        // could not fail a test about it (Tesla, round 3; third instance of
        // this fake's restore-loop class).
        subscribed
          ..clear()
          ..addAll(_intended);
        _report(up: true);
    }
  }

  final Map<String, Completer<void>> _awaited = {};

  @override
  void subscribe(String topic) {
    if (_reach case Retired()) {
      throw StateError('cannot subscribe: this bus is retired');
    }
    _intended.add(topic);
    // Recorded but NOT live while the link is down, exactly as the real bus
    // does: the record alone is correct because [restoreLink] walks the set.
    if (_reach case Attached()) subscribed.add(topic);
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
    // NO Retired guard, matching [AikoClient]: `subscribe` on a retired bus asks
    // for something it cannot have, `unsubscribe` asks us to FORGET, and
    // forgetting is always satisfiable. This fake carried the guard for one
    // round AFTER production dropped it — a fake STRICTER than the real API,
    // which is the same contract drift as a fake that is kinder, just pointing
    // the other way. `bus_contract_test.dart` now runs one body against both.
    unsubscribed.add(topic);
    _intended.remove(topic);
    subscribed.remove(topic);
  }

  LastWill? _will;

  @override
  LastWill? get will => _will;

  /// Refuse exactly as [AikoClient] does, with the same TYPES.
  ///
  /// The type is the whole point: a down link is [TransportUnavailable] and a
  /// caller error is [StateError], so the election above can tell a bug from
  /// weather. A fake that threw one shape for both would make that distinction
  /// untestable — and this fake has already hidden a promotion that kept
  /// publishing at a bus `disconnect()` had torn down.
  void _requirePublishable(String what) {
    switch (_reach) {
      case Attached():
        return;
      case Detached():
        throw TransportUnavailable(what);
      case NotStarted():
        throw StateError('cannot $what: connect() has not run');
      case Retired():
        throw StateError('cannot $what: this bus is retired');
    }
  }

  @override
  void send(
    String topic,
    String command,
    Object? params, {
    bool retain = false,
  }) {
    _requirePublishable('send to $topic');
    final message = SentMessage(topic, command, params, retain: retain);
    actions.add(message);
    sent.add(message);
  }

  @override
  void clearRetained(String topic) {
    _requirePublishable('clear the retained payload on $topic');
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
      // ASK RETIRED FIRST. A delayed failing setWill racing a `disconnect()`
      // would otherwise overwrite `Retired` with `Detached` and UN-RETIRE the
      // bus — a terminal state that is not terminal (Tesla, round 3).
      if (_reach is! Retired) {
        _reach = const Detached();
        subscribed.clear();
        _report(up: false);
      }
      throw failure;
    }
    // Mirrors AikoClient exactly: the short-circuit is about not paying a
    // reconnect for an ALREADY-ARMED will, so it may only fire when something is
    // armed. Keeping the fake's rule looser than the real one is how the driver
    // test passed over a defect that leaves a live registrar deaf forever.
    switch (_reach) {
      case Retired():
        throw StateError('cannot set a will: this bus is retired');
      case NotStarted():
        _will = next;
        return;
      case Detached():
        // RECORD AND REFUSE, exactly as the real bus does: the supervisor's next
        // open carries it, and opening here would be a second opener.
        _will = next;
        throw const TransportUnavailable('set a will while the link is down');
      case Attached():
        if (next == _will) return;
        _will = next;
        actions.add(WillChanged(next));
    }
  }

  @override
  Future<void> disconnect() async {
    _reach = const Retired();
    await _controller.close();
    await _transport.close();
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

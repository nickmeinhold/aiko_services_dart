/// The supervisor, driven against a REAL failing connect.
///
/// Port 1 refuses immediately, so every `_open()` here is the production opener
/// really failing — not a stub standing in for one. What the fake timers remove
/// is the WAITING, not the mechanism: `FakeTimers.scheduled` records the
/// durations the supervisor asked for, which turns a two-minute assertion about
/// a backoff into a list comparison.
library;

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_timers.dart';

AikoClient _deadBroker(FakeTimers timers) =>
    AikoClient(host: '127.0.0.1', port: 1, createTimer: timers.create);

void main() {
  group('a failed first connect is owned', () {
    test('lands in Detached with recovery ARMED, not merely down', () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);

      await expectLater(
        client.connect(),
        throwsA(isA<TransportUnavailable>()),
      );

      // INSTANCE 6'S ARM. `reach == Detached` is `_started && !connected`, which
      // is NOT `_retry != null` — the previous revision had a table SAYING the
      // supervisor owned this state and no code that armed it here. A comment is
      // not a timer.
      expect(client.reach, isA<Detached>());
      expect(
        timers.hasPending,
        isTrue,
        reason: 'nothing else will ever try again',
      );
      expect(timers.scheduled.single, AikoClient.backoffMin);

      await client.disconnect();
    });

    test('send reports a TRANSIENT there, not a caller error', () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));

      // Honest: the caller DID ask, and something is actually working on it.
      // The type is what lets the election tell a bug from weather.
      expect(
        () => client.send('a/b', 'x', const <Object?>[]),
        throwsA(isA<TransportUnavailable>()),
      );
      await client.disconnect();
    });

    test('connect() on Detached REFUSES rather than opening a second time',
        () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));
      final openedSoFar = timers.scheduled.length;

      // The supervisor owns opening. A caller that opens here is the second
      // opener that made a failing promotion into an unbounded CONNECT storm.
      await expectLater(
        client.connect(),
        throwsA(isA<TransportUnavailable>()),
      );
      expect(
        timers.scheduled,
        hasLength(openedSoFar),
        reason: 'a refused connect must not schedule anything',
      );
      await client.disconnect();
    });

    test('setWill on Detached RECORDS and refuses', () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));

      const next = LastWill(topic: 'a/b/0/state', payload: '(absent)');
      await expectLater(
        client.setWill(next),
        throwsA(isA<TransportUnavailable>()),
      );
      // Intent does not become false because a socket failed to carry it: the
      // supervisor's next open builds its CONNECT from this.
      expect(client.will, next);
      await client.disconnect();
    });
  });

  group('backoff shape', () {
    test('doubles 1s to 120s and CAPS there — paho numbers, run not reasoned',
        () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));

      // Nine more real failing attempts. Each fire runs the production
      // `_open()`, which really tries to connect and really fails — so what the
      // fake removes is the WAITING, not the mechanism.
      for (var attempt = 2; attempt <= 10; attempt++) {
        timers.fireNext();
        await timers.whenScheduled(attempt);
      }

      expect(
        timers.scheduled.map((d) => d.inSeconds).toList(),
        [1, 2, 4, 8, 16, 32, 64, 120, 120, 120],
      );
      await client.disconnect();
    });

    test('exactly one recovery owner across the whole sequence', () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));

      for (var attempt = 2; attempt <= 6; attempt++) {
        expect(
          timers.pending,
          hasLength(1),
          reason: 'two pending timers is two racing loops',
        );
        timers.fireNext();
        await timers.whenScheduled(attempt);
      }
      await client.disconnect();
    });
  });

  group('retirement', () {
    test('disconnect DISARMS the supervisor', () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));
      expect(timers.hasPending, isTrue);

      await client.disconnect();

      // Cancelled synchronously, before any await: a teardown whose purpose is
      // promptness must not leave a loop running behind it.
      expect(timers.hasPending, isFalse);
      expect(client.reach, isA<Retired>());
    });

    test('unsubscribe after disconnect does NOT throw — teardown is idempotent',
        () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));
      client.subscribe('aiko/x/1/1/out');
      await client.disconnect();

      // ECConsumer.terminate() reaches TopicRouter.removeHandler, which
      // unsubscribes a topic when its last handler goes — and that can run after
      // the bus is gone. `subscribe` refusing on Retired is right (it asks for
      // something it cannot have); `unsubscribe` refusing is not, because
      // forgetting is always satisfiable. An earlier draft threw here for
      // symmetry and turned an idempotent cleanup into an unhandled StateError
      // out of an async drain.
      expect(() => client.unsubscribe('aiko/x/1/1/out'), returnsNormally);
      expect(() => client.unsubscribe('never/subscribed'), returnsNormally);
    });

    test('a retired bus is never reopened', () async {
      final timers = FakeTimers();
      final client = _deadBroker(timers);
      await expectLater(client.connect(), throwsA(isA<TransportUnavailable>()));
      await client.disconnect();

      // StateError, not TransportUnavailable: nothing is working on this and
      // nothing ever will. The client id is the island's notion of who we are,
      // and re-minting it inside a method called connect() would make wire
      // identity depend on which method a caller reached for.
      await expectLater(client.connect(), throwsA(isA<StateError>()));
      expect(
        () => client.send('a/b', 'x', const <Object?>[]),
        throwsA(isA<StateError>()),
      );
      expect(() => client.subscribe('a/b'), throwsA(isA<StateError>()));
    });
  });
}

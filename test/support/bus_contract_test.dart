/// ONE body of assertions, run against BOTH implementations of [MessageBus].
///
/// The design (§9) asks for exactly this and it did not exist. Two revisions
/// promised fake/real parity in prose and were struck for it; this round it
/// happened again in the *other* direction — production dropped the `Retired`
/// guard on `unsubscribe` and the fake kept it, so the fake became STRICTER than
/// the API it models. A fake that is kinder hides bugs; a fake that is stricter
/// invents them. Both are contract drift, and prose cannot catch either.
///
/// Scope, stated rather than implied: these are the refusals reachable with NO
/// broker. `Attached`-state behaviour needs a live link and lives in
/// `spike/transport-lifecycle/`.
library;

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import 'fake_bus.dart';

/// Builds a bus that has been started and then retired.
typedef BusFactory = Future<MessageBus> Function();

Future<MessageBus> _retiredFake() async {
  final bus = FakeBus();
  await bus.connect();
  bus.subscribe('aiko/a/1/1/out');
  await bus.disconnect();
  return bus;
}

Future<MessageBus> _retiredReal() async {
  // Port 1 refuses, so this never touches a broker. A failed connect still
  // marks the bus STARTED, which is the state we want to retire from.
  final bus = AikoClient(host: '127.0.0.1', port: 1);
  try {
    await bus.connect();
  } on TransportUnavailable {
    // expected
  }
  bus.subscribe('aiko/a/1/1/out');
  await bus.disconnect();
  return bus;
}

void main() {
  final implementations = <String, BusFactory>{
    'FakeBus': _retiredFake,
    'AikoClient': _retiredReal,
  };

  implementations.forEach((name, retired) {
    group('$name, retired', () {
      test('reports Retired', () async {
        expect((await retired()).reach, isA<Retired>());
      });

      test('unsubscribe is PERMITTED — forgetting is always satisfiable',
          () async {
        final bus = await retired();
        expect(() => bus.unsubscribe('aiko/a/1/1/out'), returnsNormally);
        expect(() => bus.unsubscribe('never/subscribed'), returnsNormally);
      });

      test('subscribe is REFUSED — it asks for what it cannot have', () async {
        final bus = await retired();
        expect(() => bus.subscribe('aiko/b/2/1/out'), throwsStateError);
      });

      test('send is a caller error, not weather', () async {
        final bus = await retired();
        expect(
          () => bus.send('aiko/b/2/1/out', 'x', const <Object?>[]),
          throwsStateError,
        );
      });

      test('connect is refused terminally', () async {
        final bus = await retired();
        await expectLater(bus.connect(), throwsStateError);
      });

      test('setWill is refused terminally', () async {
        final bus = await retired();
        await expectLater(
          bus.setWill(
            const LastWill(topic: 'a/b/0/state', payload: '(absent)'),
          ),
          throwsStateError,
        );
      });
    });
  });
}

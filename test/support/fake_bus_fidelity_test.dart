/// The fake must be able to PRODUCE the failure the real restore loop prevents.
///
/// Every CONNECT this port makes carries `startClean`, so a dropped link throws
/// the broker-side session away while the application's memory survives. A fake
/// with one subscription list cannot lose anything, so a test asserting "a
/// subscription survives a reconnect" passes against it even with the real
/// `_open()` restore loop deleted — a check whose success value equals its
/// disabled value.
library;

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import 'fake_bus.dart';

void main() {
  test('a dropped link loses the BROKER-side subscription', () async {
    final bus = FakeBus();
    await bus.connect();
    bus.subscribe('aiko/a/1/1/out');
    expect(bus.subscribed, contains('aiko/a/1/1/out'));

    await bus.setTransport(up: false);
    // The negative control. If this still contained the topic, the assertion
    // below could not distinguish a working restore from no loss at all.
    expect(
      bus.subscribed,
      isEmpty,
      reason: 'startClean throws the broker session away',
    );
  });

  test('restoreLink replays the memory, including a topic taken while down',
      () async {
    final bus = FakeBus();
    await bus.connect();
    bus.subscribe('aiko/a/1/1/out');
    await bus.setTransport(up: false);

    // Recorded with no socket at all — the record alone is correct because the
    // supervisor's next open walks the set.
    bus.subscribe('aiko/b/2/1/out');
    expect(bus.subscribed, isEmpty);

    await bus.restoreLink();
    expect(bus.subscribed, containsAll(['aiko/a/1/1/out', 'aiko/b/2/1/out']));
  });

  test('subscribe BEFORE connect reaches the broker on connect', () async {
    final bus = FakeBus();
    // A documented, load-bearing path in AikoClient: the set IS the memory, and
    // `_open()` walks it on the FIRST connect as well as on a reopen.
    bus.subscribe('aiko/a/1/1/out');
    expect(bus.subscribed, isEmpty, reason: 'no socket yet');

    await bus.connect();
    expect(bus.subscribed, contains('aiko/a/1/1/out'));
  });

  test('a failing setWill does NOT un-retire a bus', () async {
    final bus = FakeBus()
      ..setWillDelay = const Duration(milliseconds: 30)
      ..failSetWillWith = StateError('reopen failed');
    await bus.connect();

    // Leave while the will change is in flight. Terminal must stay terminal:
    // the failure path used to overwrite Retired with Detached.
    final inFlight = bus.setWill(
      const LastWill(topic: 'a/b/0/state', payload: '(absent)'),
    );
    await bus.disconnect();
    await expectLater(inFlight, throwsA(isA<Object>()));

    expect(bus.reach, isA<Retired>(), reason: 'Retired is terminal');
  });

  test('unsubscribing while down means it is NOT replayed', () async {
    final bus = FakeBus();
    await bus.connect();
    bus.subscribe('aiko/a/1/1/out');
    await bus.setTransport(up: false);
    bus.unsubscribe('aiko/a/1/1/out');

    await bus.restoreLink();
    expect(bus.subscribed, isEmpty);
  });
}

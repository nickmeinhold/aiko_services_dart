import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_bus.dart';

const _in = 'aiko/testhost/7/1/in';
const _out = 'aiko/testhost/7/1/out';
const _reply = 'aiko/asker/3/1/registrar_history';

Future<void> settle() async {
  for (var turn = 0; turn < 20; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A clock that ticks one second per reading, so every timestamp in a test is
/// distinct and the ORDER of the readings is visible in the values.
///
/// Deterministic on purpose: the wall clock is the one input here that would
/// otherwise make an assertion about `time_add`/`time_remove` either vacuous
/// (assert it parses) or flaky (assert a real elapsed time).
class _TickingClock {
  var _seconds = 1000;
  String call() => (_seconds++).toDouble().toStringAsFixed(6);
}

RegistrarProcess _process(FakeBus bus, WallClock now) => RegistrarProcess(
  host: 'testhost',
  processId: 7,
  bus: bus,
  searchTimeout: const Duration(seconds: 30),
  now: now,
);

List<Object?> _add(String path, {String name = 'chat_server'}) => [
  path,
  name,
  'github.com/x/protocol/$name:0',
  'mqtt',
  'root',
  ['ec=true'],
];

void main() {
  late FakeBus bus;
  late RegistrarProcess registrar;
  late _TickingClock clock;

  setUp(() async {
    bus = FakeBus();
    clock = _TickingClock();
    registrar = _process(bus, clock.call);
    await registrar.connect();
    bus.clear();
  });

  tearDown(() => registrar.disconnect());

  /// Everything published to the reply topic, which is where a history answer
  /// goes. Deliberately NOT filtered to `add`, so a stray verb shows up.
  List<SentMessage> replies() =>
      bus.sent.where((m) => m.topic == _reply).toList(growable: false);

  Future<void> ask(Object? count) async {
    await bus.deliver(_in, 'history', [_reply, count]);
    await settle();
  }

  group('the empty case, which is the one a fresh island is always in', () {
    test('an empty buffer answers (item_count 0) and nothing else', () async {
      await ask(16);

      expect(replies().length, 1);
      expect(replies().single.command, 'item_count');
      expect(replies().single.params, [0]);
    });

    test('a LIVE service is not history — only a departed one is', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      bus.clear();

      await ask(16);

      // The roster has one service and the history has none. If this ever goes
      // green by returning the live roster, the verb is answering the wrong
      // question in the most plausible wrong way.
      expect(registrar.roster.count, 1);
      expect(replies().single.params, [0]);
    });
  });

  group('a departure is recorded, with both timestamps', () {
    test('remove puts the service in history with time_add and '
        'time_remove', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      await bus.deliver(_in, 'remove', ['aiko/h/1/1']);
      await settle();
      bus.clear();

      await ask(16);

      final answer = replies();
      expect(answer.first.command, 'item_count');
      expect(answer.first.params, [1]);

      final record = answer[1];
      expect(record.command, 'add');
      final params = record.params! as List<Object?>;
      // EIGHT, not six: the live-roster six plus time_add and time_remove.
      // `registrar.py:317-326`.
      expect(params.length, 8);
      expect(params[0], 'aiko/h/1/1');
      expect(params[5], ['ec=true']);
      // The add was read before the remove, so the clock's earlier value is
      // time_add. Asserting the ORDER rather than the literals would pass on a
      // pair of identical timestamps, which is the bug a coarse clock produces.
      final timeAdd = double.parse(params[6]! as String);
      final timeRemove = double.parse(params[7]! as String);
      expect(timeAdd, lessThan(timeRemove));
    });

    test('a history answer sends NO (sync ...) — that is the share '
        'protocol, not this one', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      await bus.deliver(_in, 'remove', ['aiko/h/1/1']);
      await settle();
      bus.clear();

      await ask(16);

      // `services_history` (`registrar.py:307-328`) publishes item_count and the
      // adds, and stops. `services_share` is the one that completes with a sync
      // on the registrar's own /out. Copying the share's shape here would be
      // the easiest wrong move available.
      expect(bus.sent.where((m) => m.topic == _out), isEmpty);
      expect(bus.sent.every((m) => m.topic == _reply), isTrue);
    });

    test('a process death records EVERY service it hosted', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1', name: 'a'));
      await bus.deliver(_in, 'add', _add('aiko/h/1/2', name: 'b'));
      await settle();
      // Service `0` is the PROCESS. This is the path the BROKER takes on our
      // behalf when a process is killed, so it is the departure that matters
      // most and the one a deregistering service never sends.
      await bus.deliver(_in, 'remove', ['aiko/h/1/0']);
      await settle();
      bus.clear();

      await ask(16);

      expect(replies().first.params, [2]);
      final records = replies().skip(1).toList();
      final paths = records
          .map((m) => (m.params! as List<Object?>).first)
          .toList();
      expect(paths, containsAll(<Object?>['aiko/h/1/1', 'aiko/h/1/2']));

      // ONE time_remove for the whole batch, not one per service. A process
      // death is a SINGLE event — the broker published one Last Will — so
      // staggered removal times would invent a sequence the wire never carried.
      //
      // Tesla, cage-match round 2: `_recordDepartures` reads the clock once by
      // design and nothing asserted it. `containsAll` above passes either way,
      // and `_TickingClock` ticks per reading, so a per-service `_now()` would
      // have produced two distinct stamps in silence.
      final removals = records
          .map((m) => (m.params! as List<Object?>)[7])
          .toSet();
      expect(removals, hasLength(1), reason: 'one death, one timestamp');
    });
  });

  group('the ring buffer, and the count', () {
    test('newest first', () async {
      for (final id in [1, 2, 3]) {
        await bus.deliver(_in, 'add', _add('aiko/h/1/$id'));
        await settle();
        await bus.deliver(_in, 'remove', ['aiko/h/1/$id']);
        await settle();
      }
      bus.clear();

      await ask(16);

      final paths = replies()
          .skip(1)
          .map((m) => (m.params! as List<Object?>).first)
          .toList();
      // `appendleft` (`registrar.py:394`) — the most recent departure is the
      // head, so a consumer asking for 1 gets the latest and not the oldest.
      expect(paths, ['aiko/h/1/3', 'aiko/h/1/2', 'aiko/h/1/1']);
    });

    test('a count SMALLER than the buffer truncates, keeping the '
        'newest', () async {
      for (final id in [1, 2, 3]) {
        await bus.deliver(_in, 'add', _add('aiko/h/1/$id'));
        await settle();
        await bus.deliver(_in, 'remove', ['aiko/h/1/$id']);
        await settle();
      }
      bus.clear();

      await ask(2);

      expect(replies().first.params, [2]);
      final paths = replies()
          .skip(1)
          .map((m) => (m.params! as List<Object?>).first)
          .toList();
      expect(paths, ['aiko/h/1/3', 'aiko/h/1/2']);
    });

    test('a count LARGER than the buffer is clamped, and the count '
        'published matches what is sent', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      await bus.deliver(_in, 'remove', ['aiko/h/1/1']);
      await settle();
      bus.clear();

      await ask(500);

      // `if len(self.history) < count: count = len(self.history)`
      // (`registrar.py:308-309`). The published count and the number of records
      // must agree, or a consumer counting down to zero never completes the
      // frame.
      expect(replies().first.params, [1]);
      expect(replies().skip(1).length, 1);
    });

    test('roster.clear() forgets the LIVING and keeps the DEAD — the '
        'asymmetry upstream has', () async {
      // Tesla, cage-match round 1: this behaviour was documented at `clear()`
      // and tested nowhere, so the doc was an assertion rather than a fact.
      // `registrar.py:281` rebinds `self.services` and never touches
      // `self.history`, so a `(primary absent)` roster wipe leaves the already-
      // departed still speaking while the living vanish with no record at all.
      final roster = ServiceRoster(now: clock.call);
      final departed = ServiceDetails.tryParse(_add('aiko/h/1/1'))!;
      final living = ServiceDetails.tryParse(_add('aiko/h/1/2'))!;

      roster.add(departed);
      roster.remove(departed.topicPath); // a real departure — recorded
      roster.add(living); // still here when the wipe lands

      roster.clear();

      expect(roster.count, 0, reason: 'the living are gone');
      expect(roster.history.length, 1, reason: 'the dead keep speaking');
      expect(roster.history.single.details.topicPath.path, 'aiko/h/1/1');
      // And the consequence worth pinning: the living left NO trace. A consumer
      // cannot read "absent from the roster and absent from history" as
      // anything, because that is exactly what a wiped service looks like.
      expect(
        roster.history.map((d) => d.details.topicPath.path),
        isNot(contains('aiko/h/1/2')),
      );
    });

    test('history is an UNMODIFIABLE view — a caller cannot drain the '
        'ring buffer through a getter', () async {
      final roster = ServiceRoster(now: clock.call);
      final details = ServiceDetails.tryParse(_add('aiko/h/1/1'))!;
      roster.add(details);
      roster.remove(details.topicPath);

      expect(roster.history.length, 1);
      // Returning the internal ListQueue typed as Iterable would make this
      // succeed and silently empty the buffer.
      expect(
        () => (roster.history as List<ServiceDeparture>).clear(),
        throwsUnsupportedError,
      );
      expect(roster.history.length, 1, reason: 'still intact');
    });

    test('BOTH ring-buffer constants match the reference, by value', () {
      // Tesla, cage-match round 3 — and this is the SIBLING of round 1's
      // finding, not a new one. Round 1 pinned `_historyLimitDefault` (16) and
      // left its twin unpinned: mutating `defaultHistoryLimit` 4096 -> 40 left
      // the whole suite green, because every other arm only needs the bound to
      // be "bigger than this test's corpses".
      //
      // Fixing the instance a reviewer points at and leaving its twin standing
      // is a class this repo has paid for before. Both constants are pinned
      // here, together, against the reference's own numbers:
      //   `_HISTORY_RING_BUFFER_SIZE = 4096` (`registrar.py:135`)
      //   `_HISTORY_LIMIT_DEFAULT    = 16`   (`registrar.py:134`)
      expect(ServiceRoster.defaultHistoryLimit, 4096);
      // The default count has no public symbol — it is asserted through the
      // wire in "the fallback is SIXTEEN", which fills the buffer past 16 so
      // the number is observable rather than coincidental.
    });

    test('the buffer is BOUNDED — it does not grow without limit', () async {
      // Smaller than the 4096 default would be untestable at speed, so the
      // bound itself is exercised on the roster directly. The wire path above
      // proves the plumbing; this proves the thing that keeps a long-lived
      // registrar from growing forever.
      final roster = ServiceRoster(now: clock.call, historyLimit: 3);
      for (final id in [1, 2, 3, 4, 5]) {
        final details = ServiceDetails.tryParse(_add('aiko/h/1/$id'))!;
        roster.add(details);
        roster.remove(details.topicPath);
      }

      expect(roster.history.length, 3);
      expect(roster.history.map((d) => d.details.topicPath.path), [
        'aiko/h/1/5',
        'aiko/h/1/4',
        'aiko/h/1/3',
      ]);
    });
  });

  group('what the verb refuses', () {
    test('a count that is not a number falls back to the default, '
        'rather than dropping the request', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      await bus.deliver(_in, 'remove', ['aiko/h/1/1']);
      await settle();
      bus.clear();

      // `parse_int` failing is not an error upstream — `registrar.py:298-303`
      // substitutes `_HISTORY_LIMIT_DEFAULT`. A request that silently produced
      // nothing would be indistinguishable from an empty island.
      await ask('not-a-number');

      expect(replies().first.params, [1]);
      expect(replies().skip(1).length, 1);
    });

    test('a NEGATIVE count reproduces upstream faithfully — including the '
        'frame a consumer can never complete', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      await bus.deliver(_in, 'remove', ['aiko/h/1/1']);
      await settle();
      bus.clear();

      await ask(-5);

      // THIS PINS A DEFECT, it does not endorse one. `registrar.py:308-309`
      // clamps only downward, so a negative count survives, `(item_count -5)`
      // is published, and `if count < 1: break` then sends nothing. A consumer
      // counting down to zero never finishes the frame.
      //
      // Clamping to 0 here would be a one-character fix and a unilateral
      // divergence — see claude-tasks#4306. If this test ever goes red because
      // somebody "fixed" it, the fix is the thing to question, not the test.
      expect(replies().single.command, 'item_count');
      expect(replies().single.params, [-5]);
    });

    test('the fallback is SIXTEEN — the default value itself, not merely '
        '"we did not drop the request"', () async {
      // Tesla, cage-match round 1: the fallback arm above asked with ONE corpse
      // in the buffer, so min(16, 1) and min(4096, 1) are both 1 and swapping
      // the default changed nothing. Measured: 16 -> 4096 left the suite GREEN.
      // A check whose success value equals its disabled value cannot report its
      // own absence — the exact class this repo's reviewer brief hunts.
      //
      // Twenty departures makes the constant observable: 16 comes back, not 20
      // and not 4096.
      for (var id = 1; id <= 20; id++) {
        await bus.deliver(_in, 'add', _add('aiko/h/1/$id'));
        await settle();
        await bus.deliver(_in, 'remove', ['aiko/h/1/$id']);
        await settle();
      }
      bus.clear();

      await ask('not-a-number');

      expect(replies().first.params, [16]);
      expect(replies().skip(1).length, 16);
    });

    test('count parsing matches CPython int(), not Dart int.tryParse', () async {
      for (var id = 1; id <= 40; id++) {
        await bus.deliver(_in, 'add', _add('aiko/h/1/$id'));
        await settle();
        await bus.deliver(_in, 'remove', ['aiko/h/1/$id']);
        await settle();
      }

      // `0x20`: CPython's base-10 int() raises, so upstream falls back to 16.
      // Dart's int.tryParse would read it as 32 — a silent divergence where the
      // same request draws a different answer from each implementation.
      bus.clear();
      await ask('0x20');
      expect(replies().first.params, [
        16,
      ], reason: '0x20 is not a number to CPython');

      // `1_000`: CPython has accepted digit underscores since PEP 515, so
      // upstream reads 1000 and clamps to the buffer. Dart's int.tryParse
      // returns null, which would have fallen back to 16.
      bus.clear();
      await ask('1_000');
      expect(replies().first.params, [40], reason: 'PEP 515 underscores parse');

      // The shapes both already agreed on, kept so a future "simplification"
      // back to int.tryParse cannot pass by satisfying only the two rows above.
      for (final (atom, expected) in <(String, int)>[
        ('3', 3),
        ('  3  ', 3),
        ('+3', 3),
        ('3.0', 16),
        ('_1', 16),
        ('1__0', 16),
        // TRAILING underscore, which CPython also rejects. Tesla, round 2: the
        // doc comment names `1_` as illegal and the table did not cover it, so
        // a "simplification" to `^\d[\d_]*$` would read it as 1 where upstream
        // falls back to 16 — and this table, which exists to prevent exactly
        // that, would still have glowed green.
        ('1_', 16),
      ]) {
        bus.clear();
        await ask(atom);
        expect(replies().first.params, [expected], reason: 'atom "$atom"');
      }
    });

    test('a count too big for a 64-bit int still behaves like CPython — '
        'BOTH signs', () async {
      // Carnot, cage-match round 4, found inside the function round 1 added to
      // eliminate this exact class. CPython's `int` is arbitrary precision;
      // Dart's is 64-bit, so `int.tryParse` returned null on overflow and an
      // oversized count silently became the default.
      //
      // Measured against CPython with a 40-entry buffer:
      //   999…999  -> (item_count 40)      clamped to the buffer
      //  -999…999  -> (item_count -999…999) published verbatim
      for (var id = 1; id <= 40; id++) {
        await bus.deliver(_in, 'add', _add('aiko/h/1/$id'));
        await settle();
        await bus.deliver(_in, 'remove', ['aiko/h/1/$id']);
        await settle();
      }
      const huge = '999999999999999999999999999999';

      // POSITIVE: clamps to the buffer, and actually sends that many.
      bus.clear();
      await ask(huge);
      expect(replies().first.params, [40]);
      expect(replies().skip(1).length, 40);

      // NEGATIVE — the row Carnot did not name, and the worse of the two.
      // Upstream's one-sided clamp leaves it untouched and the f-string prints
      // every digit, so the only Dart type that can say it is a BigInt. The
      // atom goes out as digits, which `generate` renders identically to an
      // int (measured: `(x 40)` from both 40 and '40').
      bus.clear();
      await ask('-$huge');
      expect(replies().single.command, 'item_count');
      expect(replies().single.params, ['-$huge']);
    });

    test('a reply topic we will not publish to gets nothing', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      await bus.deliver(_in, 'remove', ['aiko/h/1/1']);
      await settle();
      bus.clear();

      // Same gate the share path uses. A wildcard is the case paho itself
      // refuses, so publishing it would throw rather than merely misdeliver.
      await bus.deliver(_in, 'history', ['aiko/+/1/1/x', 16]);
      await settle();

      expect(bus.sent, isEmpty);
    });

    test('the wrong arity is dropped, not guessed at', () async {
      await bus.deliver(_in, 'history', [_reply]);
      await settle();

      // `len(parameters) == 2` (`registrar.py:298`). One parameter is not a
      // history request with a default; it is not a history request.
      expect(bus.sent, isEmpty);
    });
  });
}

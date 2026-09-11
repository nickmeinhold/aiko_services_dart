import 'dart:async';

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_bus.dart';

/// Let every microtask-bound effect finish.
///
/// The driver performs effects through an async queue because one of them
/// reconnects, so a synchronous assertion after `deliver` would be testing the
/// scheduler. Everything the fake does completes in microtasks, so a bounded
/// number of turns is enough — and bounded rather than open so a hang fails
/// here rather than in the suite's global timeout.
Future<void> settle() async {
  for (var turn = 0; turn < 20; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const _bootTopic = 'aiko/service/registrar';

RegistrarProcess _process(
  FakeBus bus, {
  Duration searchTimeout = const Duration(milliseconds: 40),
}) => RegistrarProcess(
  host: 'testhost',
  processId: 7,
  bus: bus,
  searchTimeout: searchTimeout,
);

/// An announcement from SOMEBODY ELSE — a different host, so nothing here can
/// pass by accidentally reading our own path back.
Future<void> _deliverFound(FakeBus bus) => bus.deliver(
  _bootTopic,
  'primary',
  const ['found', 'aiko/otherhost/99/1', 2, '12345.6'],
);

Future<void> _deliverAbsent(FakeBus bus) =>
    bus.deliver(_bootTopic, 'primary', const ['absent']);

void main() {
  group('RegistrarProcess identity', () {
    test('announces a SERVICE path, not the process path', () {
      final process = _process(FakeBus());
      // The live island publishes `aiko/{host}/{pid}/1`. Service `0` is the
      // process itself; a registrar is a service that process hosts.
      expect(process.topicPath.path, 'aiko/testhost/7/1');
      expect(process.topicPath.isProcess, isFalse);
    });

    test('the boot topic is the one retained topic in Aiko', () {
      expect(_process(FakeBus()).bootTopic, _bootTopic);
    });

    test('a primary holds a RETAINED will, unlike a plain process', () {
      final process = _process(FakeBus());
      expect(process.primaryWill.topic, _bootTopic);
      expect(process.primaryWill.payload, '(primary absent)');
      // The flag is the whole difference between the two wills Aiko has: a late
      // joiner must be able to learn primacy was lost without asking.
      expect(process.primaryWill.retain, isTrue);
    });
  });

  group('joining an island that already has a primary', () {
    test('stands down to secondary and announces NOTHING', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      bus.clear();

      await _deliverFound(bus);
      await settle();

      expect(process.role, RegistrarRole.secondary);
      // The negative half, and the one that matters: a second registrar that
      // announced itself would put two retained `found` payloads on one topic.
      expect(
        bus.actions.whereType<SentMessage>().where(
          (sent) => sent.topic == _bootTopic,
        ),
        isEmpty,
        reason: 'a secondary must not touch the boot topic',
      );
      expect(bus.actions.whereType<WillChanged>(), isEmpty);
      expect(bus.actions.whereType<RetainedCleared>(), isEmpty);
      await process.disconnect();
    });

    test('records how long the announcement took to arrive', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      expect(process.announcementLatency, isNull);

      await _deliverFound(bus);
      await settle();

      // The margin against the 2s promotion timer. A number, not a boolean,
      // because the question the live probe asks is "how much room is there".
      expect(process.announcementLatency, isNotNull);
      expect(
        process.announcementLatency!,
        lessThan(const Duration(seconds: 2)),
      );
      await process.disconnect();
    });

    test('the timer does not promote us after we stood down', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      await _deliverFound(bus);
      await settle();

      // Outlive the search timeout. A driver that handed back a stale epoch —
      // or none — would promote here, onto an island that already has a
      // primary.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(process.role, RegistrarRole.secondary);
      await process.disconnect();
    });
  });

  group('joining an island with no primary', () {
    test(
      'promotes on (primary absent) without waiting out the timer',
      () async {
        final bus = FakeBus();
        final process = _process(
          bus,
          searchTimeout: const Duration(seconds: 30),
        );
        await process.connect();
        bus.clear();

        await _deliverAbsent(bus);
        await settle();

        expect(process.role, RegistrarRole.primary);
        await process.disconnect();
      },
    );

    test('promotes when nothing answers before the timer', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      expect(process.role, RegistrarRole.primarySearch);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();

      expect(process.role, RegistrarRole.primary);
      await process.disconnect();
    });

    test('takes the retained will BEFORE it announces', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      bus.clear();

      await _deliverAbsent(bus);
      await settle();

      // The ordering IS the protocol, which is why the fake records one list
      // across kinds. Announcing first leaves a window in which a crash strands
      // a retained `found` naming a dead process.
      final ordered = bus.actions
          .where(
            (action) =>
                action is RetainedCleared ||
                action is WillChanged ||
                (action is SentMessage && action.topic == _bootTopic),
          )
          .toList();
      expect(ordered, hasLength(3));
      expect(ordered[0], isA<RetainedCleared>());
      expect(ordered[1], isA<WillChanged>());
      expect(ordered[2], isA<SentMessage>());

      expect((ordered[0] as RetainedCleared).topic, _bootTopic);
      expect((ordered[1] as WillChanged).will, process.primaryWill);
      await process.disconnect();
    });

    test('the announcement is retained and has upstream arity', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      bus.clear();

      await _deliverAbsent(bus);
      await settle();

      final announcement = bus.actions.whereType<SentMessage>().singleWhere(
        (sent) => sent.topic == _bootTopic,
      );
      expect(announcement.command, 'primary');
      // `process.py:333` requires EXACTLY four parameters for `found`; three or
      // five is silently ignored by every Python peer on the island.
      expect(announcement.params, hasLength(4));
      final params = announcement.params! as List<Object?>;
      expect(params[0], 'found');
      expect(params[1], 'aiko/testhost/7/1');
      expect(params[2], registrarVersion);
      expect(params[3], process.timeStarted);
      // Retained, or a peer joining a minute later learns nothing.
      expect(announcement.retain, isTrue);
      await process.disconnect();
    });

    test('lifecycle reports every role entered, in order', () async {
      final bus = FakeBus();
      final process = _process(bus);
      final roles = <RegistrarRole>[];
      final sub = process.lifecycle.listen(roles.add);
      await process.connect();
      await _deliverAbsent(bus);
      await settle();

      expect(roles, [RegistrarRole.primarySearch, RegistrarRole.primary]);
      await sub.cancel();
      await process.disconnect();
    });
  });

  group('the world-writable boot topic', () {
    test('a malformed announcement does not move the election', () async {
      final bus = FakeBus();
      final process = _process(bus, searchTimeout: const Duration(seconds: 30));
      await process.connect();

      // Every one of these is reachable by any peer on ADR-023's
      // unauthenticated bus, and none of them is a valid announcement.
      await bus.deliver(_bootTopic, 'primary', const ['found']);
      await bus.deliver(_bootTopic, 'primary', const ['found', 'a', 'b']);
      await bus.deliver(_bootTopic, 'primary', const [
        'found',
        'a',
        'b',
        'c',
        'd',
      ]);
      await bus.deliver(_bootTopic, 'primary', const ['absent', 'extra']);
      await bus.deliver(_bootTopic, 'primary', const ['sideways']);
      await bus.deliver(_bootTopic, 'sabotage', const ['absent']);
      await settle();

      expect(process.role, RegistrarRole.primarySearch);
      expect(bus.actions.whereType<WillChanged>(), isEmpty);
      await process.disconnect();
    });

    test(
      '(primary absent) while primary drops the roster and re-searches',
      () async {
        final bus = FakeBus();
        final process = _process(
          bus,
          searchTimeout: const Duration(seconds: 30),
        );
        final drops = <void>[];
        final sub = process.rosterDrops.listen(drops.add);
        await process.connect();
        await _deliverAbsent(bus);
        await settle();
        expect(process.role, RegistrarRole.primary);

        // Upstream's own behaviour (`registrar.py:280-282`), reproduced rather
        // than fixed: on this bus any peer can make a healthy registrar forget
        // every service it knows. Recorded as a finding, not silently diverged.
        await _deliverAbsent(bus);
        await settle();

        expect(drops, hasLength(1));
        expect(process.role, RegistrarRole.primarySearch);
        await sub.cancel();
        await process.disconnect();
      },
    );
  });

  group('leaving', () {
    test('disconnect cancels a search still in flight', () async {
      final bus = FakeBus();
      final process = _process(bus);
      await process.connect();
      expect(process.role, RegistrarRole.primarySearch);

      await process.disconnect();
      bus.clear();

      // Outlive the search timeout. A timer left armed promotes a process that
      // has already LEFT, publishing a retained announcement that names it —
      // the exact corpse-is-primary state the retained will exists to prevent,
      // arrived at without anybody dying.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await settle();

      expect(bus.actions, isEmpty);
    });

    test('leaving mid-promotion lets it finish instead of publishing at a dead '
        'bus', () async {
      // A real will change costs a reconnect. This models the window it opens.
      final bus = FakeBus()..setWillDelay = const Duration(milliseconds: 80);
      final process = _process(bus, searchTimeout: const Duration(seconds: 30));
      await process.connect();
      bus.clear();

      // Open a promotion, then leave while the will change is still in flight.
      unawaited(_deliverAbsent(bus));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await process.disconnect();
      final atLeaving = bus.actions.length;

      // Outlive the will change. Anything arriving after disconnect() RETURNED
      // is a publish at a bus that has already been torn down — which on a real
      // client throws ConnectionException out of an async drain, where the only
      // catch belongs to AnnouncePrimary and so reports a promotion failure for
      // something that was really a shutdown.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await settle();

      expect(
        bus.actions.length,
        atLeaving,
        reason: 'nothing may touch the bus after disconnect() returns',
      );
      // The promotion was allowed to COMPLETE rather than being cut in half:
      // taking the retained will and then never announcing is the worst of the
      // three outcomes, because the will is what a peer would act on.
      expect(bus.actions.whereType<WillChanged>(), hasLength(1));
      expect(
        bus.actions.whereType<SentMessage>().where(
          (sent) => sent.topic == _bootTopic,
        ),
        hasLength(1),
      );
    });
  });

  group('leaving is a filter on INPUTS, not only effects', () {
    test(
      'a timer armed BY the drain does not move the election after we leave',
      () async {
        // Tesla, round 3: disconnect cancels the timer, then awaits the drain —
        // and the drain can PERFORM a StartSearchTimer queued before we left. That
        // timer fires on a departed process and `onSearchTimeout` enters `primary`.
        // The old test could not see it: it asserted on bus.actions, and a leaving
        // process publishes nothing either way. Assert the ROLE.
        final bus = FakeBus()..setWillDelay = const Duration(milliseconds: 60);
        final process = _process(
          bus,
          searchTimeout: const Duration(milliseconds: 40),
        );
        await process.connect();
        unawaited(_deliverAbsent(bus));
        await Future<void>.delayed(const Duration(milliseconds: 15));
        await process.disconnect();
        final roleOnLeaving = process.role;

        await Future<void>.delayed(const Duration(milliseconds: 200));
        await settle();

        expect(
          process.role,
          roleOnLeaving,
          reason: 'the election must not advance on a process that has left',
        );
      },
    );
  });

  group('a promotion that fails', () {
    test('stands back down instead of holding a role it never announced', () async {
      final bus = FakeBus()..failSetWillWith = StateError('broker gone');
      final process = _process(bus, searchTimeout: const Duration(seconds: 30));
      final failures = <Object>[];
      final sub = process.promotionFailures.listen(failures.add);
      await process.connect();
      bus.clear();

      await _deliverAbsent(bus);
      await settle();

      expect(failures, hasLength(1));
      // The role must NOT be `primary`: an unannounced primary serves an island
      // that cannot see it, and every layer above reads `role` to decide
      // whether this process is serving.
      expect(process.role, RegistrarRole.primarySearch);
      expect(
        bus.actions.whereType<SentMessage>().where(
          (sent) => sent.topic == _bootTopic,
        ),
        isEmpty,
        reason: 'nothing may be announced when the will was never taken',
      );
      await sub.cancel();
      await process.disconnect();
    });
  });
}

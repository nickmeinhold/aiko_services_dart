import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('RegistrarElection', () {
    test('start is inert until initialized', () {
      final election = RegistrarElection();
      expect(election.role, RegistrarRole.start);
      // A boot-topic message before initialize must not promote anything. The
      // retained announcement is delivered the instant we subscribe, which can
      // be before the machine is running.
      expect(election.onAnnouncement(RegistrarAnnouncement.absent), isNotEmpty);
      expect(
        election.role,
        isNot(RegistrarRole.primary),
        reason: 'an absent arriving in `start` must not mint a primary',
      );
    });

    test('initialize enters the search and arms the timer', () {
      final election = RegistrarElection();
      final effects = election.initialize();
      expect(election.role, RegistrarRole.primarySearch);
      expect(effects, [
        PublishLifecycle(RegistrarRole.primarySearch),
        StartSearchTimer(RegistrarElection.defaultSearchTimeout),
      ]);
    });

    test('initialize is idempotent — a second call changes nothing', () {
      final election = RegistrarElection()..initialize();
      expect(election.initialize(), isEmpty);
      expect(election.role, RegistrarRole.primarySearch);
    });

    // The whole point of the machine: the announcement every joining peer needs
    // is emitted here and nowhere else, so a registrar that skips the election
    // publishes nothing while looking entirely healthy.
    test('nobody answers, the timer fires, we take primacy', () {
      final election = RegistrarElection()..initialize();
      final effects = election.onSearchTimeout();
      expect(election.role, RegistrarRole.primary);
      expect(effects, [
        PublishLifecycle(RegistrarRole.primary),
        const ClearBootTopic(),
        const AnnouncePrimary(),
      ]);
    });

    // ORDER IS PROTOCOL. Announcing before the will is taken leaves a window
    // where a crash strands a retained `found` naming a dead process, and every
    // later joiner is told a corpse is primary.
    test('the boot topic is cleared BEFORE the announcement', () {
      final effects = (RegistrarElection()..initialize()).onSearchTimeout();
      final clear = effects.indexWhere((e) => e is ClearBootTopic);
      final announce = effects.indexWhere((e) => e is AnnouncePrimary);
      expect(clear, isNonNegative);
      expect(announce, greaterThan(clear));
    });

    test('a found while searching stands us down to secondary', () {
      final election = RegistrarElection()..initialize();
      final effects = election.onAnnouncement(RegistrarAnnouncement.found);
      expect(election.role, RegistrarRole.secondary);
      expect(effects, [
        const CancelSearchTimer(),
        PublishLifecycle(RegistrarRole.secondary),
      ]);
      expect(
        effects.whereType<AnnouncePrimary>(),
        isEmpty,
        reason: 'a secondary must never announce itself as primary',
      );
    });

    // The race the reference guards with `timer_valid` (`registrar.py:172`). A
    // timer that fires after a `found` has already made us secondary would
    // promote a SECOND primary onto an island that already has one — and both
    // would then hold a retained announcement on the same topic.
    test('a timeout that lands after a found is ignored, not obeyed', () {
      final election = RegistrarElection()..initialize();
      election.onAnnouncement(RegistrarAnnouncement.found);
      expect(election.role, RegistrarRole.secondary);

      final late = election.onSearchTimeout();
      expect(late, isEmpty);
      expect(
        election.role,
        RegistrarRole.secondary,
        reason: 'a stale timer must not promote a second primary',
      );
    });

    test(
      'an absent while searching promotes without waiting out the timer',
      () {
        final election = RegistrarElection()..initialize();
        final effects = election.onAnnouncement(RegistrarAnnouncement.absent);
        expect(election.role, RegistrarRole.primary);
        expect(effects.first, isA<CancelSearchTimer>());
        expect(effects.whereType<AnnouncePrimary>(), hasLength(1));
      },
    );

    // `registrar.py:280-282`. Faithful, and a wire-reachable way to make a
    // healthy registrar forget every service it knows — any peer can publish
    // `(primary absent)` on ADR-023's unauthenticated bus. Reproduced because
    // diverging unilaterally is an interop change; recorded because it is a
    // finding for upstream.
    test(
      'an absent while primary drops the roster and re-runs the election',
      () {
        final election = RegistrarElection()..initialize();
        election.onSearchTimeout();
        expect(election.role, RegistrarRole.primary);

        final effects = election.onAnnouncement(RegistrarAnnouncement.absent);
        expect(effects.first, isA<DropRoster>());
        expect(election.role, RegistrarRole.primarySearch);
        expect(effects.whereType<StartSearchTimer>(), hasLength(1));
      },
    );

    test('an absent while secondary does the same', () {
      final election = RegistrarElection()..initialize();
      election.onAnnouncement(RegistrarAnnouncement.found);
      final effects = election.onAnnouncement(RegistrarAnnouncement.absent);
      expect(effects.first, isA<DropRoster>());
      expect(election.role, RegistrarRole.primarySearch);
    });

    // A primary re-reads its OWN retained announcement on every reconnect. If
    // that were treated as news the machine would churn on every broker blip.
    test('a found while already primary is not news', () {
      final election = RegistrarElection()..initialize();
      election.onSearchTimeout();
      expect(election.onAnnouncement(RegistrarAnnouncement.found), isEmpty);
      expect(election.role, RegistrarRole.primary);
    });

    test('a found while secondary is not news either', () {
      final election = RegistrarElection()..initialize();
      election.onAnnouncement(RegistrarAnnouncement.found);
      expect(election.onAnnouncement(RegistrarAnnouncement.found), isEmpty);
      expect(election.role, RegistrarRole.secondary);
    });

    // The role names are the wire's `lifecycle` values, not Dart-side labels: a
    // peer reads these exact strings off the share. Pinned so a rename for
    // Dart taste cannot silently become a wire change.
    test('role names are the wire lifecycle values', () {
      expect(RegistrarRole.values.map((r) => r.lifecycle), [
        'start',
        'primary_search',
        'secondary',
        'primary',
      ]);
    });

    test(
      'the search timeout is configurable and defaults to the reference',
      () {
        expect(
          RegistrarElection.defaultSearchTimeout,
          const Duration(seconds: 2),
        );
        final quick = RegistrarElection(
          searchTimeout: const Duration(milliseconds: 50),
        );
        expect(
          quick.initialize(),
          contains(const StartSearchTimer(Duration(milliseconds: 50))),
        );
      },
    );

    // A full cycle: primary, deposed, and back. The roster drop must happen on
    // the way down and NOT again on the way back up.
    test('a deposed primary re-takes primacy, dropping the roster once', () {
      final election = RegistrarElection()..initialize();
      election.onSearchTimeout();
      final down = election.onAnnouncement(RegistrarAnnouncement.absent);
      final up = election.onSearchTimeout();

      expect(down.whereType<DropRoster>(), hasLength(1));
      expect(up.whereType<DropRoster>(), isEmpty);
      expect(election.role, RegistrarRole.primary);
      expect(up.whereType<AnnouncePrimary>(), hasLength(1));
    });
  });
}

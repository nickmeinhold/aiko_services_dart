import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('RegistrarElection', () {
    // THE WINDOW BETWEEN SUBSCRIBING AND STARTING. The retained announcement is
    // delivered the instant we subscribe, which can be before the machine is
    // running. An earlier version of this test named that window and then only
    // struck `absent` — the harmless half — while `found` was silently dropped.
    // Dropping a `found` is the dual-primary bug: discard it, start searching,
    // and two seconds later a second primary announces onto an island that
    // already has one, both holding a retained announcement on one topic.
    test(
      'a found seen before initialize makes us a SECONDARY, not a rival',
      () {
        final election = RegistrarElection();
        expect(election.onAnnouncement(RegistrarAnnouncement.found), isEmpty);
        expect(
          election.role,
          RegistrarRole.start,
          reason: 'latched, not acted on — the machine is not running yet',
        );

        final effects = election.initialize();
        expect(
          election.role,
          RegistrarRole.secondary,
          reason: 'an island with a primary must not be raced',
        );
        expect(effects.whereType<AnnouncePrimary>(), isEmpty);
        expect(effects.whereType<StartSearchTimer>(), isEmpty);
      },
    );

    test('an absent seen before initialize still leads to a search', () {
      final election = RegistrarElection();
      expect(election.onAnnouncement(RegistrarAnnouncement.absent), isEmpty);
      expect(election.role, RegistrarRole.start);

      final effects = election.initialize();
      expect(election.role, RegistrarRole.primarySearch);
      expect(effects.whereType<StartSearchTimer>(), hasLength(1));
      expect(
        effects.whereType<DropRoster>(),
        isEmpty,
        reason: 'there is no roster to drop before the machine has started',
      );
    });

    // The latch takes the LATEST word. A primary that announces and then dies
    // before we start must not leave us permanently standing down.
    test('the latch keeps the most recent announcement, not the first', () {
      final election = RegistrarElection();
      election.onAnnouncement(RegistrarAnnouncement.found);
      election.onAnnouncement(RegistrarAnnouncement.absent);
      election.initialize();
      expect(election.role, RegistrarRole.primarySearch);
    });

    test('initialize enters the search and arms the timer', () {
      final election = RegistrarElection();
      final effects = election.initialize();
      expect(election.role, RegistrarRole.primarySearch);
      expect(effects, [
        PublishLifecycle(RegistrarRole.primarySearch),
        StartSearchTimer(RegistrarElection.defaultSearchTimeout, 1),
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
      final effects = election.onSearchTimeout(1);
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
      final effects = (RegistrarElection()..initialize()).onSearchTimeout(1);
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

      final late = election.onSearchTimeout(1);
      expect(late, isEmpty);
      expect(
        election.role,
        RegistrarRole.secondary,
        reason: 'a stale timer must not promote a second primary',
      );
    });

    // THE SECOND HARMONIC, and the one the first must-fail arm could not reach.
    // A boolean "is a search pending" is a second name for the ROLE, so it is
    // true again as soon as a NEW search starts — and a timer left over from
    // the previous one then finds the flag set and the role right, and
    // promotes. Two primaries, both holding a retained announcement on one
    // topic.
    //
    // The earlier arm only struck a timeout arriving while SECONDARY, where the
    // flag was already false. That is the harmless phase.
    test('a timer from a PREVIOUS search cannot promote the current one', () {
      final election = RegistrarElection();
      final first = election.initialize().whereType<StartSearchTimer>().single;

      // Stood down, then hunting again — a fresh search, a fresh timer.
      election.onAnnouncement(RegistrarAnnouncement.found);
      final restart = election.onAnnouncement(RegistrarAnnouncement.absent);
      final second = restart.whereType<StartSearchTimer>().single;
      expect(election.role, RegistrarRole.primarySearch);
      expect(
        second.epoch,
        isNot(first.epoch),
        reason: 'a new search must be nameable apart from the old one',
      );

      // Timer A arrives late, into a role that once again says primarySearch.
      expect(election.onSearchTimeout(first.epoch), isEmpty);
      expect(
        election.role,
        RegistrarRole.primarySearch,
        reason: 'a stale pulse must not promote the current search',
      );

      // And the CURRENT timer still works — without this, the test would pass
      // for a machine that had simply stopped honouring timeouts at all.
      final effects = election.onSearchTimeout(second.epoch);
      expect(election.role, RegistrarRole.primary);
      expect(effects.whereType<AnnouncePrimary>(), hasLength(1));
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
        election.onSearchTimeout(1);
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
      election.onSearchTimeout(1);
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
    // Carnot's catch: four of six effects had identity equality only, working
    // by `const` canonicalisation alone. A caller constructing one WITHOUT
    // `const` would then compare unequal to a structurally identical effect,
    // and the PR claiming "effects carry value equality" would be true of two
    // of them. Constructed non-const here on purpose — that is the case that
    // was broken.
    test('every effect compares by value, not by identity', () {
      // ignore: prefer_const_constructors
      expect(CancelSearchTimer(), CancelSearchTimer());
      // ignore: prefer_const_constructors
      expect(ClearBootTopic(), ClearBootTopic());
      // ignore: prefer_const_constructors
      expect(AnnouncePrimary(), AnnouncePrimary());
      // ignore: prefer_const_constructors
      expect(DropRoster(), DropRoster());
      expect(
        PublishLifecycle(RegistrarRole.primary),
        PublishLifecycle(RegistrarRole.primary),
      );
      // ignore: prefer_const_constructors
      expect(
        StartSearchTimer(Duration(seconds: 2), 1),
        StartSearchTimer(Duration(seconds: 2), 1),
      );

      // And DIFFERENT effects must not collapse together.
      expect(const ClearBootTopic(), isNot(const AnnouncePrimary()));
      expect(
        PublishLifecycle(RegistrarRole.primary),
        isNot(PublishLifecycle(RegistrarRole.secondary)),
      );
      expect(
        const StartSearchTimer(Duration(seconds: 2), 1),
        isNot(const StartSearchTimer(Duration(seconds: 3), 1)),
      );
    });

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
          contains(const StartSearchTimer(Duration(milliseconds: 50), 1)),
        );
      },
    );

    // A full cycle: primary, deposed, and back. The roster drop must happen on
    // the way down and NOT again on the way back up.
    test('a deposed primary re-takes primacy, dropping the roster once', () {
      final election = RegistrarElection()..initialize();
      election.onSearchTimeout(1);
      final down = election.onAnnouncement(RegistrarAnnouncement.absent);
      // The SECOND search has its own epoch. Passing 1 again here would be a
      // stale pulse, and is now correctly refused — which is what makes this
      // line evidence rather than decoration.
      final second = down.whereType<StartSearchTimer>().single;
      final up = election.onSearchTimeout(second.epoch);

      expect(down.whereType<DropRoster>(), hasLength(1));
      expect(up.whereType<DropRoster>(), isEmpty);
      expect(election.role, RegistrarRole.primary);
      expect(up.whereType<AnnouncePrimary>(), hasLength(1));
    });
  });
}

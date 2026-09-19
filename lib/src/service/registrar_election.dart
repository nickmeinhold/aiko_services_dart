/// The registrar's primary election, as a pure state machine.
///
/// Ported from `registrar.py:142-199` (`StateMachineModel`) plus its trigger
/// sites in `RegistrarImpl._registrar_handler` (`:272-282`).
///
/// **Why this is the FIRST piece of the registrar, and why it emits effects
/// rather than performing them.** `(primary found …)` is published in exactly
/// one place upstream — `on_enter_primary` — so the announcement every joining
/// peer depends on is *downstream of the election*. A registrar that skips the
/// election never announces itself at all, which is why the inherited plan's
/// step list, which did not mention the election, would have produced code that
/// runs, publishes nothing, and looks correct.
///
/// The effects are data. That is not ceremony: entering `primary` requires
/// CHANGING the process's Last Will, and MQTT carries a will only in the
/// CONNECT packet — so the driver has to reconnect (see [AnnouncePrimary]).
/// Baking that into the state machine would make the election untestable
/// without a broker, and the states worth testing are exactly the ones a live
/// island will not produce on demand: a stale retained announcement naming a
/// dead process, an `absent` arriving while already primary, a timeout racing a
/// `found`.
library;

/// Where this registrar currently sits.
///
/// The names are the reference's own (`registrar.py:143`), because they are
/// also the values published into the share as `lifecycle` — a peer reading
/// `lifecycle` off the wire sees exactly these strings, so renaming them for
/// Dart taste would be a wire change wearing a refactor's clothes.
enum RegistrarRole {
  start('start'),
  primarySearch('primary_search'),
  secondary('secondary'),
  primary('primary');

  const RegistrarRole(this.lifecycle);

  /// The value published as the share's `lifecycle` key.
  final String lifecycle;
}

/// Something the election needs the process to do.
///
/// Ordered lists of these come back from every input, and ORDER IS PROTOCOL —
/// see [AnnouncePrimary] for the one place it is load-bearing.
sealed class ElectionEffect {
  const ElectionEffect();
}

/// Publish `lifecycle` into the registrar's own share.
///
/// Every state entry does this upstream (`:163`, `:179`, `:183`), which is how
/// a dashboard watching the share can see an election happen.
final class PublishLifecycle extends ElectionEffect {
  const PublishLifecycle(this.role);

  final RegistrarRole role;

  // Effects are VALUES, so they compare by value. Without this a test asserting
  // the exact effect list compares by identity and fails against a structurally
  // identical list — which would push tests toward matching on `isA<>` and
  // quietly stop checking WHICH lifecycle or WHICH timeout was emitted.
  @override
  bool operator ==(Object other) =>
      other is PublishLifecycle && other.role == role;

  @override
  int get hashCode => role.hashCode;

  @override
  String toString() => 'PublishLifecycle(${role.lifecycle})';
}

/// Start the search timer; if nothing answers before it fires, promote.
///
/// `_PRIMARY_SEARCH_TIMEOUT = 2.0` (`registrar.py:136`). Upstream's own TODO at
/// `:167` asks for `+/- delta` jitter to avoid collisions between simultaneous
/// registrars and does not implement it, so two registrars started together
/// collide identically here. Reproducing that is deliberate: diverging would
/// mean inventing an election rule the Python side does not share.
final class StartSearchTimer extends ElectionEffect {
  const StartSearchTimer(this.timeout, this.epoch);

  final Duration timeout;

  /// Which search this timer belongs to. The driver must hand it back to
  /// [RegistrarElection.onSearchTimeout].
  ///
  /// A boolean "is a search pending" cannot do this job, and looked like it
  /// could. It was written in lockstep with entering `primarySearch` and
  /// cleared in lockstep with leaving it — a second name for the ROLE, not the
  /// identity of a timer. The sequence that breaks it: `initialize` arms timer
  /// A, a `found` stands us down, an `absent` re-enters the search and arms
  /// timer B, and then timer A arrives LATE to find the flag true and the role
  /// `primarySearch` again. It promotes, and the island has two primaries both
  /// holding a retained announcement on one topic.
  ///
  /// An epoch is not a tighter guard on that window; it removes it. A timeout
  /// that cannot name its own search cannot be honoured.
  final int epoch;

  @override
  bool operator ==(Object other) =>
      other is StartSearchTimer &&
      other.timeout == timeout &&
      other.epoch == epoch;

  @override
  int get hashCode => Object.hash(timeout, epoch);

  @override
  String toString() =>
      'StartSearchTimer(${timeout.inMilliseconds}ms, epoch $epoch)';
}

/// Cancel a pending search timer.
final class CancelSearchTimer extends ElectionEffect {
  const CancelSearchTimer();

  @override
  bool operator ==(Object other) => other is CancelSearchTimer;

  @override
  int get hashCode => (CancelSearchTimer).hashCode;

  @override
  String toString() => 'CancelSearchTimer()';
}

/// Become the primary: clear the boot topic, take the retained will, THEN
/// announce. **Three steps, ONE effect, because they are one transaction.**
///
/// **The order is the protocol and is not incidental.** The driver must
/// (1) publish an EMPTY retained payload to the boot topic — `registrar.py:186`,
/// whose comment says why: *"Clear LWT, so this registrar doesn't receive
/// another LWT on reconnect"*, without which the previous primary's retained
/// `(primary absent)` is still sitting there and this process reads its own
/// predecessor's death as news; (2) set the will to a retained
/// `(primary absent)`; and only then (3) publish the retained
/// `(primary found …)`. Announcing first leaves a window in which a crash
/// strands a retained `found` naming a dead process, and every peer that joins
/// afterwards is told a corpse is primary — the exact failure that makes a will
/// non-optional for a registrar.
///
/// Setting the will means RECONNECTING, because MQTT carries a will only in the
/// CONNECT packet. Upstream does the same thing for the same reason
/// (`message/mqtt.py:200-209`); it is MQTT's law rather than paho clumsiness.
///
/// **The clear used to be its own effect, and that split was a defect.** A
/// promotion either completes or stands the role back down, and the only thing
/// that stands it down is this effect's failure handler. With the clear outside
/// it, a `TransportUnavailable` from a down link threw out of the drain, the
/// announcement never ran, `onPrimaryFailed` never fired — and the process sat
/// at `RegistrarRole.primary` having published NOTHING. Measured, not reasoned:
/// role `primary`, actions `[]`. Merging is not tidiness; it is what makes the
/// transaction boundary and the catch boundary the same boundary, so no future
/// step can be added outside the handler by accident.
final class AnnouncePrimary extends ElectionEffect {
  const AnnouncePrimary();

  @override
  bool operator ==(Object other) => other is AnnouncePrimary;

  @override
  int get hashCode => (AnnouncePrimary).hashCode;

  @override
  String toString() => 'AnnouncePrimary()';
}

/// Drop the whole service roster.
///
/// `registrar.py:281` — `self.services = Services()` when an `absent` arrives
/// while this registrar is NOT searching. Reproduced faithfully and flagged
/// loudly: on ADR-023's unauthenticated bus any peer can publish
/// `(primary absent)`, so this is a wire-reachable way to make a healthy
/// registrar forget every service it knows. It is upstream's behaviour, and
/// diverging unilaterally would be an interop change, so it is recorded for the
/// findings note rather than silently "fixed".
final class DropRoster extends ElectionEffect {
  const DropRoster();

  @override
  bool operator ==(Object other) => other is DropRoster;

  @override
  int get hashCode => (DropRoster).hashCode;

  @override
  String toString() => 'DropRoster()';
}

/// What the boot topic just said about a primary registrar.
enum RegistrarAnnouncement { found, absent }

/// The primary election. Pure: inputs in, effects out, no I/O.
class RegistrarElection {
  RegistrarElection({this.searchTimeout = defaultSearchTimeout});

  /// `registrar.py:136`, `_PRIMARY_SEARCH_TIMEOUT = 2.0`.
  static const defaultSearchTimeout = Duration(seconds: 2);

  final Duration searchTimeout;

  RegistrarRole _role = RegistrarRole.start;
  RegistrarRole get role => _role;

  /// Which search is current. Incremented on every entry to `primarySearch`.
  ///
  /// Upstream re-checks the state inside the timer callback (`:172`,
  /// `timer_valid = state == "primary_search"`), which is sufficient there
  /// because a Python registrar has one timer handler at a time. It is NOT
  /// sufficient for an API that can re-enter the search while a previous
  /// driver callback is still outstanding — see [StartSearchTimer.epoch].
  int _epoch = 0;

  /// What the boot topic said while we were still in [RegistrarRole.start].
  ///
  /// The retained announcement is delivered the INSTANT we subscribe, which can
  /// be before the machine is running — so an announcement arriving in `start`
  /// is latched rather than acted on or discarded.
  ///
  /// Discarding a `found` here is a dual-primary bug, and it is the asymmetry a
  /// cage-match caught: the reference's ordering closes this window by accident
  /// (`registrar.py:264-266` registers the handler and transitions in one
  /// synchronous `__init__`), but a machine with an explicit `initialize()` has
  /// a real gap between subscribing and starting. Drop the `found`, then start
  /// searching, and two seconds later a second primary announces itself onto an
  /// island that already has one — both holding a retained announcement on the
  /// same topic, and every later `found` dismissed as "not news".
  bool? _seenPrimaryBeforeStart;

  /// Enter the election. `registrar.py:266`.
  ///
  /// Honours anything the boot topic already said. A `found` seen while in
  /// `start` means an island already has a primary, so we begin as a SECONDARY
  /// rather than racing it.
  List<ElectionEffect> initialize() {
    if (_role != RegistrarRole.start) return const [];
    if (_seenPrimaryBeforeStart ?? false) return _enterSecondary();
    return _enterPrimarySearch();
  }

  /// The retained boot topic said something.
  List<ElectionEffect> onAnnouncement(RegistrarAnnouncement announcement) =>
      switch ((announcement, _role)) {
        // Before initialize(): LATCH, do not act. Both arms, symmetrically —
        // an earlier version acted on `absent` here and dropped `found`, which
        // is precisely backwards: the harmless one moved the machine and the
        // dangerous one was thrown away.
        (_, RegistrarRole.start) => _latch(announcement),
        // Somebody else is primary and we are looking: stand down.
        (RegistrarAnnouncement.found, RegistrarRole.primarySearch) =>
          _enterSecondary(),
        // A `found` in any other state is not news. Upstream's handler simply
        // does nothing (`:273-275` guards on primary_search), and in particular
        // a primary reading its OWN retained announcement must not react.
        (RegistrarAnnouncement.found, _) => const [],
        // Nobody is primary and we are looking: take it, without waiting out
        // the timer. `:277-279`.
        (RegistrarAnnouncement.absent, RegistrarRole.primarySearch) => [
          const CancelSearchTimer(),
          ..._enterPrimary(),
        ],
        // `absent` while NOT searching — including while WE are primary. The
        // roster goes, and the election restarts. `:280-282`.
        (RegistrarAnnouncement.absent, _) => [
          const DropRoster(),
          ..._enterPrimarySearch(),
        ],
      };

  /// The search timer fired.
  ///
  /// Returns nothing at all unless [epoch] names the CURRENT search. A timer
  /// from a previous search — one that fired after a `found` stood us down and
  /// an `absent` started a fresh hunt — would otherwise promote a second
  /// primary onto an island that already has one.
  List<ElectionEffect> onSearchTimeout(int epoch) {
    if (epoch != _epoch || _role != RegistrarRole.primarySearch) {
      return const [];
    }
    return _enterPrimary();
  }

  /// Promotion could not be completed.
  ///
  /// `registrar.py:198-200`: `on_enter_primary` wraps the will-and-announce
  /// sequence in `try/except SystemError` — its own comment guesses *"Probably
  /// MQTT server not running"* — and transitions `primary_failed`. The
  /// transition table carries that edge from BOTH `primary` and `secondary`
  /// (`:151-155`), which is why this accepts either.
  ///
  /// Without this input a driver whose will-change throws is left holding the
  /// role `primary` while having announced nothing. That is the one role that
  /// is a LIE rather than a stage: every layer above reads it to decide whether
  /// this process is serving the island, and an unannounced primary serves an
  /// island that cannot see it.
  List<ElectionEffect> onPrimaryFailed() => switch (_role) {
    RegistrarRole.primary || RegistrarRole.secondary => _enterPrimarySearch(),
    // `start` and `primary_search` have no such edge upstream, and inventing
    // one would restart a search that is already running — re-arming the timer
    // under a new epoch and orphaning the one in flight.
    RegistrarRole.start || RegistrarRole.primarySearch => const [],
  };

  List<ElectionEffect> _latch(RegistrarAnnouncement announcement) {
    _seenPrimaryBeforeStart = announcement == RegistrarAnnouncement.found;
    return const [];
  }

  List<ElectionEffect> _enterPrimarySearch() {
    _role = RegistrarRole.primarySearch;
    // A NEW search, so any timer still in flight from the previous one is stale
    // by construction rather than by a flag anyone has to maintain.
    _epoch++;
    return [PublishLifecycle(_role), StartSearchTimer(searchTimeout, _epoch)];
  }

  List<ElectionEffect> _enterSecondary() {
    _role = RegistrarRole.secondary;
    return [const CancelSearchTimer(), PublishLifecycle(_role)];
  }

  List<ElectionEffect> _enterPrimary() {
    _role = RegistrarRole.primary;
    return [PublishLifecycle(_role), const AnnouncePrimary()];
  }
}

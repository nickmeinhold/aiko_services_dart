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
  const StartSearchTimer(this.timeout);

  final Duration timeout;

  @override
  bool operator ==(Object other) =>
      other is StartSearchTimer && other.timeout == timeout;

  @override
  int get hashCode => timeout.hashCode;

  @override
  String toString() => 'StartSearchTimer(${timeout.inMilliseconds}ms)';
}

/// Cancel a pending search timer.
final class CancelSearchTimer extends ElectionEffect {
  const CancelSearchTimer();

  @override
  String toString() => 'CancelSearchTimer()';
}

/// Publish an EMPTY retained payload to the boot topic.
///
/// `registrar.py:186`, and its comment says why: *"Clear LWT, so this registrar
/// doesn't receive another LWT on reconnect."* Without it, the previous
/// primary's retained `(primary absent)` is still sitting on the topic and this
/// process reads its own predecessor's death as news.
final class ClearBootTopic extends ElectionEffect {
  const ClearBootTopic();

  @override
  String toString() => 'ClearBootTopic()';
}

/// Become the primary: take the retained will, THEN announce.
///
/// **The order inside this effect is the protocol and is not incidental.** The
/// driver must (1) set the will to a retained `(primary absent)` and only then
/// (2) publish the retained `(primary found …)`. Announcing first leaves a
/// window in which a crash strands a retained `found` naming a dead process,
/// and every peer that joins afterwards is told a corpse is primary — the exact
/// failure that makes a will non-optional for a registrar.
///
/// Setting the will means RECONNECTING, because MQTT carries a will only in the
/// CONNECT packet. Upstream does the same thing for the same reason
/// (`message/mqtt.py:200-209`); it is MQTT's law rather than paho clumsiness.
final class AnnouncePrimary extends ElectionEffect {
  const AnnouncePrimary();

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

  /// Whether a search timer is outstanding.
  ///
  /// Tracked so a late timeout can be IGNORED rather than acted on. Upstream
  /// re-checks the state inside the timer callback (`:172`,
  /// `timer_valid = state == "primary_search"`) precisely because the timer can
  /// fire after a `found` has already moved it to `secondary`; a machine that
  /// trusted the timer would promote a second primary onto a live island.
  bool _searchPending = false;

  /// Enter the election. `registrar.py:266`.
  List<ElectionEffect> initialize() {
    if (_role != RegistrarRole.start) return const [];
    return _enterPrimarySearch();
  }

  /// The retained boot topic said something.
  List<ElectionEffect> onAnnouncement(RegistrarAnnouncement announcement) =>
      switch ((announcement, _role)) {
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
  /// Returns nothing at all if it is stale. A timer that fires after a `found`
  /// has already made us `secondary` would otherwise promote a second primary
  /// onto an island that already has one.
  List<ElectionEffect> onSearchTimeout() {
    if (!_searchPending || _role != RegistrarRole.primarySearch) {
      return const [];
    }
    _searchPending = false;
    return _enterPrimary();
  }

  List<ElectionEffect> _enterPrimarySearch() {
    _role = RegistrarRole.primarySearch;
    _searchPending = true;
    return [PublishLifecycle(_role), StartSearchTimer(searchTimeout)];
  }

  List<ElectionEffect> _enterSecondary() {
    _role = RegistrarRole.secondary;
    _searchPending = false;
    return [const CancelSearchTimer(), PublishLifecycle(_role)];
  }

  List<ElectionEffect> _enterPrimary() {
    _role = RegistrarRole.primary;
    _searchPending = false;
    // Clear BEFORE announcing, and announce only after the will is taken —
    // see [ClearBootTopic] and [AnnouncePrimary]. This ordering is the whole
    // reason effects are an ordered list rather than a set.
    return [
      PublishLifecycle(_role),
      const ClearBootTopic(),
      const AnnouncePrimary(),
    ];
  }
}

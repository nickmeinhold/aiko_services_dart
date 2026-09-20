/// The registrar's roster: which services exist, grouped by the process that
/// hosts them.
///
/// Ported from `Services` (`service.py:375-450`). It is a two-level map rather
/// than a flat one, and that shape is load-bearing rather than tidy: a process
/// dies as a UNIT. Its Last Will names `{ns}/{host}/{pid}/0/state`, service `0`,
/// and `registrar.py:381-386` reads that as "remove every service of this
/// process" — which is only cheap because the roster is already grouped that
/// way.
library;

import 'dart:collection';

import 'service_details.dart';
import 'service_topic_path.dart';

/// Reads a wall-clock instant, in the form the registrar puts on the wire.
///
/// A seam so a test can assert on `time_add` and `time_remove` at all: with the
/// real clock the only honest assertions left are "it parses" and "it is not in
/// the future", neither of which can fail on a record whose two timestamps are
/// swapped.
typedef WallClock = String Function();

/// Seconds since the Unix epoch, to microseconds.
///
/// **A deliberate divergence, and the SAME one already recorded for
/// `time_started`** — see `RegistrarProcess.timeStarted`, which carries the
/// argument in full. Upstream samples `time.monotonic()` (`registrar.py:389`,
/// `:393`), a clock Dart cannot read and whose origin CPython documents as
/// undefined. This substitutes the same quantity on a different scale.
///
/// One consequence specific to history, which `time_started` does not have:
/// these two values are compared with EACH OTHER far more plausibly than with
/// anything of Python's — how long a service lived is `time_remove - time_add`.
///
/// **That difference is NOT unconditionally correct, and an earlier draft of
/// this comment claimed it was.** A wall clock is not monotonic: an NTP step
/// backwards between a service's arrival and its departure makes the computed
/// lifetime short, or negative. `time.monotonic()` upstream cannot do that —
/// that is the entire reason the function is named "monotonic" — so this is a
/// place where the substitution is genuinely WEAKER than what it replaces,
/// rather than merely differently scaled.
///
/// It is kept anyway, because a `Stopwatch` resets to zero on every restart and
/// would make every service on a freshly-restarted registrar appear to have
/// arrived at the dawn of time — a worse lie, told constantly, instead of a
/// rare one told when the clock steps. Recorded here so the next reader
/// inherits the tradeoff rather than the earlier draft's false reassurance.
String wallClockSeconds() =>
    (DateTime.now().microsecondsSinceEpoch / 1e6).toStringAsFixed(6);

/// A service that has left, and when it arrived and went.
///
/// Upstream has no type for this: it mutates the live service's dict, setting
/// `time_remove` on it and pushing the SAME object onto the history deque
/// (`registrar.py:392-394`). That aliasing is invisible there because nothing
/// mutates the dict afterwards. Modelled as a separate immutable record instead
/// — a departed service is a different thing from a live one, and giving the
/// live [ServiceDetails] two nullable time fields would put a "has it left yet"
/// question into every reader of the roster.
final class ServiceDeparture {
  const ServiceDeparture({
    required this.details,
    required this.timeAdd,
    required this.timeRemove,
  });

  final ServiceDetails details;

  /// When the service registered. `time.monotonic()` upstream.
  final String timeAdd;

  /// When it was removed — by its own `(remove ...)`, or by the broker
  /// publishing its process's Last Will.
  final String timeRemove;

  /// The eight positional parameters of a history `(add ...)`.
  ///
  /// The live roster's six (`registrar.py:341-348`) plus the two times
  /// (`:317-326`). The tail is the whole reason this is a separate wire shape,
  /// and `services_cache.dart` already parses `>= 6` rather than `== 6` because
  /// of it.
  List<Object?> toAddParameters() => [
    details.topicPath.path,
    details.name,
    details.protocol,
    details.transport,
    details.owner,
    details.tags,
    timeAdd,
    timeRemove,
  ];

  @override
  String toString() =>
      'ServiceDeparture(${details.topicPath}, '
      '$timeAdd -> $timeRemove)';
}

/// `main/__init__.py:16-17`. Not assembled from parts here: the whole string is
/// what a service publishes and what this file compares against, and building
/// it from three constants would invite one of them to drift.
const registrarProtocol =
    'github.com/geekscape/aiko_services/protocol/registrar:2';

/// An ordered, process-grouped set of known services.
final class ServiceRoster {
  /// A factory over a private constructor, the same shape `RegistrarProcess`
  /// uses and for the same reason: the fields are private, so initializing
  /// formals would force every caller to write `_now:` — an underscore in
  /// somebody else's API. Positional here, where the names are invisible.
  factory ServiceRoster({
    WallClock now = wallClockSeconds,
    int historyLimit = defaultHistoryLimit,
  }) => ServiceRoster._(now, historyLimit);

  ServiceRoster._(this._now, this._historyLimit);

  /// `_HISTORY_RING_BUFFER_SIZE` (`registrar.py:135`).
  static const int defaultHistoryLimit = 4096;

  final WallClock _now;
  final int _historyLimit;

  final Map<String, Map<String, ServiceDetails>> _byProcess = {};

  /// When each LIVE service registered, by service path.
  ///
  /// Held beside the roster rather than inside [ServiceDetails] because that
  /// type is also what a CONSUMER parses off the wire from somebody else's
  /// `(add ...)`, where no such time exists. Only the registrar — the process
  /// that witnessed the arrival — can know it.
  final Map<String, String> _addedAt = {};

  /// Departures, newest first, bounded.
  ///
  /// `deque(maxlen=_HISTORY_RING_BUFFER_SIZE)` with `appendleft`
  /// (`registrar.py:247`, `:394`). The bound is the point: a registrar that
  /// runs for months on an island with churn would otherwise hold every service
  /// that has ever existed.
  final ListQueue<ServiceDeparture> _history = ListQueue();

  /// Everything that has left, newest first.
  ///
  /// An unmodifiable VIEW, not the queue itself. Returning `_history` directly
  /// typed as `Iterable` still hands out the live `ListQueue`, and
  /// `(roster.history as ListQueue).clear()` would then drain the ring buffer
  /// through a getter that advertises read-only. Every other accessor here is
  /// safe by construction — `services` is a generator, `topicPaths` a lazy map
  /// — and this one was the exception.
  Iterable<ServiceDeparture> get history => UnmodifiableListView(_history);

  /// Process paths in the order they are served.
  ///
  /// A separate list because the order is not insertion order. `add_service`
  /// (`service.py:390-393`) calls `move_to_end(last=…)` with `last` FALSE when
  /// the arriving service's protocol is the registrar's — so a registrar's own
  /// process is moved to the FRONT and everything else to the back. Dart's
  /// insertion-ordered maps have no move-to-front, so the order is held here
  /// explicitly.
  ///
  /// It is observable, not cosmetic: it is the order services come back in from
  /// `(share …)`, and the live island's roster puts its registrar first for
  /// exactly this reason.
  final List<String> _processOrder = [];

  int _count = 0;

  /// How many services are known.
  ///
  /// Upstream keeps its own counter and its comment asks why `len()` is wrong
  /// (`service.py:407`). The answer is that `_services` is keyed by PROCESS, so
  /// its length counts processes; the count that matters — and the one
  /// published as `service_count` — is services. Kept as a counter here for the
  /// same reason, and asserted against a walk in the tests.
  int get count => _count;

  bool get isEmpty => _count == 0;

  /// Every service, in serving order.
  Iterable<ServiceDetails> get services sync* {
    for (final processPath in _processOrder) {
      yield* _byProcess[processPath]!.values;
    }
  }

  /// Every service path, in serving order.
  Iterable<String> get topicPaths => services.map((s) => s.topicPath.path);

  /// Adds [service], returning whether it was NEW.
  ///
  /// A repeat registration of a path already held is ignored and reports false.
  /// That is upstream's behaviour and it is publicly visible: `service_add`
  /// builds its `(add …)` payload before the guard but publishes it INSIDE
  /// (`registrar.py:357-377`), so a duplicate registration produces no traffic
  /// at all. A peer that re-registers on reconnect — which `process.py:353-358`
  /// does on every `found` — must not make every consumer see a second arrival.
  bool add(ServiceDetails service) {
    final processPath = service.topicPath.processPath;
    final servicePath = service.topicPath.path;

    final process = _byProcess[processPath];
    if (process == null) {
      _addedAt[servicePath] = _now();
      _byProcess[processPath] = {servicePath: service};
      // The ordering decision is made ONCE, by whichever service of a process
      // arrives first — upstream only reaches `move_to_end` on the branch that
      // creates the process entry. A registrar's second service would not
      // re-promote a process that arrived as something else.
      if (service.protocol == registrarProtocol) {
        _processOrder.insert(0, processPath);
      } else {
        _processOrder.add(processPath);
      }
      _count++;
      return true;
    }
    if (process.containsKey(servicePath)) return false;
    _addedAt[servicePath] = _now();
    process[servicePath] = service;
    _count++;
    return true;
  }

  /// Records [removed] as departures, newest first, within the bound.
  ///
  /// Reads the clock ONCE for the whole call, not once per service. A process
  /// death removes every service that process hosted in a single event — the
  /// broker published one Last Will — so giving them staggered removal times
  /// would invent a sequence the wire never carried.
  void _recordDepartures(List<ServiceDetails> removed) {
    if (removed.isEmpty) return;
    final timeRemove = _now();
    for (final service in removed) {
      final path = service.topicPath.path;
      _history.addFirst(
        ServiceDeparture(
          details: service,
          // A service in the roster always has an arrival time, because the
          // only way in is `add`. Defaulted rather than asserted: a registrar
          // that has served an island for a month should not die over a
          // bookkeeping gap in a diagnostic verb.
          timeAdd: _addedAt.remove(path) ?? timeRemove,
          timeRemove: timeRemove,
        ),
      );
      if (_history.length > _historyLimit) _history.removeLast();
    }
  }

  /// Removes what [path] names, returning everything actually removed.
  ///
  /// **Service `0` is the PROCESS, and removing it removes every service that
  /// process hosts** (`registrar.py:381-386`). That is not a special case bolted
  /// on: it is how a roster stays true when a process is killed rather than shut
  /// down, because the Last Will a broker publishes on its behalf names
  /// `{process}/0/state` and nothing finer. The two halves were designed
  /// together upstream and are only correct together.
  ///
  /// Returns the removed services in serving order so a caller can announce each
  /// one — upstream publishes a separate `(remove <path>)` per service, not one
  /// per request.
  List<ServiceDetails> remove(ServiceTopicPath path) {
    final processPath = path.processPath;
    final process = _byProcess[processPath];
    if (process == null) return const [];

    final removed = <ServiceDetails>[];
    if (path.isProcess) {
      removed.addAll(process.values);
      process.clear();
    } else {
      final one = process.remove(path.path);
      if (one != null) removed.add(one);
    }

    _count -= removed.length;
    _recordDepartures(removed);
    if (process.isEmpty) {
      _byProcess.remove(processPath);
      _processOrder.remove(processPath);
    }
    return removed;
  }

  ServiceDetails? lookup(ServiceTopicPath path) =>
      _byProcess[path.processPath]?[path.path];

  /// The services matching [filter], in serving order.
  ///
  /// `services_share` (`registrar.py:331-333`) builds its filter with topic_path
  /// pinned to `*` and only the five attribute fields taken from the request, so
  /// filtering here is by ATTRIBUTE only. A caller wanting a path filter is
  /// asking for something the wire cannot express.
  Iterable<ServiceDetails> filter(ServiceFilter filter) =>
      services.where(filter.matches);

  /// Forget everything.
  ///
  /// `registrar.py:281` — `self.services = Services()` when an `(primary absent)`
  /// arrives while this registrar is not searching. Reproduced faithfully and
  /// flagged loudly: on ADR-023's unauthenticated bus any peer can publish that,
  /// so this is a wire-reachable way to make a healthy registrar forget every
  /// service it knows.
  /// HISTORY SURVIVES THIS, and that is upstream's behaviour rather than a
  /// choice made here. `registrar.py:281` rebinds `self.services` and never
  /// touches `self.history`, which is a separate attribute.
  ///
  /// The consequence is worth naming because it is easy to read the wrong way:
  /// services dropped by this path leave NO departure record, so they simply
  /// vanish — they were not removed, the roster was replaced. A history
  /// consumer therefore cannot use "absent from the roster and absent from
  /// history" to mean anything. Combined with the note above — any peer can
  /// publish `(primary absent)` on an unauthenticated bus — that makes this the
  /// one way to make services disappear without a trace, in both
  /// implementations.
  void clear() {
    _byProcess.clear();
    _processOrder.clear();
    _addedAt.clear();
    _count = 0;
  }
}

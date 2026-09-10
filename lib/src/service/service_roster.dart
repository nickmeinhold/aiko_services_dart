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

import 'service_details.dart';
import 'service_topic_path.dart';

/// `main/__init__.py:16-17`. Not assembled from parts here: the whole string is
/// what a service publishes and what this file compares against, and building
/// it from three constants would invite one of them to drift.
const registrarProtocol =
    'github.com/geekscape/aiko_services/protocol/registrar:2';

/// An ordered, process-grouped set of known services.
final class ServiceRoster {
  final Map<String, Map<String, ServiceDetails>> _byProcess = {};

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
    process[servicePath] = service;
    _count++;
    return true;
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
  void clear() {
    _byProcess.clear();
    _processOrder.clear();
    _count = 0;
  }
}

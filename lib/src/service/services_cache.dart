/// The registrar's view of the island, mirrored locally.
///
/// **This is not an ECConsumer**, and that is worth stating because the shapes
/// rhyme. Both send a `(share ...)` and both receive `(item_count N)` followed
/// by `(add ...)`. Everything else differs, and the differences are the
/// protocol:
///
/// | | ECConsumer | ServicesCache |
/// |---|---|---|
/// | request | `(share <topic> <lease> <filter>)` | `(share <topic> * * * * *)` |
/// | sent to | the producer's `/control` | the registrar's `/in` |
/// | `add` arity | 2 — name, value | 6 — a service record |
/// | lease | yes, auto-extended | none |
/// | replies on | one topic | two: a private share topic AND the registrar's `/out` |
/// | "complete" | `items_received == item_count` | count reaches 0, THEN a `(sync ...)` arrives on `/out` |
///
/// Source: `share.py:688-830`. An earlier scoping note recorded these as one
/// mechanism used twice; they are two mechanisms that share three words.
library;

import 'dart:async';

import '../transport/mqtt_transport.dart';
import 'bus_process.dart';
import 'service_topic_path.dart';
import 'service_details.dart';

/// How much of the registrar's snapshot has landed.
///
/// The last two are distinct on purpose. At [loaded] the snapshot is complete
/// and readable; at [ready] the registrar has confirmed on its own `/out` topic
/// that nothing raced the snapshot. `share.py:823 wait_ready()` blocks for
/// [ready], not [loaded].
enum ServicesCacheState { empty, share, loaded, ready }

/// A change to the island's service roster.
sealed class const ServiceChange();

final class const ServiceAdded(final ServiceDetails service)
    extends ServiceChange;

final class const ServiceRemoved(final ServiceDetails service)
    extends ServiceChange;

/// The snapshot is complete and readable — [ServicesCacheState.loaded].
///
/// NOT the sync barrier, despite the reference calling this moment `sync`
/// (`share.py:810`, where `_update_handlers("sync")` fires at loaded). The
/// BEHAVIOUR is parity; the NAME was ours, and a `ServicesSynced` firing one
/// state before `ready` contradicted this file's own state documentation. A type
/// name that lies is worse than no type.
final class const ServicesLoaded() extends ServiceChange;

/// The roster has been dropped because the registrar that produced it is gone.
///
/// Emitted on a registrar loss or replacement. NOT a statement that the services
/// died — no [ServiceRemoved] accompanies it, matching `share.py:747
/// _cache_reset()`, because a registrar blinking says nothing about its members.
///
/// The reference emits nothing here at all, which leaves any consumer attached
/// to a producer this roster can no longer vouch for: the only teardown trigger
/// is a [ServiceRemoved] that will never come, so a lease goes on renewing into
/// a topic whose owner may already be dead. Emitting it is a deliberate,
/// additive divergence — a subscriber that holds resources on behalf of the
/// roster needs to be told the roster is no longer speaking for anything.
final class const RosterReleased() extends ServiceChange;

/// The registrar has confirmed on its own `/out` topic that nothing raced the
/// snapshot — [ServicesCacheState.ready].
///
/// The reference reaches this state and emits nothing (`share.py:816-818` sets
/// `ready` with no handler call), leaving a subscriber to poll a getter.
/// Emitting it is a deliberate, additive divergence: the state is public, so the
/// transition should be observable.
final class const ServicesReady() extends ServiceChange;

/// Mirrors the registrar's service roster.
class ServicesCache {
  ServicesCache(this._process);

  final BusProcess _process;

  /// Our private topic for the snapshot. `share.py:700`.
  late final String shareTopic = '${_process.topicPath.path}/registrar_share';

  final Map<String, ServiceDetails> _services = {};
  final _changes = StreamController<ServiceChange>.broadcast();

  ServicesCacheState _state = ServicesCacheState.empty;
  int? _itemCount;
  String? _registrarOut;
  bool _attached = false;
  StreamSubscription<ServiceTopicPath?>? _ladder;

  ServicesCacheState get state => _state;

  /// The roster, keyed by topic path. Empty until [state] reaches
  /// [ServicesCacheState.loaded] — reading before then is reading a snapshot
  /// mid-flight, which is why [state] is public.
  Iterable<ServiceDetails> get services => _services.values;

  /// Add/remove/sync as they happen.
  Stream<ServiceChange> get changes => _changes.stream;

  /// Starts mirroring, and keeps mirroring across a registrar restart.
  ///
  /// Requires the registrar to have been found once; [BusProcess.connect] does
  /// not return until it has. From then on this follows the connection ladder in
  /// BOTH directions, as `share.py:719-747` does — the reverse direction being
  /// the one that is easy to leave out and impossible to see. Without it, a
  /// registrar restart leaves the roster frozen at whatever it last held: no new
  /// share request goes out, no error is raised, and every outward sign of
  /// health persists over a view that stopped tracking the island.
  void attach() {
    if (_attached) return;
    if (_process.registrar == null) {
      throw StateError(
        'ServicesCache.attach() before the registrar was found; await '
        'BusProcess.connect() first',
      );
    }
    _attached = true;
    // Keyed on the registrar's IDENTITY, not on a ladder transition. A restarted
    // registrar announces a new `{host}/{pid}` and may do so with no intervening
    // `(primary absent)`, in which case the ladder never moves — it is already at
    // REGISTRAR. Listening for a transition would leave this cache subscribed to
    // a dead `/out` while never sending `(share …)` to the living `/in`, with
    // every outward sign of health intact. The reference drives this object from
    // the announcement; keying it off the ladder's equality was our error.
    _ladder = _process.registrarChanges.listen(_onRegistrarChanged);
    _requestRoster();
  }

  /// A registrar appeared, vanished, or was replaced by a different one.
  ///
  /// All three are the same move: let go of everything that was true only while
  /// the previous registrar was reachable, then ask the current one afresh. The
  /// release runs even when a new registrar is arriving, because the topics are
  /// derived from the path and the old pair is now a dead address.
  void _onRegistrarChanged(ServiceTopicPath? registrar) {
    _releaseRegistrar();
    if (registrar != null) _requestRoster();
  }

  /// Subscribes to the two reply topics and asks for everything.
  void _requestRoster() {
    final registrar = _process.registrar;
    if (registrar == null) return;
    _registrarOut = registrar.topicOut;
    _process.router.addHandler(shareTopic, _onShare);
    _process.router.addHandler(registrar.topicOut, _onRegistrarOut);
    // Five wildcards: name, protocol, transport, owner, tags. The registrar
    // filters server-side (`registrar.py:331 services_share()`); asking for
    // everything and filtering locally is what `ServiceFilter` is for.
    _process.bus.send(registrar.topicIn, 'share', <Object?>[
      shareTopic,
      ServiceFilter.anyValue,
      ServiceFilter.anyValue,
      ServiceFilter.anyValue,
      ServiceFilter.anyValue,
      ServiceFilter.anyValue,
    ]);
    _state = ServicesCacheState.share;
  }

  /// Drops everything that was true only while that registrar was alive.
  ///
  /// The roster is cleared rather than kept: it describes an island as one
  /// registrar saw it, and a registrar we can no longer reach is not a source
  /// we can still cite. No [ServiceRemoved] is emitted, matching
  /// `share.py:747 _cache_reset()` — a registrar blinking is not a statement
  /// that its services died, and the fresh snapshot on reconnection re-emits
  /// every [ServiceAdded] anyway.
  void _releaseRegistrar() {
    final out = _registrarOut;
    if (out == null) return;
    _process.router.removeHandler(shareTopic, _onShare);
    _process.router.removeHandler(out, _onRegistrarOut);
    _registrarOut = null;
    _services.clear();
    _itemCount = null;
    _state = ServicesCacheState.empty;
    _emit(const RosterReleased());
  }

  static List<Object?> _positional(AikoMessage message) =>
      switch (message.arguments) {
        PositionalArguments(:final values) => values,
        KeywordArguments() => const <Object?>[],
      };

  /// The snapshot, on our private topic. `share.py:781 registrar_share_handler`.
  void _onShare(AikoMessage message) {
    final parameters = _positional(message);
    switch ((message.command, parameters)) {
      case ('item_count', [final String n]) when int.tryParse(n) != null:
        _itemCount = int.parse(n);
      case ('add', _) when parameters.length >= 6:
        if (_itemCount == null) return; // an `add` with no frame open
        _itemCount = _itemCount! - 1;
        // `>= 6`, not `== 6`: the registrar's `history` reply carries the same
        // six fields plus `time_add` and `time_remove` (`registrar.py:320-327`),
        // and Python's share handler accepts both arities. We never ask for
        // history, so the tail is dropped rather than modelled.
        final service = ServiceDetails.tryParse(parameters.sublist(0, 6));
        if (service != null) _services[service.topicPath.path] = service;
      default:
        return;
    }

    if (_itemCount == 0) {
      _itemCount = null;
      _state = ServicesCacheState.loaded;
      _emit(const ServicesLoaded());
      for (final service in _services.values.toList()) {
        _emit(ServiceAdded(service));
      }
    }
  }

  /// Live changes, on the registrar's own topic.
  /// `share.py:813 registrar_out_handler`.
  void _onRegistrarOut(AikoMessage message) {
    final parameters = _positional(message);
    switch ((message.command, parameters)) {
      case ('sync', [final String topic]):
        // Only OUR snapshot's completion counts. The registrar answers every
        // consumer on the same `/out`, so an unfiltered `sync` would promote
        // this cache to ready on somebody else's snapshot.
        if (topic == shareTopic && _state == ServicesCacheState.loaded) {
          _state = ServicesCacheState.ready;
          _emit(const ServicesReady());
        }
      case ('add', _) when parameters.length == 6:
        final service = ServiceDetails.tryParse(parameters);
        if (service == null) return;
        _services[service.topicPath.path] = service;
        _emit(ServiceAdded(service));
      case ('remove', [final String path]):
        final service = _services.remove(path);
        if (service != null) _emit(ServiceRemoved(service));
      default:
        return;
    }
  }

  void _emit(ServiceChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  Future<void> terminate() async {
    if (!_attached) return;
    _attached = false;
    await _ladder?.cancel();
    _ladder = null;
    _releaseRegistrar();
    await _changes.close();
  }
}

/// Lookup over the mirrored roster.
extension ServiceLookup on ServicesCache {
  /// The first service matching [filter], or `null` if none does.
  ServiceDetails? findFirst(ServiceFilter filter) {
    for (final service in services) {
      if (filter.matches(service)) return service;
    }
    return null;
  }
}

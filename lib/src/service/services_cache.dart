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

/// The registrar has confirmed the snapshot is coherent.
final class const ServicesSynced() extends ServiceChange;

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

  ServicesCacheState get state => _state;

  /// The roster, keyed by topic path. Empty until [state] reaches
  /// [ServicesCacheState.loaded] — reading before then is reading a snapshot
  /// mid-flight, which is why [state] is public.
  Iterable<ServiceDetails> get services => _services.values;

  /// Add/remove/sync as they happen.
  Stream<ServiceChange> get changes => _changes.stream;

  /// Subscribes and requests the roster. Requires the registrar to have been
  /// found; [BusProcess.connect] does not return until it has.
  void attach() {
    if (_attached) return;
    final registrar = _process.registrar;
    if (registrar == null) {
      throw StateError(
        'ServicesCache.attach() before the registrar was found; await '
        'BusProcess.connect() first',
      );
    }
    _attached = true;
    _registrarOut = registrar.topicOut;
    _process.router.addHandler(shareTopic, _onShare);
    _process.router.addHandler(registrar.topicOut, _onRegistrarOut);
    // Five wildcards: name, protocol, transport, owner, tags. The registrar
    // filters server-side (`registrar.py:331 services_share()`); asking for
    // everything and filtering locally is what `ServiceFilter` is for.
    _process.bus.send(registrar.topicIn, 'share', <Object?>[
      shareTopic,
      '*',
      '*',
      '*',
      '*',
      '*',
    ]);
    _state = ServicesCacheState.share;
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
      _emit(const ServicesSynced());
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
    _process.router.removeHandler(shareTopic, _onShare);
    final out = _registrarOut;
    if (out != null) {
      _process.router.removeHandler(out, _onRegistrarOut);
    }
    _services.clear();
    _state = ServicesCacheState.empty;
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

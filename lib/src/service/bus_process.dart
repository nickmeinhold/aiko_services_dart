/// A process on the bus: its identity, its connection ladder, and the registrar
/// it has found.
///
/// This is the part of `process.py` an observer needs and no more. It does NOT
/// register services — and that is the finding the whole increment rests on.
/// `process.py:331 on_registrar()` reaches [ConnectionState.registrar] purely by
/// receiving the retained `(primary found ...)` announcement (`:348`); only
/// afterwards, at `:359-364`, does it push services THIS process has added.
/// A process that adds none is a first-class citizen of the bus that the
/// registrar never hears about.
library;

import 'dart:async';
import 'dart:io';

import '../dispatch/topic_router.dart';
import '../transport/mqtt_transport.dart';
import 'connection_state.dart';
import 'service_topic_path.dart';

/// Where every process listens for the registrar's retained announcement.
/// `process.py:91`, `TOPIC_REGISTRAR_BOOT`.
String registrarBootTopic(String namespace) => '$namespace/service/registrar';

/// A bus-attached process that owns no services.
class BusProcess {
  BusProcess({
    this.namespace = 'aiko',
    String? host,
    int? processId,
    String brokerHost = 'localhost',
    int brokerPort = 1883,
    MessageBus? bus,
  }) : // `process.py:100`. A `/` in either segment would silently re-shape the
       // four-segment path into something longer, so a hostname is taken only
       // for its first label — which is also what a container reports.
       // `Platform.localHostname` throws on a platform that cannot answer, and
       // it is the one line here that touches the OS. A host segment only has to
       // be stable and slash-free, so a failure degrades to something legible in
       // a topic rather than failing construction with an opaque trace.
       host = _sanitise(host ?? _localHostnameOr('unknown-host')),
       processId = processId ?? pid,
       bus = bus ?? AikoClient(host: brokerHost, port: brokerPort);

  static String _localHostnameOr(String fallback) {
    try {
      return Platform.localHostname;
    } on Object {
      return fallback;
    }
  }

  static String _sanitise(String host) =>
      host.split('.').first.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  final String namespace;
  final String host;
  final int processId;

  /// The transport. Injectable so the layers above can be exercised without a
  /// broker; in a real process this is an [AikoClient].
  final MessageBus bus;

  late final TopicRouter router = TopicRouter(bus);

  /// `process.py:101` — service id `0` is the process itself. Services this
  /// process added would be `1`, `2`, … from a monotonic counter; we add none.
  late final ServiceTopicPath topicPath = ServiceTopicPath(
    namespace,
    host,
    '$processId',
    '0',
  );

  ConnectionState _state = ConnectionState.none;
  ServiceTopicPath? _registrar;
  final _states = StreamController<ConnectionState>.broadcast();
  final _registrars = StreamController<ServiceTopicPath?>.broadcast();
  StreamSubscription<bool>? _transportWatch;

  ConnectionState get state => _state;

  /// Every transition, for a caller that needs to act on one. The current state
  /// is [state]; this stream does not replay it.
  Stream<ConnectionState> get states => _states.stream;

  /// The registrar's address, or `null` while it is absent.
  ServiceTopicPath? get registrar => _registrar;

  /// Every change of registrar IDENTITY, `null` when there is none.
  ///
  /// Distinct from [states], and the distinction is load-bearing. A registrar
  /// that restarts announces a NEW `{host}/{pid}` path; if it does so without an
  /// intervening `(primary absent)` — a retained overwrite, a replacement, the
  /// PID reuse this port has already measured on a container restart — then the
  /// ladder never moves, because it is already at [ConnectionState.registrar].
  /// Anything keyed on a ladder TRANSITION would go on talking to the dead
  /// address: the ladder cannot carry a new identity at the same potential.
  Stream<ServiceTopicPath?> get registrarChanges => _registrars.stream;

  /// Connects and waits until the registrar has been found.
  ///
  /// Returns when the ladder reaches [ConnectionState.registrar]. It does not
  /// time out: an island whose registrar is down is a legitimate state to wait
  /// in, and returning early would hand the caller a `null` registrar dressed
  /// as an answer.
  Future<void> connect() async {
    await bus.connect();
    // The wire's own liveness moves the ladder DOWN. Without this, `autoReconnect`
    // repairs a broken socket in silence while every layer above still reports
    // REGISTRAR — a roster frozen mid-restart, a lease renewing into a dead
    // topic, and no signal anywhere that the island stopped answering.
    _transportWatch = bus.transportUp.listen((up) {
      if (up) {
        _transition(ConnectionState.transport);
      } else {
        _setRegistrar(null);
        _transition(ConnectionState.none);
      }
    });
    _transition(ConnectionState.transport);
    final found = _awaitRegistrar();
    router.addHandler(registrarBootTopic(namespace), _onRegistrar);
    await found;
  }

  Future<void> _awaitRegistrar() {
    if (_state.isConnected(ConnectionState.registrar)) return Future.value();
    // `orElse` is load-bearing, not defensive padding: `firstWhere` on a stream
    // that CLOSES without a match throws StateError, and `disconnect()` closes
    // this stream unconditionally. So giving up on an island whose registrar is
    // down — the exact state the doc above says it is legitimate to wait in —
    // would complete this future with an exception the caller has no reason to
    // be catching. Waiting ends quietly when we stop waiting.
    return states
        .firstWhere(
          (s) => s.isConnected(ConnectionState.registrar),
          orElse: () => ConnectionState.none,
        )
        .then((_) {});
  }

  /// `process.py:331 on_registrar()`.
  ///
  /// Two payloads only: `(primary found <topic_path> <version> <timestamp>)`
  /// and `(primary absent)`. Anything else is ignored — this topic is
  /// world-writable on an unauthenticated bus, and a malformed announcement
  /// must not move the ladder.
  void _onRegistrar(AikoMessage message) {
    if (message.command != 'primary') return;
    final parameters = switch (message.arguments) {
      PositionalArguments(:final values) => values,
      KeywordArguments() => const <Object?>[],
    };
    switch (parameters) {
      case ['found', final String path, _, _]:
        final ServiceTopicPath registrar;
        try {
          registrar = ServiceTopicPath.parse(path);
        } on FormatException {
          return;
        }
        _setRegistrar(registrar);
        _transition(ConnectionState.registrar);
      case ['absent']:
        _setRegistrar(null);
        // Drop one rung, not to `none`: the broker is still connected.
        // `process.py:371-373` does exactly this.
        _transition(ConnectionState.transport);
      default:
        return;
    }
  }

  /// Records the registrar's identity and announces a CHANGE of it.
  ///
  /// Re-announcing the same path is not a change and stays quiet; a different
  /// path is a change even when the ladder does not move.
  void _setRegistrar(ServiceTopicPath? next) {
    if (next == _registrar) return;
    _registrar = next;
    if (!_registrars.isClosed) _registrars.add(next);
  }

  void _transition(ConnectionState next) {
    if (next == _state) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  Future<void> disconnect() async {
    await _transportWatch?.cancel();
    _transportWatch = null;
    await router.dispose();
    await bus.disconnect();
    _transition(ConnectionState.none);
    await _states.close();
    await _registrars.close();
  }
}

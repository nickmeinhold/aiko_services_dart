/// The first Dart process that joins a real island's bus.
///
/// It registers nothing, serves nothing, and nothing depends on it — it is a
/// process you POINT at an island. Run one against a live Python island and it
/// prints that island's channel list, then tracks it.
///
///     dart run example/bus_observer.dart --host localhost --namespace aiko
///
/// The six verbs it exists to demonstrate, each with its own visible evidence:
/// **connect** (the ladder reaches REGISTRAR), **discover** (the ChatServer
/// appears in the roster), **subscribe** (a share request goes out),
/// **receive** (the channel list prints), **leave** (Ctrl-C cancels the lease),
/// **recover** (restart the ChatServer under it and the list comes back).
library;

import 'dart:async';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);

  final process = BusProcess(
    namespace: options.namespace,
    brokerHost: options.host,
    brokerPort: options.port,
  );

  _log(
    'connecting to ${options.host}:${options.port} '
    'as ${process.topicPath}',
  );
  process.states.listen((state) => _log('connection state: ${state.name}'));

  await process.connect();
  _log('registrar found at ${process.registrar}');

  final roster = ServicesCache(process);
  final observer = _ChannelListObserver(process, options.serviceName);
  // Listen BEFORE attaching. `changes` is a broadcast stream, which drops every
  // event that arrives with no listener — so subscribing after `attach()` makes
  // correctness depend on the reply not arriving within the same synchronous
  // block. That happens to hold over MQTT today and is a property of delivery
  // latency, not of this code. `_attach()` below already gets this order right
  // for the consumer's own stream; this is the same hazard six lines up.
  roster.changes.listen(observer.onServiceChange);
  roster.attach();

  // A clean leave is a verb we owe evidence for, so it gets a real path rather
  // than process death: cancel the share lease, drop the subscriptions, then
  // disconnect.
  late final StreamSubscription<ProcessSignal> signals;
  signals = ProcessSignal.sigint.watch().listen((_) async {
    _log('leaving');
    await signals.cancel();
    // THROUGH the chain, not around it. This was the one caller that touched the
    // consumer slot directly, which defeats the serialisation it exists for: an
    // attach already in flight would resume after the shutdown detach and leave
    // a live consumer and a lease timer behind as the process exits — the exact
    // leak the chain was added to prevent, reintroduced by the shutdown path.
    await observer.detachSerialised();
    await roster.terminate();
    await process.disconnect();
    exit(0);
  });
}

/// Follows one named service and mirrors its `channel_list` share.
class _ChannelListObserver {
  _ChannelListObserver(this._process, this._serviceName);

  final BusProcess _process;
  final String _serviceName;

  ECConsumer? _consumer;
  StreamSubscription<ShareEvent>? _events;
  int _generation = 0;

  /// Serialises every mutation of the consumer slot.
  ///
  /// `detach()` yields twice — cancelling a subscription and closing a stream —
  /// so a remove immediately followed by an add runs two futures over one
  /// mutable field. The stale detach can resume AFTER the new consumer is in
  /// place and either terminate it or null the slot without terminating it: in
  /// the first case recovery dies silently with the generation already spent, in
  /// the second a lease timer and a handler leak while the observer believes it
  /// is waiting. A single island emitting remove-then-add in one breath is
  /// enough. Chaining is the fix: the slot has one writer at a time.
  Future<void> _slot = Future<void>.value();

  Future<void> _serialise(Future<void> Function() op) =>
      _slot = _slot.then((_) => op()).catchError((Object e) {
        _log('consumer transition failed: $e');
      });

  void onServiceChange(ServiceChange change) {
    switch (change) {
      case ServicesLoaded():
        // NOT the place to report absence. This event fires BEFORE the snapshot's
        // ServiceAdded events, so the consumer slot is necessarily still empty
        // here — the happy path printed "not present" every single run, one line
        // before attaching. Worse, the acceptance suite's negative control greps
        // for that string, so it was passing unconditionally: a check whose
        // outcome did not depend on the thing it checked.
        _log('roster loaded');
      case ServicesReady():
        // The registrar's own `/out` sync barrier: the roster is complete AND
        // confirmed, so an empty answer here is a real answer. Absence must be
        // stated — silence reads as success, and "no output" is also exactly
        // what a broken discover verb looks like.
        _log('roster confirmed by the registrar');
        if (_consumer == null) {
          _log('$_serviceName not present on this island — waiting for it');
        }
      case RosterReleased():
        // The registrar that vouched for our producer is gone, and no
        // ServiceRemoved is coming. Holding the consumer would renew a 300s
        // lease into a topic whose owner may already be dead — and if the
        // producer reincarnates at the same path (the PID reuse this port
        // measured), those renewals would bind a live producer to a generation
        // already in the grave.
        _log('registrar gone — releasing the consumer with the roster');
        unawaited(_serialise(detach));
      case ServiceAdded(:final service) when service.name == _serviceName:
        // A re-add without an intervening remove is not ruled out by the
        // protocol, so attaching is idempotent by detaching first — otherwise
        // the previous consumer's handler and lease leak.
        unawaited(_serialise(() => _attach(service)));
      case ServiceAdded(:final service):
        _log('service: ${service.name} (${service.topicPath})');
      case ServiceRemoved(:final service) when service.name == _serviceName:
        _log('${service.name} left — waiting for it to come back');
        // Deliberately no "channels removed" output: a producer disappearing is
        // a transient absence, not a statement that the channels are gone.
        unawaited(_serialise(detach));
      case ServiceRemoved(:final service):
        _log('service gone: ${service.name}');
    }
  }

  /// Attaches a consumer. Only ever called through [_serialise].
  Future<void> _attach(ServiceDetails service) async {
    await detach();
    if (!service.hasShare) {
      _log(
        '${service.name} advertises no ECProducer (no ec=true tag); '
        'not subscribing',
      );
      return;
    }
    final generation = ++_generation;
    final consumer = ECConsumer(
      _process.router,
      _process.bus,
      consumerPath: _process.topicPath,
      // Distinct per attachment: a restarted producer is a NEW subscription,
      // and reusing the id would make the old and new share-in topics the same
      // one — a stale handler and a live one on a single address.
      consumerId: generation,
      producerControlTopic: service.topicPath.topicControl,
      filter: 'channel_list',
    );
    _consumer = consumer;
    _log(
      'subscribing to ${service.topicPath.topicControl} '
      'filter=channel_list as consumer $generation',
    );
    _events = consumer.events.listen((event) => _onShareEvent(consumer, event));
    consumer.attach();
  }

  void _onShareEvent(ECConsumer consumer, ShareEvent event) {
    switch (event) {
      case ShareItemAdded() when consumer.cacheState == CacheState.ready:
        _printChannels(consumer);
      case ShareItemUpdated(:final path) || ShareItemRemoved(:final path):
        _log('channel_list changed: $path');
        _printChannels(consumer);
      case _:
        return;
    }
  }

  void _printChannels(ECConsumer consumer) {
    final channels = consumer.replica.read('channel_list');
    if (channels is! Map<String, Object?>) {
      _log('channel_list absent from the replica');
      return;
    }
    final names = channels.keys.toList()..sort();
    _log('channels (${names.length}): ${names.join(', ')}');
    for (final name in names) {
      _log('  $name = ${renderWireValue(channels[name])}');
    }
  }

  /// [detach] queued behind whatever the slot is already doing.
  Future<void> detachSerialised() => _serialise(detach);

  Future<void> detach() async {
    await _events?.cancel();
    _events = null;
    await _consumer?.terminate();
    _consumer = null;
  }
}

class _Options {
  const _Options(this.host, this.port, this.namespace, this.serviceName);

  factory _Options.parse(List<String> arguments) {
    var host = 'localhost';
    var port = 1883;
    var namespace = 'aiko';
    var serviceName = 'chat_server';
    for (var i = 0; i + 1 < arguments.length; i += 2) {
      final value = arguments[i + 1];
      switch (arguments[i]) {
        case '--host':
          host = value;
        case '--port':
          port = int.parse(value);
        case '--namespace':
          namespace = value;
        case '--service':
          serviceName = value;
        default:
          // Fail closed on an unrecognised flag rather than silently observing
          // the wrong island.
          stderr.writeln('unknown option: ${arguments[i]}');
          exit(64);
      }
    }
    return _Options(host, port, namespace, serviceName);
  }

  final String host;
  final int port;
  final String namespace;
  final String serviceName;
}

void _log(String message) =>
    stdout.writeln('${DateTime.now().toIso8601String()}  $message');

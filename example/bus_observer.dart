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
  roster.attach();

  final observer = _ChannelListObserver(process, options.serviceName);
  roster.changes.listen(observer.onServiceChange);

  // A clean leave is a verb we owe evidence for, so it gets a real path rather
  // than process death: cancel the share lease, drop the subscriptions, then
  // disconnect.
  late final StreamSubscription<ProcessSignal> signals;
  signals = ProcessSignal.sigint.watch().listen((_) async {
    _log('leaving');
    await signals.cancel();
    await observer.detach();
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

  void onServiceChange(ServiceChange change) {
    switch (change) {
      case ServicesSynced():
        _log('roster loaded');
        // Absence must be stated. A silent observer is indistinguishable from
        // one that is still starting up, and "no output" is exactly what a
        // broken discover verb also looks like.
        if (_consumer == null) {
          _log('$_serviceName not present on this island — waiting for it');
        }
      case ServiceAdded(:final service) when service.name == _serviceName:
        // A re-add without an intervening remove is not ruled out by the
        // protocol, so attaching is idempotent by detaching first — otherwise
        // the previous consumer's handler and lease leak.
        unawaited(_attach(service));
      case ServiceAdded(:final service):
        _log('service: ${service.name} (${service.topicPath})');
      case ServiceRemoved(:final service) when service.name == _serviceName:
        _log('${service.name} left — waiting for it to come back');
        // Deliberately no "channels removed" output: a producer disappearing is
        // a transient absence, not a statement that the channels are gone.
        unawaited(detach());
      case ServiceRemoved(:final service):
        _log('service gone: ${service.name}');
    }
  }

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

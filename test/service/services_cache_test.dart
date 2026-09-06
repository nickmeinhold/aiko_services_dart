import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_bus.dart';

const _registrar = 'aiko/island/1/1';
const _chatRecord = [
  'aiko/island/17/1',
  'chat_server',
  'p/chat_server:0',
  'mqtt',
  'root',
  ['ec=true'],
];
const _registrarRecord = [
  _registrar,
  'registrar',
  'p/registrar:2',
  'mqtt',
  'root',
  ['ec=true'],
];

Future<BusProcess> connectedProcess(FakeBus bus) async {
  final process = BusProcess(host: 'dart', processId: 99, bus: bus);
  final connected = process.connect();
  await bus.whenSubscribed('aiko/service/registrar');
  await bus.deliver('aiko/service/registrar', 'primary', [
    'found',
    _registrar,
    '2',
    '1234.5',
  ]);
  await connected;
  return process;
}

void main() {
  late FakeBus bus;
  late BusProcess process;
  late ServicesCache cache;

  setUp(() async {
    bus = FakeBus();
    process = await connectedProcess(bus);
    cache = ServicesCache(process);
  });

  group('BusProcess', () {
    test(
      'the retained announcement alone reaches REGISTRAR — no registration',
      () {
        expect(process.state, ConnectionState.registrar);
        expect(process.registrar?.path, _registrar);
        // Nothing was published. An observer that adds no services tells the
        // registrar nothing, which is the whole reason this increment is small.
        expect(bus.sent, isEmpty);
      },
    );

    test('a malformed announcement does not move the ladder', () async {
      final quiet = FakeBus();
      final p = BusProcess(host: 'dart', processId: 1, bus: quiet);
      final connected = p.connect();
      await quiet.whenSubscribed('aiko/service/registrar');
      await quiet.deliver('aiko/service/registrar', 'primary', [
        'found',
        'not-a-topic-path',
        '2',
        '1',
      ]);
      await quiet.deliver('aiko/service/registrar', 'primary', ['garbage']);
      expect(p.state, ConnectionState.transport);
      expect(p.registrar, isNull);
      // And then a good one lands, proving the probe could have observed it.
      await quiet.deliver('aiko/service/registrar', 'primary', [
        'found',
        _registrar,
        '2',
        '1',
      ]);
      await connected;
      expect(p.state, ConnectionState.registrar);
    });

    test('(primary absent) drops one rung, not to none', () async {
      await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
      expect(process.state, ConnectionState.transport);
      expect(process.registrar, isNull);
    });
  });

  group('ServicesCache', () {
    test('attach asks the registrar for everything, on two topics', () {
      cache.attach();
      expect(cache.shareTopic, 'aiko/dart/99/0/registrar_share');
      expect(
        bus.subscribed,
        containsAll([cache.shareTopic, '$_registrar/out']),
      );
      final request = bus.sent.single;
      expect(request.topic, '$_registrar/in');
      expect(request.command, 'share');
      // Five wildcards after the response topic: name, protocol, transport,
      // owner, tags (`registrar.py:331 services_share()`).
      expect(request.params, [cache.shareTopic, '*', '*', '*', '*', '*']);
      expect(cache.state, ServicesCacheState.share);
    });

    test(
      'attach before the registrar is known is an error, not a silent wait',
      () {
        final lonely = ServicesCache(
          BusProcess(host: 'dart', processId: 1, bus: FakeBus()),
        );
        expect(lonely.attach, throwsStateError);
      },
    );

    test('the snapshot loads, then the registrar confirms it', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);

      await bus.deliver(cache.shareTopic, 'item_count', ['2']);
      await bus.deliver(cache.shareTopic, 'add', _registrarRecord);
      expect(cache.state, ServicesCacheState.share);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);

      expect(cache.state, ServicesCacheState.loaded);
      expect(cache.services.map((s) => s.name), ['registrar', 'chat_server']);
      expect(changes.first, isA<ServicesSynced>());
      expect(changes.whereType<ServiceAdded>().length, 2);

      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      expect(cache.state, ServicesCacheState.ready);
    });

    // The registrar answers EVERY consumer on one `/out` topic. An unfiltered
    // `sync` would promote this cache to ready on somebody else's snapshot —
    // a state no live island produces on demand, which is exactly why it is
    // tested here rather than left to the acceptance run.
    test("another consumer's sync does not make this cache ready", () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.state, ServicesCacheState.loaded);

      await bus.deliver('$_registrar/out', 'sync', [
        'aiko/somebody/else/0/registrar_share',
      ]);
      expect(cache.state, ServicesCacheState.loaded);

      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      expect(cache.state, ServicesCacheState.ready);
    });

    test('live add and remove arrive on the registrar out topic', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);
      await bus.deliver(cache.shareTopic, 'item_count', ['0']);
      expect(cache.state, ServicesCacheState.loaded);

      await bus.deliver('$_registrar/out', 'add', _chatRecord);
      expect(
        changes.whereType<ServiceAdded>().single.service.name,
        'chat_server',
      );

      await bus.deliver('$_registrar/out', 'remove', ['aiko/island/17/1']);
      expect(
        changes.whereType<ServiceRemoved>().single.service.name,
        'chat_server',
      );
      expect(cache.services, isEmpty);
    });

    test('removing something never added emits nothing', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);
      await bus.deliver('$_registrar/out', 'remove', ['aiko/ghost/1/1']);
      expect(changes, isEmpty);
    });

    test('an add with no frame open is ignored', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.services, isEmpty);
      expect(cache.state, ServicesCacheState.share);
    });

    test('findFirst selects by attribute', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['2']);
      await bus.deliver(cache.shareTopic, 'add', _registrarRecord);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(
        cache
            .findFirst(const ServiceFilter(name: 'chat_server'))
            ?.topicPath
            .path,
        'aiko/island/17/1',
      );
      expect(cache.findFirst(const ServiceFilter(name: 'nope')), isNull);
    });

    test('terminate drops both subscriptions and empties the roster', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      await cache.terminate();
      expect(
        bus.unsubscribed,
        containsAll([cache.shareTopic, '$_registrar/out']),
      );
      expect(cache.services, isEmpty);
      expect(cache.state, ServicesCacheState.empty);
    });
  });
}

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_bus.dart';

const _in = 'aiko/testhost/7/1/in';
const _out = 'aiko/testhost/7/1/out';
const _reply = 'aiko/asker/3/1/registrar_share';

Future<void> settle() async {
  for (var turn = 0; turn < 20; turn++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A long search timeout, so nothing here is racing a promotion. These tests
/// are about what the registrar SERVES, not how it got the job.
RegistrarProcess _process(FakeBus bus) => RegistrarProcess(
  host: 'testhost',
  processId: 7,
  bus: bus,
  searchTimeout: const Duration(seconds: 30),
);

List<Object?> _add(String path, {String name = 'chat_server'}) => [
  path,
  name,
  'github.com/x/protocol/$name:0',
  'mqtt',
  'root',
  ['ec=true'],
];

const _wideOpen = ['*', '*', '*', '*', '*'];

void main() {
  late FakeBus bus;
  late RegistrarProcess registrar;

  setUp(() async {
    bus = FakeBus();
    registrar = _process(bus);
    await registrar.connect();
    bus.clear();
  });

  tearDown(() => registrar.disconnect());

  group('registration', () {
    test('an (add ...) joins the roster and is announced on /out', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();

      expect(registrar.roster.count, 1);
      final announced = bus.sent.single;
      expect(announced.topic, _out);
      expect(announced.command, 'add');
      expect((announced.params! as List<Object?>).first, 'aiko/h/1/1');
      // Live arrivals are NOT retained: a consumer that joins later asks for a
      // snapshot instead. Only primacy is retained in Aiko.
      expect(announced.retain, isFalse);
    });

    test('a duplicate registration produces NO traffic at all', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      bus.clear();

      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();

      expect(registrar.roster.count, 1);
      // process.py re-pushes every service on every `found`, which a reconnect
      // re-reads — so this is the routine path, not an edge case. A second
      // announcement would make every consumer see a second arrival.
      expect(bus.sent, isEmpty);
    });

    test('a (remove ...) announces exactly what left', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await bus.deliver(_in, 'add', _add('aiko/h/1/2'));
      await settle();
      bus.clear();

      await bus.deliver(_in, 'remove', const ['aiko/h/1/1']);
      await settle();

      expect(registrar.roster.count, 1);
      expect(bus.sent.single.command, 'remove');
      expect(bus.sent.single.params, ['aiko/h/1/1']);
    });

    test(
      'removing service 0 announces every service of that process',
      () async {
        await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
        await bus.deliver(_in, 'add', _add('aiko/h/1/2'));
        await bus.deliver(_in, 'add', _add('aiko/h/2/1'));
        await settle();
        bus.clear();

        // The shape a Last Will arrives in: the broker names {process}/0/state
        // and nothing finer.
        await bus.deliver(_in, 'remove', const ['aiko/h/1/0']);
        await settle();

        expect(registrar.roster.count, 1);
        // ONE announcement PER SERVICE. A consumer tracking individual paths
        // cannot act on a single message that means "and some others".
        expect(bus.sent, hasLength(2));
        expect(
          bus.sent.map((s) => (s.params! as List<Object?>).first),
          containsAll(<Object?>['aiko/h/1/1', 'aiko/h/1/2']),
        );
      },
    );

    test('service_count is published after every change', () async {
      final counts = <int>[];
      final sub = registrar.serviceCounts.listen(counts.add);
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await bus.deliver(_in, 'add', _add('aiko/h/1/2'));
      await bus.deliver(_in, 'remove', const ['aiko/h/1/1']);
      await settle();

      expect(counts, [1, 2, 1]);
      await sub.cancel();
    });
  });

  group('serving a snapshot', () {
    test('item_count, then one add each, then sync', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await bus.deliver(_in, 'add', _add('aiko/h/2/1', name: 'other'));
      await settle();
      bus.clear();

      await bus.deliver(_in, 'share', [_reply, ..._wideOpen]);
      await settle();

      final toReply = bus.sent.where((s) => s.topic == _reply).toList();
      expect(toReply, hasLength(3));
      expect(toReply[0].command, 'item_count');
      expect(toReply[0].params, [2]);
      expect(toReply[1].command, 'add');
      expect(toReply[2].command, 'add');
    });

    test('(sync ...) goes to OUR /out, not to the asker', () async {
      await bus.deliver(_in, 'share', [_reply, ..._wideOpen]);
      await settle();

      final sync = bus.sent.singleWhere((s) => s.command == 'sync');
      // registrar.py:349-350. This is how a consumer tells its own snapshot's
      // end from a peer's, and how every consumer learns somebody else asked.
      // Sending it to the reply topic would look identical for one consumer and
      // silently break the moment there are two.
      expect(sync.topic, _out);
      expect(sync.params, [_reply]);
    });

    test('an empty roster still gets a complete frame', () async {
      await bus.deliver(_in, 'share', [_reply, ..._wideOpen]);
      await settle();

      expect(bus.sent.first.command, 'item_count');
      expect(bus.sent.first.params, [0]);
      // A consumer completes its frame at zero. Skipping item_count for an
      // empty roster leaves it waiting forever for a snapshot that already
      // finished.
      expect(bus.sent.last.command, 'sync');
    });

    test(
      'the filter is honoured, and the count matches what follows',
      () async {
        await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
        await bus.deliver(_in, 'add', _add('aiko/h/2/1', name: 'other'));
        await settle();
        bus.clear();

        await bus.deliver(_in, 'share', [
          _reply,
          'chat_server',
          '*',
          '*',
          '*',
          '*',
        ]);
        await settle();

        final toReply = bus.sent.where((s) => s.topic == _reply).toList();
        expect(toReply.first.params, [1]);
        // The count and the rows must come from ONE walk. A count from one walk
        // and rows from another is a frame that never completes.
        expect(toReply.where((s) => s.command == 'add'), hasLength(1));
      },
    );
  });

  group('the world-writable /in topic', () {
    test('wrong arity is dropped in silence', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1')..removeLast());
      await bus.deliver(_in, 'add', [..._add('aiko/h/1/1'), 'extra']);
      await bus.deliver(_in, 'remove', const []);
      await bus.deliver(_in, 'remove', const ['a', 'b']);
      await bus.deliver(_in, 'share', const ['too', 'few']);
      await bus.deliver(_in, 'sabotage', const []);
      await settle();

      expect(registrar.roster.count, 0);
      expect(bus.sent, isEmpty);
    });

    test('an unparseable path in a remove is dropped', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      bus.clear();

      await bus.deliver(_in, 'remove', const ['not-a-topic-path']);
      await settle();

      expect(registrar.roster.count, 1);
      expect(bus.sent, isEmpty);
    });

    test('a reply topic we cannot publish to is refused', () async {
      await bus.deliver(_in, 'share', ['', ..._wideOpen]);
      await bus.deliver(_in, 'share', ['a/+/b', ..._wideOpen]);
      await bus.deliver(_in, 'share', ['a/#', ..._wideOpen]);
      await settle();

      // Parity, not a unilateral divergence: upstream validates topic_response
      // not at all, and the only rejections observed were paho refusing exactly
      // these. The wider hole is left open and stays filed.
      expect(bus.sent, isEmpty);
    });
  });

  group('noticing a death nobody announced (verb 4)', () {
    test('a will on a PROCESS state topic removes all its services', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await bus.deliver(_in, 'add', _add('aiko/h/1/2'));
      await bus.deliver(_in, 'add', _add('aiko/h/2/1'));
      await settle();
      bus.clear();

      // The exact topic and payload a broker publishes for a dead process:
      // {ns}/{host}/{pid}/0/state, `(absent)`, un-retained.
      await bus.deliver('aiko/h/1/0/state', 'absent', const []);
      await settle();

      expect(registrar.roster.count, 1);
      expect(bus.sent.map((s) => s.command).toSet(), {'remove'});
      expect(bus.sent, hasLength(2));
    });

    test(
      'a will on a single SERVICE state topic removes only that one',
      () async {
        await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
        await bus.deliver(_in, 'add', _add('aiko/h/1/2'));
        await settle();
        bus.clear();

        await bus.deliver('aiko/h/1/2/state', 'absent', const []);
        await settle();

        expect(registrar.roster.topicPaths, ['aiko/h/1/1']);
      },
    );

    test('any other state payload is ignored', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      bus.clear();

      // A live island's state topics carry more than deaths. Acting on
      // anything but `(absent)` would evict healthy services.
      await bus.deliver('aiko/h/1/0/state', 'ready', const []);
      await bus.deliver('aiko/h/1/0/state', 'running', const []);
      await settle();

      expect(registrar.roster.count, 1);
      expect(bus.sent, isEmpty);
    });

    test('a will for a process we never knew changes nothing', () async {
      await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
      await settle();
      bus.clear();

      await bus.deliver('aiko/h/9/0/state', 'absent', const []);
      await settle();

      expect(registrar.roster.count, 1);
      expect(bus.sent, isEmpty);
    });

    test('the subscription is a depth-exact filter, not a suffix match', () async {
      expect(registrar.serviceStateFilter, 'aiko/+/+/+/state');
      // The reference's local matcher compares only the first and last segments
      // of a `+` filter, so this topic matches there. Ours refuses it, and the
      // broker would never have delivered it either.
      expect(
        topicFilterMatches(registrar.serviceStateFilter, 'aiko/h/state'),
        isFalse,
      );
    });
  });

  test('(primary absent) while primary drops the roster', () async {
    await bus.deliver(_in, 'add', _add('aiko/h/1/1'));
    await settle();
    // Promote, then have any peer say the primary is gone.
    await bus.deliver('aiko/service/registrar', 'primary', const ['absent']);
    await settle();
    expect(registrar.role, RegistrarRole.primary);

    await bus.deliver('aiko/service/registrar', 'primary', const ['absent']);
    await settle();

    // registrar.py:281, reproduced faithfully and flagged: on this bus any peer
    // can make a healthy registrar forget every service it knows.
    expect(registrar.roster.count, 0);
  });
}

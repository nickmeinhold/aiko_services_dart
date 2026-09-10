import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

ServiceDetails _service(
  String path, {
  String name = 'thing',
  String protocol = 'github.com/x/protocol/thing:0',
  List<String> tags = const ['ec=true'],
}) => ServiceDetails(
  topicPath: ServiceTopicPath.parse(path),
  name: name,
  protocol: protocol,
  transport: 'mqtt',
  owner: 'root',
  tags: tags,
);

ServiceDetails _registrar(String path) =>
    _service(path, name: 'registrar', protocol: registrarProtocol);

void main() {
  group('adding', () {
    test('a repeat registration is ignored and reports it', () {
      final roster = ServiceRoster();
      expect(roster.add(_service('aiko/h/1/1')), isTrue);
      expect(roster.add(_service('aiko/h/1/1')), isFalse);
      expect(roster.count, 1);
      // Publicly visible, not an internal nicety: `service_add` builds its
      // (add …) payload before the guard and publishes INSIDE it, so a
      // duplicate registration produces no traffic. process.py re-pushes every
      // service on every `found`, so this fires on every reconnect.
    });

    test('count tracks services, not processes', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1'));
      roster.add(_service('aiko/h/1/2'));
      roster.add(_service('aiko/h/2/1'));
      expect(roster.count, 3);
      // The counter and a walk must agree. Upstream keeps a counter and its own
      // comment asks why len() is wrong; the answer is that len() counts
      // PROCESSES, which is 2 here.
      expect(roster.services, hasLength(3));
    });
  });

  group('serving order', () {
    test('a registrar process is served FIRST, however late it arrives', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1', name: 'chat_server'));
      roster.add(_service('aiko/h/2/1', name: 'other'));
      roster.add(_registrar('aiko/h/9/1'));

      expect(roster.topicPaths.first, 'aiko/h/9/1');
      // Observable on the wire: this is the order (share …) replies in, and the
      // live island's roster puts its registrar first for exactly this reason.
    });

    test('the ordering decision is made once, by the first service of a process', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1', name: 'chat_server'));
      // A registrar-protocol service arriving into a process that was already
      // created as something else must NOT re-promote it: upstream only reaches
      // move_to_end on the branch that creates the process entry.
      roster.add(_registrar('aiko/h/1/2'));

      expect(roster.topicPaths, ['aiko/h/1/1', 'aiko/h/1/2']);
    });
  });

  group('removing', () {
    test('one service leaves its siblings alone', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1'));
      roster.add(_service('aiko/h/1/2'));

      final removed = roster.remove(ServiceTopicPath.parse('aiko/h/1/1'));
      expect(removed.map((s) => s.topicPath.path), ['aiko/h/1/1']);
      expect(roster.count, 1);
      expect(roster.topicPaths, ['aiko/h/1/2']);
    });

    test('service 0 removes every service of that process', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1'));
      roster.add(_service('aiko/h/1/2'));
      roster.add(_service('aiko/h/1/3'));
      roster.add(_service('aiko/h/2/1'));

      // This is the shape a Last Will arrives in: the broker publishes
      // {ns}/{host}/{pid}/0/state and nothing finer, so a process dies as a
      // unit or the roster keeps serving corpses.
      final removed = roster.remove(ServiceTopicPath.parse('aiko/h/1/0'));

      expect(removed, hasLength(3));
      expect(roster.count, 1);
      expect(roster.topicPaths, ['aiko/h/2/1']);
    });

    test('removing the last service drops the process from the order', () {
      final roster = ServiceRoster();
      roster.add(_registrar('aiko/h/9/1'));
      roster.add(_service('aiko/h/1/1'));
      roster.remove(ServiceTopicPath.parse('aiko/h/9/1'));
      roster.add(_registrar('aiko/h/8/1'));

      // If the emptied process lingered in the order list, the new registrar
      // would be inserted in front of a ghost and the count would drift.
      expect(roster.topicPaths, ['aiko/h/8/1', 'aiko/h/1/1']);
      expect(roster.count, 2);
    });

    test('removing something unknown removes nothing and says so', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1'));
      expect(roster.remove(ServiceTopicPath.parse('aiko/h/5/1')), isEmpty);
      expect(roster.remove(ServiceTopicPath.parse('aiko/h/1/7')), isEmpty);
      expect(roster.count, 1);
    });
  });

  group('filtering', () {
    test('matches by attribute, in serving order', () {
      final roster = ServiceRoster();
      roster.add(_registrar('aiko/h/9/1'));
      roster.add(_service('aiko/h/1/1', name: 'chat_server'));
      roster.add(_service('aiko/h/2/1', name: 'chat_server'));

      final matched = roster.filter(
        const ServiceFilter(
          name: 'chat_server',
          protocol: ServiceFilter.anyValue,
          transport: ServiceFilter.anyValue,
          owner: ServiceFilter.anyValue,
          tags: AnyTags(),
        ),
      );
      expect(matched.map((s) => s.topicPath.path), [
        'aiko/h/1/1',
        'aiko/h/2/1',
      ]);
    });

    test('a wide-open filter returns everything, registrar first', () {
      final roster = ServiceRoster();
      roster.add(_service('aiko/h/1/1'));
      roster.add(_registrar('aiko/h/9/1'));

      const wideOpen = ServiceFilter(
        name: ServiceFilter.anyValue,
        protocol: ServiceFilter.anyValue,
        transport: ServiceFilter.anyValue,
        owner: ServiceFilter.anyValue,
        tags: AnyTags(),
      );
      expect(roster.filter(wideOpen).map((s) => s.topicPath.path), [
        'aiko/h/9/1',
        'aiko/h/1/1',
      ]);
    });
  });

  test('clear forgets everything, order included', () {
    final roster = ServiceRoster();
    roster.add(_registrar('aiko/h/9/1'));
    roster.add(_service('aiko/h/1/1'));
    roster.clear();

    expect(roster.count, 0);
    expect(roster.isEmpty, isTrue);
    expect(roster.services, isEmpty);
    // A stale order entry would resurrect on the next add.
    roster.add(_service('aiko/h/1/1'));
    expect(roster.topicPaths, ['aiko/h/1/1']);
  });
}

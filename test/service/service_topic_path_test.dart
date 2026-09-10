import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('ServiceTopicPath', () {
    test('parses the four-segment wire form and derives its topics', () {
      final path = ServiceTopicPath.parse('aiko/host/17/1');
      expect(path.namespace, 'aiko');
      expect(path.host, 'host');
      expect(path.processId, '17');
      expect(path.serviceId, '1');
      expect(path.topicIn, 'aiko/host/17/1/in');
      expect(path.topicOut, 'aiko/host/17/1/out');
      expect(path.topicControl, 'aiko/host/17/1/control');
      expect(path.topicState, 'aiko/host/17/1/state');
    });

    // The registrar's announcement topic is world-writable on an
    // unauthenticated bus, so a malformed path must not compose into a
    // subscription to something unintended.
    test('rejects every wrong shape rather than composing a wrong topic', () {
      for (final wire in [
        'aiko/host/17',
        'aiko/host/17/1/extra',
        'aiko//17/1',
        '',
        'aiko/host/17/',
      ]) {
        expect(
          () => ServiceTopicPath.parse(wire),
          throwsFormatException,
          reason: '"$wire" should not parse',
        );
      }
    });

    // `+` and `#` are MQTT subscription wildcards, not name characters — a path
    // carrying one changes what a DERIVED topic means. `aiko/+/1/1` composes to
    // a subscription matching every host's `/out`, and this value arrives from
    // world-writable topics on an unauthenticated bus.
    test('rejects MQTT wildcards, which change what a derived topic means', () {
      for (final wire in [
        'aiko/+/1/1',
        'aiko/h/#/1',
        'aiko/h/1/+',
        '+/h/1/1',
        'aiko/ho+st/1/1',
      ]) {
        expect(
          () => ServiceTopicPath.parse(wire),
          throwsFormatException,
          reason: '"$wire" would compose into a wildcard subscription',
        );
      }
    });

    // A process, not a service, is what dies. The LWT lands on the process's
    // `0` path and the registrar answers it by removing every service of that
    // process, so the roster has to be able to ask "who belongs to this
    // process?" — which needs the path with the service id dropped.
    test('exposes the owning process path, which is what an LWT names', () {
      final service = ServiceTopicPath.parse('aiko/host/17/3');
      expect(service.processPath, 'aiko/host/17');
      expect(service.isProcess, isFalse);

      final process = ServiceTopicPath.parse('aiko/host/17/0');
      expect(process.processPath, 'aiko/host/17');
      expect(process.isProcess, isTrue);
      expect(
        process.topicState,
        'aiko/host/17/0/state',
        reason: 'the per-process LWT topic, verified on a live island',
      );
    });

    // Every service of one process shares a process path, and that is the
    // property the remove-all branch relies on. Asserting it on siblings
    // rather than on one path is what makes the test able to fail if the
    // getter ever included the service id.
    test('siblings of one process agree on the process path', () {
      final siblings = ['aiko/h/9/0', 'aiko/h/9/1', 'aiko/h/9/2']
          .map(ServiceTopicPath.parse)
          .map((p) => p.processPath)
          .toSet();
      expect(siblings, hasLength(1));
      expect(siblings.single, 'aiko/h/9');
    });

    // The must-fail direction: two processes on one host must NOT collapse
    // together, or "remove every service of this process" would take out a
    // bystander's services.
    test('different processes on one host do not share a process path', () {
      expect(
        ServiceTopicPath.parse('aiko/h/9/1').processPath,
        isNot(ServiceTopicPath.parse('aiko/h/10/1').processPath),
      );
    });

    test('equality is by path, so it can key a roster', () {
      expect(
        ServiceTopicPath.parse('aiko/h/1/2'),
        equals(const ServiceTopicPath('aiko', 'h', '1', '2')),
      );
    });
  });

  group('ConnectionState', () {
    test('is a ladder: each state implies every state below it', () {
      expect(
        ConnectionState.registrar.isConnected(ConnectionState.transport),
        isTrue,
      );
      expect(
        ConnectionState.registrar.isConnected(ConnectionState.registrar),
        isTrue,
      );
      expect(
        ConnectionState.transport.isConnected(ConnectionState.registrar),
        isFalse,
      );
      expect(
        ConnectionState.none.isConnected(ConnectionState.network),
        isFalse,
      );
    });

    test('declaration order is the ordering, with no second list to drift', () {
      expect(ConnectionState.values.map((s) => s.name), [
        'none',
        'network',
        'transport',
        'registrar',
      ]);
    });
  });
}

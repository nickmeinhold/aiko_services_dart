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

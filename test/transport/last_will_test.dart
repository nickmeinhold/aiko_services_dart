import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('LastWill', () {
    // The two wills in Aiko differ in EVERY field, which is the reason this is
    // a value type rather than a constant. Three of this repo's own documents
    // asserted the process will was retained before `process.py:169` was read.
    test('the process will is un-retained, matching the reference', () {
      final will = LastWill.processAbsent('aiko/host/17');
      expect(will.topic, 'aiko/host/17/0/state');
      expect(will.payload, '(absent)');
      expect(
        will.retain,
        isFalse,
        reason: 'process.py:169 passes False as position 5 of MQTT.__init__',
      );
    });

    // The registrar's is the other shape: different topic, different payload,
    // and RETAINED so a late joiner can discover primacy without asking.
    test('a registrar will is a different shape in all three fields', () {
      const will = LastWill(
        topic: 'aiko/service/registrar',
        payload: '(primary absent)',
        retain: true,
      );
      final process = LastWill.processAbsent('aiko/host/17');
      expect(will.topic, isNot(process.topic));
      expect(will.payload, isNot(process.payload));
      expect(will.retain, isNot(process.retain));
    });

    // The service id is `0` because a PROCESS dies, not a service — the same
    // magic value ServiceTopicPath.isProcess names, and the reason the
    // registrar's remove branch sweeps every service of that process.
    test('the will topic addresses the process, not one of its services', () {
      final will = LastWill.processAbsent('aiko/host/17');
      final path = ServiceTopicPath.parse('aiko/host/17/0');
      expect(will.topic, path.topicState);
      expect(path.isProcess, isTrue);
      expect(path.processPath, 'aiko/host/17');
    });

    test('toString names the retain flag, which is easy to get wrong', () {
      expect(
        LastWill.processAbsent('aiko/h/1').toString(),
        'LastWill(aiko/h/1/0/state: (absent))',
      );
      expect(
        const LastWill(topic: 't', payload: 'p', retain: true).toString(),
        contains('retained'),
      );
    });
  });

  group('AikoClient will wiring', () {
    // A client with no will is the normal case — an observer needs none, and
    // that is why the transport went this long without one.
    test('a client without a will holds null, not an empty will', () {
      final client = AikoClient(clientId: 'test');
      expect(client.will, isNull);
    });

    test('a client keeps the will it was given', () {
      final will = LastWill.processAbsent('aiko/h/1');
      final client = AikoClient(clientId: 'test', will: will);
      expect(client.will, same(will));
    });
  });
}

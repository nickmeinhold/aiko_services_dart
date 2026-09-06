import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

// Captured verbatim from a live island's registrar share, 2026-09-06.
const _chatServer = [
  'aiko/4b4281a12660/17/1',
  'chat_server',
  'github.com/geekscape/aiko_services/protocol/chat_server:0',
  'mqtt',
  'root',
  ['ec=true'],
];

void main() {
  group('ServiceDetails.tryParse', () {
    test('reads a real registrar record', () {
      final service = ServiceDetails.tryParse(_chatServer)!;
      expect(service.topicPath.path, 'aiko/4b4281a12660/17/1');
      expect(service.name, 'chat_server');
      expect(service.transport, 'mqtt');
      expect(service.owner, 'root');
      expect(service.tags, ['ec=true']);
      expect(service.hasShare, isTrue);
      expect(service.topicPath.topicControl, 'aiko/4b4281a12660/17/1/control');
    });

    test('a service with no ECProducer advertises no share', () {
      final service = ServiceDetails.tryParse([
        'aiko/h/1/1',
        'plain',
        'p',
        'mqtt',
        'root',
        <Object?>[],
      ])!;
      expect(service.hasShare, isFalse);
    });

    test('drops a record it cannot trust rather than half-reading it', () {
      expect(ServiceDetails.tryParse(_chatServer.sublist(0, 5)), isNull);
      expect(
        ServiceDetails.tryParse([
          'not-a-topic-path',
          'n',
          'p',
          't',
          'o',
          <Object?>[],
        ]),
        isNull,
      );
      expect(
        ServiceDetails.tryParse([
          'aiko/h/1/1',
          ['a', 'list', 'where', 'a', 'name', 'goes'],
          'p',
          't',
          'o',
          <Object?>[],
        ]),
        isNull,
      );
    });
  });

  group('ServiceFilter', () {
    final chat = ServiceDetails.tryParse(_chatServer)!;

    test('a bare wildcard matches everything', () {
      expect(const ServiceFilter().matches(chat), isTrue);
    });

    test('names must match exactly', () {
      expect(const ServiceFilter(name: 'chat_server').matches(chat), isTrue);
      expect(const ServiceFilter(name: 'chat_serve').matches(chat), isFalse);
      expect(const ServiceFilter(name: 'registrar').matches(chat), isFalse);
    });

    test('every named attribute must match, not just one', () {
      expect(
        const ServiceFilter(
          name: 'chat_server',
          transport: 'zeromq',
        ).matches(chat),
        isFalse,
      );
    });
  });
}

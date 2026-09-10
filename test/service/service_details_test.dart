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

  group('malformed tag lists fail closed', () {
    // `hasShare` is read from these tags to decide whether to send a share
    // request, and every other arm of this parser fails closed. Partially
    // accepting a record — keeping the strings and dropping the rest — was the
    // one place it did not.
    test('a non-list tags field is a malformed record, not "no tags"', () {
      expect(
        ServiceDetails.tryParse([
          'aiko/h/1/1',
          'n',
          'p',
          'mqtt',
          'root',
          'ec=true',
        ]),
        isNull,
      );
    });

    test('a tag list with a non-string element is rejected whole', () {
      expect(
        ServiceDetails.tryParse([
          'aiko/h/1/1',
          'n',
          'p',
          'mqtt',
          'root',
          [
            'ec=true',
            <Object?>['nested'],
          ],
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

  group('ServiceFilter tags', () {
    // Two tags, so "subset" is distinguishable from "equal".
    final multi = ServiceDetails.tryParse([
      'aiko/h/1/1',
      'svc',
      'p:0',
      'mqtt',
      'root',
      ['ec=true', 'role=leaf'],
    ])!;
    final tagless = ServiceDetails.tryParse([
      'aiko/h/1/2',
      'plain',
      'p:0',
      'mqtt',
      'root',
      <String>[],
    ])!;

    test('the wildcard ignores tags entirely', () {
      expect(const ServiceFilter().matches(multi), isTrue);
      expect(const ServiceFilter().matches(tagless), isTrue);
    });

    test('required tags are a SUBSET test — extra service tags are fine', () {
      expect(
        const ServiceFilter(tags: RequiredTags(['ec=true'])).matches(multi),
        isTrue,
      );
      expect(
        const ServiceFilter(tags: RequiredTags(['role=leaf', 'ec=true']))
            .matches(multi),
        isTrue,
        reason: 'order is irrelevant',
      );
      expect(
        const ServiceFilter(tags: RequiredTags(['ec=true'])).matches(tagless),
        isFalse,
      );
    });

    test('matching is whole-string: no key-only, no prefix', () {
      for (final wrong in ['ec', 'ec=t', 'EC=true', 'ec=true ']) {
        expect(
          ServiceFilter(tags: RequiredTags([wrong])).matches(multi),
          isFalse,
          reason: '"$wrong" must not match "ec=true"',
        );
      }
    });

    // The edge that inverts under the obvious instinct. `[] != "*"` so the
    // reference ENTERS the tag branch, and `all([])` is true — an empty
    // required list matches EVERY service, tagless ones included. Writing
    // `if (required.isEmpty) return false` would be backwards.
    test('an empty required list matches everything, as `all([])` does', () {
      expect(
        const ServiceFilter(tags: RequiredTags([])).matches(multi),
        isTrue,
      );
      expect(
        const ServiceFilter(tags: RequiredTags([])).matches(tagless),
        isTrue,
        reason: 'including a service with no tags at all',
      );
    });

    // `*` and `()` agree on every outcome and are still different wire bytes,
    // which is why this is a sealed pair rather than one field with a magic
    // member. A List cannot hold `*`; a String cannot hold the list.
    test('`*` and `()` agree on outcomes but stay distinguishable', () {
      const wildcard = ServiceFilter();
      const empty = ServiceFilter(tags: RequiredTags([]));
      for (final s in [multi, tagless]) {
        expect(wildcard.matches(s), empty.matches(s));
      }
      expect(wildcard.tags, isA<AnyTags>());
      expect(empty.tags, isA<RequiredTags>());
    });

    group('tryParseTags reads the wire slot', () {
      test('the atom `*` is the wildcard', () {
        expect(ServiceFilter.tryParseTags('*'), isA<AnyTags>());
      });

      test('a sub-list is a requirement, empty included', () {
        final one = ServiceFilter.tryParseTags(<Object?>['ec=true']);
        expect((one! as RequiredTags).required, ['ec=true']);
        final none = ServiceFilter.tryParseTags(<Object?>[]);
        expect((none! as RequiredTags).required, isEmpty);
      });

      // The reference does not refuse a bare atom here: "ec=true" != "*" sends
      // it into match_tags, which iterates the STRING and tests each CHARACTER
      // for membership. No conformant sender produces that, so we refuse rather
      // than reproduce it.
      test(
        'a bare non-wildcard atom is refused, not iterated per character',
        () {
          expect(ServiceFilter.tryParseTags('ec=true'), isNull);
        },
      );

      test('a list containing a non-String is refused', () {
        expect(ServiceFilter.tryParseTags(<Object?>['ok', 7]), isNull);
        expect(ServiceFilter.tryParseTags(<Object?>['ok', null]), isNull);
        expect(
          ServiceFilter.tryParseTags(<Object?>[
            <Object?>['nested'],
          ]),
          isNull,
        );
      });

      test('a map or null is refused', () {
        expect(ServiceFilter.tryParseTags(null), isNull);
        expect(ServiceFilter.tryParseTags(<String, Object?>{}), isNull);
      });
    });
  });
}

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('classifyShareEvent', () {
    test('reads all five producer -> consumer forms', () {
      expect(
        classifyShareEvent('item_count', ['5']),
        isA<ShareItemCount>().having((e) => e.count, 'count', 5),
      );
      expect(
        classifyShareEvent('add', ['channel_list.general', 'x']),
        isA<ShareItemAdded>()
            .having((e) => e.path, 'path', 'channel_list.general')
            .having((e) => e.value, 'value', 'x'),
      );
      expect(
        classifyShareEvent('update', ['metrics.running', '3']),
        isA<ShareItemUpdated>(),
      );
      expect(
        classifyShareEvent('remove', ['lifecycle']),
        isA<ShareItemRemoved>(),
      );
      expect(classifyShareEvent('sync', ['whatever']), isA<ShareSync>());
    });

    test('a nested value survives as a list, not a flattened string', () {
      final event = classifyShareEvent('add', [
        'channel_list.general',
        ['*', 'general', <Object?>[]],
      ]);
      expect(event, isA<ShareItemAdded>());
      expect((event! as ShareItemAdded).value, isA<List<Object?>>());
    });

    // This topic is reachable by any peer on an unauthenticated bus, so an
    // unrecognised payload is an expected input to drop — not an exception, and
    // never a partially-applied mutation.
    test('drops anything that is not one of the five', () {
      expect(classifyShareEvent('add', ['only-one-parameter']), isNull);
      expect(classifyShareEvent('add', ['a', 'b', 'c']), isNull);
      expect(classifyShareEvent('item_count', ['not-a-number']), isNull);
      expect(classifyShareEvent('item_count', []), isNull);
      expect(classifyShareEvent('remove', []), isNull);
      expect(classifyShareEvent('destroy_everything', ['x']), isNull);
    });
  });

  group('renderWireValue', () {
    test('prints a decoded value the way the island wrote it', () {
      expect(
        renderWireValue(['*', 'general', '*', '*', '*', <Object?>[]]),
        '(* general * * * ())',
      );
      expect(
        renderWireValue([
          ['*', 'general', '*', '*', '*', <Object?>[]],
          'None',
          'None',
        ]),
        '((* general * * * ()) None None)',
      );
    });

    test('a null renders as the wire null, not the word', () {
      expect(renderWireValue(null), '0:');
    });
  });
}

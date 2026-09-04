/// `classifyArguments` is the wire-boundary discrimination that replaced an
/// `Object? params // List or Map` comment.
///
/// The cases are driven from real `parse()` output rather than hand-built
/// literals, so the test fails if the codec's `cdr` contract ever moves —
/// which is the only way the sealed set could become wrong.
library;

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  group('classifyArguments, fed from parse()', () {
    test('positional arguments classify as PositionalArguments', () {
      final (_, cdr) = parse('(add channel_list general)');
      final arguments = classifyArguments(cdr);
      expect(arguments, isA<PositionalArguments>());
      expect((arguments as PositionalArguments).values, [
        'channel_list',
        'general',
      ]);
    });

    test('keyword arguments classify as KeywordArguments', () {
      final (_, cdr) = parse('(update lease: 300 filter: channel_list)');
      final arguments = classifyArguments(cdr);
      expect(arguments, isA<KeywordArguments>());
      expect((arguments as KeywordArguments).values, {
        'lease': '300',
        'filter': 'channel_list',
      });
    });

    test('a command with no arguments is empty positional, not null', () {
      final (_, cdr) = parse('(sync)');
      final arguments = classifyArguments(cdr);
      expect(arguments, isA<PositionalArguments>());
      expect((arguments as PositionalArguments).values, isEmpty);
    });

    test('an exhaustive switch needs no default arm', () {
      // The point of sealing: this compiles only while the set stays closed.
      String describe(CallArguments arguments) => switch (arguments) {
        PositionalArguments(:final values) => 'positional:${values.length}',
        KeywordArguments(:final values) => 'keyword:${values.length}',
      };
      expect(describe(classifyArguments(parse('(a b c)').$2)), 'positional:2');
      expect(describe(classifyArguments(parse('(a b: c)').$2)), 'keyword:1');
    });
  });

  group('the must-fail arm', () {
    // Without this, the throw is unreachable code that reads as a guard.
    test('a shape parse cannot currently produce is rejected, not widened', () {
      expect(
        () => classifyArguments('a bare atom'),
        throwsA(isA<FormatException>()),
      );
      expect(() => classifyArguments(null), throwsA(isA<FormatException>()));
    });

    test('the rejection names what it got', () {
      expect(
        () => classifyArguments(42),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('int'),
          ),
        ),
      );
    });
  });
}

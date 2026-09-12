/// R1, as a mechanical count rather than a sentence.
///
/// Revision 4's first draft asserted "`_open()` is called from exactly two
/// places". It has three, all four reviewer families counted them, and the false
/// sentence is what hid the next finding from its own author: counting stopped
/// because the rule said the count was done.
///
/// A countable code fact stated in prose is a claim with no enforcement. This is
/// the enforcement — claude-tasks #9.
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final source = File('lib/src/transport/mqtt_transport.dart');

  test('the source this test reads actually exists', () {
    // A positive control. A grep over a file that is not there returns zero
    // matches and reads exactly like a passing count.
    expect(source.existsSync(), isTrue, reason: source.path);
  });

  test('_open() has exactly three call sites, and they are the named three', () {
    final lines = source.readAsLinesSync();
    final calls = <int, String>{};
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // The declaration is not a call site.
      if (line.contains('Future<void> _open()')) continue;
      // `_gate(_open)` is a tear-off, which is a call site wearing a different
      // hat — the supervisor's. Missing it is how a count goes wrong.
      if (line.contains('_open()') || line.contains('_gate(_open)')) {
        calls[i + 1] = line.trim();
      }
    }

    expect(
      calls,
      hasLength(3),
      reason:
          'R1 says ONE OPENER FUNCTION with three call sites — the first '
          'connect(), _reopen() for a will change, and the supervisor. Found:\n'
          '${calls.entries.map((e) => '  ${source.path}:${e.key}  ${e.value}').join('\n')}\n'
          'If a fourth is legitimate, the design changed and §5 R1 must change '
          'with it. If it is not, you have a second opener racing the one that '
          'already owns recovery.',
    );

    // NAME them, so three call sites in the wrong three places cannot pass.
    final text = calls.values.join('\n');
    expect(text, contains('_gate(_open)'), reason: 'the supervisor');
    expect(
      calls.values.where((line) => line == 'await _open();').length,
      2,
      reason: 'the first connect() and _reopen()',
    );
  });

  test('nothing but _open builds a client', () {
    final text = source.readAsStringSync();
    // `_build` is the only constructor of a socket, and `_open` is the only
    // caller of `_build`. Two greps rather than one, because "one opener" is
    // two claims: one function that connects, and nothing else that constructs.
    expect(
      RegExp('MqttServerClient.withPort').allMatches(text),
      hasLength(1),
      reason: 'a second construction site is a second opener',
    );
    expect(
      RegExp(r'_build\(').allMatches(text),
      hasLength(2),
      reason: 'the declaration and exactly one call, inside _open',
    );
  });
}

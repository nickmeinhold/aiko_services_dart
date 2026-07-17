/// Interop tests for the S-expression codec.
///
/// The oracle is Aiko's REAL Python reference: the golden vectors in
/// `fixtures/s_expression_golden.json` are produced by running
/// `aiko_services/main/utilities/parser.py` (see
/// `tool/generate_codec_fixtures.py`). Passing these means the Dart codec
/// agrees byte-for-byte with the exact code on Andy's wire — not merely that
/// it is self-consistent. (A codec tested only against its own inverse can be
/// self-consistently wrong.)
import 'dart:convert';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(
    File('test/codec/fixtures/s_expression_golden.json').readAsStringSync(),
  ) as Map<String, dynamic>;

  group('generate() byte-matches the Python reference', () {
    for (final vector in fixture['generate'] as List) {
      final v = vector as Map<String, dynamic>;
      final command = v['command'] as String;
      final params = v['params']; // List or Map from JSON
      final expected = v['expected'] as String;
      test('$command ${jsonEncode(params)} -> $expected', () {
        expect(generate(command, params as Object), expected);
      });
    }
  });

  group('parse() structurally matches the Python reference', () {
    for (final vector in fixture['parse'] as List) {
      final v = vector as Map<String, dynamic>;
      final payload = v['payload'] as String;
      final expectedCommand = v['command'] as String;
      final expectedCdr = v['cdr']; // List or Map from JSON
      test('$payload -> ($expectedCommand, ${jsonEncode(expectedCdr)})', () {
        final (command, cdr) = parse(payload);
        expect(command, expectedCommand);
        expect(cdr, equals(expectedCdr));
      });
    }
  });

  group('round-trip: parse(generate(x)) recovers x for wire-shaped commands',
      () {
    // A round-trip is a WEAKER check than the golden vectors above (it only
    // proves self-consistency), so it is scoped to the flat command shape the
    // wire actually uses, and layered ON TOP of the external-oracle tests.
    for (final (command, args) in const [
      ('increment', ['5']),
      ('add', ['topic', 'protocol', 'owner']),
      ('update', ['log_level', 'DEBUG']),
      // Astral + malformed-surrogate round-trips: encode counts with
      // String.runes, decode walks pairs by hand — these keep the two
      // counters honest against each other (cage-match round 1).
      ('say', ['a 😀', '😀🎉 x']),
      ('lone', ['\ud800x y', 'a \ud800', '\udc00 z']),
    ]) {
      test('($command ...)', () {
        final (c, cdr) = parse(generate(command, args));
        expect(c, command);
        expect(cdr, equals(args));
      });
    }
  });

  group('malformed input is rejected with FormatException', () {
    // Error-CLASS coverage only. Exact parity with parser.py's behaviour on
    // malformed input is tracked in the hardening task: the Python reference
    // currently crashes (unhandled TypeError) on these, per RFC-0001 §8.
    for (final (label, payload) in const [
      ('overlong prefix', '(c 99:ab)'),
      ('prefix exactly one too long', '(c 3:ab'),
      ('truncated after high surrogate count', '(c 2:\ud800'),
    ]) {
      test(label, () {
        expect(() => parse(payload), throwsFormatException);
      });
    }

    test('odd-length dictionary', () {
      expect(() => parse('(c a: 1 b:)'), throwsFormatException);
    });
  });
}

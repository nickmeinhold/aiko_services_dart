/// Interop tests for the S-expression codec.
///
/// The oracle is Aiko's REAL Python reference: the golden vectors in
/// `fixtures/s_expression_golden.json` are produced by running
/// `aiko_services/main/utilities/parser.py` (see
/// `tool/generate_codec_fixtures.py`). Passing these means the Dart codec
/// agrees byte-for-byte with the exact code on Andy's wire — not merely that
/// it is self-consistent. (A codec tested only against its own inverse can be
/// self-consistently wrong.)
library;

import 'dart:convert';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

void main() {
  test('red case: the test gate must be able to fail', () {
    expect(1, equals(2));
  });

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

  group(
    'round-trip: parse(generate(x)) recovers x for wire-shaped commands',
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
    },
  );

  group('parse() rejects what the Python reference rejects', () {
    // Oracle-pinned error parity: every payload the reference fails to decode
    // (recorded with its own exception type in the fixture) the Dart codec MUST
    // reject with a clean FormatException. The reference's rejection is a clean
    // ValueError (RFC-0001 §7 MUST-reject) for the dictionary cases and an
    // unhandled crash (§8 errata) for the unterminated/overlong cases; §7 only
    // requires that the input not decode SUCCESSFULLY, which we assert here.
    for (final vector in fixture['parse_errors'] as List) {
      final v = vector as Map<String, dynamic>;
      final payload = v['payload'] as String;
      final raises = v['raises'] as String;
      test('$payload (reference: $raises)', () {
        expect(() => parse(payload), throwsFormatException);
      });
    }
  });

  group('parse() DELIBERATELY rejects what the reference decodes', () {
    // A divergence, pinned rather than hidden. The reference is dynamically
    // typed, so its `car` can be None (a `0:` in command position) or a nested
    // list (`((a b) c)`); Dart's parse returns (String, Object), which admits
    // neither. Before this was pinned the list crashed the cast with a raw
    // TypeError -- escaping the "decodes, or throws FormatException" contract
    // on untrusted wire input -- and the null was silently flattened to "".
    //
    // We reject instead of widening the return type: a command names a method
    // to dispatch, and every reference sender builds one via
    // generate(method_name, ...) with a str, so no conformant encoder emits
    // either shape. The fixture carries what the reference produced, so this
    // stays a reviewable decision (RFC-0001 §8.6) rather than behaviour drift.
    for (final vector in fixture['divergences'] as List) {
      final v = vector as Map<String, dynamic>;
      final payload = v['payload'] as String;
      test('$payload (reference decodes to '
          '${jsonEncode(v['reference_car'])})', () {
        expect(() => parse(payload), throwsFormatException);
      });
    }
  });

  group('parse() rejects malformed input (Dart-only boundary probes)', () {
    // Finer-grained boundary cases not in the reference fixture: a length
    // prefix one past the end, and a truncation mid-surrogate. Both exercise
    // the length-walk's remaining-input bound (RFC-0001 §8.2 clean rejection).
    for (final (label, payload) in const [
      ('prefix exactly one too long', '(c 3:ab'),
      ('truncated after high surrogate count', '(c 2:\ud800'),
    ]) {
      test(label, () {
        expect(() => parse(payload), throwsFormatException);
      });
    }
  });
}

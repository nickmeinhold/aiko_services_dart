/// The fuzz rigs are the only instruments that can surprise us about codec
/// parity, and both of them once reported success over zero work: an empty
/// corpus produced zero mismatches, which is indistinguishable from agreement.
///
/// These tests exercise the rigs' gates the only way that means anything —
/// feed a corpus that SHOULD be refused and require a refusal.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:aiko_services/src/codec/s_expression.dart';

import '../../tool/fuzz_parse_parity.dart' show RejectCause;

/// Exit 2 is the rigs' "this corpus cannot support a verdict" code, distinct
/// from exit 1 ("compared properly, found a divergence").
const refusedExit = 2;

late Directory tmp;

String corpus(String name, Object json) {
  final f = File('${tmp.path}/$name')..writeAsStringSync(jsonEncode(json));
  return f.path;
}

Future<int> runRig(String rig, List<String> args) async {
  final r = await Process.run('dart', ['run', 'tool/$rig', ...args]);
  return r.exitCode;
}

void main() {
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('fuzz-gates'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('RejectCause classification', () {
    test('every message the codec can throw is classified', () {
      // If a codec change adds a message outside these prefixes it lands in
      // `other`, which is a gate — so this list must be kept in step with the
      // FormatExceptions in lib/src/codec/s_expression.dart.
      const thrown = [
        'S-expression command must be a symbol, got 3',
        'Canonical symbol length 9 exceeds remaining input',
        'Unterminated list: expected ")" before end of input',
        'S-expression dictionary starting at "a" must have pairs of ',
        'S-expression dictionary keyword "k" must be a string',
        'S-expression dictionary keyword "k" must end with ":"',
      ];
      for (final m in thrown) {
        expect(RejectCause.of(m), isNot(RejectCause.other), reason: m);
      }
    });

    test('an unrecognised message lands in other', () {
      expect(RejectCause.of('something nobody classified'), RejectCause.other);
    });

    test('other carries a label but is identified by the enum value', () {
      // The bug this enum replaced keyed the tally on a String built as
      // 'OTHER: $message', while the gate looked up 'OTHER' — never equal, so
      // the unclassified count was structurally always zero.
      expect(RejectCause.other.label, isNot(contains(':')));
    });
  });

  group('encoder rig refuses a corpus it cannot draw a verdict from', () {
    test('empty corpus', () async {
      final p = corpus('enc-empty.json', []);
      expect(
        await runRig('fuzz_generate_parity.dart', [p, '10', '10']),
        refusedExit,
      );
    });

    test('corpus smaller than the caller asked for', () async {
      final p = corpus('enc-small.json', [
        {'e': 'a', 'w': '(c 1:a)'},
      ]);
      expect(
        await runRig('fuzz_generate_parity.dart', [p, '1000', '1']),
        refusedExit,
      );
    });

    test('corpus with too few comparable cases', () async {
      // Full size, but almost every row is an oracle error rather than a
      // result, so there is nothing to compare against.
      final cases = [
        {'e': 'a', 'w': '(c 1:a)'},
        for (var i = 0; i < 99; i++) {'e': 'x$i', 'err': 'ValueError'},
      ];
      final p = corpus('enc-thin.json', cases);
      expect(
        await runRig('fuzz_generate_parity.dart', [p, '100', '50']),
        refusedExit,
      );
    });

    test('a healthy corpus is NOT refused', () async {
      // Expected wire forms come from the codec itself. This test is about the
      // gate not FALSE-refusing, so parity has to hold by construction rather
      // than by hand-written fixtures that can be wrong in their own right.
      final cases = [
        for (var i = 0; i < 100; i++)
          {
            'e': 'a$i',
            'w': generate('c', <Object?>['a$i']),
          },
      ];
      final p = corpus('enc-ok.json', cases);
      expect(await runRig('fuzz_generate_parity.dart', [p, '100', '50']), 0);
    });
  });

  group('decoder rig refuses a corpus it cannot draw a verdict from', () {
    test('empty corpus', () async {
      final p = corpus('dec-empty.json', []);
      expect(
        await runRig('fuzz_parse_parity.dart', [p, '10', '10']),
        refusedExit,
      );
    });

    test('every case skipped as reference errata', () async {
      // Full size and every bucket reads zero — which is exactly what an empty
      // corpus looks like. The rig printed GATE PASSED over this.
      final cases = [
        for (var i = 0; i < 100; i++) {'p': '(c $i)', 'errata': 'stray'},
      ];
      final p = corpus('dec-errata.json', cases);
      expect(
        await runRig('fuzz_parse_parity.dart', [p, '100', '50']),
        refusedExit,
      );
    });

    test('a healthy corpus is NOT refused', () async {
      // Decoded by the codec, for the same reason as the encoder case above.
      final decoded = parse('(c 1:a)');
      final cases = [
        for (var i = 0; i < 100; i++)
          {'p': '(c 1:a)', 'car': decoded.$1, 'cdr': decoded.$2},
      ];
      final p = corpus('dec-ok.json', cases);
      expect(await runRig('fuzz_parse_parity.dart', [p, '100', '50']), 0);
    });
  });
}

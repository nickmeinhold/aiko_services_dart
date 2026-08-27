import 'dart:convert';
import 'dart:io';

import 'package:aiko_services/src/codec/s_expression.dart';

/// Replays a generate() differential-fuzz corpus against the Dart codec.
///
/// Optional second argument: the minimum number of cases the CORPUS must
/// contain. `exit(mismatch == 0 ? 0 : 1)` alone cannot tell "compared 40000,
/// all agreed" from "compared nothing" — both are zero mismatches, so a corpus
/// that arrived empty or truncated reported success over no work at all.
///
/// Two distinct things are checked, because they fail for different reasons and
/// conflating them makes the message lie. The corpus SIZE answers "did the
/// oracle produce a corpus"; the COMPARED count answers "did we actually run
/// against it". Gating the compared count on the requested total would couple
/// it to how often the reference raises — at a floor of 40000 against a corpus
/// of 40001, two oracle exceptions would report a corpus that never arrived.
void main(List<String> a) {
  final cases = jsonDecode(File(a[0]).readAsStringSync()) as List;
  final minimumCases = a.length > 1 ? int.parse(a[1]) : 1;
  // Declared by the generator (its COMPARABLE line), not guessed. The previous
  // shape was `(cases.length * 0.5).floor()` — a constant whose meaning depends
  // on a rate the generator can change without telling anyone, so it decays
  // into slack in exactly the direction that matters.
  final minimumCompared = a.length > 2 ? int.parse(a[2]) : 1;
  var checked = 0, mismatch = 0;
  for (final c in cases.cast<Map<String, dynamic>>()) {
    if (!c.containsKey('w')) continue;
    final got = generate('c', <Object?>[c['e'] as String]);
    checked++;
    if (got != c['w']) {
      if (mismatch++ < 5) {
        print(
          'MISMATCH element=${jsonEncode(c['e'])}\n'
          '  oracle=${jsonEncode(c['w'])}\n  dart  =${jsonEncode(got)}',
        );
      }
    }
  }
  print('checked $checked, mismatches $mismatch');
  if (cases.length < minimumCases) {
    print(
      'GATE FAILED: corpus holds ${cases.length} cases, expected at least '
      '$minimumCases. Zero mismatches over an absent corpus is not a pass.',
    );
    exit(2);
  }
  // The generator said how many cases carry an oracle result; anything less
  // means the corpus is not what was asked for, and zero mismatches over a
  // handful of rows is not a pass.
  if (checked < minimumCompared || checked == 0) {
    print(
      'GATE FAILED: the corpus holds ${cases.length} cases but only $checked '
      'carried an oracle result to compare against (need $minimumCompared). '
      'Agreement across a handful of rows is not a pass.',
    );
    exit(2);
  }
  exit(mismatch == 0 ? 0 : 1);
}

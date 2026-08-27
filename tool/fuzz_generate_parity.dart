import 'dart:convert';
import 'dart:io';

import 'package:aiko_services/src/codec/s_expression.dart';

/// Replays a generate() differential-fuzz corpus against the Dart codec.
///
/// Args: `<corpus> [minimum cases] [minimum compared]`.
///
/// Two gates, failing for different reasons: SIZE asks whether the oracle
/// produced a corpus, COMPARED whether we ran against it. `exit(mismatch == 0)`
/// alone cannot tell either from "did nothing".
void main(List<String> a) {
  final cases = jsonDecode(File(a[0]).readAsStringSync()) as List;
  final minimumCases = a.length > 1 ? int.parse(a[1]) : 1;
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

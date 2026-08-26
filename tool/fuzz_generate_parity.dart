import 'dart:convert';
import 'dart:io';

import 'package:aiko_services/src/codec/s_expression.dart';

void main(List<String> a) {
  final cases = jsonDecode(File(a[0]).readAsStringSync()) as List;
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
  exit(mismatch == 0 ? 0 : 1);
}

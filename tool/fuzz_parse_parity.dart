/// Replays a parse() differential-fuzz corpus (tool/generate_parse_fuzz_corpus.py)
/// against the Dart codec and reports every outcome that differs from the
/// Python reference's.
///
/// Outcomes are compared at three levels, because they carry different weight:
///   * BOTH DECODE, values differ  -> silent wire divergence, the worst kind.
///   * REFERENCE DECODES, Dart rejects -> we refuse traffic the framework sends.
///   * REFERENCE REJECTS, Dart decodes -> we accept traffic it would refuse.
/// A shared rejection is agreement, whatever the exception types are: the
/// reference's TypeErrors are errata (RFC-0001 section 8), so pinning Dart to
/// reproduce a crash type would pin a bug.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aiko_services/src/codec/s_expression.dart';

void main(List<String> args) {
  final cases = jsonDecode(File(args[0]).readAsStringSync()) as List;
  var bothDecodeDiffer = 0, refOnlyDecodes = 0, dartOnlyDecodes = 0, agree = 0;
  var crashes = 0, errata = 0;
  final rejectCauses = <String, int>{};
  // Per-bucket samples: a shared cap lets one loud class hide another.
  final samples = <String, List<String>>{
    'VALUE DIFFERS': [],
    'DART DECODES, ref rejects': [],
    'DART REJECTS, ref decodes': [],
    'CRASHES': [],
  };
  void sample(String bucket, String detail) {
    final list = samples[bucket]!;
    if (list.length < 6) list.add(detail);
  }

  for (final c in cases.cast<Map<String, dynamic>>()) {
    final payload = c['p'] as String;
    if (c.containsKey('errata')) {
      errata++;
      continue;
    }
    final refRejects = c.containsKey('raises');
    Object? got;
    var dartRejects = false;
    String? rejectReason;
    try {
      final r = parse(payload);
      got = [r.$1, r.$2];
    } on FormatException catch (e) {
      dartRejects = true;
      // Bucket by CAUSE, not by count: an accept-set difference is only
      // acceptable if every instance falls into a class we deliberately chose.
      final m = e.message;
      rejectReason = m.startsWith('Canonical symbol length')
          ? 'overlong length prefix (RFC-0001 s8.2)'
          : m.startsWith('S-expression command must be')
          ? 'non-symbol command (RFC-0001 s8.6)'
          : m.startsWith('Unterminated list')
          ? 'unterminated list (RFC-0001 s8.1)'
          : m.startsWith('S-expression dictionary')
          ? 'malformed dictionary (RFC-0001 s7)'
          : 'OTHER: $m';
    } catch (e) {
      // A non-FormatException escaping the codec is its own failure class: the
      // documented contract is "decodes, or throws FormatException", so a raw
      // TypeError from untrusted wire input crashes a caller that honours it.
      crashes++;
      sample('CRASHES', '(${e.runtimeType}) payload=${jsonEncode(payload)}');
      continue;
    }

    if (refRejects && dartRejects) {
      agree++;
    } else if (refRejects && !dartRejects) {
      dartOnlyDecodes++;
      sample(
        'DART DECODES, ref rejects',
        'ref raises ${c['raises']} payload=${jsonEncode(payload)}\n'
            '    dart=${jsonEncode(got)}',
      );
    } else if (!refRejects && dartRejects) {
      refOnlyDecodes++;
      rejectCauses[rejectReason ?? '?'] =
          (rejectCauses[rejectReason ?? '?'] ?? 0) + 1;
      sample(
        'DART REJECTS, ref decodes',
        'payload=${jsonEncode(payload)}\n'
            '    ref=${jsonEncode([c['car'], c['cdr']])}',
      );
    } else {
      final want = jsonEncode([c['car'], c['cdr']]);
      if (jsonEncode(got) == want) {
        agree++;
      } else {
        bothDecodeDiffer++;
        sample(
          'VALUE DIFFERS',
          'payload=${jsonEncode(payload)}\n'
              '    ref =$want\n    dart=${jsonEncode(got)}',
        );
      }
    }
  }
  if (rejectCauses.isNotEmpty) {
    print('--- why Dart rejected what the reference decoded ---');
    final keys = rejectCauses.keys.toList()..sort();
    for (final k in keys) {
      print('  ${rejectCauses[k]}  $k');
    }
  }
  samples.forEach((bucket, list) {
    if (list.isEmpty) return;
    print('--- $bucket ---');
    for (final d in list) {
      print('  $d');
    }
  });
  print(
    '\ncases ${cases.length} | agree $agree | value-differs $bothDecodeDiffer'
    ' | dart-only-decodes $dartOnlyDecodes | ref-only-decodes $refOnlyDecodes'
    ' | CRASHES $crashes | ref-errata-skipped $errata',
  );
  // Gate on the buckets ReadMe.md declares must be zero, and ONLY those.
  //
  // The old gate summed in `dart-only-decodes` and `ref-only-decodes`, which the
  // same ReadMe documents as *allowed*. So a healthy run — 0 value-differs, 0
  // crashes — exited 1, and the instrument reported failure on correct
  // behaviour. A verifier that cannot go green is as useless as one that cannot
  // go red, and worse: its alarm gets learned-away.
  //
  // `ref-only-decodes` is allowed *conditionally*: every rejection must fall in
  // a class RFC-0001 chose. An `OTHER` cause means an unclassified divergence,
  // which is drift, so that IS a gate.
  final unclassified = rejectCauses['OTHER'] ?? 0;
  final fatal = bothDecodeDiffer + crashes + unclassified;
  if (fatal > 0) {
    print(
      '\nGATE FAILED: value-differs=$bothDecodeDiffer crashes=$crashes '
      'unclassified-rejections=$unclassified (each must be 0)',
    );
  } else {
    print(
      '\nGATE PASSED: value-differs=0, crashes=0, every rejection classified.'
      '\n  dart-only-decodes=$dartOnlyDecodes and ref-only-decodes=$refOnlyDecodes'
      ' are allowed buckets (RFC-0001 §8).',
    );
  }
  exit(fatal == 0 ? 0 : 1);
}

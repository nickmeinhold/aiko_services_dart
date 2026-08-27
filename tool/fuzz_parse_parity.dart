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

/// Why the Dart codec rejected a payload the Python reference decoded.
///
/// A CLOSED set, which is the whole point: `ref-only-decodes` is allowed only
/// while every instance lands in a class RFC-0001 deliberately chose, and
/// [other] is the "nobody chose this" bucket the gate treats as drift.
///
/// This was a String, and the stringly-typed version shipped a dead gate. The
/// classifier wrote `'OTHER: $message'` — bucket and detail concatenated into
/// one key — while the gate read `rejectCauses['OTHER']`. Map lookup is exact,
/// so the unclassified count was structurally always zero and the check could
/// never fire. An enum cannot collide its own bucket with its own detail.
enum RejectCause {
  overlongLengthPrefix('overlong length prefix (RFC-0001 s8.2)'),
  nonSymbolCommand('non-symbol command (RFC-0001 s8.6)'),
  unterminatedList('unterminated list (RFC-0001 s8.1)'),
  malformedDictionary('malformed dictionary (RFC-0001 s7)'),
  other('UNCLASSIFIED');

  const RejectCause(this.label);

  /// Human-readable name, for the per-cause tally only. Never a map key.
  final String label;

  /// The reference's exceptions carry no code, so the prefix of the message is
  /// the only signal available. Kept in one place so the mapping is auditable
  /// rather than smeared across a ternary chain.
  static RejectCause of(String message) => switch (message) {
    _ when message.startsWith('Canonical symbol length') =>
      overlongLengthPrefix,
    _ when message.startsWith('S-expression command must be') =>
      nonSymbolCommand,
    _ when message.startsWith('Unterminated list') => unterminatedList,
    _ when message.startsWith('S-expression dictionary') => malformedDictionary,
    _ => other,
  };
}

void main(List<String> args) {
  final cases = jsonDecode(File(args[0]).readAsStringSync()) as List;
  // Optional second argument: the minimum number of cases that MUST be
  // compared. Every bucket being zero is indistinguishable from having read an
  // empty corpus, and this rig printed GATE PASSED over `cases 0`.
  final minimumCases = args.length > 1 ? int.parse(args[1]) : 1;
  // Declared by the generator (its COMPARABLE line): total cases minus the ones
  // tagged as reference errata, which are skipped before any comparison. Was a
  // 0.5 ratio, a constant whose meaning moves whenever the errata
  // classification does.
  final minimumCompared = args.length > 2 ? int.parse(args[2]) : 1;
  // TWO numbers, two gates, and the comment must not promise the other one.
  // `minimumCases` gates cases.length (did the corpus arrive); `minimumCompared`
  // gates the compared count (did we run against it). An earlier version of
  // this comment described minimumCases as "the minimum number of cases that
  // MUST be compared", which is a trap: a later hand aligning the code to the
  // comment would gate compared < 20000 on a corpus that healthily compares
  // ~15000, and the instrument could never go green again. Errata entries are counted and `continue`d without ever
  // reaching a comparison, so a full-size corpus of nothing but errata clears a
  // cases.length gate with every fatal bucket at zero — GATE PASSED over no
  // comparison at all. Not hypothetical: a normal run already skips ~25% of the
  // corpus as errata (4915 of 20000), so the compared count is not pinned to the
  // corpus size and cannot be inferred from it.
  var bothDecodeDiffer = 0, refOnlyDecodes = 0, dartOnlyDecodes = 0, agree = 0;
  var crashes = 0, errata = 0;
  final rejectCauses = <RejectCause, int>{};
  // Raw messages for the unclassified bucket only: the detail is worth printing
  // but must never be part of the key, which is how the old gate died.
  final unclassifiedMessages = <String>[];
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
    RejectCause? rejectReason;
    var rejectMessage = '';
    try {
      final r = parse(payload);
      got = [r.$1, r.$2];
    } on FormatException catch (e) {
      dartRejects = true;
      // Bucket by CAUSE, not by count: an accept-set difference is only
      // acceptable if every instance falls into a class we deliberately chose.
      final m = e.message;
      rejectMessage = m;
      rejectReason = RejectCause.of(m);
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
      final cause = rejectReason ?? RejectCause.other;
      rejectCauses[cause] = (rejectCauses[cause] ?? 0) + 1;
      // Collected HERE, in the same arm that increments the gate's counter. It
      // used to be collected at classification time, before the ref/Dart
      // branch — so a shared rejection (agreement, not a finding) contributed
      // messages while the gate counted only ref-only-decodes. The printed
      // evidence could then be six rejections from a bucket the verdict never
      // looked at: verdict and evidence out of phase.
      if (cause == RejectCause.other) unclassifiedMessages.add(rejectMessage);
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
    final keys = rejectCauses.keys.toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    for (final k in keys) {
      print('  ${rejectCauses[k]}  ${k.label}');
    }
  }
  samples.forEach((bucket, list) {
    if (list.isEmpty) return;
    print('--- $bucket ---');
    for (final d in list) {
      print('  $d');
    }
  });
  // Declared before the summary line that reports it: how many cases were
  // actually COMPARED is a different number from how many were READ, and the
  // reader needs both side by side to notice a gap opening between them.
  final compared =
      agree + bothDecodeDiffer + refOnlyDecodes + dartOnlyDecodes + crashes;
  print(
    '\ncases ${cases.length} | agree $agree | value-differs $bothDecodeDiffer'
    ' | dart-only-decodes $dartOnlyDecodes | ref-only-decodes $refOnlyDecodes'
    ' | CRASHES $crashes | ref-errata-skipped $errata | compared $compared',
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
  if (cases.length < minimumCases) {
    print(
      '\nGATE FAILED: read ${cases.length} cases, expected at least '
      '$minimumCases. Every bucket reading zero is what an empty corpus looks '
      'like, so this is not a pass.',
    );
    exit(2);
  }
  // The generator declared how many cases are comparable; fewer means the
  // corpus is not what was asked for.
  if (compared < minimumCompared || compared == 0) {
    print(
      '\nGATE FAILED: read ${cases.length} cases but compared only $compared '
      'of them (need $minimumCompared) — the rest were skipped as reference '
      'errata. Zero fatal buckets over a handful of comparisons is not a pass.',
    );
    exit(2);
  }
  final unclassified = rejectCauses[RejectCause.other] ?? 0;
  if (unclassified > 0) {
    print('--- UNCLASSIFIED rejection messages (first 6) ---');
    for (final m in unclassifiedMessages.take(6)) {
      print('  ${jsonEncode(m)}');
    }
  }
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

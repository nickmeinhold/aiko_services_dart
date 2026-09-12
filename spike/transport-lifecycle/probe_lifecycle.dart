/// Revision 4's must-fail arms, re-run against the IMPLEMENTED client and a
/// real broker that really dies.
///
/// Evidence does not transfer across a type change, and sketch to
/// implementation is a type change — so nothing here is cited from the design's
/// own verification section. Every line is measured in this process.
///
/// Driven by probe_lifecycle.sh, which owns starting and killing the broker.
library;

import 'dart:async';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

const _host = '127.0.0.1';
final _port = int.parse(Platform.environment['AIKO_PROBE_PORT'] ?? '1885');
const _container = 'aiko-probe-mosquitto';

final _results = <String, String>{};

void record(String arm, bool ok, String detail) {
  _results[arm] = '${ok ? 'PASS' : 'FAIL'}  $detail';
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $arm — $detail');
}

Future<void> _docker(String verb) async {
  final result = await Process.run('docker', [verb, _container]);
  if (result.exitCode != 0) {
    stderr.writeln('docker $verb failed: ${result.stderr}');
    exit(3);
  }
}

/// Poll a condition until it holds, or give up. Returns elapsed ms, or null.
///
/// The deadline is a HANG DETECTOR, not a margin: every assertion below is on
/// the condition itself, so a slow machine makes this slower and never makes it
/// wrong.
Future<int?> until(
  bool Function() condition, {
  Duration budget = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < budget) {
    if (condition()) return watch.elapsedMilliseconds;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return null;
}

Future<void> main() async {
  // ---------------------------------------------------------------- setup
  final downAt = <int>[];
  final upAt = <int>[];
  final received = <String>[];
  final clock = Stopwatch()..start();

  final client = AikoClient(
    host: _host,
    port: _port,
    clientId: 'probe_lifecycle_${DateTime.now().microsecondsSinceEpoch}',
    will: LastWill.processAbsent('aiko/probe/1'),
  );
  client.transportUp.listen((up) {
    (up ? upAt : downAt).add(clock.elapsedMilliseconds);
  });
  client.messages.listen((m) => received.add('${m.topic} ${m.command}'));

  await client.connect();
  record(
    'connect reaches Attached',
    client.reach is Attached,
    '${client.reach}',
  );

  const topic = 'aiko/probe/lifecycle/out';
  client.subscribe(topic);

  // ------------------------- NOT AN ARM, AND THE REASON IS THE FINDING
  //
  // `reach` is `_client != null AND connectionStatus == connected`. The design
  // says reverting it to the handle alone "makes the corpse handle read Attached
  // — reproduced on demand", and cites that as proof the conjunct is
  // load-bearing rather than decoration.
  //
  // THAT PROOF DID NOT TRANSFER. It was measured against the FIVE-state model,
  // where `Dipped` existed precisely so a handle could outlive its connection
  // while the package repaired it. Option B deleted `Dipped`: `_open` is the
  // only installer and `_enterDetached` the only remover, and the remover runs
  // in the same callback that flips the status — so the two conditions are kept
  // in lockstep by construction and cannot be observed to disagree.
  //
  // Measured, not reasoned. An arm here polled `reach` at 1ms and asserted it
  // reported non-Attached no later than the transportUp callback. It passed —
  // and it passed IDENTICALLY with the conjunct deleted, at 400ms and 566ms
  // across two runs. A check whose disabled value equals its success value
  // cannot report its own absence, so it was removed rather than kept as a
  // green nobody could cash.
  //
  // The conjunct STAYS, and the honest claim is narrower than the design's: it
  // is not observably load-bearing today, it is what makes the invariant
  // STRUCTURAL. `reach` reads the mechanism's own report instead of our proxy,
  // so a future path that installs a handle the mechanism disagrees with, or
  // forgets to null one, is caught by construction rather than by every author
  // remembering. Deleting it would reinstate the proxy this design is named for.

  await _docker('stop');

  final sawDown = await until(() => downAt.isNotEmpty);
  record(
    'link loss is reported',
    sawDown != null,
    sawDown == null
        ? 'no transportUp:false in 30s'
        : 'transportUp:false at ${downAt.first}ms',
  );

  record(
    'down link reads Detached',
    client.reach is Detached,
    '${client.reach}',
  );

  // ---------------------------------------- ARM: refusals while the link is down
  var sendThrew = '';
  try {
    client.send(topic, 'x', const <Object?>[]);
  } on Object catch (error) {
    sendThrew = error.runtimeType.toString();
  }
  record(
    'send on Detached is TRANSIENT',
    sendThrew == 'TransportUnavailable',
    sendThrew.isEmpty ? 'did not throw at all' : sendThrew,
  );

  var willThrew = '';
  const promoted = LastWill(
    topic: 'aiko/service/registrar',
    payload: '(primary absent)',
    retain: true,
  );
  try {
    await client.setWill(promoted);
  } on Object catch (error) {
    willThrew = error.runtimeType.toString();
  }
  record(
    'setWill on Detached RECORDS and refuses',
    willThrew == 'TransportUnavailable' && client.will == promoted,
    '$willThrew, will=${client.will}',
  );

  // A topic taken while there is no socket at all. The set is the memory.
  const lateTopic = 'aiko/probe/lifecycle/late';
  client.subscribe(lateTopic);

  // --------------------------------------------------- ARM: idle liveness
  //
  // Nothing below calls connect(). If the bus comes back, the supervisor is the
  // only thing that could have done it.
  await _docker('start');
  final backAt = await until(() => client.reach is Attached);
  record(
    'IDLE LIVENESS — back without any caller',
    backAt != null,
    backAt == null
        ? 'still down after 30s'
        : 'Attached again after ${backAt}ms',
  );
  record(
    'recovery reported up',
    upAt.length >= 2,
    'transportUp ups=$upAt downs=$downAt',
  );

  // ------------------------------- ARM: subscriptions survived the outage
  final pub = await Process.run('mosquitto_pub', [
    '-h',
    _host,
    '-p',
    '$_port',
    '-t',
    lateTopic,
    '-m',
    '(hello)',
  ]);
  if (pub.exitCode != 0) {
    record(
      'a topic taken while Detached is live after recovery',
      false,
      'mosquitto_pub failed: ${pub.stderr}',
    );
  } else {
    final got = await until(
      () => received.any((r) => r.startsWith(lateTopic)),
      budget: const Duration(seconds: 10),
    );
    record(
      'a topic taken while Detached is live after recovery',
      got != null,
      got == null ? 'never arrived' : 'arrived after ${got}ms; got=$received',
    );
  }

  // ----------------------------------- ARM: the will the supervisor carried
  record(
    'the reopened socket carries the will recorded while down',
    client.will == promoted,
    '${client.will}',
  );

  await client.disconnect();
  record('disconnect retires', client.reach is Retired, '${client.reach}');

  // ------------------------------------------------------------- verdict
  final failed = _results.entries.where((e) => e.value.startsWith('FAIL'));
  stdout.writeln(
    '\n${_results.length - failed.length}/${_results.length} arms passed',
  );
  if (failed.isNotEmpty) {
    stdout.writeln('FAILED ARMS:');
    for (final arm in failed) {
      stdout.writeln('  ${arm.key}: ${arm.value}');
    }
    exit(1);
  }
  stdout.writeln('ALL ARMS PASS');
}

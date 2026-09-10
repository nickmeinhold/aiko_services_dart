// Narrow probe: does a Last Will actually reach the broker, and does a CLEAN
// disconnect correctly suppress it?
//
// Two arms, because either alone proves nothing. A run that only kills the
// process and sees the will cannot tell "the will works" from "the broker
// publishes this on every disconnect"; a run that only disconnects cleanly and
// sees silence cannot tell "suppressed correctly" from "never set at all".
//
//   dart run spike/will/probe_will.dart <run-id> die   # exits WITHOUT disconnecting
//   dart run spike/will/probe_will.dart <run-id> bye   # disconnects cleanly first
//
// The run id is supplied by the driver rather than derived from our pid, so the
// will topic is known BEFORE the subscriber starts. A driver that had to wait
// for us to print the topic could only subscribe with a wildcard, and a
// wildcard makes concurrent runs read each other: a clean `bye` arm fails on
// somebody else's `die`, and a `die` arm passes on somebody else's will.
//
// The driver (probe_will.sh) watches the will topic across both arms and
// asserts fired-then-silent. Exiting without `disconnect()` closes the socket
// with no DISCONNECT packet, which is what makes the broker fire the will —
// the same thing a crash does, without needing to be signalled from outside.
import 'dart:async';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: probe_will.dart <run-id> [die|bye]');
    exit(64);
  }
  final runId = args.first;
  final clean = args.contains('bye');
  final topic = 'aiko/probe/will/$runId/0/state';

  _armWatchdog(const Duration(seconds: 45), 'the will probe');

  final client = AikoClient(
    host: '127.0.0.1',
    clientId: 'will_probe_$runId',
    will: LastWill(topic: topic, payload: '(absent)'),
  );
  await client.connect();
  print('WILL_TOPIC=$topic');
  print('connected as will_probe_$runId; arm=${clean ? "bye" : "die"}');

  // Publish something first, so the driver can prove the connection was real
  // and the broker was listening. Without this, a silent arm is ambiguous
  // between "the will was suppressed" and "we never connected at all".
  client.send('aiko/probe/will/$runId/0/out', 'alive', <Object?>[]);
  await Future<void>.delayed(const Duration(seconds: 2));

  if (clean) {
    await client.disconnect();
    print('disconnected cleanly — the broker should discard the will');
    // Give the driver a moment to observe the silence.
    await Future<void>.delayed(const Duration(seconds: 2));
  } else {
    print('exiting WITHOUT disconnect — the broker should publish the will');
  }
  exit(0);
}

/// Refuse to hang.
///
/// A probe with no upper bound turns a sick broker into CI entropy: `verify.sh`
/// waits forever instead of reporting a named failure, and nobody can Ctrl-C a
/// gate running at 3am. Bounded HERE rather than with a `timeout` wrapper
/// because `timeout` is absent on a default macOS host — the same reason it was
/// removed from this probe's own discovery step.
///
/// Exit 75 (EX_TEMPFAIL), distinct from an assertion failure, so the driver can
/// say "the harness stalled" rather than "the protocol is broken".
void _armWatchdog(Duration budget, String what) {
  Timer(budget, () {
    stderr.writeln(
      'WATCHDOG: $what did not finish within ${budget.inSeconds}s — '
      'refusing to hang a gate on a sick broker',
    );
    exit(75);
  });
}

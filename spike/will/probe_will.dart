// Narrow probe: does a Last Will actually reach the broker, and does a CLEAN
// disconnect correctly suppress it?
//
// Two arms, because either alone proves nothing. A run that only kills the
// process and sees the will cannot tell "the will works" from "the broker
// publishes this on every disconnect"; a run that only disconnects cleanly and
// sees silence cannot tell "suppressed correctly" from "never set at all".
//
//   dart run spike/will/probe_will.dart die     # exits WITHOUT disconnecting
//   dart run spike/will/probe_will.dart bye     # disconnects cleanly first
//
// The driver (probe_will.sh) watches the will topic across both arms and
// asserts fired-then-silent. Exiting without `disconnect()` closes the socket
// with no DISCONNECT packet, which is what makes the broker fire the will —
// the same thing a crash does, without needing to be signalled from outside.
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main(List<String> args) async {
  final clean = args.contains('bye');
  final topic = 'aiko/probe/will/$pid/0/state';

  final client = AikoClient(
    host: '127.0.0.1',
    clientId: 'will_probe_$pid',
    will: LastWill(topic: topic, payload: '(absent)'),
  );
  await client.connect();
  print('WILL_TOPIC=$topic');
  print('connected as will_probe_$pid; arm=${clean ? "bye" : "die"}');

  // Publish something first, so the driver can prove the connection was real
  // and the broker was listening. Without this, a silent arm is ambiguous
  // between "the will was suppressed" and "we never connected at all".
  client.send('aiko/probe/will/$pid/0/out', 'alive', <Object?>[]);
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

// Narrow probe: does a Last Will actually reach the broker, and does a CLEAN
// disconnect correctly suppress it?
//
// Two arms, because either alone proves nothing. A run that only kills the
// process and sees the will cannot tell "the will works" from "the broker
// publishes this on every disconnect"; a run that only disconnects cleanly and
// sees silence cannot tell "suppressed correctly" from "never set at all".
//
//   dart run spike/will/probe_will.dart <run-id> <die|bye> [host] [port]
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

  // Host and port from the driver, which is the half watching the broker.
  // Hardcoding 127.0.0.1 let the two halves of one instrument point at
  // DIFFERENT brokers the moment AIKO_MQTT_HOST was set — the same defect
  // this file's sibling was fixed for one round earlier, left standing here.
  final host = args.length > 2 && args[2].isNotEmpty ? args[2] : '127.0.0.1';
  final port = args.length > 3 && args[3].isNotEmpty
      ? int.tryParse(args[3])
      : 1883;
  if (port == null) {
    stderr.writeln('port must be an integer, got "${args[3]}"');
    exit(64);
  }

  final client = AikoClient(
    host: host,
    port: port,
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

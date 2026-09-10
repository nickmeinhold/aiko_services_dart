// Narrow probe: does the EC lease actually RENEW on the wire?
//
// The lease is the most protocol-specific mechanism in the consumer and the
// least observed. `tool/observer_acceptance.sh` proves the lease is TAKEN
// (`(share <topic> 300 <filter>)`) and CANCELLED (`… 0 …` on terminate), but
// never that it is RENEWED: the renewal fires at 0.8 x 300s = 240s and no run
// has ever lasted that long, so the timer has never been watched doing its job.
//
// `leaseTime` is an ordinary constructor parameter with its own validation, not
// a test-only knob bolted on for this — so a short lease makes the renewal
// boundary reachable in seconds rather than minutes, and the mechanism under
// test is the same one production uses.
//
//   dart run spike/lease/probe_lease.dart <control-topic> [seconds] [host] [port]
//
// The driver watches that control topic and asserts the SECOND request appears.
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: probe_lease.dart <control-topic> [lease-seconds] [host] [port]',
    );
    exit(64);
  }
  final producerControl = args[0];
  // tryParse, not parse. A probe that dies with an unhandled FormatException on
  // a typo'd argument reports a broken harness as a broken protocol, and the
  // driver reads only the exit code.
  final seconds = args.length > 1 ? int.tryParse(args[1]) : 5;
  if (seconds == null || seconds < 1) {
    stderr.writeln(
      'lease-seconds must be a whole number of seconds >= 1, got "${args[1]}"',
    );
    exit(64);
  }

  // Host and port come from the driver, which is the half that discovered the
  // producer and is watching the broker. Hardcoding 127.0.0.1 here made the two
  // halves of one instrument able to point at DIFFERENT brokers the moment
  // AIKO_MQTT_HOST was set -- the observer watching one, the consumer singing
  // to another.
  final host = args.length > 2 ? args[2] : '127.0.0.1';
  // Fail CLOSED, like `seconds` above. `?? 1883` silently swallowed a garbage
  // or empty port into the default while the shell handed mosquitto_sub the
  // original string — putting observer and consumer on different brokers, which
  // is the exact failure passing host/port through exists to prevent.
  final int port;
  if (args.length > 3 && args[3].isNotEmpty) {
    final parsed = int.tryParse(args[3]);
    if (parsed == null) {
      stderr.writeln('port must be an integer, got "${args[3]}"');
      exit(64);
    }
    port = parsed;
  } else {
    port = 1883;
  }
  final client = AikoClient(
    host: host,
    port: port,
    clientId: 'lease_probe_$pid',
  );
  await client.connect();
  final router = TopicRouter(client);
  final consumerPath = ServiceTopicPath.parse('aiko/leaseprobe/$pid/0');

  final consumer = ECConsumer(
    router,
    client,
    consumerPath: consumerPath,
    consumerId: 1,
    producerControlTopic: producerControl,
    leaseTime: Duration(seconds: seconds),
  );
  consumer.attach();
  print('LEASE_SECONDS=$seconds');
  print('CONSUMER_TOPIC=${consumer.topicShareIn}');
  print('attached to $producerControl with a ${seconds}s lease');

  // Long enough to cross 0.8 x lease at least twice, so the driver sees a
  // renewal AND can tell a repeating timer from a single late request.
  await Future<void>.delayed(Duration(seconds: (seconds * 2.2).round()));

  print('terminating — expect a cancellation with lease 0');
  await consumer.terminate();
  await Future<void>.delayed(const Duration(seconds: 1));
  await client.disconnect();
  exit(0);
}

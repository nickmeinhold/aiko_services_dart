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
//   dart run spike/lease/probe_lease.dart <producer-control-topic> [seconds]
//
// The driver watches that control topic and asserts the SECOND request appears.
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: probe_lease.dart <producer-control-topic> [lease-seconds]',
    );
    exit(64);
  }
  final producerControl = args[0];
  final seconds = args.length > 1 ? int.parse(args[1]) : 5;

  final client = AikoClient(host: '127.0.0.1', clientId: 'lease_probe_$pid');
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

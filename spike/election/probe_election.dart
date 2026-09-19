// Narrow probe: does the primary election actually run against a REAL broker?
//
// `RegistrarElection` is a pure state machine with a thorough unit suite. That
// suite proves it TRANSITIONS correctly given events; it says nothing about
// whether the events arrive correctly from a broker holding a real retained
// message, and nothing at all about the one invariant no fake can reach —
// that changing the will, which reconnects, does not DEAFEN the process.
//
//   dart run spike/election/probe_election.dart --namespace <ns> --mode <mode>
//
// Modes:
//   observe  connect, let the role settle, report it, leave cleanly.
//   promote  connect, wait to be promoted, then exit WITHOUT disconnecting, so
//            the broker publishes the retained will.
//   hold     connect, wait to be promoted, then stay up so the driver can
//            publish an external `(primary absent)` and watch us stand down.
//            A process deafened by its own promotion sits there as primary.
//
// Every machine-readable line is `KEY=value` on its own line, so the driver
// greps rather than parses prose.
import 'dart:async';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';
import 'package:args/args.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('namespace', defaultsTo: 'aiko')
    ..addOption('mode', allowed: ['observe', 'promote', 'hold'])
    ..addOption('host', defaultsTo: '127.0.0.1')
    ..addOption('port', defaultsTo: '1883')
    ..addOption('settle-ms', defaultsTo: '4000')
    ..addOption('hold-ms', defaultsTo: '8000')
    ..addFlag('help', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('$error\n${parser.usage}');
    exit(64);
  }
  if (options.flag('help') || options.option('mode') == null) {
    stderr.writeln(parser.usage);
    exit(64);
  }

  final port = int.tryParse(options.option('port')!);
  final settleMs = int.tryParse(options.option('settle-ms')!);
  final holdMs = int.tryParse(options.option('hold-ms')!);
  if (port == null || settleMs == null || holdMs == null) {
    stderr.writeln('port, settle-ms and hold-ms must be integers');
    exit(64);
  }

  final mode = options.option('mode')!;
  final process = RegistrarProcess(
    namespace: options.option('namespace')!,
    brokerHost: options.option('host')!,
    brokerPort: port,
  );

  // Printed BEFORE connecting, so the driver knows what to expect on the wire
  // even if we never get there. A driver that had to wait for a path could only
  // match a wildcard, and a wildcard makes concurrent runs read each other.
  print('TOPIC_PATH=${process.topicPath.path}');
  print('BOOT_TOPIC=${process.bootTopic}');

  final roles = process.lifecycle.listen(
    (role) => print('ROLE=${role.lifecycle}'),
  );

  // Waiting on the ANNOUNCEMENT, not on the role. An earlier version of this
  // probe waited for `role == primary` and exited — and caught a broker holding
  // the empty ClearBootTopic and nothing else, because the role leads the wire
  // by one reconnect. The signal to wait on is the one that witnesses the
  // publish.
  final promoted = Completer<void>();
  final announced = process.announcements.listen((path) {
    print('ANNOUNCED=$path');
    if (!promoted.isCompleted) promoted.complete();
  });
  final failures = process.promotionFailures.listen(
    (error) => print('PROMOTION_FAILED=$error'),
  );

  await process.connect();
  print('CONNECTED=${process.topicPath.path}');

  switch (mode) {
    case 'observe':
      // No waiting on a completer: the point of this arm is the role we end up
      // in when nothing happens, and a completer would only ever prove the
      // happy case arrived.
      await Future<void>.delayed(Duration(milliseconds: settleMs));

    case 'promote':
    case 'hold':
      await promoted.future.timeout(
        Duration(milliseconds: settleMs),
        onTimeout: () {
          print('NEVER_PROMOTED=${process.role.lifecycle}');
          exit(1);
        },
      );
      if (mode == 'hold') {
        // Stay up and keep printing role changes. The driver publishes an
        // external `(primary absent)` during this window; hearing it at all is
        // the assertion, because hearing requires the subscription to have
        // SURVIVED the reconnect that changing the will costs.
        print('HOLDING=${holdMs}ms');
        await Future<void>.delayed(Duration(milliseconds: holdMs));
      }
  }

  final latency = process.announcementLatency;
  print('LATENCY_MS=${latency == null ? 'none' : latency.inMilliseconds}');
  print('FINAL_ROLE=${process.role.lifecycle}');

  await roles.cancel();
  await announced.cancel();
  await failures.cancel();

  if (mode == 'promote') {
    // Exit WITHOUT disconnecting. Closing the socket with no DISCONNECT packet
    // is what makes the broker fire the will — the same thing a crash does,
    // without needing to be signalled from outside.
    print('DYING_WITHOUT_GOODBYE=1');
    exit(0);
  }
  await process.disconnect();
  print('LEFT_CLEANLY=1');
}

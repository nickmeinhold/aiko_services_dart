// A runnable Dart registrar.
//
//   dart run example/registrar.dart [--namespace aiko] [--host H] [--port P]
//
// This is the process an island would point at. It elects, announces itself
// retained, accepts registrations on its `/in`, serves the roster to anyone who
// asks, and retracts on death via a retained Last Will.
//
// What it does NOT do yet: consume the island's `{ns}/+/+/+/state` wills, so a
// service killed rather than deregistered stays in the roster. `(history ...)`
// is unimplemented. Both are the next increment, and both are named here rather
// than left for a reader to discover from silence.
//
// A CLEAN shutdown deliberately leaves the retained `(primary found ...)`
// standing, because that is what upstream does — nothing in `registrar.py`
// retracts on the way out; only the will fires, and a clean disconnect
// suppresses a will. So a gracefully stopped registrar tells the island a
// corpse is primary until something replaces it. Parity, and a hazard: see
// docs/notes/registrar-scope.md.
import 'dart:async';
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';
import 'package:args/args.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('namespace', defaultsTo: 'aiko')
    ..addOption('host', defaultsTo: '127.0.0.1')
    ..addOption('port', defaultsTo: '1883')
    ..addFlag('help', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('$error\n${parser.usage}');
    exit(64);
  }
  if (options.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final port = int.tryParse(options.option('port')!);
  if (port == null) {
    stderr.writeln('port must be an integer');
    exit(64);
  }

  final registrar = RegistrarProcess(
    namespace: options.option('namespace')!,
    brokerHost: options.option('host')!,
    brokerPort: port,
  );

  final subscriptions = <StreamSubscription<void>>[
    registrar.lifecycle.listen((role) => print('ROLE=${role.lifecycle}')),
    registrar.announcements.listen((path) => print('ANNOUNCED=$path')),
    registrar.serviceCounts.listen((n) => print('SERVICE_COUNT=$n')),
    registrar.rosterDrops.listen((_) => print('ROSTER_DROPPED=1')),
    registrar.promotionFailures.listen((e) => print('PROMOTION_FAILED=$e')),
  ];

  print('TOPIC_PATH=${registrar.topicPath.path}');
  print('BOOT_TOPIC=${registrar.bootTopic}');
  print('TOPIC_IN=${registrar.topicIn}');
  await registrar.connect();
  print('CONNECTED=1');

  // A container stop sends SIGTERM, so handling only SIGINT would make every
  // `docker stop` an unclean exit — which fires the will and is a DIFFERENT
  // observable from a graceful shutdown. Getting that wrong would make the two
  // cases indistinguishable in exactly the gate that exists to tell them apart.
  final stop = Completer<void>();
  void requestStop(ProcessSignal signal) {
    if (!stop.isCompleted) {
      print('SIGNAL=${signal.toString()}');
      stop.complete();
    }
  }

  final signals = <StreamSubscription<void>>[
    ProcessSignal.sigint.watch().listen(requestStop),
    ProcessSignal.sigterm.watch().listen(requestStop),
  ];

  await stop.future;
  for (final subscription in [...subscriptions, ...signals]) {
    await subscription.cancel();
  }
  await registrar.disconnect();
  print('LEFT_CLEANLY=1');
}

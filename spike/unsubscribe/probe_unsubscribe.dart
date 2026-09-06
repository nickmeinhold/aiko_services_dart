// Narrow probe: does AikoClient.unsubscribe() produce the broker-side
// "malformed packet" disconnect, or does something else?
//
//   dart run spike/unsubscribe/probe_unsubscribe.dart [no-unsub]
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main(List<String> args) async {
  final unsub = !args.contains('no-unsub');
  final c = AikoClient(host: 'localhost', clientId: 'probe_$pid');
  await c.connect();
  print('connected as probe_$pid; will ${unsub ? "" : "NOT "}unsubscribe');
  c.subscribe('aiko/probe/short');
  await Future<void>.delayed(const Duration(seconds: 3));
  if (unsub) c.unsubscribe('aiko/probe/short');
  await Future<void>.delayed(const Duration(seconds: 6));
  print('done');
  await c.disconnect();
}

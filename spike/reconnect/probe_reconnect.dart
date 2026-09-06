// Which callback actually fires when the broker goes away?
//
// Measured 2026-09-06 across a real broker restart. With `autoReconnect` set,
// `onDisconnected` is NEVER called — the client goes straight to reconnecting,
// so the observed sequence is `true, true` with no `false` between them. Any
// down-signal wired to `onDisconnected` alone is therefore working code for an
// event that is never delivered. `onAutoReconnect` is the one that fires.
//
//   dart run spike/reconnect/probe_reconnect.dart
//   (restart the broker while it runs)
import 'dart:io';

import 'package:aiko_services/aiko_services.dart';

Future<void> main() async {
  final c = AikoClient(host: 'localhost', clientId: 'reconnect_probe_$pid');
  c.transportUp.listen((up) => print('${DateTime.now()}  transportUp=$up'));
  c.messages.listen(
    (m) => print('${DateTime.now()}  msg ${m.topic} ${m.command}'),
  );
  await c.connect();
  c.subscribe('aiko/service/registrar');
  print('${DateTime.now()}  connected + subscribed; restart the broker now');
  await Future<void>.delayed(const Duration(seconds: 45));
  print('${DateTime.now()}  done');
  await c.disconnect();
}

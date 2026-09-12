// Tesla, round 6: "onDisconnected on a FAILED connect() is unmeasured — you
// probed the drop of a LIVE socket, not this arm." Correct: round 5's probe
// established one proposition and revision 4 leaned it on an adjacent one.
// Port 18899 has nothing listening.
import 'dart:async';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

Future<void> main() async {
  var disconnected = false;
  final c = MqttServerClient.withPort('localhost', 'failconn_$pid', 18899)
    ..logging(on: false)
    ..autoReconnect = false
    ..setProtocolV311()
    ..onDisconnected = (() {
      disconnected = true;
      print('  onDisconnected FIRED');
    })
    ..onConnected = (() => print('  onConnected'));
  c.connectionMessage = MqttConnectMessage().startClean();

  try {
    await c.connect();
    print('connect returned without throwing (unexpected)');
  } on Object catch (e) {
    print('connect threw: ${e.runtimeType}');
  }
  await Future<void>.delayed(const Duration(seconds: 3));
  print('state=${c.connectionStatus?.state}');
  print('--- onDisconnected fired on a FAILED connect: $disconnected ---');
  print(
    disconnected
        ? 'the package would arm nothing extra — but we still must not depend on it'
        : 'CONFIRMED: nothing fires. A failed connect arms NO recovery unless we do it.',
  );
  exit(0);
}

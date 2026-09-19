// Does `onDisconnected` actually fire when `autoReconnect` is FALSE?
//
// The design fork "should Dipped exist at all" turns on this. With
// `autoReconnect = true` it is measured DEAD — spike/reconnect/probe_reconnect.dart
// saw `true, true` and never a `false` across a real broker restart, so the
// down-signal is working code for an event that is never delivered. Option B
// (own the reconnect) makes `onDisconnected` load-bearing, and Tesla's round-5
// note is that fact 2 only ever probed the `true` path.
//
// So this probes the OTHER path, and it does it against a THROWAWAY broker on
// 18831 rather than the live island's 1883 — killing the island's broker to
// answer a design question would spend Nick's running services on our curiosity.
//
//   docker run -d --name probe-mosq -p 18831:1883 eclipse-mosquitto:2 \
//     mosquitto -c /mosquitto-no-auth.conf
//   dart run spike/autoreconnect-off/probe_disconnect_signal.dart
//   (the probe stops the broker itself)
//
// MEASURED 2026-09-11, against mqtt_client 10.11.11:
//
//   17:24:57.933  onConnected
//   17:24:57.937  stopping the throwaway broker
//   17:24:57.998  onDisconnected          <-- 65ms after the stop
//   17:25:18.108  final state=disconnected
//   onAutoReconnect fired: false
//
// So `onDisconnected` IS a live signal when `autoReconnect` is false, and the
// client stays down rather than resurrecting. That is the one premise Option B
// rests on that four design rounds never checked — Tesla's round-5 note that
// fact 2 only ever probed the `true` path. It is now checked, on both arms: the
// callback that is dead under `autoReconnect = true` is alive under false, and
// the callback that fires under true correctly does not fire under false.
import 'dart:async';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

Future<void> main() async {
  final events = <String>[];
  void note(String s) {
    final line = '${DateTime.now().toIso8601String()}  $s';
    events.add(line);
    print(line);
  }

  final client = MqttServerClient.withPort('localhost', 'ar_off_$pid', 18831)
    ..logging(on: false)
    ..keepAlivePeriod =
        5 // short, so the probe does not outlive our patience
    ..autoReconnect =
        false // THE VARIABLE UNDER TEST
    ..setProtocolV311()
    ..onConnected = (() => note('onConnected'))
    ..onDisconnected = (() => note('onDisconnected'))
    ..onAutoReconnect = (() => note('onAutoReconnect'))
    ..onAutoReconnected = (() => note('onAutoReconnected'));

  client.connectionMessage = MqttConnectMessage().startClean();

  await client.connect();
  note('connected; state=${client.connectionStatus?.state}');
  client.subscribe('probe/topic', MqttQos.atMostOnce);

  note('stopping the throwaway broker');
  final stop = await Process.run('docker', ['stop', 'probe-mosq']);
  note('docker stop rc=${stop.exitCode}');

  // Long enough for 1.5 x keepAlive plus slack.
  await Future<void>.delayed(const Duration(seconds: 20));

  note('final state=${client.connectionStatus?.state}');
  note('--- VERDICT ---');
  final fired = events.any((e) => e.contains('onDisconnected'));
  note(
    fired
        ? 'onDisconnected FIRED with autoReconnect=false -> Option B has a live signal'
        : 'onDisconnected DID NOT FIRE -> Option B would be built on a dead callback',
  );
  final auto = events.any((e) => e.contains('onAutoReconnect'));
  note('onAutoReconnect fired: $auto (must be false — it is disabled)');
  exit(0);
}

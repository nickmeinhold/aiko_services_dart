import 'package:aiko_services/aiko_services.dart';

/// A Dart app on a live Aiko bus: connect to MQTT, publish function calls as
/// S-expressions, and decode whatever comes back. Run against a local broker:
///
///   /opt/homebrew/sbin/mosquitto -p 1883 &
///   dart run example/bus_demo.dart
///
/// Pass a broker host as the first arg (default localhost).
Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : 'localhost';
  final client = AikoClient(host: host);
  await client.connect();
  print('connected to $host:1883');

  const topic = 'aiko/demo/robot/in';
  client.subscribe(topic);
  client.messages.listen((m) {
    // Exhaustive: the switch has no default arm, so a new CallArguments case
    // would be a compile error here rather than a silently unhandled shape.
    final shape = switch (m.arguments) {
      PositionalArguments(:final values) => 'positional $values',
      KeywordArguments(:final values) => 'keyword $values',
    };
    print('recv <- ${m.topic}: ${m.command} $shape');
  });

  await Future<void>.delayed(const Duration(milliseconds: 300));

  print('send -> move("forward","10")');
  client.send(topic, 'move', ['forward', '10']);

  print('send -> message{username:nick, message:"hello bus"}');
  client.send(topic, 'message', {'username': 'nick', 'message': 'hello bus'});

  await Future<void>.delayed(const Duration(seconds: 1));
  await client.disconnect();
  print('done');
}

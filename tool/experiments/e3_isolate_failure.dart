// EXPERIMENT 3 — Isolate failure-linking.
//
// Question: when an isolate dies, does anything tell its peers? Or does its
// SendPort simply go silent forever, leaving the fleet talking to a corpse?
import 'dart:async';
import 'dart:isolate';

void main() async {
  // --- Arm 1: NO onError/onExit requested (the default a naive port writes) ---
  final rp = ReceivePort();
  final ready = Completer<SendPort>();
  rp.listen((Object? m) {
    if (m is SendPort) {
      ready.complete(m);
    } else {
      print('  parent received: $m');
    }
  });

  await Isolate.spawn(_child, rp.sendPort);
  final childPort = await ready.future;

  print('ARM 1 — no onExit/onError requested');
  childPort.send('ping-1');
  await Future<void>.delayed(const Duration(milliseconds: 200));

  childPort.send('DIE');
  await Future<void>.delayed(const Duration(milliseconds: 300));

  print('  child should now be dead. Sending ping-2 into the corpse...');
  childPort.send('ping-2');
  await Future<void>.delayed(const Duration(milliseconds: 300));
  print('  parent is STILL ALIVE and received no error, no exit signal.');
  rp.close();

  // --- Arm 2: onExit/onError explicitly requested (positive control) ---
  print('ARM 2 — onExit + onError explicitly requested (positive control)');
  final rp2 = ReceivePort();
  final exitPort = ReceivePort();
  final errorPort = ReceivePort();
  final ready2 = Completer<SendPort>();
  rp2.listen((Object? m) {
    if (m is SendPort) ready2.complete(m);
  });
  exitPort.listen((Object? m) => print('  onExit signal: $m'));
  errorPort.listen((Object? m) => print('  onError signal: $m'));

  await Isolate.spawn(
    _child,
    rp2.sendPort,
    onExit: exitPort.sendPort,
    onError: errorPort.sendPort,
  );
  final childPort2 = await ready2.future;
  childPort2.send('DIE');
  await Future<void>.delayed(const Duration(milliseconds: 500));
  rp2.close();
  exitPort.close();
  errorPort.close();
}

void _child(SendPort parent) {
  final rp = ReceivePort();
  parent.send(rp.sendPort);
  rp.listen((Object? m) {
    if (m == 'DIE') {
      throw StateError('child isolate is dying');
    }
    parent.send('echo of $m');
  });
}

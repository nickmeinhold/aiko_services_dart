// EXPERIMENT 4 — SendPort backpressure.
//
// Question: an unbounded queue in front of a bounded mailbox. Does a SendPort
// ever push back, block, or signal? Or does the producer win, forever?
//
// Decides whether credit-based backpressure is addable WITHOUT touching the wire.
//
// CONTROLS. Arm A pauses the consumer's subscription outright -- if the queue
// is unbounded, RSS must climb and the producer must never block. Arm B is the
// positive control: the same burst with a live consumer must drain and NOT
// climb. A run where both arms look alike is void.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

const int burst = 400000;

void main() async {
  await _arm(paused: true, label: 'ARM A: consumer PAUSED (queue must build)');
  await _arm(paused: false, label: 'ARM B: consumer LIVE  (positive control)');
  exit(0);
}

Future<void> _arm({required bool paused, required String label}) async {
  print(label);
  final rp = ReceivePort();
  var received = 0;
  final sub = rp.listen((Object? m) => received++);
  if (paused) sub.pause();

  final ctl = ReceivePort();
  final sent = Completer<int>();
  ctl.listen((Object? m) {
    if (m is int) sent.complete(m);
  });

  final rssBefore = ProcessInfo.currentRss;
  final sw = Stopwatch()..start();
  final iso = await Isolate.spawn(_producer, [ctl.sendPort, rp.sendPort]);
  final sendMs = await sent.future;
  final tAllSent = sw.elapsedMilliseconds;

  // Let the queue settle / drain.
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!paused && received >= burst) break;
  }
  final rssAfter = ProcessInfo.currentRss;

  print(
    '  producer sent $burst in ${sendMs}ms and NEVER BLOCKED '
    '(all-sent at t=${tAllSent}ms)',
  );
  print('  consumer drained: $received');
  print(
    '  rss ${(rssBefore / 1048576).toStringAsFixed(1)}MB -> '
    '${(rssAfter / 1048576).toStringAsFixed(1)}MB  '
    '(delta ${((rssAfter - rssBefore) / 1048576).toStringAsFixed(1)}MB)',
  );
  print('');

  await sub.cancel();
  rp.close();
  ctl.close();
  iso.kill(priority: Isolate.immediate);
}

void _producer(List<Object?> args) {
  final ctl = args[0]! as SendPort;
  final out = args[1]! as SendPort;
  final sw = Stopwatch()..start();
  for (var i = 0; i < burst; i++) {
    out.send({'seq': i, 'payload': List<int>.filled(64, i)});
  }
  ctl.send(sw.elapsedMilliseconds);
}

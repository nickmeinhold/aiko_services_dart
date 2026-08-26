// EXPERIMENT 1 — Scheduling.
//
// Question: when is a microtask vs a Timer vs an inbound isolate message
// serviced, relative to a *synchronous* slice and relative to a long `await`?
//
// This defines what "occupying the actor" physically means, and decides whether
// a HandlerTimeout can be built as a Timer at all.
import 'dart:async';
import 'dart:isolate';

late final Stopwatch _sw;
void log(String s) =>
    print('[${_sw.elapsedMilliseconds.toString().padLeft(5)}ms] $s');

void main() async {
  _sw = Stopwatch()..start();

  final rp = ReceivePort();
  rp.listen((Object? m) => log('INBOUND isolate message: $m'));
  await Isolate.spawn(_child, rp.sendPort);

  log('--- PHASE A: synchronous slice ---');
  Timer(Duration.zero, () => log('  Timer(0) fired'));
  Timer(const Duration(milliseconds: 50), () => log('  Timer(50ms) fired'));
  Timer(const Duration(milliseconds: 150), () => log('  Timer(150ms) fired'));
  scheduleMicrotask(() => log('  microtask fired'));

  log('sync slice START (300ms of real CPU)');
  final end = DateTime.now().add(const Duration(milliseconds: 300));
  var spins = 0;
  while (DateTime.now().isBefore(end)) {
    spins++;
  }
  log('sync slice END (spun $spins)');

  await Future<void>.delayed(const Duration(milliseconds: 100));

  log('--- PHASE B: long await ---');
  final ticks = <int>[];
  Timer.periodic(const Duration(milliseconds: 50), (t) {
    ticks.add(t.tick);
    log('  keepalive tick ${t.tick}');
    if (t.tick >= 4) t.cancel();
  });
  log('awaiting 250ms...');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  log('long await done; keepalive ticks during it: $ticks');

  rp.close();
}

void _child(SendPort p) {
  p.send('hello from child isolate');
}

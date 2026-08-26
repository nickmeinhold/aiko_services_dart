// EXPERIMENT 1b — Relative priority of microtask / inbound isolate message /
// Timer, when all three are GENUINELY pending at the moment the actor yields.
//
// NOTE: the first version of this experiment was VOID -- it settled for 50ms
// before the synchronous slice, so the isolate message was consumed before the
// contest began. The child now delays its send so the message lands DURING the
// slice. Guard: the run is only valid if all three arrive after the slice ends.
import 'dart:async';
import 'dart:isolate';

Future<List<String>> round() async {
  final seen = <String>[];
  final done = Completer<void>();
  void note(String s) {
    seen.add(s);
    if (seen.length == 3 && !done.isCompleted) done.complete();
  }

  final rp = ReceivePort();
  rp.listen((Object? m) => note('isolate-message'));
  // Child sleeps 80ms, then sends -- i.e. mid-slice.
  await Isolate.spawn(_child, rp.sendPort);

  Timer(const Duration(milliseconds: 20), () => note('timer'));
  scheduleMicrotask(() => note('microtask'));

  // Synchronous slice covering the child's send and the timer's deadline.
  final end = DateTime.now().add(const Duration(milliseconds: 200));
  while (DateTime.now().isBefore(end)) {}

  await done.future.timeout(
    const Duration(seconds: 3),
    onTimeout: () => seen.add('TIMEOUT'),
  );
  rp.close();
  return seen;
}

void main() async {
  for (var i = 1; i <= 8; i++) {
    print('run $i: ${await round()}');
  }
}

void _child(SendPort p) {
  final end = DateTime.now().add(const Duration(milliseconds: 80));
  while (DateTime.now().isBefore(end)) {}
  p.send('m');
}

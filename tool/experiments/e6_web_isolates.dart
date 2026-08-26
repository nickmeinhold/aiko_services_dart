// EXPERIMENT 6 — Web isolates.
//
// Question: is Isolate.spawn available on the browser target? D8's
// transport-isolate mitigation may simply be UNAVAILABLE on web.
//
// The COMPILE succeeding proves nothing -- dart2js compiles the call and may
// throw at runtime. This program carries its own positive control: if you do
// not see "CONTROL: program is running", the instrument is broken, not the
// feature.
import 'dart:isolate';

void main() async {
  print('CONTROL: program is running');
  try {
    final rp = ReceivePort();
    print('CONTROL: ReceivePort constructed');
    await Isolate.spawn(_child, rp.sendPort);
    print('RESULT: Isolate.spawn RETURNED (isolates appear available)');
    final got = await rp.first.timeout(
      const Duration(seconds: 2),
      onTimeout: () => 'RESULT: spawn returned but NO MESSAGE arrived',
    );
    print('RESULT: $got');
    rp.close();
  } on Object catch (e) {
    print('RESULT: Isolate.spawn THREW ${e.runtimeType}: $e');
  }
  print('CONTROL: program reached the end');
}

void _child(SendPort p) => p.send('hello from a web isolate');

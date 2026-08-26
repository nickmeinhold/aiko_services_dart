// EXPERIMENT 5 — Microtask ordering across `await`.
//
// This generalises the fact that killed `parking`: an `await`'s continuation
// resumes as a MICROTASK. No queue can own "the rest of the function", so no
// mailbox can re-admit it as a fresh turn.
//
// It also probes the §5 in-memory loopback case, where a reply completes
// SYNCHRONOUSLY -- the uniform local/remote path the mailbox exists to make
// identical.
import 'dart:async';

var actorState = 0;

Future<void> handlerA() async {
  actorState = 1;
  print('  A: set state=1, about to await');
  await Future<void>.delayed(Duration.zero);
  print(
    '  A: resumed. state is now $actorState '
    '${actorState == 1 ? "(intact)" : "(!! MUTATED UNDER ME !!)"}',
  );
}

Future<void> handlerB() async {
  print('  B: running, setting state=2');
  actorState = 2;
}

void main() async {
  print('--- interleaving: does B run between A\'s two halves? ---');
  final a = handlerA();
  final b = handlerB();
  await Future.wait([a, b]);

  print('--- who owns the continuation? ---');
  // If the continuation were a queueable unit, we could observe it as a
  // distinct scheduled entity. Show that it is indistinguishable from a
  // microtask and runs BEFORE any Timer, i.e. before a mailbox could interpose.
  Timer(
    Duration.zero,
    () => print('  Timer(0) -- a mailbox pump would live here'),
  );
  await Future<void>.value();
  print('  continuation after `await Future.value()` -- ran BEFORE the Timer');

  print('--- synchronous completion: the in-memory loopback shape ---');
  final order = <String>[];
  final c = Completer<void>();
  // A loopback reply that is ALREADY complete when awaited.
  final already = Future<void>.value();
  order.add('before await');
  scheduleMicrotask(() => order.add('microtask queued before the await'));
  await already;
  order.add('after await of an already-complete future');
  c.complete();
  await c.future;
  print('  order: $order');
  print('  => the continuation ran BEFORE a microtask queued earlier. See');
  print('     e5b: the tick cost depends on when the future\'s completion was');
  print('     SCHEDULED (construction time), not on whether it is complete.');
}

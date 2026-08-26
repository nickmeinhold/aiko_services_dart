// EXPERIMENT 5b — Does awaiting an ALREADY-COMPLETE future preempt microtasks
// queued before it?
//
// e5 observed the continuation running AHEAD of an earlier-queued microtask.
// That is an ordering hazard for the in-memory loopback (a reply that is
// already complete when awaited). Pin the exact shape rather than theorising.
import 'dart:async';

Future<void> probe(String label, Future<void> target) async {
  final order = <String>[];
  scheduleMicrotask(() => order.add('M1'));
  scheduleMicrotask(() => order.add('M2'));
  order.add('sync');
  await target;
  order.add('CONTINUATION');
  // Let anything still queued drain.
  await Future<void>.delayed(Duration.zero);
  print('  $label -> $order');
}

void main() async {
  print('How many microtask ticks does each await shape cost?');
  await probe('await Future<void>.value()      ', Future<void>.value());
  await probe('await (Completer..complete()).f ', () {
    final c = Completer<void>()..complete();
    return c.future;
  }());
  await probe(
    'await Future.microtask(()=>{})  ',
    Future<void>.microtask(() {}),
  );
  await probe('await Future.sync(()=>{})       ', Future<void>.sync(() {}));
  await probe(
    'await Future.delayed(Duration.zero)',
    Future<void>.delayed(Duration.zero),
  );

  print('');
  print('Same question, null-typed value (the fast path differs):');
  final order = <String>[];
  scheduleMicrotask(() => order.add('M1'));
  scheduleMicrotask(() => order.add('M2'));
  await null;
  order.add('CONTINUATION (await null)');
  await Future<void>.delayed(Duration.zero);
  print('  await null -> $order');
}

// EXPERIMENT 2 — Cancellation.
//
// Question: can a Dart Future be cancelled? The round-2 "zombie handler" claim
// says no: `.timeout()` abandons the WAIT, not the WORK.
import 'dart:async';

var sideEffect = 'untouched';

Future<String> handler() async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  sideEffect = 'MUTATED by a handler the caller already gave up on';
  print('  [handler] ran to completion at t=300ms');
  return 'result nobody is listening for';
}

void main() async {
  final f = handler();
  try {
    await f.timeout(const Duration(milliseconds: 100));
    print('no timeout (unexpected)');
  } on TimeoutException {
    print('caller TIMED OUT at t=100ms; sideEffect = "$sideEffect"');
  }

  await Future<void>.delayed(const Duration(milliseconds: 400));
  print('at t=500ms, sideEffect = "$sideEffect"');

  // Does the abandoned future still complete? Attach a late listener.
  final late_ = await f;
  print('the abandoned future DID complete with: "$late_"');
}

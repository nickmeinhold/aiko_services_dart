// EXPERIMENT 7 — Can ONE dart2js artifact serve as both the page and the Worker?
//
// This is the load-bearing unknown behind the whole "actor = anything on the
// other end of a duplex text channel" idea. A Worker takes a SCRIPT URL, and
// dart2js does whole-program compilation. If a single compiled artifact cannot
// detect it is running in worker scope and branch at main(), then D8's web
// story needs two build artifacts -- or is unreachable, and D8 picks "no
// offload" by default.
//
// It also probes the two web-only primitives that have NO isolate analogue:
// BroadcastChannel (broker-less same-origin mesh) and SharedWorker (one actor
// shared by N tabs).
//
// Payload is our REAL S-expression codec, not a toy string, so this measures
// the actual boundary the design proposes.
//
// Run: see tool/experiments/e7_serve.sh
@JS()
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:aiko_services/src/codec/s_expression.dart';

// --- minimal hand-rolled externs (no package:web dependency needed) ---

@JS('Worker')
extension type _Worker._(JSObject _) implements JSObject {
  external factory _Worker(String url);
  external void postMessage(JSAny? message);
  external set onmessage(JSFunction f);
  external set onerror(JSFunction f);
}

@JS('SharedWorker')
extension type _SharedWorker._(JSObject _) implements JSObject {
  external factory _SharedWorker(String url);
}

@JS('BroadcastChannel')
extension type _BroadcastChannel._(JSObject _) implements JSObject {
  external factory _BroadcastChannel(String name);
  external void postMessage(JSAny? message);
  external set onmessage(JSFunction f);
  external void close();
}

/// True when this artifact is executing in a Worker: worker global scope has
/// no `window`.
bool get _inWorker => !globalContext.has('window');

void _out(String line) {
  print(line);
  // Mirror into the DOM so the result is visible in a screenshot, not only in
  // the console.
  if (!_inWorker && globalContext.has('document')) {
    final doc = globalContext.getProperty('document'.toJS) as JSObject;
    final body = doc.getProperty('body'.toJS) as JSObject?;
    if (body == null) return;
    final pre = doc.callMethod('createElement'.toJS, 'div'.toJS) as JSObject;
    pre.setProperty('textContent'.toJS, line.toJS);
    pre.setProperty(
      'style'.toJS,
      'font:13px ui-monospace,monospace;padding:2px 0'.toJS,
    );
    body.callMethod('appendChild'.toJS, pre);
  }
}

/// The global scope's constructor name: `Window`, `DedicatedWorkerGlobalScope`
/// or `SharedWorkerGlobalScope`. This is how one artifact learns which role it
/// was loaded into.
String _globalScopeName() {
  final ctor = globalContext.getProperty('constructor'.toJS) as JSObject?;
  final name = ctor?.getProperty('name'.toJS);
  return (name as JSString?)?.toDart ?? 'unknown';
}

void main() {
  switch (_globalScopeName()) {
    case 'SharedWorkerGlobalScope':
      _sharedWorkerRole();
    case 'DedicatedWorkerGlobalScope':
      _workerRole();
    default:
      _pageRole();
  }
}

// --------------------------------------------------------- shared-worker role

/// Lives in the SHARED worker. If two tabs really share one worker instance,
/// both see this same counter increment -- which is the whole claim.
int _connections = 0;

void _sharedWorkerRole() {
  globalContext.setProperty(
    'onconnect'.toJS,
    ((JSObject event) {
      final ports = event.getProperty('ports'.toJS) as JSArray;
      final port = ports.toDart.first as JSObject;
      _connections++;
      final myConnection = _connections;
      port.setProperty(
        'onmessage'.toJS,
        ((JSObject ev) {
          final text = (ev.getProperty('data'.toJS) as JSString).toDart;
          final tree = parse(text);
          final reply = generate('shared_worker', [
            'this_connection',
            myConnection,
            'connections_total',
            _connections,
            'echo',
            tree.toString(),
          ]);
          port.callMethod('postMessage'.toJS, reply.toJS);
        }).toJS,
      );
      port.callMethod('start'.toJS);
    }).toJS,
  );
}

// ---------------------------------------------------------------- worker role

void _workerRole() {
  // Prove the codec itself runs here, not just that the script loaded.
  globalContext.setProperty(
    'onmessage'.toJS,
    ((JSObject event) {
      final data = event.getProperty('data'.toJS);
      final text = (data as JSString).toDart;
      String reply;
      try {
        final tree = parse(text);
        // Echo the parsed shape back out through our own generator, so a
        // round-trip failure anywhere in the codec shows up as a mismatch.
        reply = generate('worker_parsed', [tree.toString()]);
      } on Object catch (e) {
        reply = generate('worker_error', ['$e']);
      }
      globalContext.callMethod('postMessage'.toJS, reply.toJS);
    }).toJS,
  );
}

// ------------------------------------------------------------------ page role

void _pageRole() {
  _out('CONTROL: page role is running (this artifact executed as a page)');

  // --- Probe A: one artifact, two roles ---
  final request = generate('test', [1, 'two', 3.5]);
  _out('A. page -> worker  : $request');
  try {
    final w = _Worker('e7.js');
    w.onmessage = ((JSObject event) {
      final reply = (event.getProperty('data'.toJS) as JSString).toDart;
      _out('A. worker -> page  : $reply');
      _out(
        'A. RESULT: ONE ARTIFACT SERVED BOTH ROLES. Codec ran in the worker.',
      );
      _probeB();
    }).toJS;
    w.onerror = ((JSObject event) {
      final msg = event.getProperty('message'.toJS);
      _out('A. RESULT: worker FAILED to start: ${msg?.dartify()}');
      _probeB();
    }).toJS;
    w.postMessage(request.toJS);
  } on Object catch (e) {
    _out('A. RESULT: Worker construction THREW ${e.runtimeType}: $e');
    _probeB();
  }
}

// --- Probe B: BroadcastChannel -- broker-less same-origin mesh ---
void _probeB() {
  try {
    final rx = _BroadcastChannel('aiko-mesh');
    final tx = _BroadcastChannel('aiko-mesh');
    rx.onmessage = ((JSObject event) {
      final msg = (event.getProperty('data'.toJS) as JSString).toDart;
      _out('B. received on channel: $msg');
      _out(
        'B. RESULT: BroadcastChannel carries S-expressions. A broker-less '
        'same-origin mesh is available.',
      );
      rx.close();
      tx.close();
      _probeC();
    }).toJS;
    final msg = generate('share', ['lifecycle', 'ready']);
    _out('B. posting to channel : $msg');
    tx.postMessage(msg.toJS);
  } on Object catch (e) {
    _out('B. RESULT: BroadcastChannel THREW ${e.runtimeType}: $e');
    _probeC();
  }
}

// --- Probe C: SharedWorker -- one actor for N tabs (no isolate analogue) ---
void _probeC() {
  if (!globalContext.has('SharedWorker')) {
    _out('C. RESULT: SharedWorker is NOT DEFINED in this browser.');
    _done();
    return;
  }
  try {
    final sw = _SharedWorker('e7.js');
    final port = sw.getProperty('port'.toJS) as JSObject;
    port.setProperty(
      'onmessage'.toJS,
      ((JSObject ev) {
        final reply = (ev.getProperty('data'.toJS) as JSString).toDart;
        _out('C. shared worker -> : $reply');
        _out(
          'C. RESULT: a SharedWorker served this tab. If a SECOND tab reports '
          'connections_total > 1, both tabs share ONE actor instance.',
        );
        _done();
      }).toJS,
    );
    port.callMethod('start'.toJS);
    final hello = generate('hello', ['tab', DateTime.now().millisecond]);
    _out('C. -> shared worker  : $hello');
    port.callMethod('postMessage'.toJS, hello.toJS);
  } on Object catch (e) {
    _out('C. RESULT: SharedWorker THREW ${e.runtimeType}: $e');
    _done();
  }
}

void _done() => _out('CONTROL: all probes reached the end');

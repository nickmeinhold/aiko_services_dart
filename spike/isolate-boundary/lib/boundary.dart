/// Isolate-boundary spike — proving Aiko's *distributed* actor seam survives
/// the Dart isolate boundary, and that the composed-mixin mapping from the
/// composition spike never has to cross it.
///
/// Python reference (aiko_services/main):
///   * `discovery.py:_make_service_proxy` and `transport/transport_mqtt.py:
///     make_proxy_mqtt` build a remote-actor proxy from a list of PUBLIC METHOD
///     NAME STRINGS (`getmembers(protocol_class, isfunction)`) — never the impl
///     object. Each proxy method does:
///         payload = generate(method_name, arguments)   # NAME + args -> String
///         aiko.message.publish(target_topic_in, payload)
///   * `actor.py:_topic_in_handler` receives the String off the wire:
///         command, parameters = parse(payload_in)
///         target.__getattribute__(command)(*parameters)   # by-NAME dispatch
///   * `utilities/parser.py:generate/parse` are documented inverses producing
///     canonical S-expressions: `(command arg1 arg2 ...)`.
///
/// The load-bearing claim this file makes falsifiable:
///   Nothing but a String ever crosses an actor boundary. The composed mixin
///   object lives entirely inside ONE isolate; a second isolate invokes its
///   methods by sending only an S-expr command String; the far side dispatches
///   BY NAME against its own local object. Method tables never ride the wire.
///
/// The ONE real porting nuance vs Python: Dart has no runtime `getattr` without
/// `dart:mirrors` (banned in Flutter/AOT). By-name dispatch therefore uses an
/// explicit `Map<String, Function>` built from the SAME method-name list the
/// proxy uses — symmetric, bounded, codegen-friendly.
library;

import 'dart:async';
import 'dart:isolate';

// ─────────────────────────────────────────────────────────────────────────
// Minimal faithful port of parser.py `generate`/`parse` for the FLAT command
// case `(command arg1 arg2 ...)` that topic_in dispatch and EC deltas use.
// Scope: flat lists of atoms. Full nested/dict canonical S-expressions are the
// Python reference's job; this spike proves the wire mechanism ports, not that
// the whole grammar is reimplemented. Atoms containing whitespace/parens are
// length-prefixed (`len:data`) exactly as generate_s_expression does; null ->
// `0:`; empty String -> `""`.
// ─────────────────────────────────────────────────────────────────────────

final RegExp _delimiters = RegExp(r'^\d+:|[\s()]');

/// Port of `generate(command, parameters)` for flat atom lists.
String generate(String command, List<Object?> parameters) {
  final buf = StringBuffer('(');
  var sep = '';
  for (final element in <Object?>[command, ...parameters]) {
    String token;
    if (element == null) {
      token = '0:';
    } else if (element is String) {
      if (element.isEmpty) {
        token = '""';
      } else if (_delimiters.hasMatch(element)) {
        token = '${element.length}:$element';
      } else {
        token = element;
      }
    } else {
      token = '$element'; // int/double/bool ride as their String form
    }
    buf.write('$sep$token');
    sep = ' ';
  }
  buf.write(')');
  return buf.toString();
}

final RegExp _canonical = RegExp(r'^(\d+):');

/// Port of `parse(payload)` for the flat `(command ...)` case. Returns
/// `(command, args)` mirroring parser.py's car/cdr split. Numbers stay Strings
/// (Python leans on parse_int/parse_float at the use-site), matching the wire.
(String, List<String?>) parse(String payload) {
  var s = payload.trim();
  if (!s.startsWith('(') || !s.endsWith(')')) {
    throw FormatException('Not a flat S-expression: $payload');
  }
  s = s.substring(1, s.length - 1);
  final tokens = <String?>[];
  var i = 0;
  while (i < s.length) {
    // Skip whitespace between atoms.
    if (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {
      i++;
      continue;
    }
    // Canonical length-prefixed atom: `len:data` (may contain spaces).
    final m = _canonical.matchAsPrefix(s.substring(i));
    if (m != null) {
      final len = int.parse(m.group(1)!);
      final start = i + m.group(0)!.length;
      if (len == 0) {
        tokens.add(null); // `0:` encodes None/null
        i = start;
      } else {
        tokens.add(s.substring(start, start + len));
        i = start + len;
      }
      continue;
    }
    // Quoted string (handles the empty-string `""` case).
    if (s[i] == '"' || s[i] == "'") {
      final quote = s[i];
      final end = s.indexOf(quote, i + 1);
      tokens.add(s.substring(i + 1, end));
      i = end + 1;
      continue;
    }
    // Plain token up to the next delimiter.
    var j = i;
    while (j < s.length && s[j] != ' ' && s[j] != '\t' && s[j] != '\n') {
      j++;
    }
    tokens.add(s.substring(i, j));
    i = j;
  }
  final command = tokens.isEmpty ? '' : (tokens.first ?? '');
  final args = tokens.length > 1 ? tokens.sublist(1) : <String?>[];
  return (command, args);
}

// ─────────────────────────────────────────────────────────────────────────
// A composed-mixin "actor" — the SAME shape as the composition spike. This is
// the object whose method table the consolidation feared couldn't cross a
// boundary. It never needs to: it lives inside the actor-host isolate and is
// invoked by name.
// ─────────────────────────────────────────────────────────────────────────

mixin CounterMixin {
  int _count = 0;
  void increment(int by) => _count += by;
  int get count => _count;
}

mixin GreeterMixin {
  String greet(String who) => 'hello $who';
}

/// Aiko's `self.share` state dictionary, mutated by EC-style `(update ...)`
/// deltas arriving on the wire — the same `generate`/`parse` mechanism.
mixin ShareMixin {
  final Map<String, String> share = {'lifecycle': 'ready', 'running': 'false'};
  void applyDelta(String command, String itemName, String? itemValue) {
    // Mirrors share.py `_consumer_handler`: add/update/remove on a flat map.
    if (command == 'update' || command == 'add') {
      share[itemName] = itemValue ?? '';
    } else if (command == 'remove') {
      share.remove(itemName);
    }
  }
}

/// The full composed actor — three mixins flattened onto one object, exactly
/// like `class Category(Actor, Dependency)` composes slices.
class CounterActor with CounterMixin, GreeterMixin, ShareMixin {}

// ─────────────────────────────────────────────────────────────────────────
// The by-name dispatch table — Dart's mirrors-free stand-in for Python's
// `target.__getattribute__(command)(*parameters)`. Built from a known set of
// method names (the same list a remote proxy would be built from). Returns a
// String result, mirroring the S-expr reply convention.
// ─────────────────────────────────────────────────────────────────────────

/// The public "interface" as method-name strings — this is ALL a remote proxy
/// needs (discovery.py `_get_public_method_names`). The dispatch table is its
/// mirror image on the receiving side.
const counterActorMethods = ['increment', 'greet', 'describe', 'update'];

String dispatch(CounterActor actor, String command, List<String?> args) {
  switch (command) {
    case 'increment':
      actor.increment(int.parse(args[0] ?? '0'));
      return generate('count', [actor.count]);
    case 'greet':
      return generate('greeting', [actor.greet(args[0] ?? '')]);
    case 'describe':
      return generate('description', ['CounterActor(count=${actor.count})']);
    case 'update': // EC state delta: (update itemName itemValue)
      actor.applyDelta('update', args[0] ?? '', args.length > 1 ? args[1] : '');
      return generate('ack', [args[0]]);
    default:
      // Mirrors actor.py Message.invoke() "Function not found" — a diagnostic,
      // never a crash.
      return generate('error', ['Function not found: $command']);
  }
}

// ─────────────────────────────────────────────────────────────────────────
// The actor-host isolate entry point. It CONSTRUCTS the composed mixin object
// locally (inside this isolate) and only ever exchanges Strings with the
// outside world — the exact Aiko contract. `topicIn` stands in for MQTT.
// ─────────────────────────────────────────────────────────────────────────

/// Message envelope crossing the SendPort: a topic_in String payload + a reply
/// port. Both are sendable primitives — no actor object is ever included.
class WirePayload {
  final String payload; // canonical S-expr, e.g. "(increment 5)"
  final SendPort reply;
  WirePayload(this.payload, this.reply);
}

void actorHostIsolate(SendPort handshake) {
  // The composed mixin actor is born HERE and never leaves.
  final actor = CounterActor();
  final topicIn = ReceivePort();
  handshake.send(topicIn.sendPort); // hand the caller only a SendPort
  topicIn.listen((message) {
    final wire = message as WirePayload;
    final (command, args) = parse(wire.payload); // String -> (name, args)
    final result = dispatch(actor, command, args); // by-name on LOCAL object
    wire.reply.send(result); // reply is a String too
  });
}

/// Caller-side helper: spawn the actor host, return a function that sends an
/// S-expr command String and awaits the String reply. The caller NEVER holds a
/// reference to the actor object — only its topic_in SendPort.
Future<Future<String> Function(String payload)> spawnActor() async {
  final handshake = ReceivePort();
  await Isolate.spawn(actorHostIsolate, handshake.sendPort);
  final topicIn = await handshake.first as SendPort;
  return (String payload) async {
    final reply = ReceivePort();
    topicIn.send(WirePayload(payload, reply.sendPort));
    final result = await reply.first as String;
    reply.close();
    return result;
  };
}

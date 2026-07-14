/// By-name message dispatch — Dart's mirrors-free stand-in for Python's
/// `target.__getattribute__(command)(*parameters)`.
///
/// Python resolves an incoming command to a method dynamically via `getattr`
/// (`actor.py:Message.invoke`). Dart has no runtime `getattr` without
/// `dart:mirrors`, which is banned in Flutter/AOT — so the receive side uses
/// an explicit `Map<String, CommandHandler>` instead. The handler keys are the
/// same public method-name strings a remote proxy is built from
/// (`discovery.py:_get_public_method_names`), so the send and receive sides are
/// mirror images of one interface. At scale this map is a codegen target; the
/// manual registration here is exactly what generated code would emit.
///
/// See `docs/distributed-seam.html` §4.
library;

import '../codec/s_expression.dart';

/// A handler for one command. Receives the parsed positional [arguments]
/// (Strings / null / nested lists — the wire never carries typed values, so a
/// handler coerces with `int.parse` etc. at the use site, exactly as the
/// Python methods do). Returns a fully-formed reply payload (build it with
/// [generate]) or `null` for a fire-and-forget command.
typedef CommandHandler = String? Function(List<Object?> arguments);

/// Routes canonical S-expression payloads to handlers by command name.
///
/// Mirrors `actor.py:_topic_in_handler` + `Message.invoke`: it parses the
/// payload, dispatches by name, and — critically — turns an unknown command or
/// a throwing handler into a diagnostic reply rather than crashing the actor's
/// event loop.
class MessageDispatcher {
  final Map<String, CommandHandler> _handlers;

  MessageDispatcher(Map<String, CommandHandler> handlers)
      : _handlers = Map.unmodifiable(handlers);

  /// The command names this dispatcher answers — the receive-side mirror of a
  /// remote proxy's method list.
  Iterable<String> get commands => _handlers.keys;

  /// Parse [payload] and invoke the matching handler. Returns the handler's
  /// reply payload, or a diagnostic `(error ...)` payload for an unknown
  /// command or a handler that throws. Returns `null` when the handler chose
  /// not to reply.
  String? dispatch(String payload) {
    final (command, cdr) = parse(payload);
    // Positional args are the common case; a keyword-dict cdr is passed as a
    // single argument so handlers can destructure it.
    final arguments = cdr is List<Object?> ? cdr : <Object?>[cdr];

    final handler = _handlers[command];
    if (handler == null) {
      // Mirrors Message.invoke()'s "Function not found in: ..." diagnostic.
      return generate('error', ['Function not found: $command']);
    }
    try {
      return handler(arguments);
    } catch (exception) {
      // Python catches and logs so one bad message can't take down the loop.
      return generate('error', ['$command: $exception']);
    }
  }
}

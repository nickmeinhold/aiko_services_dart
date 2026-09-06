/// Routes decoded messages to handlers by MQTT topic.
///
/// This is the layer *above* `MessageDispatcher`, and the two are often
/// confused because both are called dispatch. `MessageDispatcher` looks inside
/// one payload and picks a handler by *command name*. This picks a handler by
/// the *topic the payload arrived on* — which is what a process needs the
/// moment it holds more than one subscription at a time, and an observer holds
/// several from its first second (the registrar's `/out`, its own share-in
/// topic, one more per producer it consumes).
///
/// Mirrors `process.py:211 add_message_handler()`, including the part that is
/// easy to miss: handlers are kept in a **list** per topic and appended without
/// a duplicate check, so registering twice delivers twice. That is not a
/// detail — it is the mechanism behind an ECProducer's snapshot arriving once
/// per producer in a service's inheritance chain (see `docs/notes/`).
library;

import 'dart:async';

import '../transport/mqtt_transport.dart';

/// Receives one decoded message on a subscribed topic.
typedef TopicHandler = void Function(AikoMessage message);

/// A topic-keyed handler registry over a [MessageBus].
class TopicRouter {
  TopicRouter(this._bus) {
    _subscription = _bus.messages.listen(_route);
  }

  final MessageBus _bus;
  late final StreamSubscription<AikoMessage> _subscription;
  final Map<String, List<TopicHandler>> _handlers = {};

  /// Registers [handler] for [topic], subscribing on first registration.
  ///
  /// Throws on a wildcard topic. Python keeps a separate wildcard list and
  /// matches those topics through a different path; this router does exact
  /// matching only, so accepting `+`/`#` here would register a handler that can
  /// never fire — a silent no-op is the worst of the three options.
  void addHandler(String topic, TopicHandler handler) {
    if (topic.contains('#') || topic.contains('+')) {
      throw ArgumentError.value(
        topic,
        'topic',
        'TopicRouter matches exact topics only; wildcard subscriptions are '
            'not routed here',
      );
    }
    final existing = _handlers[topic];
    if (existing == null) {
      _handlers[topic] = [handler];
      _bus.subscribe(topic);
    } else {
      existing.add(handler);
    }
  }

  /// Removes one registration of [handler] from [topic].
  ///
  /// Unsubscribes when the last handler for a topic goes. Removing a handler
  /// registered twice removes one of the two, matching `list.remove`.
  void removeHandler(String topic, TopicHandler handler) {
    final existing = _handlers[topic];
    if (existing == null) return;
    existing.remove(handler);
    if (existing.isEmpty) {
      _handlers.remove(topic);
      _bus.unsubscribe(topic);
    }
  }

  void _route(AikoMessage message) {
    // Iterate a copy: a handler may add or remove handlers for its own topic
    // while it runs — an ECConsumer's terminate() does exactly that.
    final handlers = _handlers[message.topic];
    if (handlers == null) return;
    for (final handler in List<TopicHandler>.of(handlers)) {
      handler(message);
    }
  }

  Future<void> dispose() => _subscription.cancel();
}

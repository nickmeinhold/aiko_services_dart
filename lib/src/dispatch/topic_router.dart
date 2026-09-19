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
import 'topic_filter.dart';

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

  /// The registered topics that are wildcard FILTERS rather than exact topics.
  final List<String> _filters = [];

  /// Registers [handler] for [topic], subscribing on first registration.
  ///
  /// [topic] may be a wildcard FILTER. This router used to refuse one, on the
  /// grounds that registering a handler which can never fire is worse than
  /// throwing — true at the time, because nothing matched them. The registrar
  /// is what changed: it subscribes `{ns}/+/+/+/state` to hear the Last Will of
  /// every process on the island, which is the only way a roster stays true
  /// when a service is KILLED rather than deregistered. Matching now exists
  /// (see [topicFilterMatches]), so the refusal has become the silent no-op it
  /// was guarding against.
  void addHandler(String topic, TopicHandler handler) {
    final existing = _handlers[topic];
    if (existing == null) {
      _handlers[topic] = [handler];
      // Held separately so the ordinary case stays a map lookup. Every message
      // would otherwise be walked against every registration.
      if (isTopicFilter(topic)) _filters.add(topic);
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
      // Upstream's equivalent is a real defect: `process.py:227-230` does
      // `del <list>[topic]` on a LIST with a string index — a TypeError — and
      // its first branch keys the wildcard delete off the BINARY dict. Latent
      // only because nothing ever removes a wildcard handler there.
      _filters.remove(topic);
      _bus.unsubscribe(topic);
    }
  }

  void _route(AikoMessage message) {
    // Iterate a copy: a handler may add or remove handlers for its own topic
    // while it runs — an ECConsumer's terminate() does exactly that.
    final handlers = <TopicHandler>[
      ...?_handlers[message.topic],
      // A topic can match an exact registration AND a filter at once, and both
      // owners want it: a registrar holding `{ns}/+/+/+/state` and something
      // else watching one specific process's state are asking different
      // questions about the same message. Upstream collects from every matched
      // topic for the same reason (`process.py:299-302`).
      for (final filter in List<String>.of(_filters))
        if (topicFilterMatches(filter, message.topic)) ...?_handlers[filter],
    ];
    for (final handler in handlers) {
      handler(message);
    }
  }

  Future<void> dispose() => _subscription.cancel();
}

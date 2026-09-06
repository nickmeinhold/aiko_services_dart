/// The producer -> consumer half of the share vocabulary.
///
/// Five cases (`share.py:465-502`), and deliberately NOT an extension of
/// `ShareCommand`. Three of the names collide — `add`, `update`, `remove` — and
/// mean different things in each direction: on `/control` they are requests a
/// producer may refuse, here they are facts a replica must accept. The other
/// two have no counterpart at all: `item_count` is a frame boundary rather than
/// an item, and `sync` carries nothing. One sealed type spanning both
/// directions would make the collision invisible.
library;

/// One message from an ECProducer to a subscribed consumer.
sealed class const ShareEvent();

/// `(item_count N)` — opens a snapshot frame of [count] items.
///
/// Not an item. It resets the received counter, which is what makes a repeated
/// snapshot idempotent rather than cumulative.
final class const ShareItemCount(final int count) extends ShareEvent {
  @override
  String toString() => 'ShareItemCount($count)';
}

/// `(add <name> <value>)` — an item appearing, snapshot or live.
final class const ShareItemAdded(final String path, final Object? value)
    extends ShareEvent {
  @override
  String toString() => 'ShareItemAdded($path, $value)';
}

/// `(update <name> <value>)` — an item changing.
final class const ShareItemUpdated(final String path, final Object? value)
    extends ShareEvent {
  @override
  String toString() => 'ShareItemUpdated($path, $value)';
}

/// `(remove <name>)` — an item going away.
final class const ShareItemRemoved(final String path) extends ShareEvent {
  @override
  String toString() => 'ShareItemRemoved($path)';
}

/// `(sync ...)` — a barrier the producer echoes back.
///
/// `share.py:497` passes it to handlers and stores nothing; the registrar uses
/// the same word on its own `/out` topic to mean "the snapshot you asked for is
/// complete" (`registrar.py:350`). Same name, different job — [ShareSync] is
/// only the ECProducer one.
final class const ShareSync() extends ShareEvent;

/// Classifies a parsed payload, or returns `null` if it is not share traffic.
///
/// `null` rather than a throw: a consumer's inbound topic is reachable by
/// anyone on an unauthenticated bus, so an unrecognised payload is an expected
/// input to drop, not an exceptional one. Python's `else` branch does the same
/// thing, one log line louder (`share.py:499-501`).
ShareEvent? classifyShareEvent(String command, List<Object?> parameters) {
  return switch ((command, parameters)) {
    ('item_count', [final String n]) when int.tryParse(n) != null =>
      ShareItemCount(int.parse(n)),
    ('add', [final String name, final value]) => ShareItemAdded(name, value),
    ('update', [final String name, final value]) => ShareItemUpdated(
      name,
      value,
    ),
    ('remove', [final String name]) => ShareItemRemoved(name),
    ('sync', _) => const ShareSync(),
    _ => null,
  };
}

/// Renders a decoded value back to something that READS LIKE the wire, for
/// display only — hence `debug`.
///
/// The name carries the warning because the doc alone did not: an earlier
/// `renderWireValue` claimed to produce a wire value while its own comment said
/// it must never be published.
///
/// The parser turns `((* general * * * ()) None None)` into nested Dart lists,
/// and `Object.toString` would print that as `[[*, general, ...], None, None]`
/// — Dart syntax for something an island wrote in Lisp syntax. A human
/// comparing our output against `mosquitto_sub` needs to see what was sent.
///
/// This is NOT `generate`: it omits length prefixes and quoting, so its output
/// must never be published. Use `generate` for anything that goes back out.
String debugRenderWireValue(Object? value) => switch (value) {
  final List<Object?> items => '(${items.map(debugRenderWireValue).join(' ')})',
  null => '0:',
  final other => '$other',
};

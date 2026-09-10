/// MQTT topic-filter matching, as the spec defines it (3.1.1 §4.7).
///
/// **This is a deliberate divergence from the reference, and the reason is that
/// the reference's version is not a matcher.** `process.py:408-424` compares
/// only the FIRST and LAST segments of a `+` filter and ignores both the depth
/// and everything between, so `aiko/+/+/+/state` locally matches
/// `aiko/a/state`, `aiko/a/b/c/d/e/state`, and anything else that starts with
/// the namespace and ends in `state`.
///
/// That is harmless upstream for a reason worth stating, because it is what
/// makes the divergence safe: **the BROKER does the real filtering.** A process
/// only ever sees topics its subscriptions brought in, and mosquitto matches
/// strictly. The local matcher is a second pass over already-filtered
/// messages, so a loose one can only ever MISROUTE between two wildcard
/// subscriptions held at once — never admit traffic the broker withheld.
///
/// Matching strictly therefore cannot drop anything a handler wanted: if no
/// filter matches a delivered topic under the spec's rules, no handler
/// subscribed to it. Recorded for Andy rather than reproduced.
library;

/// Whether [topic] matches the MQTT [filter].
///
/// [filter] may contain `+` (exactly one level) and `#` (this level and all
/// below, last segment only). An exact filter is just the degenerate case, so
/// callers do not need to ask which kind they hold.
bool topicFilterMatches(String filter, String topic) {
  if (filter == topic) return true;

  final filterLevels = filter.split('/');
  final topicLevels = topic.split('/');

  // `$SYS`-style topics are not reachable by a filter that STARTS with a
  // wildcard (§4.7.2). Without this, a `#` subscription silently enrols the
  // broker's own telemetry — which for a registrar means treating mosquitto's
  // internal tree as island traffic.
  if (topicLevels.isNotEmpty &&
      topicLevels.first.startsWith(r'$') &&
      (filterLevels.first == '+' || filterLevels.first == '#')) {
    return false;
  }

  for (var level = 0; level < filterLevels.length; level++) {
    final pattern = filterLevels[level];

    if (pattern == '#') {
      // `#` is only legal last, and it matches the PARENT level too: `a/#`
      // matches `a`. Anything after it is a malformed filter, which cannot
      // match rather than throwing — filters arrive from callers, not from the
      // wire, but a throw here would be a crash in a dispatch loop.
      return level == filterLevels.length - 1;
    }

    // Ran out of topic before running out of filter.
    if (level >= topicLevels.length) return false;

    // `+` matches exactly one level, INCLUDING an empty one: `a//b` has three
    // levels and `a/+/b` matches it. Treating empty as absent would silently
    // drop a legal topic.
    if (pattern == '+') continue;
    if (pattern != topicLevels[level]) return false;
  }

  // No `#` consumed the tail, so the depths must agree exactly. This is the
  // clause the reference does not have, and the one that stops
  // `aiko/+/+/+/state` from matching `aiko/a/state`.
  return filterLevels.length == topicLevels.length;
}

/// Whether [topic] contains a wildcard, and so must be matched rather than
/// looked up.
bool isTopicFilter(String topic) => topic.contains('+') || topic.contains('#');

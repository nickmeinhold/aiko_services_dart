/// One service as the registrar describes it.
///
/// Six fields, in wire order (`registrar.py:341-348`):
/// `(add <topic_path> <name> <protocol> <transport> <owner> (<tags>...))`.
/// The same six appear in a registrar share snapshot and in the live `(add ...)`
/// on the registrar's `/out` topic, so one type reads both.
library;

import 'service_topic_path.dart';

/// A service record from the registrar.
final class ServiceDetails {
  const ServiceDetails({
    required this.topicPath,
    required this.name,
    required this.protocol,
    required this.transport,
    required this.owner,
    required this.tags,
  });

  /// Reads the six positional parameters of an `(add ...)`.
  ///
  /// Returns `null` on any other shape rather than throwing: this arrives from
  /// a topic any peer can publish to (ADR-023's bus is unauthenticated), so a
  /// malformed record is an expected input to drop. The caller decides whether
  /// dropping it is worth a log line.
  static ServiceDetails? tryParse(List<Object?> parameters) {
    if (parameters.length != 6) return null;
    final [path, name, protocol, transport, owner, tags] = parameters;
    if (path is! String ||
        name is! String ||
        protocol is! String ||
        transport is! String ||
        owner is! String) {
      return null;
    }
    final ServiceTopicPath topicPath;
    try {
      topicPath = ServiceTopicPath.parse(path);
    } on FormatException {
      return null;
    }
    // An empty tag list parses as the empty list; a single tag still arrives
    // inside parentheses, so a bare String here is a malformed record. Partially
    // accepting one — keeping the strings and dropping the rest — is the wrong
    // posture for a parser whose every other arm fails closed, and `hasShare` is
    // read from these tags to decide whether to send a share request.
    if (tags is! List<Object?> || tags.any((t) => t is! String)) return null;
    final tagList = List<String>.unmodifiable(tags.cast<String>());

    return ServiceDetails(
      topicPath: topicPath,
      name: name,
      protocol: protocol,
      transport: transport,
      owner: owner,
      tags: tagList,
    );
  }

  final ServiceTopicPath topicPath;
  final String name;
  final String protocol;
  final String transport;
  final String owner;
  final List<String> tags;

  /// Whether this service runs an ECProducer, and so has a share to consume.
  ///
  /// `share.py:224` — every `ECProducerImpl` constructor calls
  /// `service.add_tags(["ec=true"])`. The dashboard gates on exactly this tag
  /// before attaching a consumer (`dashboard.py:406`), and so should anything
  /// else: sending `(share ...)` to a service without a producer gets silence,
  /// which is indistinguishable from a slow one.
  bool get hasShare => tags.contains('ec=true');

  @override
  String toString() =>
      'ServiceDetails($topicPath, $name, $protocol, $transport, $owner, $tags)';
}

/// What a filter requires of a service's tags.
///
/// Two shapes, because the wire has two and a single field cannot hold both:
/// the atom `*` and the sub-list `(…)`. A `List<String>` cannot express the
/// wildcard and a `String` cannot express the list, so this is a sealed pair
/// rather than either with a magic member.
///
/// They agree on every match OUTCOME — see [RequiredTags] — and still must
/// round-trip distinctly, because the Dart side will emit its own `(share …)`
/// and the bytes differ.
sealed class TagConstraint {
  const TagConstraint();
}

/// The wire's `*`: tags are not considered at all.
///
/// `registrar.py:452` gates the whole tag test on `filter.tags != "*"`, an
/// equality check against the string rather than a truthiness test.
final class AnyTags extends TagConstraint {
  const AnyTags();
}

/// The wire's `(tag …)`: every listed tag must be present.
///
/// Subset semantics by exact, case-sensitive, whole-string equality on each
/// `key=value` atom — `ServiceTags.match_tags` is
/// `all(tag in service_tags for tag in match_tags)` (`service.py:264-265`).
/// Extra tags on the service are fine; order and duplicates are irrelevant;
/// there is no key-only and no prefix matching, so `ec` and `ec=t` both fail
/// against `ec=true`.
///
/// **An EMPTY list matches every service, including a tagless one.** That is
/// not a degenerate case to special-case away: `[] != "*"` is true so the
/// reference ENTERS the tag branch, and `all([])` is `true`. The instinct to
/// write `if (required.isEmpty) return false` inverts the reference. `*` and
/// `()` reach the same answer by different code paths; only the bytes differ.
final class RequiredTags extends TagConstraint {
  /// Copies the list rather than aliasing it.
  ///
  /// Deliberately NOT `const`. A filter is a protocol value read off the wire
  /// and then consulted repeatedly; holding the caller's list means a later
  /// `add` on their side silently changes what this filter matches, from
  /// somewhere the filter cannot see. `ServiceDetails.tryParse` six inches
  /// away already copies for exactly this reason, and the inconsistency
  /// between them was the tell.
  ///
  /// The cost is that a `ServiceFilter` carrying required tags is not a
  /// constant. [AnyTags] stays `const`, so the common `const ServiceFilter()`
  /// is unaffected.
  RequiredTags(Iterable<String> required)
    : required = List<String>.unmodifiable(required);

  final List<String> required;
}

/// Selects services by attribute, with `*` meaning "any".
///
/// Matches the four scalar attributes the registrar filters on, plus tags.
/// (An earlier doc comment said "five scalar attributes" and that this ignores
/// tags; it matched four and the tag half was genuinely absent. The registrar's
/// `services_share` must honour whatever filter arrives, and `tags` is one of
/// the six wire parameters — so the call site that comment asked for now
/// exists.)
///
/// Still narrower than upstream in one way: `topic_paths` filtering
/// (`service.py:471 filter_by_topic_paths`) is not modelled, because nothing
/// sends it.
final class ServiceFilter {
  const ServiceFilter({
    this.name = anyValue,
    this.protocol = anyValue,
    this.transport = anyValue,
    this.owner = anyValue,
    this.tags = const AnyTags(),
  });

  /// The wire's "any" — `registrar.py:331 services_share()` takes five of these.
  /// Named because it appears in three places here and in every share request;
  /// a bare `'*'` is a protocol token wearing a string literal's clothes.
  static const anyValue = '*';

  final String name;
  final String protocol;
  final String transport;
  final String owner;
  final TagConstraint tags;

  bool matches(ServiceDetails service) =>
      _match(name, service.name) &&
      _match(protocol, service.protocol) &&
      _match(transport, service.transport) &&
      _match(owner, service.owner) &&
      _matchTags(service.tags);

  static bool _match(String pattern, String value) =>
      pattern == anyValue || pattern == value;

  bool _matchTags(List<String> serviceTags) => switch (tags) {
    AnyTags() => true,
    // `every` on an empty iterable is `true`, which is exactly Python's
    // `all([])`. Deliberately not special-cased — see [RequiredTags].
    RequiredTags(:final required) => required.every(serviceTags.contains),
  };

  /// Reads the tag slot of a wire filter.
  ///
  /// The codec hands us `Object?` there: the atom `'*'`, or a sub-list which is
  /// a `List<Object?>` (`()` decodes to an empty one). Anything else is
  /// malformed and is refused rather than coerced.
  ///
  /// The reference does NOT refuse a bare atom here — `"ec=true" != "*"` sends
  /// it into `match_tags`, which then iterates the STRING and tests each
  /// CHARACTER for membership. No conformant sender can produce that, and
  /// reproducing it would be copying a defect rather than matching a protocol.
  /// Recorded as a deliberate receive-side divergence.
  static TagConstraint? tryParseTags(Object? wire) {
    if (wire == anyValue) return const AnyTags();
    if (wire is! List<Object?>) return null;
    if (wire.any((t) => t is! String)) return null;
    return RequiredTags(List<String>.unmodifiable(wire.cast<String>()));
  }
}

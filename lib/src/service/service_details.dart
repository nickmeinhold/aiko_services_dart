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

/// Selects services by attribute, with `*` meaning "any".
///
/// A deliberate subset of `ServiceFilter` upstream: this matches the five
/// scalar attributes and ignores tags. It exists to answer "which service is
/// the ChatServer", and widening it without a call site that needs the width
/// would be inventing protocol.
final class ServiceFilter {
  const ServiceFilter({
    this.name = '*',
    this.protocol = '*',
    this.transport = '*',
    this.owner = '*',
  });

  final String name;
  final String protocol;
  final String transport;
  final String owner;

  bool matches(ServiceDetails service) =>
      _match(name, service.name) &&
      _match(protocol, service.protocol) &&
      _match(transport, service.transport) &&
      _match(owner, service.owner);

  static bool _match(String pattern, String value) =>
      pattern == '*' || pattern == value;
}

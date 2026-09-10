/// A service's address on the bus, and the four topics derived from it.
///
/// The wire form is `{namespace}/{host}/{process_id}/{service_id}` — four
/// segments, built locally by every process (`process.py`) and never assigned
/// by the registrar. It arrives as a bare String in three different payloads
/// (the retained `(primary found ...)` announcement, each `(add ...)` in a
/// registrar share, and every `topic_path` field of a service record), and
/// every consumer of those payloads immediately wants one of the four derived
/// topics. Parsing once, here, is what stops `'$topicPath/control'` being
/// spelled out at each call site.
library;

/// The address of one service, and the topics that hang off it.
final class ServiceTopicPath {
  const ServiceTopicPath(
    this.namespace,
    this.host,
    this.processId,
    this.serviceId,
  );

  /// Parses the four-segment wire form.
  ///
  /// Throws [FormatException] on any other shape. The registrar's own
  /// announcement is attacker-reachable on an unauthenticated bus (ADR-023),
  /// so a malformed path must fail loudly at the boundary rather than compose
  /// into a subscription to something unintended.
  factory ServiceTopicPath.parse(String wire) {
    final parts = wire.split('/');
    if (parts.length != 4 || parts.any((p) => p.isEmpty)) {
      throw FormatException(
        'a service topic path is namespace/host/process_id/service_id, '
        'got "$wire"',
      );
    }
    // `+` and `#` are MQTT subscription wildcards, not name characters. A path
    // carrying one is not merely odd — it changes what a derived topic MEANS:
    // `aiko/+/1/1` composes to a subscription matching every host's `/out`. This
    // value arrives from the registrar's retained announcement and from service
    // records, both world-writable on ADR-023's unauthenticated bus. The comment
    // above already promised a malformed path fails before it can compose into a
    // subscription to something unintended; without this it only promised it.
    if (parts.any((p) => p.contains('+') || p.contains('#'))) {
      throw FormatException(
        'a service topic path may not contain the MQTT wildcards + or #, '
        'got "$wire"',
      );
    }
    return ServiceTopicPath(parts[0], parts[1], parts[2], parts[3]);
  }

  final String namespace;
  final String host;
  final String processId;
  final String serviceId;

  /// The path itself — what appears in a payload field.
  String get path => '$namespace/$host/$processId/$serviceId';

  /// The owning process, without the service id (`service.py:350`).
  ///
  /// A process, not a service, is the unit that dies: the Last Will and
  /// Testament is published on this process's `0` path, and the registrar
  /// answers it by removing *every* service belonging to the process
  /// (`registrar.py:381-386`). So a roster needs to look services up by
  /// process, not only by their own path.
  String get processPath => '$namespace/$host/$processId';

  /// Whether this path addresses the process itself rather than one of its
  /// services.
  ///
  /// Service id `0` is the process (`registrar.py:381`, `# Process
  /// terminated`). Named because the reference spells the comparison inline
  /// against a bare `"0"`, and the same magic value decides two unrelated
  /// things: which `/state` topic carries the process LWT, and whether a
  /// `(remove ...)` means one service or all of them.
  bool get isProcess => serviceId == '0';

  /// Commands addressed to this service (`actor.py:_topic_in_handler`).
  String get topicIn => '$path/in';

  /// This service's outbound announcements.
  String get topicOut => '$path/out';

  /// An ECProducer's request topic — where `(share ...)` is sent
  /// (`share.py:218`, `topic_in if topic_in else service.topic_control`).
  String get topicControl => '$path/control';

  /// An ECProducer's broadcast topic for state changes.
  String get topicState => '$path/state';

  @override
  String toString() => path;

  @override
  bool operator ==(Object other) =>
      other is ServiceTopicPath && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

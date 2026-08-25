/// The eventually-consistent `share` tree (ADR-0001 D5).
///
/// One canonical wire-shaped tree is the single source of truth; typed access
/// is a facade over it, never a second store. The shape is inherited, not
/// chosen: `share.py::_ec_parse_item_path()` splits on `.` and raises
/// `EC "share" dictionary depth maximum is 2`, so this is a depth-2 tree
/// addressed by dotted paths — `(update metrics.running 3)`.
library;

import 'dart:async';

/// Framework-reserved top-level keys. `lifecycle` is live cross-service wire
/// vocabulary — `pipeline.py:287` reads *another element's*, `:949`/`:1032`
/// branch on it, and the subscription form `(share <topic> <lease> (lifecycle x))`
/// names it in the protocol. Applications may not write these.
const reservedShareKeys = {'lifecycle', 'log_level', 'running'};

const _logLevels = {'DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'};

sealed class ShareError {
  const ShareError(this.path);
  final String path;
}

final class ReservedKeyError extends ShareError implements Exception {
  const ReservedKeyError(super.path);
  @override
  String toString() => 'ReservedKeyError: "$path" is framework-reserved';
}

final class InvalidFrameworkValueError extends ShareError {
  const InvalidFrameworkValueError(super.path, this.rejected);
  final Object? rejected;
  @override
  String toString() =>
      'InvalidFrameworkValueError: "$path" rejected $rejected; previous value retained';
}

final class ShareDepthError extends ShareError {
  const ShareDepthError(super.path);
  @override
  String toString() => 'ShareDepthError: "$path" exceeds the inherited depth maximum of 2';
}

final class ShareMissingPathError extends ShareError {
  const ShareMissingPathError(super.path);
  @override
  String toString() => 'ShareMissingPathError: "$path" has no intermediate node';
}

/// A `/control` mutation, in the three forms the wire carries.
sealed class ShareCommand {
  const ShareCommand(this.path);
  final String path;
}

final class ShareUpdate extends ShareCommand {
  const ShareUpdate(super.path, this.value);
  final Object? value;
}

final class ShareAdd extends ShareCommand {
  const ShareAdd(super.path, this.value);
  final Object? value;
}

final class ShareRemove extends ShareCommand {
  const ShareRemove(super.path);
}

/// Whether this tree is our own state or a mirror of a peer's.
///
/// The distinction is load-bearing and was a round-2 finding: there is a tree
/// per consumed topic, and one mutator law does not fit both. Rejecting a
/// producer's value on a replica would make us diverge from the mesh we exist
/// to converge with, while `pipeline.py:287` still reads whatever the peer
/// actually stored.
enum ShareRole { own, replica }

class Share {
  Share._(this.role, this.producerTopic);

  factory Share.own() => Share._(ShareRole.own, null);
  factory Share.replicaOf(String producerTopic) =>
      Share._(ShareRole.replica, producerTopic);

  final ShareRole role;
  final String? producerTopic;

  final Map<String, Object?> _tree = <String, Object?>{};
  final StreamController<ShareError> _errors =
      StreamController<ShareError>.broadcast();

  /// Rejections and dropped writes. Nothing here is silent — `dir-id 3f6b`.
  Stream<ShareError> get errors => _errors.stream;

  void dispose() => _errors.close();

  void _report(ShareError e) {
    if (!_errors.isClosed) _errors.add(e);
  }

  static List<String> _split(String path) => path.split('.');

  /// Reads a value by dotted path. Nested maps come back as **copies** — handing
  /// out the live map would create a dual writer by alias, bypassing the
  /// mutator, the reserved-key check and the notification.
  Object? read(String path) {
    final parts = _split(path);
    if (parts.length > 2) return null;
    final head = _tree[parts.first];
    if (parts.length == 1) return _defensive(head);
    if (head is! Map<String, Object?>) return null;
    return _defensive(head[parts[1]]);
  }

  static Object? _defensive(Object? v) =>
      v is Map<String, Object?> ? Map<String, Object?>.unmodifiable(v) : v;

  /// An application write. Reserved keys throw *and* report: the caller is
  /// present to be told, and the rejection is observable.
  void setApp(String path, Object? value) {
    final head = _split(path).first;
    if (reservedShareKeys.contains(head)) {
      final e = ReservedKeyError(path);
      _report(e);
      throw e;
    }
    _write(path, value, validate: false);
  }

  /// A framework write, through the privileged mutator.
  void setFramework(String path, Object? value) =>
      _write(path, value, validate: false);

  /// Applies an inbound `/control` command from the wire.
  void applyInbound(ShareCommand command) {
    switch (command) {
      case ShareRemove():
        final head = _split(command.path).first;
        if (role == ShareRole.own && reservedShareKeys.contains(head)) {
          _report(ReservedKeyError(command.path));
          return;
        }
        _remove(command.path);
      case ShareUpdate(:final value):
        _write(command.path, value, validate: true);
      case ShareAdd(:final value):
        _write(command.path, value, validate: true);
    }
  }

  void _write(String path, Object? value, {required bool validate}) {
    final parts = _split(path);
    if (parts.length > 2) {
      _report(ShareDepthError(path));
      return;
    }

    if (validate && reservedShareKeys.contains(parts.first) && parts.length == 1) {
      if (!_valid(parts.first, value)) {
        // Both roles report. Only `own` refuses: a replica must mirror its
        // producer or it diverges from the mesh.
        _report(InvalidFrameworkValueError(path, value));
        if (role == ShareRole.own) return;
      }
    }

    if (parts.length == 1) {
      _tree[parts.first] = value;
      return;
    }

    final head = _tree[parts.first];
    if (head is! Map<String, Object?>) {
      // Conform: `_ec_modify_item(create_path: False)` does not vivify. Diverge
      // only on observability — the reference drops this silently.
      _report(ShareMissingPathError(path));
      return;
    }
    head[parts[1]] = value;
  }

  void _remove(String path) {
    final parts = _split(path);
    if (parts.length > 2) {
      _report(ShareDepthError(path));
      return;
    }
    if (parts.length == 1) {
      _tree.remove(parts.first);
      return;
    }
    final head = _tree[parts.first];
    if (head is! Map<String, Object?>) {
      _report(ShareMissingPathError(path));
      return;
    }
    head.remove(parts[1]);
  }

  static bool _valid(String key, Object? value) => switch (key) {
        'log_level' => value is String && _logLevels.contains(value),
        'running' => value is bool,
        // `lifecycle` is deliberately open: Python may introduce a state we have
        // not enumerated, and a closed set would make us blind to something it
        // branches on. ServiceState carries the `unknown` case for the same reason.
        'lifecycle' => value is String,
        _ => true,
      };

  /// Seeds a nested node. Only the framework may create intermediate levels.
  void seedNode(String key) => _tree[key] = <String, Object?>{};

  Map<String, Object?> snapshot() => Map<String, Object?>.unmodifiable({
        for (final e in _tree.entries)
          e.key: e.value is Map<String, Object?>
              ? Map<String, Object?>.unmodifiable(e.value! as Map<String, Object?>)
              : e.value,
      });
}

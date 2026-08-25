/// Aiko Services — Dart port of Andy Gelme's (geekscape) distributed actor
/// framework. Early design phase; see `docs/` for the mapping notes.
library;

export 'src/codec/s_expression.dart';
export 'src/dispatch/message_dispatcher.dart';
export 'src/transport/mqtt_transport.dart';

/// Service state (ADR-0001 D5) — the eventually-consistent share tree.
export 'src/service/share.dart';

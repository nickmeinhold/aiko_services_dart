/// Aiko Services — Dart port of Andy Gelme's (geekscape) distributed actor
/// framework. Early design phase; see `docs/` for the mapping notes.
library;

export 'src/codec/s_expression.dart';
export 'src/dispatch/message_dispatcher.dart';
export 'src/transport/mqtt_transport.dart';

/// Service state (ADR-0001 D5) — the eventually-consistent share tree.
export 'src/service/share.dart';

/// The runtime an observer needs: an identity, a connection ladder, discovery
/// through the registrar, and a replica of a remote producer's share.
export 'src/dispatch/topic_router.dart';
export 'src/service/bus_process.dart';
export 'src/service/connection_state.dart';
export 'src/service/service_details.dart';
export 'src/service/service_topic_path.dart';
export 'src/service/services_cache.dart';
export 'src/share/ec_consumer.dart';
export 'src/share/share_event.dart';

/// A leased, filtered replica of one remote ECProducer's share.
///
/// Wire form, from `share.py:414-421` and the handler at `:465-502`: publish
/// `(share <topic_share_in> <lease_time> <filter>)` to the producer's control
/// topic, then receive `(item_count N)`, N × `(add name value)`, and thereafter
/// `(update ...)` / `(remove ...)` / `(sync)` as the producer's state moves.
///
/// The replica is a [Share] in [ShareRole.replica], so the producer's values
/// are mirrored rather than validated — a consumer that refused a value would
/// diverge from the mesh it exists to converge with.
library;

import 'dart:async';

import '../service/service_topic_path.dart';
import '../service/share.dart';
import '../transport/mqtt_transport.dart';
import '../dispatch/topic_router.dart';
import 'share_event.dart';

/// Whether this replica has received a complete snapshot yet.
enum CacheState {
  /// No snapshot frame has completed. A read here is not an answer.
  empty,

  /// `items_received == item_count` — the snapshot landed.
  ready,
}

/// `share.py:114`, `_LEASE_TIME = 300`.
const defaultLeaseTime = Duration(seconds: 300);

/// `lease.py:39`, `_LEASE_EXTEND_TIME_FACTOR = 0.8` — a lease is renewed at 80%
/// of its life, not at its end, so a renewal may be lost without expiring it.
const _leaseExtendFactor = 0.8;

/// Replicates one remote ECProducer's share into a local [Share].
class ECConsumer {
  /// The `router` and `bus` are the process-wide bus infrastructure and are
  /// positional because they are not this consumer's configuration — everything
  /// that describes *this* subscription is named below.
  ECConsumer(
    this._router,
    this._bus, {
    required ServiceTopicPath consumerPath,
    required this.consumerId,
    required this.producerControlTopic,
    this.filter = '*',
    this.leaseTime = defaultLeaseTime,
  }) : // `share.py:455`, verbatim: the consumer's inbound topic embeds the
       // WHOLE producer control topic, slashes and all, inside its own path.
       // The result is long and looks like a mistake; it is the wire, and it is
       // what makes two consumers of different producers land on different
       // topics without needing a broker-side allocator.
       topicShareIn =
           '${consumerPath.path}/$producerControlTopic/$consumerId/in',
       replica = Share.replicaOf(producerControlTopic) {
    // A non-positive lease would make `Timer.periodic` fire every event-loop
    // turn, republishing to a REMOTE service's control topic without pause — an
    // accidental flood from a class whose whole premise is being pointed at
    // somebody else's island. It is also self-contradictory: zero is the CANCEL
    // form (`terminate()` sends exactly that), so a zero lease would construct a
    // consumer that continuously cancels a subscription it never took.
    // Whole SECONDS, because that is the unit the wire carries: `_requestShare`
    // publishes `lease.inSeconds`, so any sub-second duration passes a
    // greater-than-zero check and then goes out as `0` — the CANCEL form, on a
    // repeating timer. The 300s default hides it; the type does not.
    if (leaseTime.inSeconds < 1) {
      throw ArgumentError.value(
        leaseTime,
        'leaseTime',
        'must be at least one whole second; the wire carries lease time in '
            'seconds, and zero is the cancellation form, not a lease',
      );
    }
  }

  final TopicRouter _router;
  final MessageBus _bus;

  /// This consumer's id, unique within this process per producer.
  final Object consumerId;

  /// `{producer topic_path}/control` — where the share request is sent.
  final String producerControlTopic;

  /// `*` for everything, or an item-name prefix. The wire filter matches on
  /// NAME only — `share.py:296 _filter_compare()` receives `item_name` and
  /// never `item_value`.
  final String filter;

  final Duration leaseTime;

  /// Where the producer's replies arrive.
  final String topicShareIn;

  /// The mirrored state.
  final Share replica;

  final _events = StreamController<ShareEvent>.broadcast();
  Timer? _leaseTimer;
  int _itemCount = 0;
  int _itemsReceived = 0;
  final Map<String, Object?> _frame = {};

  /// Whether a snapshot frame is open.
  ///
  /// Explicit, because it cannot be INFERRED from the counters. `add` means
  /// "snapshot or live" on the wire, and a version of this class that inferred
  /// frame membership from `_itemsReceived == _itemCount` silently dropped every
  /// live add after the snapshot: the counter went one past the target, the
  /// equality never held again, and the item never left the staging map. The
  /// replica went on being reported as current while the island moved on.
  bool _inFrame = false;
  CacheState _cacheState = CacheState.empty;
  bool _attached = false;
  bool _terminated = false;

  /// Every classified event, in arrival order. A caller that only wants the
  /// settled state should read [replica] once [cacheState] is ready instead.
  Stream<ShareEvent> get events => _events.stream;

  CacheState get cacheState => _cacheState;

  /// Subscribes and sends the share request.
  ///
  /// The caller sequences this rather than a connection-state handler doing it
  /// (Python wires `aiko.connection.add_handler` in the constructor). The
  /// reason is the same one the gateway acts on: a producer's topic path
  /// changes when its process restarts, so the useful lifetime of a consumer is
  /// one producer INSTANCE, not one connection. Rebinding is a new consumer,
  /// which makes the reset total instead of partial.
  void attach() {
    if (_attached) return;
    if (_terminated) {
      // A terminated consumer has closed its event stream, so re-attaching
      // would subscribe, mirror, and emit nothing — working perfectly and
      // reporting silence. One producer instance, one consumer: build a new
      // one, which is what a rebind means anyway.
      throw StateError(
        'ECConsumer.attach() after terminate(); construct a new consumer for '
        'the new producer instance',
      );
    }
    _attached = true;
    _router.addHandler(topicShareIn, _onMessage);
    _requestShare(leaseTime);
    final extendAfter = Duration(
      microseconds: (leaseTime.inMicroseconds * _leaseExtendFactor).round(),
    );
    _leaseTimer = Timer.periodic(extendAfter, (_) => _requestShare(leaseTime));
  }

  /// Replaces the replica with the frame just received, and marks it ready.
  void _commitFrame() {
    replica.clear();
    for (final entry in _frame.entries) {
      replica.applyInbound(ShareAdd(entry.key, entry.value));
    }
    _frame.clear();
    _inFrame = false;
    _cacheState = CacheState.ready;
  }

  void _requestShare(Duration lease) => _bus.send(
    producerControlTopic,
    'share',
    <Object?>[topicShareIn, '${lease.inSeconds}', filter],
  );

  void _onMessage(AikoMessage message) {
    // Only positional arguments occur here; a keyword map on this topic is not
    // share traffic and falls through to the null case below.
    final parameters = switch (message.arguments) {
      PositionalArguments(:final values) => values,
      KeywordArguments() => const <Object?>[],
    };
    final event = classifyShareEvent(message.command, parameters);
    if (event == null) return;

    switch (event) {
      // A snapshot is the producer's FULL state for this filter, so it has to
      // REPLACE the replica rather than merge into it. Merging is not
      // hypothetical here: this port measured one `(share …)` request drawing
      // three complete snapshots from a HyperSpace service, and every lease
      // renewal draws another. A key that vanished between bursts — or a
      // `(remove …)` lost to QoS 0 — would otherwise survive as fact forever.
      //
      // Staged rather than cleared-in-place: clearing on frame OPEN would make
      // the replica flap empty and full on every renewal, so a reader could
      // catch it mid-frame holding nothing. The old state stays readable until
      // the new one is complete, then swaps.
      case ShareItemCount(:final count):
        // A frame boundary, and the reason a repeated snapshot is idempotent
        // rather than cumulative: the counter resets, so the second burst
        // simply re-arrives at ready. That is not hypothetical — a service
        // whose class chain constructs more than one ECProducer answers one
        // request once per producer (measured; see docs/notes/).
        _itemCount = count;
        _itemsReceived = 0;
        _frame.clear();
        _inFrame = true;
        // Zero equals zero immediately. The reference checks completion only
        // inside its `add` arm (`share.py:479-480`), so an empty filtered share
        // never becomes ready there either — but `cacheState` is a LOCAL
        // accessor, not a wire behaviour, and reproducing a gap no peer can
        // observe is copying, not parity. A filter that legitimately matches
        // nothing must be distinguishable from a producer that never answered.
        if (count == 0) {
          _commitFrame();
        } else {
          _cacheState = CacheState.empty;
        }
      case ShareItemAdded(:final path, :final value):
        if (_inFrame) {
          _frame[path] = value;
          _itemsReceived++;
          if (_itemsReceived == _itemCount) _commitFrame();
        } else {
          // A live add — an item that appeared on the producer after its
          // snapshot. It is a delta, not part of any frame, so it goes straight
          // to the replica and leaves the cache state alone.
          replica.applyInbound(ShareAdd(path, value));
        }
      case ShareItemUpdated(:final path, :final value):
        replica.applyInbound(ShareUpdate(path, value));
      case ShareItemRemoved(:final path):
        replica.applyInbound(ShareRemove(path));
      case ShareSync():
        break;
    }
    if (!_events.isClosed) _events.add(event);
  }

  /// Cancels the lease and the subscription, and empties the replica.
  ///
  /// The final `(share <topic> 0 <filter>)` is a cancellation, not a request:
  /// `share.py:539` sends `lease_time=0` for exactly this. Skipping it leaves
  /// the producer publishing updates to a topic nobody reads until the lease
  /// runs out — which is the difference between a clean `leave` and a quiet
  /// one, and `leave` is a verb this port owes evidence for.
  Future<void> terminate() async {
    if (!_attached) return;
    _attached = false;
    _terminated = true;
    _leaseTimer?.cancel();
    _leaseTimer = null;
    _requestShare(Duration.zero);
    _router.removeHandler(topicShareIn, _onMessage);
    // `share.py:534`, `self.cache = {}`. This was a straight divergence: the doc
    // comment above already promised it and the code did not do it, so a caller
    // holding the consumer after termination could read a full replica through
    // an `empty` cache state.
    replica.clear();
    _frame.clear();
    _inFrame = false;
    _cacheState = CacheState.empty;
    _itemCount = 0;
    _itemsReceived = 0;
    await _events.close();
  }
}

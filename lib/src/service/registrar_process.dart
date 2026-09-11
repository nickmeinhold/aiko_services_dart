/// The primary election, RUNNING — on a real bus, against a real island.
///
/// [RegistrarElection] is a pure state machine: inputs in, effects out, no I/O.
/// It has been merged, unit-tested and green since PR #23 with **zero
/// production callers**. This is the driver that gives it a wire, and building
/// it is what turned up why nobody had: of the five effects the election emits,
/// two could not be performed by the transport at all.
///
/// * [AnnouncePrimary] needs a RETAINED publish — `MessageBus.send` had no
///   `retain`, so every publish this port could make was `retain: false`.
/// * clearing the boot topic needs an EMPTY retained publish — `send` runs
///   `generate`, and no command name encodes to zero bytes.
/// * and promotion changes the will, which MQTT permits only in a CONNECT
///   packet, so it needs a reconnect that does not deafen the process.
///
/// All three landed alongside this file. The gap was never laziness; the
/// composition was blocked on affordances an observer had never needed.
///
/// **What this does NOT do yet.** It elects, announces, and retracts. It does
/// not accept registrations on `/in`, hold a roster, serve `(share ...)`, or
/// consume the island's `{ns}/+/+/+/state` wills. Those are verbs 2, 3 and 4 of
/// the scope note's capability invariant and they are the next increment. The
/// two effects with nowhere to go — [PublishLifecycle] and [DropRoster] — are
/// surfaced on streams rather than performed or dropped, so that the unfinished
/// half is VISIBLE instead of looking like a decision.
library;

import 'dart:async';

import '../dispatch/topic_router.dart';
import '../time/create_timer.dart';
import '../transport/mqtt_transport.dart';
import 'bus_process.dart' show registrarBootTopic;
import 'process_identity.dart';
import 'registrar_election.dart';
import 'service_topic_path.dart';

/// `main/__init__.py:15`, `REGISTRAR_VERSION = 2`. Published as parameter 2 of
/// the announcement, where `process.py:335` reads it into `registrar["version"]`
/// and — measured, not assumed — never compares it to anything.
const registrarVersion = 2;

/// A process that runs the registrar's primary election against a live bus.
class RegistrarProcess {
  /// Resolve this process's identity, then build the parts around it.
  ///
  /// A factory because the bus needs the process path in its will, and the
  /// process path is not available in an initializer list that is still
  /// computing it.
  factory RegistrarProcess({
    String namespace = 'aiko',
    String? host,
    int? processId,
    String serviceId = '1',
    String brokerHost = 'localhost',
    int brokerPort = 1883,
    MessageBus? bus,
    Duration searchTimeout = RegistrarElection.defaultSearchTimeout,
    CreateTimer createTimer = Timer.new,
  }) {
    // Service `0` is the PROCESS; the registrar is a service that process
    // hosts, and upstream's own announcement names a service path — the live
    // island publishes `aiko/{host}/{pid}/1`, not `/0`.
    final topicPath = ServiceTopicPath(
      namespace,
      processHostSegment(host),
      '${processId ?? currentProcessId}',
      serviceId,
    );
    return RegistrarProcess._(
      topicPath: topicPath,
      bus:
          bus ??
          AikoClient(
            host: brokerHost,
            port: brokerPort,
            // The PER-PROCESS will, which every Aiko process carries from its
            // first connection (`process.py:169`). Promotion swaps it for the
            // retained `(primary absent)`; see [_perform].
            will: LastWill.processAbsent(topicPath.processPath),
          ),
      election: RegistrarElection(searchTimeout: searchTimeout),
      createTimer: createTimer,
    );
  }

  // The underscore in the parameter name is invisible: this constructor is
  // private, so there is no public API for it to leak into.
  RegistrarProcess._({
    required this.topicPath,
    required this.bus,
    required this._election,
    required this._createTimer,
  });

  /// How the search timer is made. See [CreateTimer] for why this is a seam.
  final CreateTimer _createTimer;


  /// This registrar's service address, as published in the announcement.
  final ServiceTopicPath topicPath;

  final MessageBus bus;

  final RegistrarElection _election;

  late final TopicRouter router = TopicRouter(bus);

  String get namespace => topicPath.namespace;

  /// `process.py:91`, `TOPIC_REGISTRAR_BOOT` — the one retained topic in Aiko.
  String get bootTopic => registrarBootTopic(namespace);

  /// The will a PRIMARY holds: retained, so a late joiner learns the registrar
  /// is gone without having to ask anyone who is no longer there to answer.
  ///
  /// **NOTHING EVER GIVES THIS BACK, and that is upstream's behaviour too.**
  /// `set_last_will_and_testament` appears exactly once in `registrar.py`
  /// (`:189`, inside `on_enter_primary`); the state machine has no
  /// `on_exit_primary` and no relinquish path. So a process that was primary
  /// and has since been demoted — stood down to `secondary`, or knocked back to
  /// `primary_search` by a `(primary absent)` — is STILL holding a retained
  /// `(primary absent)` aimed at the boot topic.
  ///
  /// The failure that makes this worth a paragraph: once a DIFFERENT registrar
  /// has legitimately announced itself, an unclean death of this demoted
  /// process makes the broker publish our stale tombstone over the top of a
  /// healthy `(primary found …)`. The island is then told it has no primary
  /// while one is running and answering — a false absence, from a process that
  /// has not been primary for hours.
  ///
  /// Found by Carnot in the cage-match on PR #24, and verified against the
  /// reference rather than assumed. Reproduced faithfully and filed for Andy
  /// rather than fixed unilaterally: relinquishing costs another reconnect and
  /// is a state-machine change, so it is a decision, not a patch.
  LastWill get primaryWill =>
      LastWill(topic: bootTopic, payload: '(primary absent)', retain: true);

  /// Where this process sits in the election.
  RegistrarRole get role => _election.role;

  /// Every role entered, in order.
  ///
  /// Upstream publishes each one into the registrar's own EC share as
  /// `lifecycle` (`registrar.py:163,179,183`), which is how a dashboard watches
  /// an election happen. This port has no share PRODUCER yet, so the effect is
  /// surfaced rather than performed — a stream nobody reads is visibly
  /// unfinished, where a dropped effect would look like a decision.
  Stream<RegistrarRole> get lifecycle => _lifecycle.stream;

  /// Fires when the election says to forget every service we know.
  ///
  /// `registrar.py:281`. There is no roster in this port yet, so there is
  /// nothing to drop; the signal is surfaced so that the roster, when it
  /// arrives, has an obvious place to listen rather than a re-derivation.
  Stream<void> get rosterDrops => _rosterDrops.stream;

  /// Fires once the retained announcement is ON THE WIRE, carrying the address
  /// it named.
  ///
  /// **Distinct from [role] reaching primary, and the split is forced by the
  /// port rather than chosen.** Upstream's `on_enter_primary` is a single
  /// synchronous handler: its first line updates `lifecycle` and its last line
  /// publishes, so by the time any Python peer can observe
  /// `lifecycle == "primary"` the announcement has already gone out. Ours
  /// cannot work that way — taking the retained will means RECONNECTING, and a
  /// reconnect is an await — so [role] reaches primary while the island has not
  /// yet been told, and stays that way for as long as a socket takes.
  ///
  /// This was found by a probe killing itself on `role == primary` and catching
  /// a broker that had received the empty boot-topic clear and nothing else. A
  /// caller keying on the role reports a registrar that is not yet
  /// discoverable; there is no such window upstream, so there is no upstream
  /// signal to port. Hence a new one, named for what it actually witnesses.
  Stream<ServiceTopicPath> get announcements => _announcements.stream;

  /// A promotion that could not be completed, after the election has been stood
  /// back down. See [RegistrarElection.onPrimaryFailed].
  Stream<Object> get promotionFailures => _promotionFailures.stream;

  /// How long the retained announcement took to reach us after we subscribed,
  /// or null if none arrived before we stopped searching.
  ///
  /// **This is a measurement, not bookkeeping.** Promotion races delivery: a
  /// retained `(primary found ...)` that arrives after the 2-second search
  /// timeout puts a SECOND primary on an island that already has one, both
  /// holding a retained announcement on the same topic. Upstream has the same
  /// 2 seconds and the same race. Nobody has ever measured the margin, so the
  /// driver publishes it and the live probe prints it.
  Duration? get announcementLatency => _announcementLatency;

  /// `time_started`, parameter 3 of the announcement — and a DELIBERATE
  /// divergence from the reference, recorded here rather than smoothed over.
  ///
  /// Upstream sends `time.monotonic()` sampled when the service started
  /// (`service.py:564`). CPython documents that clock's origin as *undefined*;
  /// on Linux it happens to be boot. Dart cannot read that clock, so exact
  /// parity is not available at any price — the only question is which way to
  /// be wrong.
  ///
  /// A `Stopwatch` would give the same KIND of quantity but reset to ~0 on
  /// every restart, making a fresh registrar look like the OLDEST process on
  /// the island. That matters because `registrar.py:166` carries a TODO to
  /// promote *"the oldest known secondary"* — under which a Dart registrar
  /// resetting to zero would win every election it entered, forever.
  ///
  /// Wall-clock seconds since the Unix epoch is a different SCALE from
  /// upstream's (1.7e9 against 8.3e5) and cannot be compared with it, but it
  /// rises across restarts, is stable across hosts, matches what the field is
  /// NAMED, and fails SAFE against that TODO: a Dart registrar always looks
  /// newest and therefore always defers. Nothing in `process.py` compares this
  /// field today — checked, at `:332-337`, where it is stored and never read.
  /// Filed for Andy as a finding rather than resolved unilaterally.
  final String timeStarted = (DateTime.now().microsecondsSinceEpoch / 1e6)
      .toStringAsFixed(6);

  final _lifecycle = StreamController<RegistrarRole>.broadcast();
  final _rosterDrops = StreamController<void>.broadcast();
  final _announcements = StreamController<ServiceTopicPath>.broadcast();
  final _promotionFailures = StreamController<Object>.broadcast();

  final Stopwatch _clock = Stopwatch();
  Duration? _subscribedAt;
  Duration? _announcementLatency;

  Timer? _timer;

  /// Effects awaiting performance, in the order the election emitted them.
  ///
  /// A queue rather than a loop over the returned list, because performing one
  /// effect is ASYNCHRONOUS — [AnnouncePrimary] reconnects — while the election
  /// is driven from synchronous message handlers that can fire during that
  /// await. Two overlapping drains would interleave a promotion's
  /// will-then-announce with somebody else's effects, and the ORDER inside a
  /// promotion is the protocol.
  final List<ElectionEffect> _pending = [];
  bool _draining = false;

  /// The drain currently in flight, so [disconnect] can wait for it.
  Future<void>? _drain;

  /// Set by [disconnect]. Refuses NEW effects while letting in-flight ones
  /// finish — see [disconnect] for why the asymmetry matters.
  bool _leaving = false;

  /// Join the bus and enter the election.
  ///
  /// Subscribes to the boot topic BEFORE initialising, which is what lets a
  /// retained announcement already on the topic be honoured rather than raced.
  /// The election latches anything that arrives while it is still in `start`;
  /// anything that arrives after stands us down during `primary_search`. Both
  /// paths lead to `secondary`, and the two-second timer is the only window in
  /// which neither can.
  Future<void> connect() async {
    _clock.start();
    await bus.connect();
    router.addHandler(bootTopic, _onAnnouncement);
    _subscribedAt = _clock.elapsed;
    await _apply(_election.initialize());
  }

  /// `(primary found <path> <version> <timestamp>)` or `(primary absent)`.
  ///
  /// Arity is load-bearing and is upstream's rule, not ours: `process.py:333`
  /// requires exactly four parameters for `found` and exactly one for `absent`.
  /// Anything else is ignored — this topic is world-writable on ADR-023's
  /// unauthenticated bus, and a malformed announcement must not move an
  /// election.
  void _onAnnouncement(AikoMessage message) {
    // Refuse the INPUT, not just its effects. Tesla, round 3: `_apply` dropping
    // effects while leaving still let the election ADVANCE, so the machine's
    // role moved on a process that had gone — the exact lie `onPrimaryFailed`
    // exists to prevent, and invisible to a test that sniffs `bus.actions`
    // rather than `role`.
    if (_leaving) return;
    if (message.command != 'primary') return;
    final parameters = switch (message.arguments) {
      PositionalArguments(:final values) => values,
      KeywordArguments() => const <Object?>[],
    };
    final announcement = switch (parameters) {
      ['found', final String _, _, _] => RegistrarAnnouncement.found,
      ['absent'] => RegistrarAnnouncement.absent,
      _ => null,
    };
    if (announcement == null) return;
    // Only while we are still LOOKING. After promotion this topic carries our
    // own retained announcement, and timing our own echo would overwrite the
    // measurement with a number about ourselves.
    final subscribedAt = _subscribedAt;
    if (subscribedAt != null &&
        _announcementLatency == null &&
        (role == RegistrarRole.start || role == RegistrarRole.primarySearch)) {
      _announcementLatency = _clock.elapsed - subscribedAt;
    }
    unawaited(_apply(_election.onAnnouncement(announcement)));
  }

  /// Perform [effects] in order, one at a time, never two drains at once.
  Future<void> _apply(List<ElectionEffect> effects) async {
    // A search timer can fire after we have begun leaving. Queueing its effects
    // would publish from a process that is on its way out.
    if (_leaving) return;
    _pending.addAll(effects);
    // A drain is already running and will reach what we just queued. Returning
    // here is what keeps the ordering single-threaded.
    if (_draining) return;
    _draining = true;
    final drain = _drainPending();
    _drain = drain;
    try {
      await drain;
    } finally {
      _draining = false;
      _drain = null;
    }
  }

  Future<void> _drainPending() async {
    while (_pending.isNotEmpty) {
      await _perform(_pending.removeAt(0));
    }
  }

  Future<void> _perform(ElectionEffect effect) async {
    switch (effect) {
      case PublishLifecycle(:final role):
        if (!_lifecycle.isClosed) _lifecycle.add(role);

      case StartSearchTimer(:final timeout, :final epoch):
        _timer?.cancel();
        _timer = _createTimer(timeout, () {
          _timer = null;
          // Same rule as [_onAnnouncement]: a timer that fires on a process
          // which has begun leaving must not move the election either. Checked
          // BEFORE `onSearchTimeout`, because that call is what enters `primary`.
          if (_leaving) return;
          // The epoch goes back exactly as it came. A timer that cannot name
          // its own search cannot be honoured — see [StartSearchTimer.epoch].
          unawaited(_apply(_election.onSearchTimeout(epoch)));
        });

      case CancelSearchTimer():
        // Defence in depth, and honest about which layer is load-bearing: a
        // stray timer is ALREADY harmless because [RegistrarElection] rejects a
        // timeout whose epoch does not name the current search. Mutating this
        // to a no-op leaves every behavioural test green — measured, not
        // assumed. What it buys is not leaving armed timers behind, and on
        // [disconnect] that stops being bookkeeping and becomes protocol: a
        // timer surviving our departure promotes a process that has left.
        _timer?.cancel();
        _timer = null;

      case AnnouncePrimary():
        try {
          // Clear, will, announce — in that order, inside ONE try, because they
          // are one transaction. The gap between the will and the announcement
          // is the whole point: announcing first leaves a window in which a
          // crash strands a retained `found` naming a dead process, and every
          // peer joining afterwards is told a corpse is primary.
          bus.clearRetained(bootTopic);
          await bus.setWill(primaryWill);
          // RE-READ THE AUTHORITY AFTER THE AWAIT. `setWill` reconnects, and
          // `_onAnnouncement` mutates the election SYNCHRONOUSLY while we are
          // suspended in it — so the decision that sent us here can be revoked
          // mid-transaction. Measured: a predecessor's retained
          // `(primary absent)` delivered during the will change stands us down
          // to `primarySearch`, and without this guard we then published a
          // RETAINED `(primary found <us>)` anyway. Final state: not primary,
          // and the boot topic tells every future joiner that we are — the
          // corpse-primary failure the will exists to prevent, reached without
          // anybody dying.
          //
          // Not a failure, so NOT `onPrimaryFailed`: the election already moved
          // and standing it down again would be a second demotion for one
          // event. We simply abandon the publish. The boot topic is left
          // CLEARED, which is the honest state — no primary is claimed, and a
          // joiner asks rather than believing a corpse.
          //
          // WHAT THIS LEAVES BEHIND, stated rather than absorbed. We abandon
          // still holding the PRIMARY will, because taking it is the step
          // before this one. Two consequences, and only one of them is benign:
          //   * a search timeout re-promotes us cheaply — `setWill`short-circuits
          //     on `next == _will`, so there is no second reconnect;
          //   * but if a PEER announces first we settle at `secondary` holding
          //     a retained `(primary absent)` aimed at the boot topic, and an
          //     unclean death then publishes it over that peer's healthy
          //     `found`.
          // That is claude-tasks #4319, reached by a route that did not exist
          // before this guard. It is NOT covered by "upstream parity": upstream
          // cannot abandon at all, because its `on_enter_primary` is
          // synchronous. This window is ours, so the residual is ours to decide
          // rather than to inherit.
          // SCOPED TO WHAT WAS PROVEN: the ELECTION's authority, not `_leaving`.
          // An earlier draft of this guard also refused while leaving, which
          // silently reversed a separate decision that has its own test and its
          // own rationale ("leaving mid-promotion lets it finish"): a promotion
          // cut in half leaves the retained will armed with nothing announced.
          // That question is live — Carnot's cage-match finding is that a clean
          // shutdown never retracts the `found` either (claude-tasks #4319) —
          // but it is an upstream-parity decision, not this fix's to take.
          if (role != RegistrarRole.primary) return;
          bus.send(bootTopic, 'primary', [
            'found',
            topicPath.path,
            registrarVersion,
            timeStarted,
          ], retain: true);
          if (!_announcements.isClosed) _announcements.add(topicPath);
        } on Object catch (error) {
          // `registrar.py:198-200` catches here and stands the registrar back
          // down. Anything thrown between clearing the topic and publishing
          // leaves an island holding a primary that never spoke, so the ROLE has
          // to go back rather than the error go up.
          //
          // A TRANSIENT reaches here like anything else and is handled the same
          // way. That is deliberate: standing back down and re-searching is the
          // correct response to "the broker is unreachable right now", and the
          // supervisor beneath us — not this election — owns getting the link
          // back. The retry is a cheap local throw that never touches the wire.
          if (!_promotionFailures.isClosed) _promotionFailures.add(error);
          _pending.addAll(_election.onPrimaryFailed());
        }

      case DropRoster():
        if (!_rosterDrops.isClosed) _rosterDrops.add(null);
    }
  }

  /// Leave the bus.
  ///
  /// A CLEAN disconnect, which SUPPRESSES the will — so a primary that shuts
  /// down this way leaves its retained `(primary found ...)` standing and the
  /// island believes a departed registrar is still serving. That is upstream's
  /// behaviour too (nothing in `registrar.py` retracts on shutdown), and the
  /// two-arm probe asserts both halves rather than only the convenient one.
  Future<void> disconnect() async {
    // Stop accepting NEW effects, then let anything already in flight finish
    // against a bus that is still up. The asymmetry is the point: a promotion
    // is HALF DONE between taking the retained will and publishing the
    // announcement, and tearing the bus out from under it throws from
    // `clearRetained` or `send` inside an async drain, where there is nobody to
    // catch it. Only `AnnouncePrimary` sits in a try, so the throw would come
    // from `ClearBootTopic` and surface as an unhandled async error rather than
    // as a promotion failure.
    _leaving = true;
    _timer?.cancel();
    _timer = null;
    await _drain;
    // AGAIN, after the drain. The drain can PERFORM a `StartSearchTimer` queued
    // before we set `_leaving` — from a failed in-flight promotion's
    // `onPrimaryFailed`, or a re-search — which arms a timer after the cancel
    // above already ran. Cancelling once is cancelling the timer that existed
    // when we decided to leave, not the one leaving produced.
    _timer?.cancel();
    _timer = null;
    await router.dispose();
    await bus.disconnect();
    await _lifecycle.close();
    await _rosterDrops.close();
    await _announcements.close();
    await _promotionFailures.close();
  }
}

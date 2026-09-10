import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_bus.dart';

const _registrar = 'aiko/island/1/1';
const _chatRecord = [
  'aiko/island/17/1',
  'chat_server',
  'p/chat_server:0',
  'mqtt',
  'root',
  ['ec=true'],
];
const _registrarRecord = [
  _registrar,
  'registrar',
  'p/registrar:2',
  'mqtt',
  'root',
  ['ec=true'],
];

Future<BusProcess> connectedProcess(FakeBus bus) async {
  final process = BusProcess(host: 'dart', processId: 99, bus: bus);
  final connected = process.connect();
  await bus.whenSubscribed('aiko/service/registrar');
  await bus.deliver('aiko/service/registrar', 'primary', [
    'found',
    _registrar,
    '2',
    '1234.5',
  ]);
  await connected;
  return process;
}

void main() {
  late FakeBus bus;
  late BusProcess process;
  late ServicesCache cache;

  setUp(() async {
    bus = FakeBus();
    process = await connectedProcess(bus);
    cache = ServicesCache(process);
  });

  group('BusProcess', () {
    test(
      'the retained announcement alone reaches REGISTRAR — no registration',
      () {
        expect(process.state, ConnectionState.registrar);
        expect(process.registrar?.path, _registrar);
        // Nothing was published. An observer that adds no services tells the
        // registrar nothing, which is the whole reason this increment is small.
        expect(bus.sent, isEmpty);
      },
    );

    test('a malformed announcement does not move the ladder', () async {
      final quiet = FakeBus();
      final p = BusProcess(host: 'dart', processId: 1, bus: quiet);
      final connected = p.connect();
      await quiet.whenSubscribed('aiko/service/registrar');
      await quiet.deliver('aiko/service/registrar', 'primary', [
        'found',
        'not-a-topic-path',
        '2',
        '1',
      ]);
      await quiet.deliver('aiko/service/registrar', 'primary', ['garbage']);
      expect(p.state, ConnectionState.transport);
      expect(p.registrar, isNull);
      // And then a good one lands, proving the probe could have observed it.
      await quiet.deliver('aiko/service/registrar', 'primary', [
        'found',
        _registrar,
        '2',
        '1',
      ]);
      await connected;
      expect(p.state, ConnectionState.registrar);
    });

    // `autoReconnect` repairs a broken socket in silence. A ladder built only
    // from protocol messages climbs once and then reports REGISTRAR over a dead
    // wire — the roster frozen, the lease renewing into nothing, and every
    // outward sign of health intact.
    test(
      'a broker drop moves the ladder DOWN and clears the registrar',
      () async {
        expect(process.state, ConnectionState.registrar);
        await bus.setTransport(up: false);
        expect(process.state, ConnectionState.none);
        expect(process.registrar, isNull);

        await bus.setTransport(up: true);
        expect(process.state, ConnectionState.transport);
      },
    );

    // `onConnected` and `onAutoReconnected` both report `up`, and the retained
    // `(primary found …)` can land between them. An unguarded transition writes
    // TRANSPORT over a LIVING registrar without clearing it — leaving
    // `registrar != null` while `isConnected(registrar)` says false. Not a
    // missing rung: a lying one.
    test('an up-beat never demotes a living registrar', () async {
      expect(process.state, ConnectionState.registrar);
      await bus.setTransport(up: true);
      expect(process.state, ConnectionState.registrar);
      expect(process.registrar, isNotNull);
    });

    test('(primary absent) drops one rung, not to none', () async {
      await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
      expect(process.state, ConnectionState.transport);
      expect(process.registrar, isNull);
    });
  });

  group('ServicesCache', () {
    test('attach asks the registrar for everything, on two topics', () {
      cache.attach();
      expect(cache.shareTopic, 'aiko/dart/99/0/registrar_share');
      expect(
        bus.subscribed,
        containsAll([cache.shareTopic, '$_registrar/out']),
      );
      final request = bus.sent.single;
      expect(request.topic, '$_registrar/in');
      expect(request.command, 'share');
      // Five wildcards after the response topic: name, protocol, transport,
      // owner, tags (`registrar.py:331 services_share()`).
      expect(request.params, [cache.shareTopic, '*', '*', '*', '*', '*']);
      expect(cache.state, ServicesCacheState.share);
    });

    test(
      'attach before the registrar is known is an error, not a silent wait',
      () {
        final lonely = ServicesCache(
          BusProcess(host: 'dart', processId: 1, bus: FakeBus()),
        );
        expect(lonely.attach, throwsStateError);
      },
    );

    // `int.tryParse('-1')` is `-1`, not null, so a guard that only asks "does
    // this parse" admits a negative frame — and a negative one never recovers,
    // because every `add` decrements away from the `== 0` that completes the
    // snapshot. Our share topic is reachable: the registrar broadcasts
    // `(sync <topic_response>)` on its `/out`, naming it to the whole island.
    //
    // The positive control matters as much as the arm: without it, a cache
    // that ignored EVERY item_count would pass the first two expectations.
    test('a negative item_count is refused, and does not wedge the frame', () async {
      cache.attach();

      await bus.deliver(cache.shareTopic, 'item_count', ['-1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(
        cache.state,
        ServicesCacheState.share,
        reason: 'still awaiting a valid snapshot — no frame was opened',
      );
      expect(cache.services, isEmpty);

      // Positive control, on the same cache: a good frame still lands, so the
      // rejection above is about the value and not about the cache being inert.
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.state, ServicesCacheState.loaded);
      expect(cache.services.map((s) => s.name), ['chat_server']);
    });

    // The arm a bounds-check cannot cover. `999999` is a perfectly well-formed
    // non-negative count, so the `>= 0` guard admits it — and the frame then
    // waits for records that never arrive, wedged exactly as a negative one
    // would. No bound on the VALUE closes this; only "did we ask?" does.
    test(
      'an unsolicited frame is refused however plausible its count',
      () async {
        cache.attach();
        await bus.deliver(cache.shareTopic, 'item_count', ['1']);
        await bus.deliver(cache.shareTopic, 'add', _chatRecord);
        // The REGISTRAR confirms on its own `/out`, which is what actually
        // answers the request. `loaded` alone is a claim any peer can make.
        await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
        expect(cache.state, ServicesCacheState.ready);

        // Our request is answered; the topic should now be silent. A peer that
        // knows our share topic — and the registrar broadcasts it, in
        // `(sync <topic_response>)` on its own `/out` — opens a frame we never
        // asked for.
        await bus.deliver(cache.shareTopic, 'item_count', ['999999']);
        await bus.deliver(cache.shareTopic, 'add', _registrarRecord);

        expect(
          cache.state,
          ServicesCacheState.ready,
          reason: 'an unsolicited frame must not reopen an answered snapshot',
        );
        expect(cache.services.map((s) => s.name), [
          'chat_server',
        ], reason: 'and must not smuggle a record into the roster');
      },
    );

    // THE RACE THE FIRST VERSION OF THIS GUARD ARMED INSTEAD OF CLOSING.
    // Zero is a legal frame, so `(item_count 0)` from a racing peer COMPLETES
    // instantly with an empty roster. When the window closed on `loaded`, that
    // one packet marked us confidently-empty and then locked out the
    // registrar's real reply — strictly worse than the wedge the guard was
    // added to fix, because a wedged cache at least does not claim an answer.
    // Closing the window on `ready` instead is what makes the registrar's
    // `(sync …)`, on its OWN topic, the thing that ends the exchange.
    test('a raced empty frame cannot lock out the real snapshot', () async {
      cache.attach();

      // One packet from any peer that knows our topic.
      await bus.deliver(cache.shareTopic, 'item_count', ['0']);
      expect(cache.state, ServicesCacheState.loaded);
      expect(cache.services, isEmpty);
      expect(
        cache.state,
        isNot(ServicesCacheState.ready),
        reason: 'nothing has confirmed on the registrar\'s own topic yet',
      );

      // The registrar's real answer still lands and still wins.
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      expect(cache.state, ServicesCacheState.ready);
      expect(cache.services.map((s) => s.name), ['chat_server']);
    });

    // A frame REPLACES, it does not merge. Without clearing the accumulator, a
    // peer's oversized frame plus one poisoned record, followed by the
    // registrar's real frame, completes with the poison still in the roster and
    // emitted as a ServiceAdded — a lie rather than a void, and the harder of
    // the two to notice.
    test('a replacing frame discards records the previous one accumulated', () async {
      cache.attach();

      await bus.deliver(cache.shareTopic, 'item_count', ['2']);
      await bus.deliver(cache.shareTopic, 'add', _registrarRecord);
      expect(
        cache.services,
        isEmpty,
        reason:
            'an open frame is staged, not published — the roster is only '
            'replaced when the frame commits',
      );

      // The registrar's real frame opens; the poisoned record must not survive.
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);

      expect(cache.state, ServicesCacheState.ready);
      expect(cache.services.map((s) => s.name), [
        'chat_server',
      ], reason: 'the earlier frame\'s record must not survive into this one');
    });

    // The other writer. Live deltas arrive on the registrar's `/out` while a
    // snapshot frame is open on our private topic, and a delta is NEWER than
    // the snapshot the registrar already serialised — so it must survive the
    // commit. An earlier fix cleared the roster when a frame opened, which
    // emitted the live service as a ServiceAdded and then annihilated it with
    // no ServiceRemoved and no second chance: the publisher does not send it
    // again.
    test('a service registering mid-snapshot survives the commit', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);

      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      // A live registration lands on the registrar's own topic mid-frame.
      await bus.deliver('$_registrar/out', 'add', _registrarRecord);
      expect(changes.whereType<ServiceAdded>(), hasLength(1));

      // The frame completes with a snapshot that predates that registration.
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);

      expect(cache.state, ServicesCacheState.ready);
      expect(cache.services.map((s) => s.name).toSet(), {
        'chat_server',
        'registrar',
      }, reason: 'the mid-frame registration must not be erased by the commit');
      expect(
        changes.whereType<ServiceRemoved>(),
        isEmpty,
        reason: 'and it must not vanish silently either',
      );
    });

    // A live REMOVE during a frame must also survive, or the commit resurrects
    // a service the registrar has already retired.
    test(
      'a service deregistering mid-snapshot stays gone after the commit',
      () async {
        cache.attach();
        await bus.deliver(cache.shareTopic, 'item_count', ['1']);
        await bus.deliver(cache.shareTopic, 'add', _chatRecord);
        // The snapshot named it, and then it left before the frame committed.
        await bus.deliver('$_registrar/out', 'remove', [
          _chatRecord[0] as String,
        ]);
        await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);

        expect(cache.state, ServicesCacheState.ready);
        expect(
          cache.services,
          isEmpty,
          reason: 'the commit must not resurrect a service already retired',
        );
      },
    );

    // The healing property, and the reason the flag stays true across an
    // INCOMPLETE frame rather than being cleared as soon as one opens: a peer
    // that wins the race to answer our request must not be able to lock out the
    // registrar's real reply.
    test('a genuine snapshot still replaces a frame someone raced us to', () async {
      cache.attach();

      // A racing peer answers our outstanding request first, with a count that
      // will never complete.
      await bus.deliver(cache.shareTopic, 'item_count', ['999999']);
      expect(cache.state, ServicesCacheState.share);

      // The registrar's real reply lands second and takes over.
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.state, ServicesCacheState.loaded);
      expect(cache.services.map((s) => s.name), ['chat_server']);
    });

    // Positive control for the invariant itself: after a re-request the topic
    // is legitimately live again. Without this, a cache that simply stopped
    // listening after its first snapshot would pass the refusal tests above.
    test('a re-request makes the topic legitimate again', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.state, ServicesCacheState.loaded);

      // A registrar restart at a new path re-asks, which re-opens the window.
      await bus.deliver('aiko/service/registrar', 'primary', [
        'found',
        'aiko/island/2/1',
        '2',
        '9999.0',
      ]);
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _registrarRecord);
      expect(cache.state, ServicesCacheState.loaded);
      expect(cache.services.map((s) => s.name), ['registrar']);
    });

    // Zero is a legal frame — an island with no matching services — and is the
    // boundary the fix must not overshoot into.
    test(
      'a zero item_count is a legal empty snapshot, not a rejection',
      () async {
        cache.attach();
        final changes = <ServiceChange>[];
        cache.changes.listen(changes.add);

        await bus.deliver(cache.shareTopic, 'item_count', ['0']);
        expect(cache.state, ServicesCacheState.loaded);
        expect(cache.services, isEmpty);
        expect(changes.whereType<ServicesLoaded>(), isNotEmpty);
      },
    );

    test('the snapshot loads, then the registrar confirms it', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);

      await bus.deliver(cache.shareTopic, 'item_count', ['2']);
      await bus.deliver(cache.shareTopic, 'add', _registrarRecord);
      expect(cache.state, ServicesCacheState.share);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);

      expect(cache.state, ServicesCacheState.loaded);
      expect(cache.services.map((s) => s.name), ['registrar', 'chat_server']);
      expect(changes.first, isA<ServicesLoaded>());
      expect(changes.whereType<ServiceAdded>().length, 2);

      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      expect(cache.state, ServicesCacheState.ready);
      // The reference reaches ready and emits nothing, leaving a subscriber to
      // poll. The state is public, so the transition is observable here.
      expect(changes.last, isA<ServicesReady>());
    });

    // The two halves arrive on two different topics, and MQTT orders per topic,
    // not across them. A `sync` that overtakes the last `(add …)` must still
    // count — a both-conditions-now test would drop it and leave the cache at
    // `loaded` for the rest of its life, with ServicesReady never firing.
    test('a sync that ARRIVES FIRST still promotes the cache', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);

      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      expect(
        cache.state,
        ServicesCacheState.share,
        reason: 'nothing loaded yet',
      );

      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.state, ServicesCacheState.ready);
      expect(changes.whereType<ServicesReady>(), isNotEmpty);
    });

    test('a stale sync does not survive a registrar replacement', () async {
      cache.attach();
      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
      await bus.deliver('aiko/service/registrar', 'primary', [
        'found',
        _registrar,
        '2',
        '1',
      ]);
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(
        cache.state,
        ServicesCacheState.loaded,
        reason: 'the new registrar has not sent its own barrier yet',
      );
    });

    // The registrar answers EVERY consumer on one `/out` topic. An unfiltered
    // `sync` would promote this cache to ready on somebody else's snapshot —
    // a state no live island produces on demand, which is exactly why it is
    // tested here rather than left to the acceptance run.
    test("another consumer's sync does not make this cache ready", () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.state, ServicesCacheState.loaded);

      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);
      await bus.deliver('$_registrar/out', 'sync', [
        'aiko/somebody/else/0/registrar_share',
      ]);
      expect(cache.state, ServicesCacheState.loaded);
      expect(changes.whereType<ServicesReady>(), isEmpty);

      await bus.deliver('$_registrar/out', 'sync', [cache.shareTopic]);
      expect(cache.state, ServicesCacheState.ready);
    });

    test('live add and remove arrive on the registrar out topic', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);
      await bus.deliver(cache.shareTopic, 'item_count', ['0']);
      expect(cache.state, ServicesCacheState.loaded);

      await bus.deliver('$_registrar/out', 'add', _chatRecord);
      expect(
        changes.whereType<ServiceAdded>().single.service.name,
        'chat_server',
      );

      await bus.deliver('$_registrar/out', 'remove', ['aiko/island/17/1']);
      expect(
        changes.whereType<ServiceRemoved>().single.service.name,
        'chat_server',
      );
      expect(cache.services, isEmpty);
    });

    test('removing something never added emits nothing', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);
      await bus.deliver('$_registrar/out', 'remove', ['aiko/ghost/1/1']);
      expect(changes, isEmpty);
    });

    test('an add with no frame open is ignored', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(cache.services, isEmpty);
      expect(cache.state, ServicesCacheState.share);
    });

    test('findFirst selects by attribute', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['2']);
      await bus.deliver(cache.shareTopic, 'add', _registrarRecord);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      expect(
        cache
            .findFirst(const ServiceFilter(name: 'chat_server'))
            ?.topicPath
            .path,
        'aiko/island/17/1',
      );
      expect(cache.findFirst(const ServiceFilter(name: 'nope')), isNull);
    });

    // `share.py:719-747` drives this cache from the connection ladder in BOTH
    // directions. The reverse direction is the one that is easy to leave out and
    // impossible to see: without it a registrar restart leaves the roster frozen
    // at whatever it last held, no new share request goes out, and every outward
    // sign of health persists over a view that stopped tracking the island.
    group('across a registrar restart', () {
      setUp(() async {
        cache.attach();
        await bus.deliver(cache.shareTopic, 'item_count', ['1']);
        await bus.deliver(cache.shareTopic, 'add', _chatRecord);
        expect(cache.state, ServicesCacheState.loaded);
      });

      test(
        'losing the registrar clears the roster rather than freezing it',
        () async {
          await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
          expect(cache.services, isEmpty);
          expect(cache.state, ServicesCacheState.empty);
          expect(
            bus.unsubscribed,
            containsAll([cache.shareTopic, '$_registrar/out']),
          );
        },
      );

      test(
        'a stale message from the old registrar is no longer ours',
        () async {
          await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
          await bus.deliver('$_registrar/out', 'add', _chatRecord);
          expect(cache.services, isEmpty);
        },
      );

      test('the registrar returning at a NEW path re-asks the new one', () async {
        await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
        bus.sent.clear();

        const reborn = 'aiko/island/44/1';
        await bus.deliver('aiko/service/registrar', 'primary', [
          'found',
          reborn,
          '2',
          '9999.0',
        ]);

        // Addressed to the NEW registrar. A cache that re-used the remembered
        // topics would be talking to a dead process id and would look, from the
        // outside, exactly like one that was simply not being told anything.
        expect(bus.sent.single.topic, '$reborn/in');
        expect(bus.subscribed, contains('$reborn/out'));
        expect(cache.state, ServicesCacheState.share);

        await bus.deliver(cache.shareTopic, 'item_count', ['1']);
        await bus.deliver(cache.shareTopic, 'add', _chatRecord);
        expect(cache.state, ServicesCacheState.loaded);
        expect(cache.services.single.name, 'chat_server');
      });
    });

    // The ladder cannot carry a new identity at the same potential: a registrar
    // that restarts and re-announces WITHOUT an intervening `(primary absent)`
    // leaves the connection state exactly where it was. Anything keyed on a
    // ladder TRANSITION would keep talking to the dead address — subscribed to a
    // `/out` nobody publishes to, never asking the living `/in`, and healthy in
    // every observable way.
    test(
      'a registrar REPLACED with no intervening absent is still a change',
      () async {
        cache.attach();
        await bus.deliver(cache.shareTopic, 'item_count', ['1']);
        await bus.deliver(cache.shareTopic, 'add', _chatRecord);
        expect(cache.state, ServicesCacheState.loaded);
        expect(process.state, ConnectionState.registrar);
        bus.sent.clear();

        const replacement = 'aiko/island/77/1';
        await bus.deliver('aiko/service/registrar', 'primary', [
          'found',
          replacement,
          '2',
          '5555.0',
        ]);

        // The ladder never moved — that is the whole point of the test.
        expect(process.state, ConnectionState.registrar);
        expect(bus.sent.single.topic, '$replacement/in');
        expect(bus.subscribed, contains('$replacement/out'));
        expect(bus.unsubscribed, contains('$_registrar/out'));
        expect(cache.services, isEmpty);
      },
    );

    test('re-announcing the SAME registrar is not a change', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      bus.sent.clear();

      await bus.deliver('aiko/service/registrar', 'primary', [
        'found',
        _registrar,
        '2',
        '9999.0',
      ]);
      expect(bus.sent, isEmpty, reason: 'no re-request for an unchanged path');
      expect(cache.services, isNotEmpty, reason: 'roster survives a repeat');
    });

    // The reference emits nothing here, leaving any consumer attached to a
    // producer this roster can no longer vouch for — the only teardown trigger
    // is a ServiceRemoved that never comes.
    test('losing the registrar announces that the roster was released', () async {
      cache.attach();
      final changes = <ServiceChange>[];
      cache.changes.listen(changes.add);
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);

      await bus.deliver('aiko/service/registrar', 'primary', ['absent']);
      expect(changes.whereType<RosterReleased>(), isNotEmpty);
      // Not a claim that the services died — a registrar blinking says nothing
      // about its members.
      expect(changes.whereType<ServiceRemoved>(), isEmpty);
    });

    test('terminate drops both subscriptions and empties the roster', () async {
      cache.attach();
      await bus.deliver(cache.shareTopic, 'item_count', ['1']);
      await bus.deliver(cache.shareTopic, 'add', _chatRecord);
      await cache.terminate();
      expect(
        bus.unsubscribed,
        containsAll([cache.shareTopic, '$_registrar/out']),
      );
      expect(cache.services, isEmpty);
      expect(cache.state, ServicesCacheState.empty);
    });
  });
}

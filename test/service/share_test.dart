/// ADR-0001 §3 acceptance tests for the share tree (D5) — the ● negative
/// controls, written to be RED before `Share` exists.
///
/// Each ● arm FORCES the bad state. A test that would report the same thing
/// whether or not the failure is present is void, so every expectation here is
/// one the reference's own behaviour would fail.
library;

import 'package:aiko_services/src/service/share.dart';
import 'package:test/test.dart';

void main() {
  group('reserved framework keys (● 1)', () {
    test('an application write to a reserved key is REJECTED and reported', () {
      final share = Share.own();
      // Listen first: `errors` is a broadcast stream with no replay, so a
      // subscription taken after the event asserts nothing.
      expectLater(share.errors, emits(isA<ReservedKeyError>()));
      expect(() => share.setApp('lifecycle', 'ready'), throwsA(isA<ReservedKeyError>()));
    });

    test('a NON-reserved application key is accepted', () {
      final share = Share.own();
      share.setApp('temperature', 25);
      expect(share.read('temperature'), 25);
    });
  });

  group('inbound on our own /control (● 2, 8)', () {
    test('an invalid framework value is rejected, previous value retained, error surfaced', () {
      final share = Share.own()..setFramework('log_level', 'DEBUG');
      expectLater(share.errors, emits(isA<InvalidFrameworkValueError>()));
      share.applyInbound(const ShareUpdate('log_level', 'junk'));
      expect(share.read('log_level'), 'DEBUG',
          reason: 'a malformed remote message must not overwrite good state');
    });

    test('it does NOT throw — a malformed remote message must not kill an actor', () {
      final share = Share.own()..setFramework('log_level', 'DEBUG');
      expect(() => share.applyInbound(const ShareUpdate('log_level', 'junk')), returnsNormally);
    });

    test('(remove <reserved>) from a peer is refused', () {
      final share = Share.own()..setFramework('lifecycle', 'ready');
      share.applyInbound(const ShareRemove('lifecycle'));
      expect(share.read('lifecycle'), 'ready');
    });
  });

  group('inbound on a PEER REPLICA (● 3)', () {
    test('we STORE what the producer sent, even when we think it invalid', () {
      // Rejecting it would make us diverge from the mesh we exist to converge
      // with, while pipeline.py:287 still reads whatever the peer stored.
      final replica = Share.replicaOf('aiko/host/1/2');
      expectLater(replica.errors, emits(isA<InvalidFrameworkValueError>()));
      replica.applyInbound(const ShareUpdate('log_level', 'junk'));
      expect(replica.read('log_level'), 'junk',
          reason: 'a replica mirrors its producer; it does not correct it');
    });
  });

  group('depth-2 tree, dotted paths (● 4, 7)', () {
    test('dotted paths address a nested value', () {
      final share = Share.own()..seedNode('metrics');
      share.applyInbound(const ShareUpdate('metrics.running', 3));
      expect(share.read('metrics.running'), 3);
    });

    test('depth 3 is rejected and REPORTED — louder than the reference, same wire', () {
      final share = Share.own();
      expectLater(share.errors, emits(isA<ShareDepthError>()));
      share.applyInbound(const ShareUpdate('a.b.c', 1));
      expect(share.read('a.b.c'), isNull);
    });

    test('a missing intermediate path is a REPORTED drop, not a silent one', () {
      // share.py::_ec_modify_item silently no-ops here. We conform on the wire
      // and diverge on observability (D3).
      final share = Share.own();
      expectLater(share.errors, emits(isA<ShareMissingPathError>()));
      share.applyInbound(const ShareUpdate('nosuch.leaf', 1));
    });
  });

  group('the tree never leaks a live nested Map (● 5)', () {
    test('mutating a handed-out nested map does not reach the tree', () {
      final share = Share.own()..seedNode('metrics');
      share.applyInbound(const ShareUpdate('metrics.running', 3));
      final metrics = share.read('metrics')! as Map<String, Object?>;
      // Stronger than "the write does not propagate": the attempt itself fails,
      // so a dual writer by alias is impossible rather than merely ineffective.
      // A live map would bypass the mutator, the reserved-key check and the
      // ec_producer notification.
      expect(() => metrics['running'] = 999, throwsUnsupportedError);
      expect(share.read('metrics.running'), 3);
    });
  });
}

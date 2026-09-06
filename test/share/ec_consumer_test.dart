import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

import '../support/fake_bus.dart';

const _consumerPath = ServiceTopicPath('aiko', 'dart', '99', '0');
const _producerControl = 'aiko/island/17/1/control';

void main() {
  late FakeBus bus;
  late TopicRouter router;
  late ECConsumer consumer;

  setUp(() {
    bus = FakeBus();
    router = TopicRouter(bus);
    consumer = ECConsumer(
      router,
      bus,
      consumerPath: _consumerPath,
      consumerId: 1,
      producerControlTopic: _producerControl,
      filter: 'channel_list',
    );
  });

  // `share.py:455` — the consumer's inbound topic embeds the WHOLE producer
  // control topic inside its own path. It looks like a mistake and is the wire.
  test('the share-in topic is the producer control topic nested in ours', () {
    expect(
      consumer.topicShareIn,
      'aiko/dart/99/0/aiko/island/17/1/control/1/in',
    );
  });

  test('attach subscribes and asks for the lease', () {
    consumer.attach();
    expect(bus.subscribed, contains(consumer.topicShareIn));
    expect(bus.sent.single.topic, _producerControl);
    expect(bus.sent.single.command, 'share');
    expect(bus.sent.single.params, [
      consumer.topicShareIn,
      '300',
      'channel_list',
    ]);
  });

  test(
    'a snapshot frame fills the replica and reaches ready on the last item',
    () async {
      consumer.attach();
      await bus.deliver(consumer.topicShareIn, 'item_count', ['2']);
      expect(consumer.cacheState, CacheState.empty);

      await bus.deliver(consumer.topicShareIn, 'add', [
        'channel_list.general',
        'g',
      ]);
      expect(
        consumer.cacheState,
        CacheState.empty,
        reason: 'frame not complete',
      );

      await bus.deliver(consumer.topicShareIn, 'add', [
        'channel_list.llm',
        'l',
      ]);
      expect(consumer.cacheState, CacheState.ready);

      final channels = consumer.replica.read('channel_list');
      expect(channels, {'general': 'g', 'llm': 'l'});
    },
  );

  // A dotted `add` must CREATE its intermediate node. `_ec_update_item` passes
  // `create_path=True` (`share.py:155-158`) where the producer's control path
  // uses the default `False`. Get this wrong and the failure is not an error on
  // a stream — it is an entire namespace that never appears, and an observer
  // that prints an empty channel list as though that were the answer.
  test('a dotted add creates its intermediate node in a replica', () async {
    consumer.attach();
    await bus.deliver(consumer.topicShareIn, 'item_count', ['1']);
    await bus.deliver(consumer.topicShareIn, 'add', ['brand_new.leaf', 'v']);
    expect(consumer.replica.read('brand_new'), {'leaf': 'v'});
  });

  // Measured on a live island: ONE `(share ...)` request draws THREE complete
  // snapshots from a HyperSpace service and TWO from a Category, because each
  // class in the MRO chain constructs its own ECProducer over the same control
  // topic (`actor.py:237`, `category.py:107`, `hyperspace.py:158`) and
  // `process.py:211` appends handlers to a list without a duplicate check.
  // The consumer must therefore be idempotent under a repeated snapshot.
  test(
    'a repeated snapshot re-arrives at ready instead of accumulating',
    () async {
      consumer.attach();
      for (var burst = 0; burst < 3; burst++) {
        await bus.deliver(consumer.topicShareIn, 'item_count', ['2']);
        await bus.deliver(consumer.topicShareIn, 'add', [
          'channel_list.general',
          'g',
        ]);
        await bus.deliver(consumer.topicShareIn, 'add', [
          'channel_list.llm',
          'l',
        ]);
        expect(consumer.cacheState, CacheState.ready, reason: 'burst $burst');
        expect(consumer.replica.read('channel_list'), {
          'general': 'g',
          'llm': 'l',
        });
      }
    },
  );

  // Zero equals zero immediately. The reference checks completion only inside
  // its `add` arm, so an empty share never becomes ready there — but a filter
  // that legitimately matches nothing must be distinguishable from a producer
  // that never answered, and `cacheState` is a local accessor rather than a wire
  // behaviour, so reproducing that gap would be copying, not parity.
  test(
    'an empty snapshot is ready, not indistinguishable from silence',
    () async {
      consumer.attach();
      await bus.deliver(consumer.topicShareIn, 'item_count', ['0']);
      expect(consumer.cacheState, CacheState.ready);
      expect(consumer.replica.snapshot(), isEmpty);
    },
  );

  test('a non-positive lease is refused at construction', () {
    for (final bad in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => ECConsumer(
          router,
          bus,
          consumerPath: _consumerPath,
          consumerId: 1,
          producerControlTopic: _producerControl,
          leaseTime: bad,
        ),
        throwsArgumentError,
        reason:
            '$bad would make the renewal timer spin against a remote '
            'service, and zero is the cancellation form',
      );
    }
  });

  test('update and remove move the replica after the snapshot', () async {
    consumer.attach();
    await bus.deliver(consumer.topicShareIn, 'item_count', ['1']);
    await bus.deliver(consumer.topicShareIn, 'add', [
      'channel_list.general',
      'g',
    ]);

    await bus.deliver(consumer.topicShareIn, 'update', [
      'channel_list.general',
      'G',
    ]);
    expect(consumer.replica.read('channel_list'), {'general': 'G'});

    await bus.deliver(consumer.topicShareIn, 'remove', [
      'channel_list.general',
    ]);
    expect(consumer.replica.read('channel_list'), <String, Object?>{});
  });

  test('traffic for another topic is not ours', () async {
    consumer.attach();
    await bus.deliver('some/other/topic', 'item_count', ['9']);
    await bus.deliver('some/other/topic', 'add', ['channel_list.x', 'x']);
    expect(consumer.replica.read('channel_list'), isNull);
  });

  test(
    'terminate cancels the lease with a zero-second share request',
    () async {
      consumer.attach();
      await consumer.terminate();
      expect(bus.sent.last.command, 'share');
      expect(bus.sent.last.params, [
        consumer.topicShareIn,
        '0',
        'channel_list',
      ]);
      expect(bus.unsubscribed, contains(consumer.topicShareIn));
      expect(consumer.cacheState, CacheState.empty);
    },
  );

  // A terminated consumer has a closed event stream, so re-attaching would
  // subscribe, mirror and emit nothing: correct-looking and silent. One producer
  // instance, one consumer.
  test(
    'attach after terminate is refused rather than silently inert',
    () async {
      consumer.attach();
      await consumer.terminate();
      expect(consumer.attach, throwsStateError);
    },
  );

  test('terminate before attach does nothing at all', () async {
    await consumer.terminate();
    expect(bus.sent, isEmpty);
    expect(bus.unsubscribed, isEmpty);
  });
}

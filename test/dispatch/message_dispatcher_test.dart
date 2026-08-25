/// Tests for by-name dispatch — the receive-side mirror of a remote proxy.
///
/// A composed-mixin actor (same idiom as the composition spike) is invoked
/// purely by S-expression command payloads through a MessageDispatcher, with
/// no reference to the object crossing any boundary.
library;

import 'package:aiko_services/aiko_services.dart';
import 'package:test/test.dart';

// A composed actor — the object the dispatcher routes commands to. In a real
// actor this lives inside its isolate and is never sent anywhere.
mixin CounterMixin {
  int _count = 0;
  void increment(int by) => _count += by;
  int get count => _count;
}

mixin ShareMixin {
  final Map<String, String> share = {'lifecycle': 'ready', 'running': 'false'};
}

class CounterActor with CounterMixin, ShareMixin {}

/// Build the receive-side dispatch map from the actor. This registration is
/// what codegen would emit from the interface's method list.
MessageDispatcher dispatcherFor(CounterActor actor) => MessageDispatcher({
  'increment': (args) {
    actor.increment(int.parse(args[0] as String));
    return generate('count', [actor.count]);
  },
  'update': (args) {
    // EC state delta: (update itemName itemValue)
    actor.share[args[0] as String] = args[1] as String;
    return generate('ack', [args[0]]);
  },
  'describe': (args) =>
      generate('description', ['CounterActor(count=${actor.count})']),
  'ping': (args) => null, // fire-and-forget: no reply
});

void main() {
  test('routes commands by name to the composed actor; state persists', () {
    final d = dispatcherFor(CounterActor());
    expect(d.dispatch('(increment 5)'), '(count 5)');
    expect(d.dispatch('(increment 3)'), '(count 8)'); // same actor, accumulates
    expect(d.dispatch('(describe)'), '(description 21:CounterActor(count=8))');
  });

  test('EC state delta mutates the actor via the same wire', () {
    final actor = CounterActor();
    final d = dispatcherFor(actor);
    expect(d.dispatch('(update running true)'), '(ack running)');
    expect(actor.share['running'], 'true');
  });

  test('fire-and-forget command returns no reply', () {
    final d = dispatcherFor(CounterActor());
    expect(d.dispatch('(ping)'), isNull);
  });

  test('unknown command yields a diagnostic, not a crash '
      '(mirrors Message.invoke "Function not found")', () {
    final d = dispatcherFor(CounterActor());
    final reply = d.dispatch('(nonexistent_method 1)');
    expect(reply, contains('Function not found: nonexistent_method'));
  });

  test('a throwing handler is turned into a diagnostic, not a crash', () {
    final d = dispatcherFor(CounterActor());
    // increment with a non-integer arg makes int.parse throw.
    final reply = d.dispatch('(increment not_a_number)');
    expect(reply, startsWith('(error'));
    expect(reply, contains('increment:'));
  });

  test('commands exposes the registered names (proxy/dispatch mirror)', () {
    final d = dispatcherFor(CounterActor());
    expect(
      d.commands,
      containsAll(['increment', 'update', 'describe', 'ping']),
    );
  });
}

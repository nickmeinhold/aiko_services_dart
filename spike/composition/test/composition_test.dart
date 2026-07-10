import 'package:composition_spike/composition.dart';
import 'package:test/test.dart';

void main() {
  group('P1 — multi-interface flatten onto one object (the Category acid test)',
      () {
    test('Category exposes Actor, Service, Hooks AND Dependency behaviour on '
        'one shared self', () {
      final c = Category(Context('cat-0'));

      // Service slice
      expect(c.serviceName, 'cat-0');
      // Hooks slice (reached via Service cascade)
      expect(c.hooks, contains('default-hook'));
      // Actor slice
      c.run();
      expect(c.share['running'], true);
      // Dependency slice — same object
      expect(c.getType(), 'absent');
      // Category's own methods
      c.add('entry-a', 42);
      expect(c.entries['entry-a'], 42);

      // All state lives on ONE self — Actor's share sees Category's write.
      expect(c.share['source'], 'category');
    });
  });

  group('P3 — override precedence (concrete beats abstract, later mixin wins)',
      () {
    test('ActorMixin.describe overrides ServiceMixin.describe', () {
      final c = Category(Context('cat-1'));
      c.run();
      // If precedence were wrong we would get "Service(cat-1)".
      expect(c.describe(), 'Actor(cat-1, ready)');
    });
  });

  group('P4 — idempotent per-slice init (the diamond guard)', () {
    test('Service initializes exactly once when reached via two branches', () {
      final d = DiamondNode(Context('diamond-0'));
      // Actor and Registrar both cascade initService; the call_init guard
      // must short-circuit the second path.
      expect(d.serviceInitCount, 1);
      expect(d.registered, isEmpty); // Registrar slice still initialized
      expect(d.share['lifecycle'], 'ready'); // Actor slice still initialized
    });
  });

  group('P5 — absence is first-class', () {
    test('a Dependency with null service is a normal state, not an error', () {
      final absent = Category(Context('cat-2'));
      expect(absent.service, isNull);
      expect(absent.getType(), 'absent');
      expect(absent.isType('absent'), true);

      final present = Category(Context('cat-3'), serviceFilter: 'x')
        ..service = Object();
      expect(present.getType(), 'present');
    });
  });

  group('P2 — impl swap is a compile-time class choice, not runtime reflection',
      () {
    test('a fake Dependency slice is just a different composed class', () {
      final t = TestCategory(Context('cat-4'));
      expect(t.serviceName, 'cat-4'); // real Service slice
      expect(t.getType(), 'fake'); // swapped Dependency slice
    });
  });
}

import 'package:composition_spike/composition.dart';
import 'package:test/test.dart';

void main() {
  group('P1 — multi-interface flatten onto one object (the Category acid test)',
      () {
    test(
        'Category exposes Actor, Service, Hooks AND Dependency behaviour on '
        'one shared self', () {
      final c = Category(Context('cat-0'));

      // Service slice
      expect(c.serviceName, 'cat-0');
      // Hooks slice (reached via Service cascade)
      expect(c.hooks, contains('default-hook'));
      // Actor slice
      c.run();
      expect(c.share['running'], true);
      // Dependency slice — same object. A Category IS a Dependency, so it
      // reports the 'category' kind and answers to both (see the discriminator
      // group below). Whether its service was discovered is a separate,
      // separately-named question.
      expect(c.getType(), 'category');
      expect(c.isDiscovered, false);
      // Category's own methods
      final entry = Dependency(Context('entry-a'));
      c.add('entry-a', entry);
      expect(c.entries['entry-a'], same(entry));

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

  group('P4-deep — the HyperSpace two-level diamond', () {
    test(
        'Actor (and Service) initialize exactly once when reached via '
        'Category AND directly', () {
      final h = HyperSpace(Context('hs-0'));
      // Category-init cascades to Actor; the constructor also inits Actor
      // directly. Both paths must collapse to a single Actor init.
      expect(h.actorInitCount, 1);
      expect(h.serviceInitCount, 1); // Service, one level deeper, also once
      // All slices present on the one object:
      expect(h.serviceName, 'hs-0'); // Service
      expect(h.share['lifecycle'], 'ready'); // Actor
      expect(h.getType(), 'category'); // Category refines Dependency
      h.create('/cat-a');
      // Not merely non-null: create() used to store a bare `{}` that this
      // assertion's comment called a Category.
      expect(h.entries['/cat-a'], isA<CategoryMixin>());
    });
  });

  group('P5 — absence is first-class', () {
    test('a Dependency with null service is a normal state, not an error', () {
      final absent = Dependency(Context('dep-2'));
      expect(absent.service, isNull);
      expect(absent.isDiscovered, false);

      final present = Dependency(Context('dep-3'), service: Object());
      expect(present.isDiscovered, true);
      // Discovery does not change what the entry IS.
      expect(present.getType(), 'dependency');
    });
  });

  group('Entry discrimination — parity with Python, then the typed form', () {
    // Python, verified by running it against geekscape/aiko_services @ 702b896:
    //   Category.__mro__ contains Dependency
    //   issubclass(Category, Dependency) is True
    // so `Entry` is NOT a disjoint `Category | Dependency` union. Every entry
    // is a Dependency; some are additionally Categories. A sealed hierarchy
    // with the two as siblings would contradict this.
    test('a Category answers to BOTH kinds, as CategoryImpl.is_type does', () {
      final category = Category(Context('cat-5'));
      expect(category.isType('Category'), true);
      expect(category.isType('category'), true, reason: 'argument is lowered');
      expect(category.isType('dependency'), true,
          reason: 'CategoryImpl.is_type falls through to the Dependency slice');
    });

    test('a plain Dependency answers to one kind only', () {
      final dependency = Dependency(Context('dep-5'));
      expect(dependency.isType('dependency'), true);
      expect(dependency.isType('Category'), false);
    });

    test('the typed discriminator replaces is_type(String) at nine Python '
        'call sites', () {
      final entries = <String, DependencyMixin>{
        'a-category': Category(Context('cat-6')),
        'a-dependency': Dependency(Context('dep-6')),
        'a-hyperspace': HyperSpace(Context('hs-6')),
      };
      // `entry.is_type("Category")` becomes `entry is CategoryMixin`:
      // compile-checked, and it cannot silently answer the wrong question.
      final categories =
          entries.entries.where((e) => e.value is CategoryMixin).map((e) => e.key);
      expect(categories, containsAll(['a-category', 'a-hyperspace']));
      expect(categories, isNot(contains('a-dependency')));
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

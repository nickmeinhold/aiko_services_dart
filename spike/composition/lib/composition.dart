/// Composition spike — proving Aiko's Python `compose_instance` / `call_init`
/// composition system maps to idiomatic Dart mixins.
///
/// Python reference (aiko_services/main/component.py + context.py):
///   * An `Interface` is a pure-abstract class that registers ONE default
///     implementation string. `compose_class` builds a synthetic
///     "FrankensteinClass" and COPIES the concrete methods off each impl onto
///     it (concrete-beats-abstract precedence) — runtime emulation of mixins.
///   * `context.call_init(self, "Actor", context)` runs each implementation's
///     `__init__` against the ONE shared `self`, guarded by an idempotent
///     `is_initialized` flag so a shared ancestor inits once through a diamond.
///
/// Dart already HAS the trait system Python emulates. This file maps each
/// Python mechanism to its native Dart equivalent and the test proves the
/// mapping preserves every load-bearing property.
library;

// ─────────────────────────────────────────────────────────────────────────
// Context — the single init argument (mirrors context.py `ContextService`).
// Carries shared framework fields so constructors take ONE argument, plus the
// idempotent-init ledger that replaces Python's `initialized_<name>` attrs.
// ─────────────────────────────────────────────────────────────────────────
class Context {
  final String name;
  final Set<String> _initialized = {};

  Context(this.name);

  bool isInitialized(String slice) => _initialized.contains(slice);
  void setInitialized(String slice) => _initialized.add(slice);
}

/// Faithful port of `context.call_init`: run a slice's initializer exactly
/// once, keyed by name. This is the diamond guard — a shared ancestor reached
/// through two branches initializes a single time.
mixin CallInit {
  void callInit(Context ctx, String slice, void Function() init) {
    if (!ctx.isInitialized(slice)) {
      init();
      ctx.setInitialized(slice);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────
// The interface hierarchy, mirroring the REAL Python graph:
//
//   Service(ServiceProtocolInterface, Hooks)   → Service needs Hooks
//   Actor(Service)                             → Actor needs Service
//   Dependency(Interface)                      → standalone; service may be null
//   Category(Actor, Dependency)                → the acid test (two branches)
//
// Each Python `Interface` + its `Impl` becomes ONE Dart mixin: the abstract
// methods are abstract mixin members, the impl body is the concrete method.
// `on` constraints encode "needs" edges; `_initX` methods are the per-slice
// constructors mixins can't declare.
// ─────────────────────────────────────────────────────────────────────────

/// Hooks interface + impl (a leaf slice Service depends on).
mixin HooksMixin on CallInit {
  final List<String> hooks = [];

  void initHooks(Context ctx) => callInit(ctx, 'Hooks', () {
        hooks.add('default-hook');
      });

  void addHook(String name) => hooks.add(name);
}

/// Service interface + impl. Real Service = ServiceProtocolInterface + Hooks,
/// so ServiceMixin `on HooksMixin` and cascades its init.
mixin ServiceMixin on CallInit, HooksMixin {
  late String serviceName;
  int serviceInitCount = 0; // instrument: proves the diamond guard works

  void initService(Context ctx) => callInit(ctx, 'Service', () {
        initHooks(ctx); // cascade — mirrors ServiceImpl reaching Hooks
        serviceName = ctx.name;
        serviceInitCount++;
      });

  // Concrete default. Overridden by ActorMixin below → proves P3 precedence.
  String describe() => 'Service($serviceName)';
}

/// Actor interface + impl. Real Actor(Service); ActorImpl.__init__ first line
/// is `call_init(self, "Service", ...)`.
mixin ActorMixin on CallInit, HooksMixin, ServiceMixin {
  late Map<String, Object> share;

  void initActor(Context ctx) => callInit(ctx, 'Actor', () {
        initService(ctx); // cascade to Service (which cascades to Hooks)
        share = {'lifecycle': 'ready', 'running': false};
      });

  // Overrides ServiceMixin.describe — later mixin wins in linearization.
  @override
  String describe() => 'Actor($serviceName, ${share['lifecycle']})';

  void run() => share['running'] = true;
}

/// A SECOND Service-consuming branch, used only to construct a genuine diamond
/// (Actor + Registrar both `on ServiceMixin`) so the idempotency guard is
/// exercised, not just asserted.
mixin RegistrarMixin on CallInit, HooksMixin, ServiceMixin {
  late Set<String> registered;

  void initRegistrar(Context ctx) => callInit(ctx, 'Registrar', () {
        initService(ctx); // second path to Service — must NOT re-init
        registered = {};
      });
}

/// Dependency interface + impl. Real Dependency(Interface) — NOT a Service.
/// `service` is nullable: absence is a first-class, normal state (P5).
mixin DependencyMixin on CallInit {
  Object? service; // null = not discovered / absent — a normal value
  Object? serviceFilter;

  void initDependency(Context ctx, {Object? service, Object? serviceFilter}) =>
      callInit(ctx, 'Dependency', () {
        this.service = service;
        this.serviceFilter = serviceFilter;
      });

  String getType() => service == null ? 'absent' : 'present';
  bool isType(String type) => getType() == type;
}

// ─────────────────────────────────────────────────────────────────────────
// The acid test: Category IS both an Actor and a Dependency, flattened onto
// ONE object. Mirrors `class Category(Actor, Dependency)` and
// `CategoryImpl.__init__` calling `call_init("Actor")` then
// `call_init("Dependency", service_filter=...)`.
// ─────────────────────────────────────────────────────────────────────────
class Category
    with CallInit, HooksMixin, ServiceMixin, ActorMixin, DependencyMixin {
  final Map<String, Object?> entries = {};

  Category(Context ctx, {Object? serviceFilter}) {
    initActor(ctx); // Actor slice → Service → Hooks
    initDependency(ctx, serviceFilter: serviceFilter); // Dependency slice
    share['source'] = 'category'; // Category adds to Actor's share, like Python
  }

  void add(String name, Object? entry) => entries[name] = entry;
  void remove(String name) => entries.remove(name);
}

/// Diamond acid test: two branches (Actor + Registrar) both cascade to Service.
/// Proves `call_init`'s idempotency — Service initializes exactly once.
class DiamondNode
    with CallInit, HooksMixin, ServiceMixin, ActorMixin, RegistrarMixin {
  DiamondNode(Context ctx) {
    initActor(ctx); // path 1 to Service
    initRegistrar(ctx); // path 2 to Service — guard must short-circuit
  }
}

// ─────────────────────────────────────────────────────────────────────────
// P2 (impl swapping) is never used dynamically in the Python framework — every
// `compose_instance` call passes no `impl_overrides`. A "test implementation"
// is therefore just a DIFFERENT composed class, not runtime reflection. This
// fake proves swapping a slice's impl is a compile-time class choice.
// ─────────────────────────────────────────────────────────────────────────
mixin FakeDependencyMixin on CallInit {
  Object? service;
  void initDependency(Context ctx, {Object? service, Object? serviceFilter}) =>
      callInit(ctx, 'Dependency', () => this.service = 'FAKE');
  String getType() => 'fake';
  bool isType(String type) => type == 'fake';
}

class TestCategory with CallInit, HooksMixin, ServiceMixin, FakeDependencyMixin {
  TestCategory(Context ctx) {
    initService(ctx);
    initDependency(ctx);
  }
}

# Reading notes — aiko_services v0.7 `concepts/actor.md`

Read 2026-08-25 against the Dart port (task #2270). Source doc version 0.6,
last_updated 2026-08-01, generated from `src/aiko_services/main/actor.py`.

## What an Actor IS

`Actor` is-a `Service`. To Service's discovery + message topics it adds exactly
four things:

1. **The mailbox discipline** — every command, remote OR local, is wrapped as a
   `Message` and posted to a mailbox; the event loop drains and invokes them
   **one at a time**. *Serialization is the concurrency model* — the framework's
   stated alternative to locks.
2. **Built-in shared state** — `self.share` (`{lifecycle, log_level, running}`)
   published by an `ECProducer`.
3. **A per-Actor logger** with a remotely adjustable level.
4. **Message hooks** — `ACTOR_HOOK_MESSAGE_IN` (posted) and
   `ACTOR_HOOK_MESSAGE_CALL` (about to invoke).

## The wire contract (what the Dart port MUST conform to)

```
namespace/host/pid/sid/in       (method_name argument ...)
```

Publish an S-expression to `topic_in`; the event loop invokes
`self.method_name(*arguments)`. **No reply unless the method itself publishes
one — one-way messaging is the default.** Request/response (`do_request()`,
`(item_count N)` / `(response ...)`) is layered ON TOP by Discovery, not built in.

Two mailboxes: `control` (registered first, therefore drained first; method
names prefixed `control_`) and `in` (application commands). Mailbox name is
`f"{name}/{service_id}/{topic}"` — unique per Actor within a Process, which is
what allows multiple Actors per Process.

`ActorTopic` names the categories: `control`, `state`, `in`, `out`.

**Uniform local/remote:** a local call through a proxy takes the identical path.
`ActorImpl.proxy_post_message()` converts a method call into `_post_message()`.
So `actor.test(1)` does nothing until `aiko.process.run()` starts the loop.

```
 remote:  MQTT (test 1) --> _topic_in_handler --> _post_message(IN, ...)
 local :  actor.test(1)  --> proxy_post_message -> _post_message(IN, ...)
                                                       |
                                            mailbox "name/sid/in"
                                                       |
                                       event loop (single thread)
                                                       |
                                             Message.invoke()
                                                       |
                                                self.test(1)
```

`Message` captures `(target_object, command, arguments, target_function)`.
`invoke()` resolves the command with `__getattribute__` UNLESS an explicit
`target_function` was supplied — the proxy path supplies one, skipping
re-resolution. **This is exactly the seam `lib/src/dispatch/message_dispatcher.dart`
already implements mirrors-free.**

## THE DESIGN LICENCE — debts Andy's own doc names

Nick's ratified mandate (2026-08-25) is that the framework port be **designed,
not just ported**. The doc's own "Implementation notes" and "Current limitations
and roadmap" sections enumerate where the Python is knowingly unfinished. These
are where Dart should start from the roadmap's ENDPOINT rather than replicate
the debt — none of them require changing the wire:

| # | Python's stated debt | Dart's opportunity |
|---|---|---|
| 1 | `Message.invoke()` failures are logged **but swallowed**; the doc notes `except Exception` was meant to be `except TypeError` and "a catch of everything hides bugs in the target function" | Surface failures explicitly. Nick's own directive (dir-id 3f6b): *silence reads as success* — a silently-swallowed invocation is indistinguishable from a broken system. An error `Stream` costs nothing on the wire. |
| 2 | **Delayed delivery is approximate and wrong**: the timer starts only when the queue transitions from empty, and when it fires it drains the ENTIRE queue regardless of each entry's deadline — so longer-delayed entries fire EARLY | Dart `Timer` per deadline, or a proper priority queue keyed on deadline. Trivially correct in Dart; no wire impact. |
| 3 | `ActorImpl.run()` sets `share["running"]` by **direct dict assignment, not `ec_producer.update()`** — so remote consumers are never notified of the running-state change | Route every share mutation through the one door. This is Nick's dir-id 6b6a (*the single door is the MUTATOR, not the route*) applied verbatim. |
| 4 | Priority is only "first mailbox drained first" — no true priority mailbox (roadmap wants one for e.g. `(raise_exception ...)` on init failure) | Design the mailbox as an ordered structure from the start. |
| 5 | Roadmap: consolidate `share["lifecycle"]` + `share["running"]` into `share["state"]`; `is_running()` becomes `get_state()` | Start with the consolidated state machine. A sealed Dart enum/sealed class makes the states exhaustive. |
| 6 | Multiple Actors per Process not yet first-class (wants framework-generated unique names + shared ECConsumer instances) | The mailbox naming scheme already supports it; make it first-class in Dart. |

## THE OPEN DESIGN QUESTION for Dart

Python needs an explicit mailbox because its threads are preemptive and share
state. **Dart's event loop already serializes** — so is the mailbox redundant?

**No, and the reason is worth pinning:** Dart serializes *synchronous* execution,
but an `async` handler yields at every `await`, so a second message CAN begin
before the first completes and observe half-mutated state. Dart gives you
one-at-a-time *scheduling* for free; it does NOT give you one-at-a-time
*completion*. The mailbox is what turns the second into a guarantee.

So the mailbox earns its place in Dart for THREE reasons, none of which is
locking:
  * completion-ordering across `await` points (the real one)
  * uniform local/remote call path (behaviour must not depend on caller location)
  * deferral + delayed commands + priority ordering

Do NOT hand-wave this as "Dart's event loop makes Actors free". It makes the
*sync* case free and the *async* case a trap.

## Open questions to resolve before/while building

- `Interface.default("Actor", "...ActorImpl")` — the interface→impl registry.
  Already mapped in `docs/interface-inventory.html`; confirm the Dart shape
  (factory registry vs plain constructors) against `service.md`.
- `compose_instance()` / `context.call_init(self, "Actor", context)` — the
  composition seam. Already mapped in `docs/composition-mapping.html`; see
  memory `concept_mixin_vs_collaborator_boundary` (IS-A Interface-slices ->
  mixins, HAS-A collaborators -> plain fields).
- Leases attached to Messages — flagged as an OPEN design question in Andy's own
  source. Do not invent semantics here; leave the seam.
- `share`/ECProducer is a real dependency of Actor. Read `share.md` before
  building Actor, not after.

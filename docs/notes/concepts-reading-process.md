# Reading notes — aiko_services v0.7 `concepts/process.md`

Read 2026-08-25 (task #2270). Process is the runtime singleton everything hangs
off — the third leg of the Service/Actor/Process triad.

## Responsibilities

Process gives the framework for ONE operating system process:

- Owns the Message connection (MQTT)
- Pumps incoming messages onto the event loop
- Tracks the Registrar through the bootstrap topic
- Holds the table of Services hosted in this process (none, one, or MANY)
- Derives the process-level topic namespace `{namespace}/{host}/{pid}/…`

NOT to be confused with `ProcessManager`, which makes and destroys *other* OS
processes. Process is the framework runtime *inside* each one.

## Public surface

```python
aiko = ProcessData                       # class-level singleton data
aiko.process = process_create()          # ProcessImplementation singleton
aiko.message                             # Message instance (MQTT or Castaway)
aiko.logger(name, log_level=None, ...)   # AikoLogger factory (console + MQTT)
aiko.connection                          # Connection state ladder
aiko.registrar                           # {"topic_path","version","timestamp"} | None

aiko.process.run(loop_when_no_handlers=False, mqtt_connection_required=True)
aiko.process.initialize(mqtt_connection_required=True)   # idempotent
aiko.process.add_service(service)        # -> service_id (ASSIGNS topic_path)
aiko.process.remove_service(service_id)
aiko.process.add_message_handler(handler, topic, binary=False)
aiko.process.remove_message_handler(handler, topic)
aiko.process.set_last_will_and_testament(topic_lwt, payload_lwt, retain_lwt)
aiko.process.set_registrar_absent_terminate()
```

## The bootstrap ordering constraint (load-bearing)

> "Process is deliberately **not** an Interface/Component — it is a plain
> singleton created before the composition machinery can run (the ContextManager
> holding `(aiko, message)` is set up *by* `initialize()`)."

This is a genuine chicken-and-egg, not sloppiness: the composition machinery
needs a context, and the context is created by Process. So Process cannot itself
be composed. Any Dart design must preserve this ordering — **Process is
constructed first, everything else is composed against it.**

Note also: `add_service()` is what ASSIGNS `service_id` and `topic_path`
(see `concepts-reading-service.md`) — so a Service has no identity until the
Process admits it. Identity flows Process -> Service, never the reverse.

Environment-controlled: `AIKO_LOG_LEVEL_MESSAGE`, `AIKO_LOG_LEVEL_PROCESS`,
`AIKO_LOG_MQTT`, plus `AIKO_MQTT_HOST`/`AIKO_MQTT_PORT`/namespace/TLS resolved by
`utilities/configuration`.

## DESIGN LICENCE

The `aiko` global is a **mutable process-wide singleton** that every module
imports. It is load-bearing (the bootstrap ordering above is real) but the
GLOBAL part is a Python packaging convenience, not a requirement of the design.

The distinction worth holding: *"there is exactly one runtime per OS process"* is
the real invariant. *"...and it is reachable as a mutable module-level global
from anywhere"* is the implementation of that invariant, and it is the part that
makes tests share state and makes two runtimes in one process impossible.

Dart can honour the invariant without the global — an explicit runtime object
passed through construction, or a `Zone`-scoped current-runtime. That also buys
what the Python roadmap explicitly wants and cannot easily have: multiple Actors
per Process as a first-class feature, and testability without process teardown.

**Do not decide this unilaterally.** It is the single biggest structural fork in
the port and it touches every file. Surface it to Nick as a priced fork before
building on either arm — it is exactly the kind of call the "designed, not
ported" mandate authorises AND the kind whose blast radius makes it Nick's.

## Still to read before designing

- `share.md` — Actor depends on `self.share` / ECProducer; do not design Actor
  without it.
- `event.md` — the event loop + timers the mailbox drains on.
- `registrar.md` — bootstrap wire protocol + startup sequence diagram.
- `message.md` — the MQTT/Castaway abstraction (note: "Castaway" implies a
  non-MQTT transport already exists in the reference, relevant to #3240/#2268).

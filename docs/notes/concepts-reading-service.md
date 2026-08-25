# Reading notes — aiko_services v0.7 `concepts/service.md`

Read 2026-08-25 (task #2270). `Service` is Actor's parent — read this BEFORE
building Actor.

## The topic conventions (WIRE CONTRACT — conform exactly)

From the assigned topic path, five conventional topics are derived:

```
namespace/hostname/process_id/service_id            # topic_path
├── .../control     # framework control-plane (e.g. ECProducer commands)
├── .../in          # application commands in
├── .../out         # application responses / events out
├── .../log         # log records
└── .../state       # shared state changes (ECProducer publishes here)
```

This is a five-way fan-out from ONE path, and it is pure structure — a perfect
fit for a Dart value type with named accessors rather than string concatenation
at each call site. `ActorTopic` (`control`/`state`/`in`/`out`) names the subset
Actor routes on.

## Public API

`class Service(ServiceProtocolInterface, Hooks)`

| Operation | Effect |
|---|---|
| `add_message_handler(handler, topic, binary=False)` | Subscribe handler to an MQTT topic (delegates to the Process) |
| `remove_message_handler(handler, topic)` | Unsubscribe |
| `set_registrar_handler(handler)` | Callback for Registrar `found` / `absent` transitions |
| `registrar_handler_call(action, registrar)` | Invoked by the Process on Registrar state change |
| `run()` | `ServiceImpl` **raises SystemExit** — "currently only supported by Actor" |
| `stop()` | Terminate the owning Process |
| `add_tags` / `add_tags_string("a=1,b=2")` / `get_tags_string()` | Tag management |

## Descriptive data structures (map to Dart value types)

```python
topic_path     = ServiceTopicPath("namespace", "host", "process_id", "service_id")
service_fields = ServiceFields("topic_path", "name",
                     ServiceProtocol(SERVICE_PROTOCOL_AIKO, "test", "0"),
                     "transport", "owner", "tags")
```

## Behavioural facts worth pinning

- **Registration is a constructor side-effect.** `ServiceImpl.__init__()` adds
  the Service to `aiko.process` (unless `register_service=False`), which is what
  ASSIGNS `service_id` and `topic_path`. So identity is not known until
  registration — a real ordering constraint for the Dart design.
- **`protocol=None` means private.** A Service with no protocol is *not*
  announced to the Registrar; it stays local to its Process. This is the
  visibility switch.
- Construction goes through the Context / Component machinery:
  `service_args(name, implementations, parameters, protocol, tags, transport)`
  then `compose_instance(ServiceTestImpl, init_args)`.

## DESIGN LICENCE noted here

`Service.run()` raising `SystemExit` is a Python-ism standing in for "this
Interface slice is not implemented at this level". In Dart that is what the type
system is FOR — `run()` belongs on Actor, not on Service, or Service is abstract
over it. Do not port a runtime throw where a compile-time constraint expresses
the same fact. (Sibling of the actor.md licence table; same mandate.)

# Reading notes — aiko_services v0.7 `concepts/share.md`

Read 2026-08-25 (task #2270). Actor depends on this — `self.share` and
`self.ec_producer` are created for every Actor automatically.

## What Share IS

A Service owns a dictionary (its *share*); an **ECProducer** publishes every
change. Any number of **ECConsumers** hold a converging local replica. "EC" =
Eventual Consistency: consumers sync with a **snapshot**, then apply incremental
add/update/remove. A **Lease** protects the subscription and is auto-extended
while the consumer lives.

Every Actor gets `self.share` + `self.ec_producer` free, so `lifecycle`,
`log_level` and any application state appear live in the Dashboard with zero
extra code. Category stores its entries in the share. The Registrar is observed
through `ServicesCache` (also in share.py).

## WIRE CONTRACT (conform exactly)

Published to `<topic_path>/control` — plain S-expressions, so `mosquitto_pub`
exercises it directly:

```
(add <key> <value>)          # add a key
(update <key> <value>)       # update a key
(remove <key>)               # remove a key
(share <topic> <lease> *)              # subscribe, all keys
(share <topic> <lease> (lifecycle x))  # subscribe, filtered
```

Note this rides the **`control`** topic, not `in` — it is framework
control-plane, which is exactly why `ActorImpl` registers the `control` mailbox
FIRST (priority draining). The two facts are the same fact.

## Composition shape (confirms existing memory)

```python
self.share = {"lifecycle": "ready", "temperature": 25}
self.ec_producer = ECProducer(self, self.share)

self.cache = {}
self.ec_consumer = ECConsumer(self, 0, self.cache, producer_topic_control, filter="*")
self.ec_consumer.add_handler(self.change_handler)
```

ECProducer/ECConsumer are constructed and held as FIELDS, taking `self` as a
collaborator. This is verbatim confirmation of `concept_mixin_vs_collaborator_boundary`:
**HAS-A collaborators are plain fields, never mixins.** Actor IS-A Service
(mixin/extends); Actor HAS-A ECProducer (field).

## DESIGN LICENCE

`self.share` is an untyped `dict` whose keys are a mix of framework-reserved
(`lifecycle`, `log_level`, `running`) and arbitrary application state. In Dart
that is two different things wearing one type:

- the framework slice is a **closed, known set** — it wants a typed object with
  a sealed lifecycle state (and the roadmap already wants `lifecycle`+`running`
  merged into one `state`)
- the application slice is genuinely **open** — it wants a map

Conflating them is what forces `ec_producer_change_handler` to string-match
`log_level` and silently ignore invalid values. Separating them lets the
framework slice be exhaustive and the app slice stay free, **without changing
the wire** — both still serialise to the same `(update <key> <value>)`.

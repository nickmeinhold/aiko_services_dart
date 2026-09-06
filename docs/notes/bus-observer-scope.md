# Scope — the Dart bus observer

> **Status, 2026-09-06: built, and all six verbs are evidenced.**
> `example/bus_observer.dart` + `tool/observer_acceptance.sh` (12 assertions, green
> against a live island). What it found — including a protocol-version defect in our
> own transport that our logs showed no trace of — is in
> [`bus-observer-findings.md`](bus-observer-findings.md).
>
> **One claim below was wrong and is corrected in place**: discovery is NOT the same
> mechanism as the share protocol. See the marked paragraph.

Scoped 2026-09-04 against `geekscape/aiko_services` at the checkout in
`~/git/orgs/aiko/aiko_services`, and against the live island compose in
`aiko-chat-island`. Every line reference below was read, not recalled.

The observer is the first Dart process that joins a real island's bus. It is **not** a
component of an island — it is a process you *point at* one. Nothing depends on it, so
it can be wrong in production without costing anything, which is the entire reason to
build it first.

## The capability invariant

A Dart process can:

1. **connect** to a live island's broker,
2. **discover** the running ChatServer through that island's registrar,
3. **subscribe** to the ChatServer's `channel_list` eventually-consistent share,
4. **receive** the snapshot and subsequent deltas, and reconcile them into a local map,
5. **leave** without the Python side logging anything unusual, and
6. **recover** — reconnect and re-sync after the ChatServer restarts under it.

Each verb needs its own evidence. The usual gaps are 2, 5 and 6; 6 is the one most
likely to be quietly missing, because 1–4 all pass on a happy path.

## What the wire actually requires

The scoping question was whether an observer must **register itself** as a service, or
can merely listen. It can merely listen, and that cuts the largest piece out of the
first increment.

**Reaching `ConnectionState.REGISTRAR` does not require registering.** `process.py:324`
`on_registrar()` subscribes to `{namespace}/service/registrar`
(`process.py:91`, `TOPIC_REGISTRAR_BOOT`) and parses a retained
`(primary found <topic_path> <version> <timestamp>)`. On `found` it sets
`aiko.registrar` and moves the connection state to `REGISTRAR` (`:348`). Only
*afterwards*, at `:353-358`, does it push any services **this process has added** to the
registrar. A process that adds none reaches `REGISTRAR` and stays there.

**Discovery is itself a share subscription.** `ServiceDiscovery`
(`discovery.py:90`) wraps `services_cache_create_singleton`, which lives in
`share.py:856` and builds a `ServicesCache` (`share.py:688`) that subscribes to the
registrar's `/out` topic once `is_connected(REGISTRAR)` (`share.py:720-728`).

> **CORRECTION (2026-09-06, on reading `share.py:688-830` to build it).** The sentence
> that followed — "discovery and the channel-list read are the same mechanism pointed
> at two producers, one protocol to implement, used twice" — is **wrong**. They are two
> protocols that share three words. `ServicesCache` does not use `ECConsumer` at all:
> it sends `(share <topic> * * * * *)` to the registrar's `/in` (not a producer's
> `/control`), takes no lease, receives `add` with **six** parameters (not two), listens
> on **two** topics rather than one, and is only complete when a `(sync <our topic>)`
> arrives on the registrar's `/out` *after* the count reaches zero. The full comparison
> is the table in `lib/src/service/services_cache.dart`. Cost of the error: none — it
> was caught by reading the source before writing the code.

**The consumer's reply topic is derived from its own identity.** `share.py:455`:

```python
self.topic_share_in = f"{self.service.topic_path}/{self.ec_producer_topic_control}/{self.ec_consumer_id}/in"
```

So the observer needs a `topic_path` — but that is locally derived
(`{namespace}/{host}/{pid}/{service_id}`), not assigned by the registrar. Cheap.

**The EC wire form**, from `share.py:414-421` and the handler at `:465-502`: send
`(share <topic_share_in> <lease_time> <filter>)` to the producer's control topic;
receive `(item_count N)`, then N × `(add <name> <value>)`, then ongoing
`(update <name> <value>)` / `(remove <name>)` / `(sync)`. The cache is `ready` when
`items_received == item_count` (`:479-480`).

## What has to be built

In dependency order. Each step is observable on the wire before the next is written.

1. **A `topic_path` identity + connection state machine** — `NONE → NETWORK →
   TRANSPORT → REGISTRAR`, driven by the retained registrar announcement. Small; it is
   a subscription and a four-value enum, not the whole of `connection.py`.
2. **A message-handler registry keyed by topic** — the observer needs several
   concurrent subscriptions (registrar `/out`, its own share-in topics) routed
   separately. `MessageDispatcher` dispatches by *command* within one payload; this is
   the layer above it, dispatching by *topic*.
3. **`ECConsumer`** — the handshake above, plus lease refresh, writing into the
   existing `share.dart` tree. This is the substantial one.
4. **A services cache** — ~~`ECConsumer` pointed at the registrar~~, **its own
   registrar-specific protocol** (see the correction above), plus a service filter,
   yielding add/remove callbacks.
5. **A `main()`** that wires 1–4 and prints the channel list.

## What is deliberately NOT in it

- **Service registration and lease-holding.** Established above as unnecessary. This is
  what an `aiko_registrar` replacement would need, and it is the second increment.
- **`ECProducer`.** The observer only reads.
- **The remote proxy — and with it, the reply-shape question.** `do_discovery`
  (`discovery.py:189`) calls `get_service_proxy()` and hands the result to the add
  handler, but the gateway uses that proxy at exactly one site:
  `client.py:192`, `self.chat_server.send_message(...)`. A read-only observer never
  sends, so it never needs a proxy. **This increment therefore does not answer the
  reply-shape / P1 question, and must not be read as evidence about it.**
- **HyperSpace, Category, pipelines, the dashboard.** Not on this path.

## The falsifier

Point it at a live island and print the channel list. Python is the oracle on both
sides: a Python ChatServer produces the share and a Python gateway is already consuming
the same one, so the expected output is a known value, not a guess.

Acceptance, per verb, with the controls that make each check able to fail:

- **discover** — with the ChatServer stopped, the observer must report *not found* and
  keep waiting; it must not print a stale or empty channel list as if it were an answer.
- **receive** — the mirrored map equals what the Python gateway holds for the same
  island. Compare against the gateway's own view, not against a hand-typed list.
- **leave** — after the observer exits, the island's logs show nothing a normal
  disconnect would not produce, and the ChatServer's producer has dropped the lease.
- **recover** — restart the ChatServer under a running observer; it must rebind to the
  new topic path and re-receive the `add`s. `aiko-chat-island`'s
  `spike/probe_restart_removes.py` already validated this behaviour for the Python
  consumer and is the reference for what should happen.

A run that only demonstrates connect-and-print has exercised one of six verbs.

> **Done, 2026-09-06** — `tool/observer_acceptance.sh`, 12 assertions, green. The
> prediction above was half right. Verb 6 (`recover`) was NOT the quietly-missing one;
> it worked first try. `leave` was — and only because its criterion points at the
> ISLAND's logs rather than ours. The observer's own output was clean while every
> unsubscribe was dropping the broker connection (findings note §1).
>
> Two corrections to the criteria themselves:
>
> * **receive** compares against the island's own share, read by an independent
>   `mosquitto_sub` chain, rather than the gateway's view — an island running only the
>   mesh roles has no gateway, and the ChatServer's share is the thing the gateway
>   would itself be reading.
> * **recover** does NOT assert a changed topic path. It often does not change:
>   `docker restart` hands the new ChatServer the same PID inside the container's
>   namespace. That assertion was measuring Docker's PID allocation. What is asserted
>   instead is that the observer noticed the producer leave and established a *fresh*
>   subscription — which is stronger, and is also what keeps the reused path safe.

## Known risks, named before building

- **RESOLVED: the transport spoke MQTT 3.1, the reference speaks 3.1.1.** Not a risk
  named in advance — found by the `leave` criterion. See the findings note §1.
- **No Last Will and Testament in `mqtt_transport.dart`.** Verified: `connect()` sets
  `keepAlivePeriod` and `autoReconnect` and no will topic. The observer does not
  strictly need one (nothing is watching for its death), but the absence propagates
  into the registrar increment, where it is load-bearing.
- **The 86-second SIGSTOP-to-LWT measurement is `unbacked`** — quoted from session
  notes with no artifact in the repo. Re-measure before any design leans on it.
- **`ServicesCache` runs on its own thread** (`share.py:863`,
  `Thread(target=services_cache.run).start()`). Before collapsing that into Dart's
  single-threaded event loop, establish what the thread is buying — a dropped thread
  has already been found to have been keeping the MQTT heartbeat alive elsewhere in
  this port. **Partly answered:** `ServicesCache.run()` (`share.py:832-841`) only calls
  `aiko.process.run()`, and only when `event_loop_start` is set — it is the event loop
  itself, not a concurrent worker beside it. The Dart equivalent is the isolate's own
  loop, so nothing was dropped here. That said, this was read, not measured under load.
- **`do_request` has no correlation id upstream.** Not hit by this increment (no
  requests), but it constrains increment 2.

## Sequencing

This is increment 1 of the path to running an island on Dart. Increment 2 is a Dart
`aiko_registrar` — the first Dart process an island would actually depend on, adding
registration, lease-serving and LWT, swappable by one compose line. The gateway is not
on this path; its aiko surface is only 236 lines and the rest of it is FastAPI, a DB
and a WS hub.

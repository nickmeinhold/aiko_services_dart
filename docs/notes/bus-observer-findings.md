# What the bus observer found

Built 2026-09-06 against a live Python island (`ghcr.io/nickmeinhold/aiko-chat-island:edge`
— mosquitto + `aiko_registrar` + ChatServer, 5 channels) run locally from
`tool/island-rig/compose.dev-ports.yml`. Every measurement below was taken on that
island; none is recalled or inferred.

The premise of this port is that a second implementation makes a difference into a
FINDING rather than a bug. Three findings came out of the first increment, and the
expensive one was invisible from our own output.

## 1. Our MQTT client was speaking 3.1 where the reference speaks 3.1.1

**Severity: real. Every `unsubscribe` cost a dropped connection.**

`mqtt_client`'s protocol default is MQTT **3.1**; paho's — and therefore every Python
aiko service's — is **3.1.1**. Mosquitto logs the difference as `p3` versus `p4`, and
the island's log had both, ours being the odd one out.

The divergence is invisible for CONNECT, PUBLISH and SUBSCRIBE, which is why it
survived being written, reviewed and run. It bites on exactly one message.
UNSUBSCRIBE's fixed-header flags are reserved and MUST be `0b0010`, and
`MqttUnsubscribeMessage.writeTo` sets them *only* under 3.1.1
(`mqtt_client-10.11.11/lib/src/messages/unsubscribe/…:40-44`). Under the default,
mosquitto 2 answers every unsubscribe with `malformed packet` and closes the socket.

Measured, two arms, one variable:

| arm | malformed-packet disconnects |
|---|---|
| probe that unsubscribes | 1 |
| probe that does not | 0 |
| probe that unsubscribes, after `setProtocolV311()` | 0 |

`spike/unsubscribe/probe_unsubscribe.dart` is that probe, kept because it is the
evidence and not the scaffolding.

**The part worth carrying:** *nothing on our side reported this.* `autoReconnect`
reconnected, the observer's own log stayed clean, the channel list still printed, and
all four happy-path verbs passed. The only witness was `docker logs aiko-mosquitto-1`.
The scope note asked for `leave` to be judged by whether "the island's logs show
nothing a normal disconnect would not produce" — the acceptance criterion pointed the
instrument at the other side of the wire, and that is the only reason this was found.

## 2. One `(share ...)` request draws N snapshots, where N is the class chain's depth

**Severity: none for a correct consumer. A trap for a naive one.**

Sending a single share request to a service's `/control` topic returns the complete
snapshot more than once:

| service | class | complete snapshots per request |
|---|---|---|
| `chat_server` | Actor | 1 |
| `channels`, `users` | Category | 2 |
| `chat_space` | HyperSpace | 3 |

Reproducible with `mosquitto_pub` alone, and stable across filters (`lifecycle`,
`entries_count`, `*`) — so it is not an artefact of the probe.

The mechanism: `ECProducerImpl.__init__` registers `_producer_handler` on
`service.topic_control` (`share.py:223`), and it is constructed once per class in the
inheritance chain — `actor.py:237`, `category.py:107`, `hyperspace.py:158`.
`process.py:212-220` keeps handlers in a **list per topic and appends without a
duplicate check**, so all of them fire. Depth of chain = number of replies.

A consumer that treats `(item_count N)` as a frame boundary — resetting its received
counter, as `share.py:471-472` does and as ours does — simply re-arrives at `ready`.
One that accumulates would double- or triple-count. `test/share/ec_consumer_test.dart`
pins the idempotence with a three-burst case.

Not raised upstream: three threads are already queued with Andy. Filed instead.

## 3. Discovery and the share protocol are two mechanisms, not one

`docs/notes/bus-observer-scope.md` recorded that "discovery and the channel-list read
are the same mechanism pointed at two producers — one protocol to implement, used
twice." Reading `share.py:688-830` while building it, that is wrong, and the note has
been corrected. They share three words and differ in everything else — request shape,
destination, `add` arity, leasing, reply topology, and what "complete" means. The table
is in `lib/src/service/services_cache.dart`'s library comment.

Cost of the error: none, because it was caught by reading the source before writing the
code rather than after. It is recorded because the *shape* of the mistake is the
interesting part — two protocols that rhyme at the wire will read as one to anyone who
greps for `(share` and stops.

## Where the six verbs stand

`tool/observer_acceptance.sh`, 12 assertions, all green against a live island. Two
carry negative controls: `discover` with the ChatServer stopped (must print no channel
list *and* must say so — silence reads as success), and `leave` read from the broker's
log rather than ours, which is the arm that caught finding 1.

The expected channel list is derived from the island by an independent instrument
(three `mosquitto_sub` hops: retained announcement → registrar roster → the
ChatServer's own share), never hand-typed, so it cannot drift into agreement with us.

**One assertion had to be replaced for being a check of the wrong thing.** `recover`
first asserted that the producer's topic path *changed* across a restart. It does not
reliably: `docker restart` hands the new ChatServer the same PID inside the container's
namespace, and the topic path is `{namespace}/{host}/{pid}/{service_id}`. That arm was
measuring Docker's PID allocation. It now asserts what recovery actually means — the
observer noticed the producer leave, and established a *fresh* subscription. That reused
path also makes the consumer-id generation load-bearing rather than decorative: with a
constant id, the old and new share-in topics would be the same address.

## Not covered

- **The other interop direction.** A real Python ECConsumer reading a live Dart share
  snapshot still needs a Dart service to point it at (ADR-0002's Actor).
- **Lease expiry.** The 300-second lease is taken, renewed at 80%, and cancelled on
  exit; no run has yet outlived one to watch a renewal land or a lease lapse.
- **Anything the observer does not do.** It registers nothing, serves nothing, sends
  nothing, and never needs a reply — so this increment says **nothing** about the reply
  shape or the `HandlerContext` question, and must not be cited as evidence there.

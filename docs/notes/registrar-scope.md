# Scope — a Dart registrar (increment 2)

> **Status, 2026-09-10: scoped; step 1 landed.** This note began as step 0, written
> before any code. Everything below was read against a pinned ref, not recalled.
>
> **Step 1 is partly done and this note is no longer ahead of the tree.** Confirming the
> "reusable" set found two gaps: `ServiceTopicPath.processPath` / `isProcess` did not
> exist and now do, and `ServicesCache` accepted a negative `(item_count …)` that wedged
> it permanently, which is now refused.
>
> **Two step-1 items remain open, for different reasons.** `ServiceFilter`'s tag matching
> is simply unwritten. Snapshot ADMISSION is harder: a cage-match established over three
> rounds that a consumer cannot tell the registrar's frame from a peer's on ADR-023's
> unauthenticated bus, and that no arrangement of local flags fixes it — each guard
> closed one instance and opened another. That is a design question, tracked separately,
> and deliberately NOT patched further here. See *"Snapshot admission"* below.
>
> **One thing here was measured rather than read, and it found a live defect:** running
> the existing acceptance suite to establish a baseline failed, because the island had
> been serving a roster that did not contain its own ChatServer for 23 hours. See
> *"The island was found broken"* below. Baseline is now green, 14/14.
>
> **Corrected 2026-09-10 (same day):** the LWT section originally claimed Dart could skip
> upstream's disconnect-reconnect. That is wrong *for a registrar* — there are two wills
> with different retain flags and MQTT allows one per connection, so the will must change
> at promotion. Corrected in place, with the reasoning kept rather than deleted.

> **Update, 2026-09-11: step 3 landed, and it was RUN.** The election now drives a real
> bus. Verbs 1, 5 and 6 of the invariant below — elect, announce, retract — are
> demonstrated against a live broker, with a three-arm gate in `verify.sh`.
>
> **The blocker was in the transport, not in the plan.** Of the five effects the election
> emits, two could not be performed at all: `AnnouncePrimary` needs a RETAINED publish and
> `MessageBus.send` had no `retain`; `ClearBootTopic` needs an EMPTY retained publish and
> `send` runs `generate`, which cannot emit zero bytes. Promotion also CHANGES the will,
> which MQTT carries only in a CONNECT packet. All three affordances landed with the
> driver. That is why `RegistrarElection` sat merged and green with zero callers for a
> session — not neglect, an unbuilt layer underneath.
>
> **One risk below is now a number.** "The 2-second election timeout is a race with
> reality" was named and unmeasured. Measured: the live island's retained announcement
> reaches a joining process **6-54 ms** after it subscribes, against a 2000 ms promotion
> timer. Roughly 40x of margin on this broker. Still a race; no longer a guess.
>
> **A signal the reference does not have, forced by the port.** Upstream's
> `on_enter_primary` is one synchronous handler: its first line sets `lifecycle` and its
> last publishes, so a Python peer observing `lifecycle == "primary"` observes a registrar
> that has already announced. Ours cannot be — taking the retained will means reconnecting,
> and a reconnect is an await — so `role` reaches `primary` while the island has not been
> told. Found by a probe killing itself on `role == primary` and catching a broker holding
> the empty `ClearBootTopic` and nothing else. Hence `RegistrarProcess.announcements`,
> which fires when the announcement is actually on the wire.

> **Update, 2026-09-11 (later): GATE A PASSED, 14/14.** `tool/observer_acceptance.sh` —
> the fourteen-assertion suite written for increment 1 — passes **unmodified** against an
> island whose registrar is our Dart process. Verbs 1-6 of the invariant below are all
> demonstrated against the live rig. An island's roster is being served by our code and the
> Python side notices nothing.
>
> **The suite is what told us what was missing.** Its first run against a Dart-registrar
> island scored **8/14**, and every one of the six failures traced to ONE absent capability:
> verb 4. Our registrar kept serving a ChatServer that had stopped. Building the wildcard
> state subscription took it to 14/14. A falsifier that fires and NAMES the gap is worth
> more than one that passes.
>
> **The live ChatServer re-registered without being restarted.** `process.py:353-358`
> re-pushes every service whenever the boot topic says `found`, so the running Python
> process saw our announcement and registered four services with us seconds later. Nothing
> on the island had to be told to switch.
>
> **Two divergences were forced, not chosen** — see the risks section.

Scoped against `geekscape/aiko_services` at **`origin/master` = `3fa546f`** (2026-09-02).
Re-checked 2026-09-11: the oracle tree has since moved to `9dfcabc` and `origin/master` to
`d13cb98`, and `registrar.py` is byte-identical across all three. The file this note reads
is still the file it was written against.

**Oracle hygiene, because the local checkout is somebody's working tree.**
`~/git/orgs/aiko/aiko_services` currently sits on branch `fix/services-iterator-iter`
with eight local branches and an untracked `uv.lock`. Before reading a line of it, this
was established rather than assumed:

```
registrar.py: HEAD == origin/master, byte-identical
git log 702b896..origin/master -- registrar.py  ->  empty
```

So the file is unchanged since the port last read it, and which branch the tree happens
to be on does not matter *for this file*. It would matter for others.

*(The inherited task says `registrar.py` is 413 lines. It is 417 on every ref checked.
Trivial, and recorded only so the next reader does not think they have a different
file.)*

---

## The capability invariant

An **island** can:

1. **elect** our process as its primary registrar, from cold start,
2. **accept** service registrations and deregistrations on its `/in`,
3. **serve** the roster to a requester that asks for it,
4. **notice** a service dying, without that service saying anything,
5. **announce** itself so joining peers find it, and
6. **retract** that announcement when it dies, without saying anything.

Verbs 4 and 6 are the two an island actually *depends on*, and both are things that
happen when nothing sends a message. Verb 1 is the one the inherited plan omits
entirely. As with increment 1, each verb needs its own evidence — and 1, 4 and 6 are
where a happy-path run proves nothing.

---

## Three responsibilities the inherited plan does not mention

The task description (claude-tasks #3994) lists registration, the producer half of the
share protocol, the retained primary announcement, LWT, and lease serving. Reading the
file turns up three more, and one of them is a precondition for everything else.

### 1. The primary election is not optional

`StateMachineModel` (`registrar.py:142-199`) — `start → primary_search →
{secondary | primary}`, with `primary_failed` returning either back to `primary_search`.

This is load-bearing rather than decorative: **`(primary found ...)` is published in
exactly one place, `on_enter_primary` (`:182-197`).** A process that does not run the
election never announces itself, so verb 5 is downstream of verb 1. Entry to `primary`
comes from one of two triggers:

* `_registrar_handler("absent")` while in `primary_search` (`:277-279`) — the retained
  boot topic says nobody is primary; or
* `primary_search_timer` firing after `_PRIMARY_SEARCH_TIMEOUT = 2.0` seconds with the
  state still `primary_search` (`:171-176`) — nobody answered.

`secondary` is reachable (`_registrar_handler("found")`, `:272-275`) and, for our
purposes, is a state that does almost nothing: a secondary serves no roster and the
header's own To Do ("Secondary Registrar subscribe to primary Registrar and update
`self.history`") says the interesting part is unbuilt upstream.

**Scope call: implement `start → primary_search → primary` and the `primary_failed`
edge. Implement `secondary` as a state we can ENTER and sit in, doing nothing.** That is
the honest port of what upstream actually does, and it keeps a second registrar from
fighting ours. Ordering: `primary_search` is entered from `__init__` via
`transition("initialize")` (`:266`), *after* the handlers are registered (`:261-264`).

### 2. The registrar is the island's LWT *consumer*

`_SERVICE_STATE_TOPIC = f"{get_namespace()}/+/+/+/state"` (`:137`), subscribed at
`:261-262`, handled at `:284-288`: on `(absent)` from a topic ending `/state`, strip the
suffix and `service_remove(topic_path)`.

This is verb 4, and it is how a roster stays true when a service is killed rather than
shut down. **The port has been treating LWT as a thing we must *emit*; here it is a
thing we must *consume*, with a wildcard subscription across the whole namespace.**

It also connects a measured fact to a consequence. The frozen-app-to-LWT window is a
**60-90 second band** (1.5 × keepalive, keepalive=60; two observations, 86 s and 71 s,
bracketing the ceiling — ADR-0002). That band is exactly how long our registrar would
serve a roster naming a service that is already gone. That is upstream's behaviour too,
so it is parity, not a defect — but it should be written down rather than discovered.

And note the interaction with `service_remove`'s process rule (`:381-386`): the LWT
topic is per-**process**, `{ns}/{host}/{pid}/0/state`, so `service_id == "0"` fires the
"remove every service of this process" branch. The two halves are designed together.

### 3. `(history ...)` — protocol V2, and it has a different `add` arity

`services_history` (`:307-328`), reachable from `_topic_in_handler` (`:298-303`).
A `deque(maxlen=4096)` of removed services, replayed newest-first, with
`count == "*"` meaning `_HISTORY_LIMIT_DEFAULT = 16`.

The trap is in the payload. `services_share` emits a **6-field** `add`
(`:341-347`); `services_history` emits an **8-field** one, appending `time_add` and
`time_remove` (`:318-326`). Same command word, two arities, distinguished only by which
request you sent. Our `ServicesCache` table documents the 6-field form as *the* registrar
`add`; that is true of `share` and false of `history`.

**Scope call: implement `history`.** It is ~20 lines, the ring buffer is already implied
by `service_remove`, and leaving it out means a Python dashboard pointed at our registrar
gets silence where it expects a reply — the exact "an island notices nothing" claim this
increment exists to make.

---

## The island was found broken, and that is the first finding

Before writing any of the above into a plan, the existing acceptance suite was run to
establish a baseline. **It failed** — `tool/observer_acceptance.sh` exited 2 at its own
oracle step: *"ORACLE: no chat_server in the roster"*. No Dart was involved; the island
was asked directly.

What was observed, on the wire, with `mosquitto_sub`/`mosquitto_pub` and no Dart:

* `aiko/service/registrar` held a valid retained
  `(primary found aiko/fddd654e4b5a/1/1 2 831255.387865359)` — a registrar, primary,
  answering.
* Asking that registrar `(share <resp> * * * * *)` returned **`(item_count 1)`**: itself,
  and nothing else.
* Meanwhile `aiko-chat-1` had been up 23 hours, healthy, printing its full Category tree
  (`channels`, `users`, five channels). **Running, and invisible.**
* `docker restart aiko-chat-1`, then the identical query: **`(item_count 5)`** — the
  registrar, `chat_server`, `chat_space`, `channels`, `users`.

**The registrar had not lost the services. It never had them.** That is the discriminating
result: if entries had been dropped, restarting the *producer* would not be what fixes it.

The mechanism is a **hypothesis, not a measurement**, and is recorded as one. Consistent
with everything above: the whole compose project restarted ~23 h ago, the registrar's log
shows it could not reach the broker for several seconds at startup
(`Couldn't connect to MQTT server mosquitto:1883`), and a service pushes its registration
**once**, on the `on_registrar` "found" transition (`process.py:353-358`). A ChatServer
that read a *stale* retained `found` naming the previous registrar would have published
its `(add ...)` to a topic path nobody was listening on, reached `REGISTRAR` state, and
never pushed again. That is upstream's own header BUG at `registrar.py:48-50`, from the
other side.

**A SECOND candidate mechanism, added 2026-09-10 and better supported than the first.**
Surfaced by a cage-match reviewer looking at the Last Will work, not by looking at the
island at all.

A will and `autoReconnect` are two mechanisms on one connection with opposite jobs. The
broker publishes `(absent)` when IT notices a drop — for a frozen process that is 1.5 ×
keepalive later, the measured 60-90s band — while the client itself reconnects in
seconds. The registrar subscribes `{ns}/+/+/+/state` and answers `(absent)` by removing
**every service of that process** (`registrar.py:284-288` → `:381-386`).

So the ordering can invert: the ChatServer drops, reconnects, re-reads the retained
`found`, re-pushes its services (`process.py:353-358`) — and only *then* does the late
`(absent)` arrive and evict all five, permanently, with nothing that re-fires.

This fits evidence the first hypothesis did not use: the registrar's own log is full of
`MQTT on_disconnect: will reconnect` lines in the hours before the roster went empty.
Both hypotheses remain unconfirmed, and they are distinguishable — the stale-boot-topic
one predicts the `add` goes to a dead topic path, this one predicts it lands and is then
undone.

Not measured, and it would take a deliberate reproduction to confirm: hand-publish a
retained `found` naming a dead topic path, start a service, and see where its `add` goes.

**Why this belongs in a registrar scope note.** Three things follow:

1. **The baseline is a precondition, not a given.** A run of this suite against a
   silently-degraded island would have "failed" for reasons having nothing to do with our
   code, and the obvious reading — *our registrar broke it* — would have been wrong. The
   suite is now green 14/14 against a restored island. Any future comparison is against
   that, and the check is one `(share ...)` on the wire.
2. **Registration is push-once with no reconciliation, and that is the service's side,
   not ours.** Do not "fix" it in the registrar. But it does mean an empty or partial
   roster is a state a *correct* registrar can be in, so no acceptance assertion may
   treat "roster is complete" as self-evidently our doing.
3. **It is a real answer to "what does an island depend on a registrar for".** Not
   uptime — this registrar had 23 hours of it while the island was functionally
   headless. What depends on it is the *roster being true*, and nothing in the system
   currently notices when it stops being true. Worth offering to Andy alongside the
   duplicate-snapshot finding (claude-tasks #3993), once his queue drains — same channel,
   same rule about not opening a fifth thread.

---

## The reply address is a request parameter — and this decides #3962

Both request-shaped commands take the reply topic as **parameter 0**:

```
(share   topic_response name protocol transport owner tags)   -> services_share
(history topic_response count)                                -> services_history
```

The interface docstrings say it outright (`:204-210`): *"Requests reply via messages to
`topic_response` (s_02 §2), never return values"*.

This is the concrete input the HandlerContext ADR (#3962) has been missing, and it lands
on the side that ADR already chose:

* the reply address is **data in the request**, not structure derived from the topic the
  request arrived on — so a handler signature returning a payload cannot express it;
* there is **no correlation token** anywhere in either command, consistent with the
  already-recorded `do_request` finding. On the sealed two-shape reply address
  (`Uniplex(topic) | Multiplex(topic, token)`), **every registrar request is `Uniplex`.**
  Nothing here exercises `Multiplex`;
* and the reply is **not one message**. `services_share` publishes `item_count`, then N
  × `add`, then a `sync` — a handler that returns *a* reply cannot express it at all.

**One asymmetry worth pinning, because it is easy to get backwards.** The `item_count`
and the `add`s go to the caller's `topic_response`. The closing `(sync topic_response)`
goes to **the registrar's own `topic_out`** (`:350-351`) — broadcast, carrying the
requester's topic as its payload. Our `ServicesCache` already consumes it that way
(`services_cache.dart`'s table: *"replies on two topics"*), so the consumer half proves
the shape; the producer half must reproduce it.

**This does not mean writing the ADR is a prerequisite for starting.** It means the
registrar's `/in` handler is the first real call site the ADR has ever had, and the ADR
should be written *against* it rather than in the abstract — which is precisely the
mistake ADR-0003 made and was dissolved for.

---

## LWT: the registrar must reconnect, and this section previously said otherwise

`mqtt_transport.dart` sets no will (grep for `will`/`lwt` returns only a prose match).
`MessageBus` exposes `connect / subscribe / unsubscribe / send / disconnect` and no way
to declare one. So this is genuinely new surface.

**Upstream's mechanism is a reconnect.** `MQTT.set_last_will_and_testament`
(`message/mqtt.py:200-209`) is:

```python
self._disconnect()
self.wait_disconnected()
self._connect(topic_lwt, payload_lwt, retain_lwt)
```

because paho only accepts `will_set` before `connect` (`mqtt.py:118-120`). So a Python
registrar entering `primary` **drops its broker connection and reconnects**, mid-startup,
every time. That file's own header (`mqtt.py:15-23`) documents the resulting deadlock —
*"when Registrar processed `(primary absent)` message and attempts
`set_last_will_and_testament()`, which causes a `wait_disconnected()` whilst on the MQTT
thread"* — and names the registrar path by name.

> **CORRECTED 2026-09-10, same day, before any code was written against it.** The
> paragraph that stood here said Dart does not have to inherit the reconnect, because
> `mqtt_client` takes the will on the connect message and "our registrar knows its will
> topic and payload before it connects". **The second half is false, and it is false
> specifically for a registrar.** The claim was written after reading `registrar.py` and
> `mqtt.py` and before reading `process.py` — it generalised from the one will it had
> seen.

**There are TWO wills with different topics, different payloads and different retain
flags, and MQTT permits exactly one per connection.**

| | topic | payload | retain |
|---|---|---|---|
| every process, set at startup | `{ns}/{host}/{pid}/0/state` | `(absent)` | **False** (`process.py:169`, position 5 of `mqtt.py:66-74`) |
| a registrar, set on **promotion** | `{ns}/service/registrar` | `(primary absent)` | **True** (`registrar.py:189-190`) |

A registrar starts as an ordinary process holding the first will. It only learns it is
primary later — after the election, which is either a 2-second timeout or an `absent` on
the boot topic. At that moment its will must **change**. `mqtt_client` cannot do that:
assigning `connectionMessage` after `connect()` is silently ignored by the reconnect path
while reading back as though it took (measured). **So the Dart registrar must reconnect at
promotion, exactly as Python does.** Python is not being clumsy; it is doing the only
thing MQTT allows.

**Setting the retained `(primary absent)` will up front, at connect, is not a shortcut —
it is a bug.** A registrar that does so and then loses the election becomes a *secondary*
holding a retained will that says the primary is gone. When that secondary dies, it wipes
a live primary's announcement and blinds every joining peer on the island.

What Dart genuinely does get for free, and should still be recorded: the will **survives
auto-reconnect** without any work, because the connection handler retains the same
`MqttConnectMessage` instance and re-serialises it on each attempt (verified against a
live broker). That property is invisible in the code and would be silently destroyed by
anyone who later moved the configuration after `connect()`, so it wants an acceptance test
that can fail — kill the process *after* a reconnect and assert the will still fires.

The ordering inside `on_enter_primary` (`:185-197`) is not incidental and must be
reproduced:

1. publish `""` retained to `TOPIC_REGISTRAR_BOOT` — clears the *previous* primary's
   retained announcement so this process does not immediately re-read a stale one;
2. set the will to `(primary absent)`, **retained** — which in Dart means tearing down
   the connection and reconnecting with the new will, per the correction above;
3. publish `(primary found <topic_path> <version> <time_started>)`, retained.

Doing 3 before 2 leaves a window where a crash strands a retained `found` naming a dead
process — which is the exact failure the inherited task names as the reason LWT is not
optional here.

---

## What is already built and what is genuinely new

Verified by reading, not by remembering. `lib/` is 2180 lines across 13 files.

| Need | Status |
|---|---|
| `ServiceTopicPath` parse/format, `service_id == "0"` process rule | **exists** — and the process-expansion helper was MISSING; `processPath` + `isProcess` added in step 1 |
| `ConnectionState` machine | **exists** (`connection_state.dart`) — the *client* ladder; the registrar's election is a **different** state machine, not this one |
| `TopicRouter` (dispatch by topic) | **exists** (`topic_router.dart`) — needed for `/in`, the boot topic, and the `+/+/+/state` wildcard |
| `ServiceDetails` / `ServiceFilter` | **exists** (`service_details.dart`) — confirm `filter_by_attributes` semantics match `registrar.py:333` |
| S-expression codec | **exists**, fuzz-verified against CPython |
| `Share` tree, `ShareEvent` | **exists** — the registrar's own share is flat (`aiko_id`, `lifecycle`, `log_level`, `source_file`, `service_count`), depth 1 |
| `MessageBus` fake for broker-free tests | **exists** |
| `ECConsumer` | **exists** — the wrong half |
| **`ECProducer`** | **NEW.** The registrar owns one for its own share (`:257-259`) |
| **`services_share` / `services_history` producer** | **NEW.** Not `ECProducer` — the registrar-specific protocol |
| **LWT in the transport** | **NEW.** No will support at all today |
| **Wildcard `+/+/+/state` subscription + `(absent)` handling** | **NEW** |
| **The election state machine** | **NEW** |
| **The history ring buffer** | **NEW** |

Two things named as "reusable" in the inherited task are listed above as *needing
confirmation* rather than as facts: the `ServiceTopicPath` process helper and
`ServiceFilter`'s match semantics. Neither has been read against `registrar.py:333` yet.
That is step 1 and it is cheap.

---

## Upstream defects: port, fix, or diverge — decide each explicitly

`registrar.py`'s own header names four. A port has to take a position on each, because
"faithful" and "correct" point different ways.

| Upstream BUG (header line) | Position |
|---|---|
| `:46` — `service_count` needs `int()` when the ECProducer updates it | **Fix.** Our `Share` is typed; emitting a string where the reference emits a string-that-should-be-an-int is copying a defect no peer depends on. Verify what actually goes on the wire first. |
| `:48-50` — won't become primary when a stale retained `found` names a dead registrar | **Fix, carefully.** This is the same class as the LWT ordering above and it is a real availability bug: an island cannot recover. Needs its own falsifier (a hand-published stale retained `found`, then start ours). |
| `:52-53` — multiple secondaries all promote when the primary fails | **Do not encounter.** With `secondary` implemented as inert, one Dart registrar cannot exhibit it. Do not claim it fixed. |
| `:44`, `:380` — "if Process, remove *all* Process' Services" | **Appears already implemented** at `:381-386`, so both notes read as stale. Confirm by running it before saying so — a stale-TODO report to Andy is cheap and is only worth sending if measured. |

Also `service_add` (`:353-375`) computes `payload_out` *before* the duplicate check, and
a duplicate `add` is silently dropped with **no re-announcement** on `topic_out`. A
service that re-registers after a registrar restart therefore gets nothing back. Parity
says copy it; note it and move on.

---

## Snapshot admission — a design question, not a bug to patch

Established by cage-match rounds 1-3 against PR #18, and recorded here because the next
session will otherwise re-derive it.

`ServicesCache` receives its snapshot on `{our path}/registrar_share`. That topic is not
secret: it is derived from our own topic path, and the registrar BROADCASTS it in
`(sync <topic_response>)` on its own `/out`. On ADR-023's unauthenticated bus, any peer
can publish a frame onto it.

Three guards were tried and each closed one instance while opening another:

| guard | closed | opened |
|---|---|---|
| refuse a negative count | the permanent wedge | `(item_count 999999)` wedges identically |
| accept a frame only while a request is outstanding | the unsolicited frame | a raced `(item_count 0)` completes instantly, marks the cache confidently-EMPTY, and locks out the real reply |
| close the window on `ready` rather than `loaded` | that lock-out | `(sync …)` is deliberately LATCHED for cross-topic reordering, so a sync arriving first promotes whichever frame completes first |

**Only the first landed.** It is strictly narrowing and adds no new capability. The
others were reverted out of the step-1 PR, because making a frame REPLACE — which the
protocol genuinely requires, since one `(share …)` can draw several snapshots and a
merging consumer keeps keys that have vanished — simultaneously hands an unauthenticated
peer a 20-byte roster wipe that the pre-existing merging code did not have.

**REPLACE is protocol-correct and weaponisable at the same time, and that does not
resolve inside this class.** What closes it lives on the wire: an authenticated sender,
or a reply bound to its request by a correlation token. That is the same gap as the
registrar's unvalidated `topic_response`
([`registrar-findings-for-upstream.md`](registrar-findings-for-upstream.md)) and the same
argument as the HandlerContext ADR — answer it once, across all three.

Until then the consumer merges, exactly as it did before, and the duplicate-snapshot
hazard stays a known, documented divergence rather than a silently-traded one.

## The falsifier — and the inherited acceptance criterion has a hole

The task says the test is *"change one `command:` line"*. That is not achievable as
written, and it is better to say so now than to discover it at the end.

`aiko-chat-island/docker-compose.yml:327-340`:

```yaml
  registrar:
    image: ghcr.io/nickmeinhold/aiko-chat-island:${ISLAND_VERSION:-edge}
    command: ["aiko_registrar"]
```

The `command:` is one line, but the **image is the Python island image** — it contains no
Dart runtime and no compiled binary of ours. Swapping the command alone gives a container
that cannot start. The real swap is `image:` **and** `command:`, which means building and
publishing a Dart registrar image first.

**So the falsifier splits into two gates, and only the second is the claim.**

* **Gate A — the honest cheap proof.** `docker stop aiko-registrar-1`, run the Dart
  registrar on the host against the broker on `127.0.0.1:1883` (the dev-ports overlay
  already publishes it), and require **`tool/observer_acceptance.sh` to pass unmodified**
  — 14 assertions, an existing instrument written before this increment existed, which is
  what makes it a real test rather than one shaped to fit. Plus the ChatServer, which is
  a *Python* service, successfully registering itself with us and being discoverable.
* **Gate B — the actual claim.** A published Dart registrar image, `image:` + `command:`
  changed, `docker compose up`, the island coming up healthy with no Python registrar
  present at all.

Gate A is reachable this increment. Gate B needs a container story
(multi-arch GHCR, per the org's versioned-container default) and should not be folded in
silently.

**Controls, because a registrar that does nothing also produces no complaints:**

* **Must-fail arm for verb 4:** `docker kill` (not `stop`) a registered service and assert
  the roster drops it — *after* first asserting the roster still contains it while the
  service is merely paused. Without both arms, "the roster is right" is unfalsifiable.
* **Must-fail arm for verb 6:** `docker kill` our registrar and assert
  `TOPIC_REGISTRAR_BOOT` goes to `(primary absent)` — with a positive control that it
  read `(primary found ...)` a moment earlier, from the same subscription.
* **Verb 1 needs a cold-start arm:** clear the retained boot topic, start ours, assert it
  promotes via the 2-second timeout — and a second arm with a *live* Python registrar
  already primary, asserting ours enters `secondary` and does **not** announce.
* Every assertion reads the **broker**, not our own logs. The observer increment's single
  most valuable finding (MQTT 3.1 vs 3.1.1) was invisible in our output and visible only
  in `docker logs aiko-mosquitto-1`.

---

## Build order

Each step is observable on the wire before the next is written.

0. **This note.** ✔
1. **Confirm the reusable set** — `ServiceTopicPath`'s process expansion against
   `:381-386`, `ServiceFilter` against `:333`. Read, do not assume.
2. **LWT in `mqtt_transport.dart`** — moved to the front. The election's `on_enter_primary`
   cannot be written correctly without it, and it is the one piece with no Dart precedent.
3. **The election state machine** + the retained announcement (verbs 1, 5, 6). ✔
   Landed as `registrar_election.dart` (pure) + `registrar_process.dart` (the driver),
   with `spike/election/probe_election.sh` as the falsifier. Three arms: stand down to the
   live island's Python primary publishing nothing; promote, announce and retract without
   one; and — the arm no fake can reach — still HEAR after the promotion reconnect.
4. **`/in` registration** — `add` / `remove`, the roster, `service_count` (verb 2). ✔
5. **The wildcard state subscription** — `(absent)` → remove (verb 4). ✔ Needed
   spec-conformant MQTT filter matching, which `TopicRouter` had explicitly refused to do.
6. **`services_share`** — the producer half, against `services_cache.dart`'s table (verb 3). ✔
7. **`services_history`** + the ring buffer, including the 8-field `add`.
8. **`ECProducer`** for the registrar's own share, so a Python dashboard can read our
   `lifecycle`.
9. **Gate A.** ✔ 2026-09-11 — `tool/observer_acceptance.sh` 14/14 against an island whose
   registrar is a host-run `example/registrar.dart`.

Lease serving (#3995) sits under step 8 and carries its own unresolved design question
(does a test-only short-lease knob belong in production code?). Flag it there; do not
decide it silently.

## What is deliberately NOT in it

* **Gate B / the container image.** Named above, not built here.
* **A working `secondary`.** Entered, inert. Upstream's own To Do says the interesting
  behaviour does not exist there either.
* **Raft, CRDTs, multi-registrar consensus.** The header's Ideas section; not a port
  obligation.
* **`--primary` force-takeover.** Upstream's usage block marks it TODO and it is unbuilt.
* **HyperSpace / Category.** The header's "Implement Registrar as a sub-class of Category"
  is an upstream aspiration, not current behaviour. Porting current behaviour means
  `Registrar extends Service`.

## Found by RUNNING it, not by reading it

* **A gracefully stopped registrar leaves a CORPSE on the boot topic, and the island cannot
  recover by itself.** Measured: `docker stop aiko-registrar-1` at 08:19:15, and 139 seconds
  later the retained `aiko/service/registrar` still read
  `(primary found aiko/fddd654e4b5a/1/1 …)`. The will never fired, and the broker's own log
  says why — `1789078755: Client … [172.22.0.3:58683] disconnected: connection closed by
  client`, mosquitto's phrasing for a clean DISCONNECT packet, which SUPPRESSES a will. The
  container was SIGKILLed ten seconds later (exit 137), by which point the MQTT session was
  already gone.

  **The consequence is worse than a stale value, and it was verified rather than reasoned.**
  A replacement registrar joining that island reads the retained `found`, concludes somebody
  is already primary, and stands down to `secondary`. Confirmed by running one against the
  live island with NO registrar container up at all: `FINAL_ROLE=secondary`. So an island
  whose registrar is stopped cleanly has zero registrars and every replacement will refuse
  the job — a self-sustaining dead state that restarting does not escape. Clearing the
  retained topic by hand is the only exit.

  This is a much sharper form of candidate mechanism (a) for the 23-hour broken island.

* **A publish can KILL a Dart process where it merely returns a code in Python.** paho's
  `publish()` returns an error code on a down link and upstream ignores it, which is why
  `registrar.py` can afford its boot-topic clear OUTSIDE the try. `mqtt_client` THROWS. A
  live Dart registrar died of exactly this, mid-auto-reconnect. **Parity in a wire protocol
  does not imply parity in how a library FAILS**, and that is the class, not the instance.

* **A registrar can read its OWN tombstone as news.** The crash above was downstream of it:
  our link dropped, the broker published our retained `(primary absent)` will, we
  auto-reconnected, re-read that retained payload, dropped the entire roster and re-elected.
  `ClearBootTopic` exists upstream for this reason (`registrar.py:186`) but only clears on
  the NEXT promotion, so the window between the will firing and the clear is real on both
  implementations.

## Known risks, named before building

* **The transport's will support changes `connect()`, which every existing test path uses.**
  A shared-type change makes the verification surface the whole package.
* **The `+/+/+/state` wildcard is the broadest subscription this port has ever taken.**
  On a busy island it sees every process's state traffic. No volume measured yet.
* **`_registrar_handler("absent")` wipes the whole roster** (`:281`, `self.services =
  Services()`). Reproducing that faithfully means our registrar can lose everything on a
  boot-topic blip. Understand the trigger before copying it.
* **The 2-second election timeout is a race with reality**, not a constant to tune.
  Upstream's own TODO (`:167`) asks for jitter to avoid collisions and does not implement
  it. Two Dart registrars started together would collide identically.
  **MEASURED 2026-09-11:** the retained announcement arrives 6-54 ms after subscribe on
  the live rig (`LATENCY_MS` in arm 1). The margin is ~40x, and the probe reports the
  number rather than asserting a threshold — a threshold would turn a measurement into a
  flaky gate, and the number is more use to the next reader than a boolean.
* **`time_started` cannot be ported exactly, and the divergence is a decision.** Upstream
  sends `time.monotonic()` sampled at service start (`service.py:564`), a clock whose
  origin CPython documents as undefined. Dart cannot read it. A `Stopwatch` gives the same
  KIND of quantity but resets to ~0 on every restart, making a fresh registrar look like
  the OLDEST process on the island — dangerous against `registrar.py:166`'s TODO to
  promote *"the oldest known secondary"*, under which our registrar would win every
  election forever. Wall-clock epoch seconds is a different SCALE from upstream's (1.7e9
  against 8.3e5) and cannot be compared with it, but it rises across restarts and fails
  SAFE against that TODO. Nothing in `process.py` compares the field today — checked at
  `:332-337`, where it is stored into `aiko.registrar` and never read. Chosen, documented,
  and queued for Andy rather than resolved unilaterally.

* **The `+/+/+/state` wildcard forced a matcher, and the reference's is not one.**
  `process.py:408-424` compares only the FIRST and LAST segments of a `+` filter and ignores
  depth, so `aiko/+/+/+/state` locally matches `aiko/a/state` and `aiko/a/b/c/d/e/state`.
  Harmless upstream because the BROKER does the real filtering and a loose local matcher can
  only misroute between two wildcard subscriptions held at once. Ours implements 3.1.1 §4.7;
  the divergence cannot drop anything a handler wanted, and is recorded for Andy.

* ~~**Nothing here has been run.**~~ Steps 1-3 have now been run against a live broker,
  and running them corrected this note twice (the LWT section, and the acceptance
  criterion) and turned up a live island defect and a missing signal. The claim now holds
  only for steps 4-9.

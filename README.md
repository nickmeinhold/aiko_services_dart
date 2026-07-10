# Aiko Services (Dart)

A Dart port of [Aiko Services](https://github.com/geekscape/aiko_services), Andy Gelme's
distributed actor framework for IoT, machine learning, and video, built on asynchronous
MQTT messages.

> **Status:** early / design phase. No implementation yet. The Python repo is the
> reference implementation and correctness sounding-board for the port.

## Design notes

- [**An isolate-per-actor runtime**](docs/isolate-per-actor-runtime.html) — how Aiko's
  distributed actor model maps onto Dart isolate groups, and a proposed build sequence
  (single-isolate Eventual Consistency client first; MessageBus + isolate-per-actor
  runtime later). Open in a browser.

## Upstream

- [geekscape/aiko_services](https://github.com/geekscape/aiko_services) — Python reference implementation
- [geekscape/aiko_chat](https://github.com/geekscape/aiko_chat) — Aiko Services based chat server

## Scope of the initial port

Following Andy's proposed sequence:

1. Eventual Consistency `ECProducer` / `ECConsumer` (send / receive) over MQTT
2. Registrar discovery — register self, discover and use other (Python) Aiko actors
3. Discover and interact with Aiko Chat

The aim is the minimal implementation that gets someone underway and grows over time,
not a throwaway hack. Inspired by the [Make-A-LISP](https://github.com/kanaka/mal) model
of a well-specified core ported across many languages.

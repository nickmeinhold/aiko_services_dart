import 'dart:async';

/// How a component makes a one-shot timer.
///
/// Injected rather than calling [Timer.new] directly so a test can drive time
/// EXPLICITLY instead of outwaiting it. The alternative — `package:fake_async`,
/// which zone-intercepts [Timer] and needs no production surface at all — was
/// measured and does not fit: `fakeAsync` requires a SYNCHRONOUS test body, and
/// every driver here is async by construction because performing an election
/// effect can reconnect.
///
/// The recorded [Duration] is half the point. A test that only fires timers can
/// prove a timer ran; one that reads the durations it was asked for can prove
/// the SHAPE of a backoff, which is otherwise a two-minute assertion.
typedef CreateTimer =
    Timer Function(Duration duration, void Function() callback);

/// A [CreateTimer] that never touches the clock: a test fires each timer by
/// hand, and reads back every duration it was asked for.
library;

import 'dart:async';

import 'package:aiko_services/aiko_services.dart';

/// One scheduled callback. Fires only when a test says so.
class FakeTimer implements Timer {
  FakeTimer(this.duration, this._callback, this._owner);

  final Duration duration;
  final void Function() _callback;
  final FakeTimers _owner;

  var _cancelled = false;
  var _fired = false;

  @override
  bool get isActive => !_cancelled && !_fired;

  @override
  void cancel() {
    _cancelled = true;
    _owner._pending.remove(this);
  }

  /// A real timer is no longer active by the time its callback runs, and the
  /// code under test reads that: the registrar's timer arm nulls its own handle
  /// from inside the callback. Marking fired FIRST keeps a fake from being
  /// kinder than [Timer].
  void fire() {
    if (!isActive) {
      throw StateError(
        'fired a timer that is already ${_cancelled ? 'cancelled' : 'fired'}',
      );
    }
    _fired = true;
    _owner._pending.remove(this);
    _callback();
  }

  @override
  int get tick => 0;

  @override
  String toString() => 'FakeTimer(${duration.inMilliseconds}ms)';
}

/// Hand this out as a [CreateTimer] and drive time from the test body.
class FakeTimers {
  final List<FakeTimer> _pending = [];

  /// Every duration a timer was ever ASKED for, in order, including ones later
  /// cancelled. This is the instrument for a backoff shape: the schedule is
  /// observable without any of it elapsing.
  final List<Duration> scheduled = [];

  /// Pass as [CreateTimer].
  Timer create(Duration duration, void Function() callback) {
    scheduled.add(duration);
    final timer = FakeTimer(duration, callback, this);
    _pending.add(timer);
    return timer;
  }

  List<FakeTimer> get pending => List.unmodifiable(_pending);

  bool get hasPending => _pending.isNotEmpty;

  /// Fire the oldest pending timer.
  ///
  /// Refuses when nothing is pending rather than returning quietly: a test
  /// whose subject never armed a timer must fail HERE, naming that, instead of
  /// failing three assertions later on a state nothing moved. Instance 6 of
  /// this design's defect class was exactly an unarmed timer.
  void fireNext() {
    if (_pending.isEmpty) {
      throw StateError('fireNext: no timer is pending');
    }
    _pending.first.fire();
  }

  void cancelAll() {
    for (final timer in _pending.toList()) {
      timer.cancel();
    }
  }
}

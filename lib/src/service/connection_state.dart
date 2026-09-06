/// How far this process has got towards being able to use the bus.
///
/// A strict ladder: each state implies every state below it, which is the only
/// property callers actually use — `connection.py:is_connected()` is an index
/// comparison, `>=`, not an equality test. Declaration order here IS that
/// ordering, so [Enum.index] is the comparison and there is no second list to
/// keep in sync.
library;

/// The connection ladder. Order is load-bearing.
enum ConnectionState {
  /// Nothing yet.
  none,

  /// Wi-Fi or Ethernet available.
  network,

  /// MQTT (or Ray, ROS2, ZeroMQ) connected.
  transport,

  /// The registrar has been found and can be used.
  registrar;

  // Python declares a fifth constant, `BOOTSTRAP` ("MQTT configuration
  // found"), at `connection.py:32` and then omits it from the `states` list at
  // `:36` that `index()` searches — so `is_connected(BOOTSTRAP)` raises
  // ValueError, and nothing under `src/` references it. It is absent here
  // because adding it would change the ladder's arithmetic to match a state
  // the reference cannot itself evaluate. Whether it is a dead constant or a
  // missing entry is a question for upstream, not a choice for the port.

  /// Whether this process has reached at least [required].
  ///
  /// Mirrors `connection.py:is_connected()`.
  bool isConnected(ConnectionState required) => index >= required.index;
}

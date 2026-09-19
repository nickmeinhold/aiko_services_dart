/// Where a process's identity on the bus comes from.
///
/// Extracted because TWO processes need it and the repo has already paid three
/// times for the shape where a property is fixed in one copy and left standing
/// in its twin. A bus observer and a registrar derive the same four-segment
/// path by the same rules; only what they do with it differs.
///
/// It is also the whole `dart:io` surface of this layer, deliberately gathered
/// into one file. `Platform` and `pid` are the two things a browser cannot
/// answer, so a web target (#3240) has exactly one file to substitute rather
/// than a scattering of imports to hunt.
library;

import 'dart:io';

/// The host segment of a topic path, as `process.py:100` derives it.
///
/// A `/` in this segment would silently re-shape the four-segment path into
/// something longer, so a hostname is taken only for its first label — which is
/// also what a container reports.
String processHostSegment([String? host]) =>
    _sanitise(host ?? _localHostnameOr('unknown-host'));

/// This process's OS process id, the third segment of every topic path.
int get currentProcessId => pid;

/// `Platform.localHostname` throws on a platform that cannot answer, and it is
/// the one line here that touches the OS. A host segment only has to be stable
/// and slash-free, so a failure degrades to something legible in a topic rather
/// than failing construction with an opaque trace.
String _localHostnameOr(String fallback) {
  try {
    return Platform.localHostname;
  } on Object {
    return fallback;
  }
}

String _sanitise(String host) =>
    host.split('.').first.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

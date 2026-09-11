// Does `package:mqtt_client`'s MqttServerClient actually drive a real mTLS
// handshake -- client cert offered, CA-verified, broker-side identity
// derived from the cert CN -- or does the CLI-tool proof (mosquitto_pub/sub
// with --cert/--key) not transfer to the Dart client library?
//
// Bare `MqttServerClient`, not `AikoClient`: the transport class has no
// `secure`/`securityContext` knobs yet (see docs/notes/tls-identity.md), and
// wiring the whole class through as its own change with its own test.
// This probe answers one question only -- can the *package* do it.
//
//   dart run spike/tls/probe_tls.dart <arm> <host> <port> <cafile> [certfile] [keyfile]
//
// arm is one of: valid | wrong-ca | no-cert
import 'dart:async';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

Future<void> main(List<String> args) async {
  // `runZonedGuarded`, not a bare try/catch: measured live that a rejected
  // handshake does NOT always reject `connect()`'s own Future. The `no-cert`
  // and `wrong-ca` arms both threw as UNHANDLED async exceptions past an
  // `await client.connect()` wrapped in try/catch -- only after the `valid`
  // arm was fixed to actually pass, meaning the failure path taken changes
  // depending on WHERE the handshake breaks (server rejects the client's
  // missing cert mid-handshake vs. the client rejects the server's chain
  // synchronously). A production caller needs this same net, not a plain
  // try/catch around connect() -- that would silently miss exactly the
  // failure modes this spike exists to prove are correctly refused.
  await runZonedGuarded(
    () async {
      final arm = args[0];
      final host = args[1];
      final port = int.parse(args[2]);
      final cafile = args[3];
      final certfile = args.length > 4 ? args[4] : null;
      final keyfile = args.length > 5 ? args[5] : null;

      final client =
          MqttServerClient.withPort(host, 'tls_probe_${arm}_$pid', port)
            ..logging(on: false)
            ..secure = true
            ..securityContext = (SecurityContext(withTrustedRoots: false)
              ..setTrustedCertificates(cafile));

      if (certfile != null && keyfile != null) {
        client.securityContext
          ..useCertificateChain(certfile)
          ..usePrivateKey(keyfile);
      }
      // `no-cert`: neither set, so the client offers no certificate at all --
      // proving `require_certificate true` actually rejects a client, not
      // just an unsigned one.

      client.connectionMessage = MqttConnectMessage().startClean();

      try {
        await client.connect();
        print('RESULT connected status=${client.connectionStatus?.state}');
        client.disconnect();
      } on Object catch (e) {
        print('RESULT rejected error=$e');
      }
    },
    (error, stack) {
      // The catch-all this file's whole existence argues for: a handshake
      // rejection that never reaches the try/catch above.
      print('RESULT rejected error=$error');
    },
  );
}

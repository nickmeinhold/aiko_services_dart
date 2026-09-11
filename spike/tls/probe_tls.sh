#!/usr/bin/env bash
#
# Three-arm acceptance for mTLS as the tailnet-replacement identity mechanism
# (docs/notes/tls-identity.md), against a REAL broker.
#
# Arm 1 (valid):    a cert signed by our CA          -> the handshake MUST succeed.
# Arm 2 (wrong-ca): a cert NOT signed by our CA       -> the handshake MUST fail.
# Arm 3 (no-cert):  no client cert at all             -> the handshake MUST fail.
#
# All three are required. Arm 1 alone cannot distinguish "mTLS is enforced"
# from "this broker accepts anything"; arms 2 and 3 alone cannot distinguish
# "correctly rejected" from "nothing was ever listening". Self-contained on
# purpose: this needs `require_certificate true`, which the shared default
# broker the other spikes assume does not run -- so this script brings up its
# OWN scratch mosquitto on a throwaway port and tears it down after, rather
# than depending on a pre-configured external rig nothing here can verify.
#
# Exit codes: 0 pass, 1 an assertion failed, 2 a missing harness dependency,
# 75 a probe stalled. The last is NOT an assertion failure and the caller
# must be able to tell them apart -- see spike/probe_support.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
. spike/probe_support.sh

for bin in openssl mosquitto; do
  command -v "$bin" >/dev/null 2>&1 || {
    # mosquitto's daemon binary is commonly under a versioned sbin, not PATH.
    if [ "$bin" = mosquitto ] && [ -x /opt/homebrew/sbin/mosquitto ]; then
      continue
    fi
    echo "$bin not found — cannot run the TLS spike. A skip is NOT a pass." >&2
    exit 2
  }
done
MOSQUITTO_BIN=$(command -v mosquitto || echo /opt/homebrew/sbin/mosquitto)

WORK=$(mktemp -d)
trap 'kill "${broker_pid:-}" 2>/dev/null; rm -rf "$WORK"' EXIT
PORT=18884

echo "== generating a throwaway CA + certs in $WORK =="
# THREE separate fixes were needed to get here, each hiding the next behind an
# identical-looking "application verification failure" from BoringSSL, and
# each one mosquitto's OpenSSL-based validator was too lenient to catch:
#
#   1. `basicConstraints=critical,CA:TRUE` on the CA cert. A bare
#      `openssl req -x509` leaves this off; OpenSSL's chain check tolerates
#      that, dart:io's BoringSSL does not trust the issuer at all without it.
#   2. `subjectAltName` on the broker leaf covering BOTH the DNS name and the
#      literal dotted-quad. A CN-only cert fails dart:io's hostname check
#      against an IP dial target with the exact same error as #1 and #3.
#   3. `subjectKeyIdentifier`/`authorityKeyIdentifier` linking each leaf to
#      the CA, plus `basicConstraints=CA:FALSE` + explicit `keyUsage` /
#      `extendedKeyUsage` on the leaves. mosquitto builds the chain by
#      subject/issuer DN match alone; BoringSSL's chain builder additionally
#      wants the key-identifier link and complained with the same
#      CERTIFICATE_VERIFY_FAILED text as the first two causes.
#
# Each was isolated with a raw `dart:io SecureSocket.connect` probe against
# the same broker, one variable at a time -- the CLI tools (mosquitto_pub/sub)
# stayed green through every one of these, so they cannot be trusted as a
# stand-in for whether `package:mqtt_client` will actually accept a cert.
openssl req -x509 -new -nodes -newkey rsa:2048 -days 1 \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
  -addext subjectKeyIdentifier=hash \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -subj "/CN=probe-ca" 2>/dev/null

leaf_ext() {  # $1 = extra lines (subjectAltName etc), appended after the shared block
  printf 'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nbasicConstraints=CA:FALSE\n%s\n%s' \
    'keyUsage=digitalSignature,keyEncipherment' "$1"
}

openssl req -new -nodes -newkey rsa:2048 \
  -keyout "$WORK/broker.key" -out "$WORK/broker.csr" -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -in "$WORK/broker.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
  -CAcreateserial -days 1 -out "$WORK/broker.crt" \
  -extfile <(leaf_ext $'extendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1') 2>/dev/null

openssl req -new -nodes -newkey rsa:2048 \
  -keyout "$WORK/valid.key" -out "$WORK/valid.csr" -subj "/CN=probe-valid" 2>/dev/null
openssl x509 -req -in "$WORK/valid.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" \
  -CAcreateserial -days 1 -out "$WORK/valid.crt" \
  -extfile <(leaf_ext 'extendedKeyUsage=clientAuth') 2>/dev/null

# Signed by a DIFFERENT, unrelated CA -- not just self-signed, so this arm
# also covers "an attacker with their own working PKI", not only "no PKI".
# Given the SAME extension shape as the valid leaf (basicConstraints, SKI/AKI,
# keyUsage) so a failure here is attributable to the CA choice alone, not to
# some other missing extension this arm happened not to need.
openssl req -x509 -new -nodes -newkey rsa:2048 -days 1 \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
  -addext subjectKeyIdentifier=hash \
  -keyout "$WORK/other-ca.key" -out "$WORK/other-ca.crt" -subj "/CN=other-ca" 2>/dev/null
openssl req -new -nodes -newkey rsa:2048 \
  -keyout "$WORK/wrongca.key" -out "$WORK/wrongca.csr" -subj "/CN=probe-wrongca" 2>/dev/null
openssl x509 -req -in "$WORK/wrongca.csr" -CA "$WORK/other-ca.crt" -CAkey "$WORK/other-ca.key" \
  -CAcreateserial -days 1 -out "$WORK/wrongca.crt" \
  -extfile <(leaf_ext 'extendedKeyUsage=clientAuth') 2>/dev/null

cat > "$WORK/acl.conf" <<EOF
user probe-valid
topic readwrite probe/#
EOF
chmod 0700 "$WORK/acl.conf"

cat > "$WORK/mosquitto.conf" <<EOF
listener $PORT
allow_anonymous false
cafile $WORK/ca.crt
certfile $WORK/broker.crt
keyfile $WORK/broker.key
require_certificate true
use_identity_as_username true
acl_file $WORK/acl.conf
log_dest file $WORK/mosquitto.log
EOF

echo "== starting scratch broker on 127.0.0.1:$PORT =="
"$MOSQUITTO_BIN" -c "$WORK/mosquitto.conf" -d
sleep 1
broker_pid=$(pgrep -f "mosquitto -c $WORK/mosquitto.conf" | head -1)
[ -n "$broker_pid" ] || { echo "scratch broker never started" >&2; exit 3; }

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

run_arm() {  # $1=arm $2=expect(connected|rejected) $3... extra dart args
  local arm=$1 expect=$2 out rc; shift 2
  out=$(mktemp)
  rc=$(probe_run_bounded 20 "$out" \
    dart run spike/tls/probe_tls.dart "$arm" 127.0.0.1 "$PORT" "$WORK/ca.crt" "$@")
  if [ "$rc" = "75" ]; then
    bad "$arm: probe STALLED (watchdog) — proves nothing"
  elif grep -q "RESULT $expect" "$out"; then
    ok "$arm: got '$expect' as required"
  else
    bad "$arm: expected '$expect', got: $(tail -1 "$out")"
  fi
  rm -f "$out"
}

printf '\n\033[1mArm 1 — CA-signed cert: the handshake MUST succeed\033[0m\n'
run_arm valid connected "$WORK/valid.crt" "$WORK/valid.key"

printf '\n\033[1mArm 2 — cert from a DIFFERENT CA: the handshake MUST fail\033[0m\n'
run_arm wrong-ca rejected "$WORK/wrongca.crt" "$WORK/wrongca.key"

printf '\n\033[1mArm 3 — no client cert: the handshake MUST fail\033[0m\n'
run_arm no-cert rejected

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d passed, 0 failed\033[0m\n' "$pass"
  printf 'Scope: proves package:mqtt_client can DRIVE mTLS identity + rejection\n'
  printf 'against mosquitto. Does NOT cover ACL authorization (already proven at\n'
  printf 'the protocol level with mosquitto_pub/sub, not yet from this package),\n'
  printf 'nor cert rotation/revocation, nor AikoClient — that class has no\n'
  printf 'secure/securityContext knobs yet.\n'
  exit 0
fi
printf '\033[31m%d passed, %d FAILED\033[0m\n' "$pass" "$fail"
exit 1

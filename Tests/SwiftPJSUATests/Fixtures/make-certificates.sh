#!/bin/bash
#
# make-certificates.sh — regenerate the TLS fixtures next to this script.
#
# Bash rather than Swift on purpose: every step is an `openssl` invocation, and
# PKCS#12 *export* has no Apple API on iOS (SecItemExport is macOS-only), so there
# is nothing for Swift to do here that openssl(1) is not already doing.
#
# What the three fixtures are for (TLS-Transport-Tests, swift-pjsua):
#   good.p12       a small, loadable server identity — the positive control. Only
#                  works on iOS: iOS imports the key from the .p12 itself via
#                  SecPKCS12Import(), macOS resolves it through the keychain.
#   oversized.p12  ~12 KB. The Apple backend's create_data_from_file() reads a
#                  single 8192-byte chunk and treats it as the whole file, so this
#                  one must FAIL to load today. pjproject#5222 fixes that; when this
#                  fixture starts loading, the fix has arrived in our binary.
#   garbage.p12    not a PKCS#12 at all — the "unparsable" case.
#
# The PBE spelling matters. OpenSSL 3 defaults to AES-256-CBC + PBKDF2 for the
# PKCS#12 MAC/encryption, which Apple's importer rejects; `-legacy` alone then
# picks 40-bit RC2, which is weaker than anything anyone should ship. So ask for
# SHA1+3DES explicitly — the combination Apple's SecPKCS12Import has always taken —
# and fall back to a bare export if the flags are absent (LibreSSL, which is what
# /usr/bin/openssl is on macOS).
#
# Validity is 3650 days so the fixtures do not silently rot. Nothing here is
# secret: throwaway self-signed keys for a CN nobody owns, committed on purpose so
# the test suite needs no setup.

set -euo pipefail

cd "$(dirname "$0")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSWORD="secret"
DAYS=3650

p12() {
    # p12 OUT -- ARGS...  — try the -legacy spelling first, then without it.
    local out="$1"; shift 2
    openssl pkcs12 -export -out "$out" -passout "pass:$PASSWORD" -legacy \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 "$@" 2>/dev/null \
        || openssl pkcs12 -export -out "$out" -passout "pass:$PASSWORD" "$@"
}

# --- good.p12: 2048-bit self-signed leaf, key inside the bundle ---------------
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/good.key" -out "$WORK/good.pem" \
    -days "$DAYS" -nodes -subj "/CN=swift-pjsua-test" 2>/dev/null
p12 good.p12 -- -inkey "$WORK/good.key" -in "$WORK/good.pem"

# --- oversized.p12: 4096-bit leaf + a repeated CA chain, > 8 KB ---------------
openssl req -x509 -newkey rsa:4096 -keyout "$WORK/ca.key" -out "$WORK/ca.pem" \
    -days "$DAYS" -nodes -subj "/CN=swift-pjsua-test-ca" 2>/dev/null
openssl req -newkey rsa:4096 -keyout "$WORK/big.key" -out "$WORK/big.csr" \
    -nodes -subj "/CN=swift-pjsua-test-leaf" 2>/dev/null
openssl x509 -req -in "$WORK/big.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" \
    -CAcreateserial -out "$WORK/big.pem" -days "$DAYS" 2>/dev/null
cat "$WORK/ca.pem" "$WORK/ca.pem" "$WORK/ca.pem" \
    "$WORK/ca.pem" "$WORK/ca.pem" "$WORK/ca.pem" > "$WORK/chain.pem"
p12 oversized.p12 -- -inkey "$WORK/big.key" -in "$WORK/big.pem" -certfile "$WORK/chain.pem"

# --- garbage.p12: the right name, the wrong bytes ------------------------------
head -c 512 /dev/urandom > garbage.p12

for f in good.p12 oversized.p12 garbage.p12; do
    printf '%-16s %6s bytes\n' "$f" "$(wc -c < "$f" | tr -d ' ')"
done

# The oversized fixture is only useful if it is actually oversized.
size="$(wc -c < oversized.p12 | tr -d ' ')"
[[ "$size" -gt 8192 ]] || { echo "oversized.p12 is only $size bytes — not > 8192" >&2; exit 1; }

#!/bin/bash
#
# Creates a self-signed code signing identity in the login keychain. Run once.
#
# Why this matters: macOS keys camera permission (TCC) to the app's *designated
# requirement*. Ad-hoc signing produces a DR of `cdhash H"..."` -- a hash of the
# binary contents -- so every rebuild is a different app as far as TCC is
# concerned, and the camera prompt reappears after every `swift build`.
#
# A self-signed certificate yields a content-independent DR:
#
#   identifier "com.betterscreen.app" and certificate leaf = H"<cert hash>"
#
# so the grant survives rebuilds indefinitely. Verified: three consecutive real
# code changes, no re-prompt.
#
# No sudo, no Xcode, no Keychain Access GUI required.

set -euo pipefail

COMMON_NAME="${1:-BetterScreen Dev}"
LOGIN_KEYCHAIN="$(security login-keychain | tr -d ' "')"
OPENSSL=/usr/bin/openssl   # LibreSSL; always present on macOS

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# NOTE: deliberately not `find-identity -v`. Self-signed certs are untrusted, and
# -v lists valid identities only, so it would not find our own cert -- silently
# falling back to ad-hoc signing and quietly reintroducing the TCC problem.
if security find-identity -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -qF "$COMMON_NAME"; then
    echo "Identity '$COMMON_NAME' already exists. Nothing to do."
    exit 0
fi

cat > "$WORK/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign

[ dn ]
CN = $COMMON_NAME

[ v3_codesign ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating self-signed code signing certificate '$COMMON_NAME'"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -config "$WORK/openssl.cnf" 2>/dev/null

# LibreSSL rejects -legacy; OpenSSL 3 (e.g. from Homebrew) requires it to produce
# a PKCS#12 the macOS keychain will accept.
if "$OPENSSL" version 2>&1 | grep -q LibreSSL; then
    "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$COMMON_NAME" -out "$WORK/identity.p12" -passout pass:temp
else
    "$OPENSSL" pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
        -name "$COMMON_NAME" -out "$WORK/identity.p12" -passout pass:temp
fi

# -A allows any tool to use the private key without a GUI prompt. Without it,
# codesign pops an "allow access to key" dialog on every single build.
echo "==> Importing into $LOGIN_KEYCHAIN"
security import "$WORK/identity.p12" -k "$LOGIN_KEYCHAIN" -P temp -A -T /usr/bin/codesign

echo
echo "==> Done:"
security find-identity -p codesigning "$LOGIN_KEYCHAIN" | grep -F "$COMMON_NAME"
echo
echo "The certificate reports CSSMERR_TP_NOT_TRUSTED and is hidden by"
echo "'security find-identity -v'. That is expected and harmless -- codesign"
echo "signs with it fine, and the designated requirement is stable, which is the"
echo "whole point. Do not add trust settings."

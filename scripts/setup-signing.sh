#!/bin/bash
# Creates a stable local code-signing identity, once.
#
# Why: API keys live in the Keychain, and the Keychain grants access per code
# signature. Ad-hoc signing (`codesign -s -`) produces a *new* identity on every
# build, so macOS treats each rebuild as an unknown app and blocks the first
# read behind an approval dialog — every time you rebuild. A stable self-signed
# identity means you approve once and it sticks.
#
# This is a local development certificate only. It is not a Developer ID and
# cannot be used to distribute the app to anyone else.
set -euo pipefail

NAME="Jarvis Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "\"$NAME\" already exists — nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=Jarvis Local Dev
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -config "$WORK/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
  -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -passout pass:jarvis -name "$NAME" >/dev/null 2>&1

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P jarvis \
  -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

# User trust domain, so this needs no admin rights.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Created \"$NAME\". scripts/run.sh will use it automatically."
  echo "macOS will ask once more to approve Keychain access — choose Always Allow."
else
  echo "Certificate created but not valid for signing; builds will fall back to ad-hoc." >&2
  exit 1
fi

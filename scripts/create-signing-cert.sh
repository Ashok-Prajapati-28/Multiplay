#!/bin/bash
# Creates a self-signed "MultiPlay Dev" code-signing certificate in your login keychain.
#
# Why: macOS ties the "System Audio Recording" and "Microphone" permissions to the app's
# signature. With ad-hoc signing, every rebuild looks like a brand-new app and the
# permissions silently stop working. With this certificate, rebuilds keep them.
#
# The certificate never leaves your Mac and is only used to sign MultiPlay.
# Remove it any time in Keychain Access (login keychain, "MultiPlay Dev").
set -euo pipefail

NAME="MultiPlay Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then
    echo "\"$NAME\" certificate already exists. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cfg <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg 2>/dev/null
PASS="$(openssl rand -hex 16)"
# -legacy keeps the .p12 readable by macOS's keychain when OpenSSL 3 is used; LibreSSL doesn't know the flag.
if openssl version | grep -q "^OpenSSL 3"; then LEGACY=-legacy; else LEGACY=; fi
openssl pkcs12 -export $LEGACY -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout "pass:$PASS"
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

echo "Created \"$NAME\". Now run ./build.sh"

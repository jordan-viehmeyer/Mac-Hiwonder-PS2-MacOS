#!/usr/bin/env bash
# Optional: create a stable local code-signing identity for PS2MC.app.
#
# WHY THIS EXISTS
#   Without a paid Apple Developer ID, the app is ad-hoc signed. Its designated code
#   requirement is then a bare hash of the binary:
#
#       # designated => cdhash H"c760778819d8513e..."
#
#   TCC stores that requirement when you grant Input Monitoring or Accessibility. So any
#   rebuild that changes the binary produces what macOS considers a *different app*: the
#   old entry stays in System Settings looking correct while applying to nothing, and the
#   app reports the permission as missing.
#
#   Signing with a certificate instead makes the requirement name the certificate rather
#   than the binary, so grants survive rebuilds.
#
# WHAT IT DOES
#   Creates a self-signed certificate named "ps2mc Local Signing", imports it into your
#   login keychain, and marks it trusted for code signing. The trust step needs your admin
#   password.
#
# SECURITY NOTE
#   This adds a locally-trusted signing certificate to your keychain. Code signed by it
#   will be treated as validly signed on this Mac. The private key never leaves your
#   machine and is used only by scripts/build-app.sh. Remove it at any time with:
#
#       security delete-certificate -c "ps2mc Local Signing"
#
#   If you would rather not, skip this entirely: the build falls back to ad-hoc signing and
#   works fine — you just re-grant the two permissions after each rebuild.
set -euo pipefail

NAME="ps2mc Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Already present: $NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -subj "/CN=$NAME" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# Security.framework rejects OpenSSL 3's default PKCS#12 MAC, so pin the legacy algorithms.
openssl pkcs12 -export -macalg sha1 \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/id.p12" -passout pass:ps2mc -name "$NAME" 2>/dev/null

echo "==> Importing into your login keychain"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P ps2mc -T /usr/bin/codesign -A >/dev/null

echo "==> Marking it trusted for code signing (needs your admin password)"
sudo security add-trusted-cert -d -r trustRoot \
  -p codeSign -k /Library/Keychains/System.keychain "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo
  echo "Done. scripts/build-app.sh will now use \"$NAME\"."
  echo "Rebuild the app, then grant the two permissions once — they will survive rebuilds."
else
  echo
  echo "The certificate did not end up valid for code signing." >&2
  echo "The build will fall back to ad-hoc signing, which still works." >&2
  exit 1
fi

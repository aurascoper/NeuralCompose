#!/usr/bin/env bash
# sign-app-local.sh — give .build/NeuralCompose.app a STABLE self-signed code
# signature so macOS 26 will list it under System Settings → Privacy & Security →
# Local Network and let you grant it.
#
# Why: an ad-hoc signature (`codesign -s -`, what package-app-bundle.sh uses) has no
# stable code identity, so macOS 26's Local Network privacy has nothing to attach the
# permission to → the app never appears in the Local Network list and its OSC UDP
# listener is denied at creation → EEG-over-OSC silently falls back to synthetic.
# A self-signed cert gives a stable identity TCC can track.
#
# Run WITHOUT sudo (the identity must land in YOUR login keychain):
#   bash Scripts/sign-app-local.sh
# Prompts once for your login password (to trust the cert for code signing).
set -uo pipefail

# Must run as the logged-in user, not root — TCC + codesign use the user's keychain.
if [ "$(id -u)" = "0" ]; then
  echo "Do NOT run this with sudo. Re-run as your normal user:  bash Scripts/sign-app-local.sh" >&2
  exit 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/.build/NeuralCompose.app"
CN="NeuralCompose Local Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl     # macOS LibreSSL, NOT Homebrew openssl 3
P12PW="nclocal"              # throwaway password for the transient .p12 (deleted below)

[ -d "$APP" ] || { echo "error: $APP not found — build/package the app first." >&2; exit 1; }
echo "openssl: $("$OPENSSL" version)"

if ! security find-identity -v -p codesigning | grep -q "$CN"; then
  echo "==> Creating self-signed code-signing certificate '$CN'…"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  "$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" \
    || { echo "FAILED: openssl req"; exit 1; }
  # Non-empty password on BOTH ends — empty-password p12 fails MAC check on macOS.
  "$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/nc.p12" -passout "pass:$P12PW" -name "$CN" \
    || { echo "FAILED: openssl pkcs12 export"; exit 1; }
  echo "==> Importing key+cert into login keychain…"
  security import "$TMP/nc.p12" -k "$KEYCHAIN" -P "$P12PW" -A \
    || { echo "FAILED: security import"; exit 1; }
  echo "==> Trusting the cert for code signing (enter your LOGIN password if asked)…"
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" \
    || echo "WARN: add-trusted-cert failed — will still try to sign."
else
  echo "==> Reusing existing '$CN' identity."
fi

echo "==> Identities available for code signing:"
security find-identity -v -p codesigning | grep -i "NeuralCompose" || echo "  (none matching — signing will likely fail)"

echo "==> Signing $APP …"
if codesign --force --deep -s "$CN" "$APP"; then
  echo "==> SIGNED. New identity:"
  codesign -dvvv "$APP" 2>&1 | grep -iE "Authority=|Signature=|flags=" | head -4
  echo "OK — tell Claude 'signed' and it will relaunch; grant Local Network + Microphone when prompted."
else
  echo "==> codesign FAILED — paste this whole output back to Claude."
  exit 1
fi

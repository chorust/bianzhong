#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="${BIANZHONG_CERT_NAME:-Bianzhong Local Signer}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

find_existing_cert() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -F "\"$CERT_NAME\"" || true
}

if [[ "${1:-}" == "--check" ]]; then
  FOUND="$(find_existing_cert)"
  if [[ -n "$FOUND" ]]; then
    echo "Found signing identity: $FOUND"
    exit 0
  fi
  echo "Signing identity '$CERT_NAME' not found in $KEYCHAIN"
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/bz-cert-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/cert.cnf" <<EOF
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
x509_extensions    = v3_codesign
prompt             = no

[ req_distinguished_name ]
CN = $CERT_NAME
O  = Bianzhong Local Dev

[ v3_codesign ]
basicConstraints       = CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/key.pem" \
  -out "$TMP_DIR/cert.pem" \
  -days 3650 \
  -config "$TMP_DIR/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
  -out "$TMP_DIR/cert.p12" \
  -inkey "$TMP_DIR/key.pem" \
  -in "$TMP_DIR/cert.pem" \
  -passout pass:bianzhong >/dev/null 2>&1

if [[ "${1:-}" == "--dry-run" ]]; then
  openssl x509 -in "$TMP_DIR/cert.pem" -noout -subject -ext keyUsage,extendedKeyUsage
  echo "Dry-run OK: certificate template validated for '$CERT_NAME'"
  exit 0
fi

EXISTING="$(find_existing_cert)"
if [[ -n "$EXISTING" ]]; then
  echo "Signing certificate already exists:"
  echo "  $EXISTING"
  exit 0
fi

security import "$TMP_DIR/cert.p12" -k "$KEYCHAIN" -P "bianzhong" -T /usr/bin/codesign
echo "Imported '$CERT_NAME' into $KEYCHAIN."
echo "Next: open Keychain Access, locate '$CERT_NAME', and set 'Code Signing' trust to 'Always Trust' (or run with sudo security add-trusted-cert)."
echo "Then re-run: bash scripts/bundle-app.sh"

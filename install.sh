#!/bin/zsh
# Usage: ./install.sh
#
# Builds CmdTab, signs it with a stable local identity, installs it to /Applications, and launches it.
# On first run it creates a self-signed code-signing certificate in your login keychain. Because every
# build is then signed with the same certificate, macOS keeps the Accessibility and Screen Recording
# grants across rebuilds.
#
# Set CODESIGN_IDENTITY to use a different identity (e.g. an Apple Development certificate).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${CODESIGN_IDENTITY:-CmdTab Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        echo "Signing identity '$IDENTITY' not found in the login keychain." >&2
        exit 1
    fi
    echo "Creating self-signed code-signing certificate '$IDENTITY'..."
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -config "$tmp/cert.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$IDENTITY" -passout pass:cmdtab -out "$tmp/cert.p12"
    security import "$tmp/cert.p12" -k "$KEYCHAIN" -P cmdtab -T /usr/bin/codesign
    echo "Trusting the certificate for code signing (macOS will ask for your password)..."
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
fi

CODESIGN_IDENTITY="$IDENTITY" ./build.sh install

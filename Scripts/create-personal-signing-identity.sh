#!/bin/bash
set -euo pipefail

# Explicit, separately reviewed local setup. Never called by any build script.
# Creates only this signing identity; does not change trust or existing item ACLs.
if [ "${1:-}" != "--create" ]; then
    printf 'Review Documentation/Personal-Signing.md first. To create the local identity, run: %s --create\n' "$0"
    exit 2
fi
umask 077
WHOOSH_CERT_NAME='Whoosh Personal Development'
WHOOSH_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [ ! -f "$WHOOSH_LOGIN_KEYCHAIN" ]; then
    printf 'The expected login Keychain was not found. No identity was created.\n' >&2
    exit 1
fi
if /usr/bin/security find-certificate -c "$WHOOSH_CERT_NAME" "$WHOOSH_LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    printf 'A matching Whoosh certificate already exists. Inspect and reuse it; this script will not create a duplicate.\n' >&2
    exit 1
fi
WHOOSH_CERT_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/whoosh-signing-identity.XXXXXX")"
trap 'rm -rf "$WHOOSH_CERT_TEMP"' EXIT
cat > "$WHOOSH_CERT_TEMP/certificate.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = Whoosh Personal Development
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
    -config "$WHOOSH_CERT_TEMP/certificate.cnf" \
    -keyout "$WHOOSH_CERT_TEMP/private.pem" -out "$WHOOSH_CERT_TEMP/certificate.pem"
chmod 600 "$WHOOSH_CERT_TEMP/private.pem"
# LibreSSL req emits a generic PKCS#8 PEM. security's explicit openssl import
# expects the traditional RSA encoding; normalize it and verify its PEM label.
/usr/bin/openssl rsa -in "$WHOOSH_CERT_TEMP/private.pem" -out "$WHOOSH_CERT_TEMP/private-rsa.pem"
chmod 600 "$WHOOSH_CERT_TEMP/private-rsa.pem"
IFS= read -r WHOOSH_KEY_HEADER < "$WHOOSH_CERT_TEMP/private-rsa.pem"
if [ "$WHOOSH_KEY_HEADER" != '-----BEGIN RSA PRIVATE KEY-----' ]; then
    printf 'Unexpected RSA key encoding; no Keychain import was attempted.\n' >&2
    exit 1
fi
rm -f "$WHOOSH_CERT_TEMP/private.pem"
# No password is passed through argv or logs. The unencrypted private key exists
# only in this mode700 temporary directory until Keychain import completes.
/usr/bin/security import "$WHOOSH_CERT_TEMP/private-rsa.pem" -k "$WHOOSH_LOGIN_KEYCHAIN" \
    -t priv -f openssl -x -T /usr/bin/codesign
/usr/bin/security import "$WHOOSH_CERT_TEMP/certificate.pem" -k "$WHOOSH_LOGIN_KEYCHAIN" -t cert
rm -f "$WHOOSH_CERT_TEMP/private-rsa.pem"
printf 'Created the local code-signing identity. Public certificate fingerprint:\n'
/usr/bin/openssl x509 -in "$WHOOSH_CERT_TEMP/certificate.pem" -noout -fingerprint -sha1
printf 'No trust settings were changed. Prove the designated requirement on two fixtures before signing Whoosh.\n'

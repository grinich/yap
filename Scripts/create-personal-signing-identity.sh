#!/bin/bash
set -euo pipefail

# Explicit, separately reviewed local setup. Never called by any build script.
# Creates only this signing identity; does not change trust or existing item ACLs.
if [ "${1:-}" != "--create" ]; then
    printf 'Review Documentation/Personal-Signing.md first. To create the local identity, run: %s --create\n' "$0"
    exit 2
fi
umask 077
YAP_CERT_NAME='Yap Personal Development'
YAP_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [ ! -f "$YAP_LOGIN_KEYCHAIN" ]; then
    printf 'The expected login Keychain was not found. No identity was created.\n' >&2
    exit 1
fi
if /usr/bin/security find-certificate -c "$YAP_CERT_NAME" "$YAP_LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    printf 'A matching Yap certificate already exists. Inspect and reuse it; this script will not create a duplicate.\n' >&2
    exit 1
fi
YAP_CERT_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/yap-signing-identity.XXXXXX")"
trap 'rm -rf "$YAP_CERT_TEMP"' EXIT
cat > "$YAP_CERT_TEMP/certificate.cnf" <<'CONFIG'
[req]
prompt = no
distinguished_name = subject
x509_extensions = codesign
[subject]
CN = Yap Personal Development
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
/usr/bin/openssl req -new -newkey rsa:3072 -nodes -x509 -sha256 -days 3650 \
    -config "$YAP_CERT_TEMP/certificate.cnf" \
    -keyout "$YAP_CERT_TEMP/private.pem" -out "$YAP_CERT_TEMP/certificate.pem"
chmod 600 "$YAP_CERT_TEMP/private.pem"
# LibreSSL req emits a generic PKCS#8 PEM. security's explicit openssl import
# expects the traditional RSA encoding; normalize it and verify its PEM label.
/usr/bin/openssl rsa -in "$YAP_CERT_TEMP/private.pem" -out "$YAP_CERT_TEMP/private-rsa.pem"
chmod 600 "$YAP_CERT_TEMP/private-rsa.pem"
IFS= read -r YAP_KEY_HEADER < "$YAP_CERT_TEMP/private-rsa.pem"
if [ "$YAP_KEY_HEADER" != '-----BEGIN RSA PRIVATE KEY-----' ]; then
    printf 'Unexpected RSA key encoding; no Keychain import was attempted.\n' >&2
    exit 1
fi
rm -f "$YAP_CERT_TEMP/private.pem"
# No password is passed through argv or logs. The unencrypted private key exists
# only in this mode700 temporary directory until Keychain import completes.
/usr/bin/security import "$YAP_CERT_TEMP/private-rsa.pem" -k "$YAP_LOGIN_KEYCHAIN" \
    -t priv -f openssl -x -T /usr/bin/codesign
/usr/bin/security import "$YAP_CERT_TEMP/certificate.pem" -k "$YAP_LOGIN_KEYCHAIN" -t cert
rm -f "$YAP_CERT_TEMP/private-rsa.pem"
printf 'Created the local code-signing identity. Public certificate fingerprint:\n'
/usr/bin/openssl x509 -in "$YAP_CERT_TEMP/certificate.pem" -noout -fingerprint -sha1
printf 'No trust settings were changed. Prove the designated requirement on two fixtures before signing Yap.\n'

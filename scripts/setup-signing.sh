#!/bin/bash
# One-time setup: create a self-signed codesigning certificate so rebuilds
# keep the same TCC identity (Accessibility / Microphone grants persist).
set -euo pipefail

CERT_NAME="MurmurSign"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "${CERT_NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "Certificate '${CERT_NAME}' already exists — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

# OpenSSL config with codeSigning extended key usage
cat > "${TMP}/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = ${CERT_NAME}
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "${TMP}/key.pem" -out "${TMP}/cert.pem" \
    -config "${TMP}/cert.cnf" -extensions v3 >/dev/null 2>&1

openssl pkcs12 -export -out "${TMP}/cert.p12" \
    -inkey "${TMP}/key.pem" -in "${TMP}/cert.pem" \
    -passout pass: -name "${CERT_NAME}" >/dev/null 2>&1

security import "${TMP}/cert.p12" -k "${KEYCHAIN}" -P "" \
    -T /usr/bin/codesign -A >/dev/null

# Trust the cert for codesigning (requires sudo via GUI prompt)
sudo security add-trusted-cert -d -r trustRoot \
    -p codeSign -k /Library/Keychains/System.keychain "${TMP}/cert.pem"

echo ""
echo "Certificate '${CERT_NAME}' created and trusted for codesigning."
echo "Now rebuild: bash scripts/build.sh"
echo "After the first install + permission grant, future rebuilds will keep TCC grants."

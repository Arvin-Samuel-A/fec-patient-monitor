#!/bin/bash
set -e
ROOT=$(cd "$(dirname $0)/.." && pwd)
CERTS=$ROOT/certs
mkdir -p $CERTS/ca $CERTS/edge-a $CERTS/edge-b $CERTS/fog

# ── Extension config files ──────────────────────────────────────────────────
cat > $CERTS/ca/ca.cnf <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_ca
prompt = no

[req_dn]
CN = FEC-CA
O = FEC

[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF

cat > $CERTS/fog/fog-ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:fog-service,DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# Extension for edge SERVER certs (IoT→Edge TLS)
cat > $CERTS/server-ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# Extension for edge CLIENT certs (Edge→Fog mTLS)
cat > $CERTS/client-ext.cnf <<EOF
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# 1. CA key and self-signed cert (with keyUsage extensions)
openssl genrsa -out $CERTS/ca/ca.key 4096
openssl req -x509 -new -nodes -key $CERTS/ca/ca.key \
  -sha256 -days 365 -out $CERTS/ca/ca.crt \
  -config $CERTS/ca/ca.cnf

# 2. Fog SERVER cert (signed by CA, with SAN)
openssl genrsa -out $CERTS/fog/fog.key 2048
openssl req -new -key $CERTS/fog/fog.key \
  -out $CERTS/fog/fog.csr \
  -subj "/CN=fog-service/O=FEC"
openssl x509 -req -in $CERTS/fog/fog.csr \
  -CA $CERTS/ca/ca.crt -CAkey $CERTS/ca/ca.key \
  -CAcreateserial -out $CERTS/fog/fog.crt -days 365 -sha256 \
  -extfile $CERTS/fog/fog-ext.cnf

# 3. Edge-A CLIENT cert (signed by CA)
openssl genrsa -out $CERTS/edge-a/client.key 2048
openssl req -new -key $CERTS/edge-a/client.key \
  -out $CERTS/edge-a/client.csr \
  -subj "/CN=edge-a/O=FEC"
openssl x509 -req -in $CERTS/edge-a/client.csr \
  -CA $CERTS/ca/ca.crt -CAkey $CERTS/ca/ca.key \
  -CAcreateserial -out $CERTS/edge-a/client.crt -days 365 -sha256 \
  -extfile $CERTS/client-ext.cnf

# 4. Edge-B CLIENT cert (signed by CA)
openssl genrsa -out $CERTS/edge-b/client.key 2048
openssl req -new -key $CERTS/edge-b/client.key \
  -out $CERTS/edge-b/client.csr \
  -subj "/CN=edge-b/O=FEC"
openssl x509 -req -in $CERTS/edge-b/client.csr \
  -CA $CERTS/ca/ca.crt -CAkey $CERTS/ca/ca.key \
  -CAcreateserial -out $CERTS/edge-b/client.crt -days 365 -sha256 \
  -extfile $CERTS/client-ext.cnf

# 5. Edge SERVER certs for IoT→Edge TLS (SAN=localhost so IoT can verify)
for EDGE in edge-a edge-b; do
  openssl genrsa -out $CERTS/$EDGE/server.key 2048
  openssl req -new -key $CERTS/$EDGE/server.key \
    -out $CERTS/$EDGE/server.csr \
    -subj "/CN=localhost/O=FEC"
  openssl x509 -req -in $CERTS/$EDGE/server.csr \
    -CA $CERTS/ca/ca.crt -CAkey $CERTS/ca/ca.key \
    -CAcreateserial -out $CERTS/$EDGE/server.crt -days 365 -sha256 \
    -extfile $CERTS/server-ext.cnf
done

# Clean up temp config files
rm -f $CERTS/fog/fog-ext.cnf $CERTS/server-ext.cnf $CERTS/client-ext.cnf $CERTS/ca/ca.cnf

echo "All certificates generated successfully."

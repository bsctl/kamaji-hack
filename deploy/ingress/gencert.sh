#!/bin/bash

# Check if OpenSSL is installed
if [[ ! -x "$(command -v openssl)" ]]; then
    echo "Error: openssl not found"
    exit 1
fi

DOMAIN=$1
if [[ -z ${DOMAIN} ]]; then
    echo "Domain has not been specified"
    echo "for example ./gencert.sh domain.org"
    exit 1
fi

mkdir -p certs
cat <<EOF > certs/openssl.cnf
[req]
req_extensions      = req_ext
distinguished_name  = req_distinguished_name
prompt              = no

[req_ext]
subjectAltName = @alt_names

[req_distinguished_name]
commonName=${DOMAIN}

[client]
basicConstraints=CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth

[server]
basicConstraints=CA:TRUE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = localhost
DNS.2 = *.${DOMAIN}

EOF

echo "generate certs:"

openssl genrsa -out certs/rootCA.key 2048
openssl req -x509 -new -nodes -key certs/rootCA.key -sha256 -days 3650 -out certs/rootCA.crt
openssl genrsa -out certs/tls.key 2048
openssl req -subj "/CN=${DOMAIN}" -sha256 -new -key certs/tls.key -out certs/request.csr
openssl req -in certs/request.csr -noout -text
openssl x509 -req -in certs/request.csr -CA certs/rootCA.crt -CAkey certs/rootCA.key -CAcreateserial -out certs/tls.crt -days 365 -extfile certs/openssl.cnf -extensions req_ext
openssl x509 -in certs/tls.crt -noout -text

echo "create a secret with certs:"
echo "kubectl create secret tls <name> --cert=certs/tls.crt --key=certs/tls.key"
echo "."
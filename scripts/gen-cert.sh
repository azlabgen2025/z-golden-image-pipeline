#!/usr/bin/env bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
# Generate a self-signed TLS certificate for the web app.
# Usage: ./scripts/gen-cert.sh [output-dir] [domain...]
# Example: ./scripts/gen-cert.sh certs localhost 127.0.0.1 192.168.1.216
# Then run: TLS_CERT=certs/tls.crt TLS_KEY=certs/tls.key python3 web/app.py
set -euo pipefail

OUTDIR="${1:-certs}"
shift || true
DOMAINS=( "$@" )
if [ "${#DOMAINS[@]}" -eq 0 ]; then
    DOMAINS=(localhost 127.0.0.1)
fi

mkdir -p "$OUTDIR"
CERT="$OUTDIR/tls.crt"
KEY="$OUTDIR/tls.key"

# Build SAN list (DNS:..,IP:...) from the domain args
SAN=""
for d in "${DOMAINS[@]}"; do
    if [[ "$d" =~ ^[0-9.]+$ ]]; then
        SAN="${SAN}IP:${d},"
    else
        SAN="${SAN}DNS:${d},"
    fi
done
SAN="${SAN%,}"

# openssl 3.x deprecates -addext; use an ext config file for compatibility.
EXTFILE="$OUTDIR/openssl-ext.cnf"
cat > "$EXTFILE" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${DOMAINS[0]}
[v3_req]
subjectAltName = $SAN
EOF

openssl req -x509 -nodes \
    -newkey rsa:2048 \
    -sha256 \
    -days 365 \
    -keyout "$KEY" \
    -out "$CERT" \
    -config "$EXTFILE" \
    >/dev/null 2>&1

rm -f "$EXTFILE"

chmod 600 "$KEY"
echo "Certificate:  $CERT"
echo "Private key:  $KEY"
echo
echo "Run the app with HTTPS:"
echo "  TLS_CERT=$CERT TLS_KEY=$KEY python3 web/app.py"
echo "Or docker:  docker compose up -d   (with certs/ mounted + TLS_CERT/TLS_KEY env)"
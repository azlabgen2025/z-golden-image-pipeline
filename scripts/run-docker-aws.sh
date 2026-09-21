#!/usr/bin/env bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
#
# Pull-and-run the prebuilt Golden Image Pipeline container on stock Ubuntu (EC2 or elsewhere).
# No repo clone or Docker build required — everything is in the prebuilt GHCR image.
#
# Usage:
#   ./run-docker-aws.sh <public-ip-or-dns>            # HTTP on port 8080 (open SG 8080)
#   ./run-docker-aws.sh <public-ip-or-dns> --https     # HTTPS on 443 (open SG 443, self-signed cert)
set -euo pipefail

PUBLIC_IP="${1:-}"
HTTPS_FLAG="${2:-}"
if [ -z "$PUBLIC_IP" ]; then
  echo "Usage: $0 <public-ip-or-dns> [--https]"
  echo "  Run with --https to use port 443 and generate a self-signed cert."
  echo "  Otherwise the app serves plain HTTP on port 8080."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
IMAGE="ghcr.io/azlabgen2025/z-golden-image-pipeline:latest"
APP_DIR=/opt/golden-image-pipeline

# ---- 1. Install Docker (idempotent) ----
echo "==> Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "  Installing docker.io..."
  apt-get update -y
  apt-get install -y docker.io docker-compose-v2
  systemctl enable --now docker >/dev/null 2>&1 || true
else
  echo "  Docker already installed: $(docker --version)"
fi

# ---- 2. Pull the prebuilt image ----
echo "==> Pulling image (no build required)..."
docker pull "$IMAGE"

# ---- 3. Stop any previous container with the same name ----
docker rm -f golden-image-pipeline 2>/dev/null || true

# ---- 4. Certs (optional --https mode) ----
CERT_OPTS=()
PORT_MAP="-p 8080:8080"
PROTOCOL="http"
if [ "$HTTPS_FLAG" = "--https" ]; then
  echo "==> Generating self-signed cert for $PUBLIC_IP (HTTPS mode)..."
  mkdir -p "$APP_DIR/certs"
  CERT="$APP_DIR/certs/tls.crt"
  KEY="$APP_DIR/certs/tls.key"
  EXTFILE="$APP_DIR/certs/ext.cnf"
  cat > "$EXTFILE" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $PUBLIC_IP
[v3_req]
subjectAltName = IP:$PUBLIC_IP,DNS:localhost,IP:127.0.0.1
EOF
  openssl req -x509 -nodes \
    -newkey rsa:2048 -sha256 -days 365 \
    -keyout "$KEY" -out "$CERT" -config "$EXTFILE" >/dev/null 2>&1
  rm -f "$EXTFILE"
  chmod 600 "$KEY"
  CERT_OPTS=(-v "$APP_DIR/certs:/app/certs:ro")
  PORT_MAP="-p 443:8080"
  PROTOCOL="https"
  echo "  Open port 443 in your EC2 Security Group before accessing."
else
  echo "  Open port 8080 in your EC2 Security Group before accessing."
fi

# ---- 5. Generate a random admin password ----
ADMIN_PASSWORD="$(openssl rand -hex 16)"
mkdir -p "$APP_DIR"
cat > "$APP_DIR/.env" <<ENVEOF
ADMIN_USER=admin
ADMIN_PASSWORD=${ADMIN_PASSWORD}
ENVEOF
chmod 600 "$APP_DIR/.env"

# ---- 6. Run the container ----
echo "==> Starting container..."
docker run -d --name golden-image-pipeline \
  --restart unless-stopped \
  $PORT_MAP \
  "${CERT_OPTS[@]}" \
  -e ADMIN_USER=admin \
  -e ADMIN_PASSWORD="$ADMIN_PASSWORD" \
  -e FLASK_DEBUG=false \
  -v golden-image-data:/app/data \
  "$IMAGE"

echo
echo "=================================================="
echo "  Golden Image Pipeline — running on $PUBLIC_IP"
echo
echo "  URL:   ${PROTOCOL}://${PUBLIC_IP}${PORT_MAP%%:*}"
echo "  Login: admin / $ADMIN_PASSWORD"
echo
echo "  Health: curl -sk ${PROTOCOL}://${PUBLIC_IP}/api/health"
echo "  Stop:   docker stop golden-image-pipeline"
echo "  Start:  docker start golden-image-pipeline"
echo "  Remove: docker rm -f golden-image-pipeline"
echo "=================================================="
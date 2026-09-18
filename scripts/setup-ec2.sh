#!/usr/bin/env bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
#
# One-shot deployer for the golden-image-pipeline web app on a fresh EC2 box.
# Installs Docker + Compose, clones the repo (public URL), generates a self-signed
# TLS cert for the box's public IP/hostname, writes a secure .env, and starts the
# container. Designed for a short-lived demo instance.
#
# Usage on Ubuntu 24.04:
#   ssh ubuntu@<box-ip> 'bash -s' < scripts/setup-ec2.sh <repo-url> <public-ip-or-dns>
# or copy + run on the box:
#   ./scripts/setup-ec2.sh https://github.com/<you>/golden-image-pipeline.git <ip-or-dns>
#
# After it completes:
#   * open https://<box-ip>  (self-signed cert warning is expected -> click through)
#   * log in with admin / <ADMIN_PASSWORD shown in /opt/golden-image-pipeline/.env>
#   * add your AWS account + GitHub connection in the app's Settings, then build
#
# Stop the demo safely (reduces billing to ~$0 while idle):
#   docker compose stop      # container stopped, data volume preserved
#   docker compose start     # bring it back up for the next demo
set -euo pipefail

REPO_URL="${1:-}"
PUBLIC_IP="${2:-}"
if [ -z "$REPO_URL" ] || [ -z "$PUBLIC_IP" ]; then
  echo "Usage: $0 <repo-url> <public-ip-or-dns>"
  echo "Example: $0 https://github.com/you/golden-image-pipeline.git 1.2.3.4"
  exit 1
fi

APP_DIR=/opt/golden-image-pipeline
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing Docker + Compose + git..."
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker.io docker-compose-v2 git openssl ca-certificates curl jq
  systemctl enable --now docker
fi

echo "==> Cloning repo..."
if [ ! -d "$APP_DIR" ]; then
  git clone "$REPO_URL" "$APP_DIR"
else
  git -C "$APP_DIR" pull --ff-only || echo "  (pull failed; using existing checkout)"
fi
cd "$APP_DIR"

echo "==> Generating self-signed TLS cert for $PUBLIC_IP..."
mkdir -p certs
./scripts/gen-cert.sh certs localhost "$PUBLIC_IP" 127.0.0.1

echo "==> Writing .env (random admin password)..."
if [ ! -f .env ]; then
  ADMIN_PASSWORD="$(openssl rand -hex 16)"
  {
    echo "ADMIN_USER=admin"
    echo "ADMIN_PASSWORD=${ADMIN_PASSWORD}"
    echo "APP_PORT=443"
  } > .env
  chmod 600 .env
else
  echo "  (.env exists; leaving as is)"
fi

echo "==> Starting the stack on https://${PUBLIC_IP}/ ..."
docker compose up -d --build

echo
echo "==============================================="
echo "Deploy complete."
echo "   URL:      https://${PUBLIC_IP}/            (self-signed warning is OK)"
echo "   Admin:    admin / $(grep ADMIN_PASSWORD .env | cut -d= -f2)"
echo "   Health:   curl -sk https://${PUBLIC_IP}/api/version"
echo
echo "Next:        add AWS account + GitHub connection in the app Settings,"
echo "             then dispatch a build."
echo "Stop/Start:  docker compose stop   |   docker compose start"
echo "Full reset:  ./scripts/reset.sh docker"
echo "==============================================="
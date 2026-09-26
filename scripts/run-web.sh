#!/usr/bin/env bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
# Run the Golden Image Pipeline web app.
#   ./scripts/run-web.sh          # local: auto-enables HTTPS if certs/ exists
#   ./scripts/run-web.sh docker   # Docker: build + up, auto-enables HTTPS too
#
# Certs: generate once with ./scripts/gen-cert.sh certs localhost 127.0.0.1 <lan-ip>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CERT="$ROOT/certs/tls.crt"
KEY="$ROOT/certs/tls.key"

MODE="${1:-local}"

run_local() {
    cd "$ROOT"
    export DATABASE_PATH="${DATABASE_PATH:-$ROOT/web/golden_image.db}"
    export SECRET_KEY_FILE="${SECRET_KEY_FILE:-$ROOT/web/secret.key}"
    export FLASK_DEBUG="${FLASK_DEBUG:-false}"
    export PORT="${PORT:-8080}"
    if [ -z "${FLASK_SECRET:-}" ]; then
        echo "FLASK_SECRET not set -> an ephemeral session key is generated, so"
        echo "you will be logged out on restart. Set FLASK_SECRET in .env to keep"
        echo "sessions across restarts."
    fi
    if [ -z "${ADMIN_PASSWORD:-}" ] && [ ! -f "$DATABASE_PATH" ]; then
        echo "No ADMIN_PASSWORD set and no existing database -> the default"
        echo "admin/admin credentials will be created. Set ADMIN_PASSWORD in .env"
        echo "to choose your own before the first run."
    fi

    "$SCRIPT_DIR/build-version.sh"

    if [ -f "$CERT" ] && [ -f "$KEY" ]; then
        export TLS_CERT="$CERT"
        export TLS_KEY="$KEY"
        echo "HTTPS enabled  -> https://localhost:${PORT}"
    else
        unset TLS_CERT TLS_KEY 2>/dev/null || true
        echo "No certs found at certs/tls.crt -> serving HTTP on http://localhost:${PORT}"
        echo "Generate once with: ./scripts/gen-cert.sh certs localhost 127.0.0.1 <lan-ip>"
    fi
    exec python3 web/app.py
}

run_docker() {
    cd "$ROOT"
    "$SCRIPT_DIR/build-version.sh"
    if [ -f "$CERT" ] && [ -f "$KEY" ]; then
        echo "HTTPS enabled in container -> https://localhost:8080"
    else
        echo "No certs found -> serving HTTP in container on http://localhost:8080"
    fi
    exec docker compose up --build -d
}

case "$MODE" in
    docker|compose) run_docker ;;
    local|"")       run_local ;;
    *) echo "Usage: $0 [local|docker]"; exit 1 ;;
esac
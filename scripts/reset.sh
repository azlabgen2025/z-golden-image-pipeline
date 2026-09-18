#!/usr/bin/env bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
# FULL FRESH START: stop the app, wipe DB + caches, and start with a pristine DB.
# Usage:
#   ./scripts/reset.sh            # reset + start (local; HTTPS if certs/ exist)
#   ./scripts/reset.sh docker     # reset + start in Docker
#   ./scripts/reset.sh --no-start # reset only (don't launch the app)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DB="$ROOT/web/golden_image.db"

echo "==> Stopping any running web app (any port, any directory)..."
pkill -9 -f "app.py" 2>/dev/null || true
pkill -9 -f "gunicorn" 2>/dev/null || true
if command -v docker >/dev/null 2>&1; then
    docker compose -f "$ROOT/docker-compose.yml" down --remove-orphans 2>/dev/null || true
fi
sleep 0.5

echo "==> Removing DB, encryption key, and Python caches..."
rm -f "$DB"
rm -f "$ROOT/web/secret.key"
rm -rf "$ROOT/web/__pycache__" "$ROOT/__pycache__"

echo "==> Creating pristine DB (single admin: admin / admin, must-change banner shown)..."
cd "$ROOT"
DATABASE_PATH="$DB" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "web"))
os.environ["DATABASE_PATH"] = os.path.abspath("web/golden_image.db")
import db
db.init_db()
db.create_default_admin()
u = db.authenticate("admin", "admin")
print("    admin/admin ready, must_change=%s" % u["must_change_password"])
PY

echo "==> Generating build version marker..."
"$SCRIPT_DIR/build-version.sh"

case "${1:-}" in
    "--no-start")
        echo "==> Done (reset only). Start with: ./scripts/run-web.sh [docker]"
        ;;
    docker)
        echo "==> Starting in Docker..."
        exec "$SCRIPT_DIR/run-web.sh" docker
        ;;
    "")
        echo "==> Starting..."
        exec "$SCRIPT_DIR/run-web.sh" local
        ;;
    *)
        echo "Usage: $0 [--no-start|docker]"
        exit 1
        ;;
esac
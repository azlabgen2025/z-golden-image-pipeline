#!/bin/sh
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
# Container entrypoint: init the DB, auto-enable HTTPS when certs are mounted
# at /app/certs, then serve the app with gunicorn (production WSGI server).
set -e

export PORT="${PORT:-8080}"
export DATABASE_PATH="${DATABASE_PATH:-/app/data/golden_image.db}"
export SECRET_KEY_FILE="${SECRET_KEY_FILE:-/app/data/app.key}"

# Bake a build marker so /api/version reports something useful in the container.
# A version.json baked into the image (git-tracked VERSION + web/version.json)
# is kept unless BUILD_ID / BUILD_COMMIT env vars are explicitly provided.
if [ -n "${BUILD_ID}" ] && [ -n "${BUILD_COMMIT}" ]; then
  cat > /app/web/version.json <<EOF
{
  "version": "${VERSION:-0.0.0}",
  "build": "${BUILD_ID}",
  "commit": "${BUILD_COMMIT}",
  "date": "$(date +%Y-%m-%d)",
  "marker": "build ${BUILD_ID} · container"
}
EOF
fi

# Auto-generate a Flask session secret if none is provided.
if [ -z "${FLASK_SECRET}" ]; then
    export FLASK_SECRET="$(python -c "from secrets import token_hex; print(token_hex(32))")"
fi

TLS_CERTFILE=""
if [ -f /app/certs/tls.crt ] && [ -f /app/certs/tls.key ]; then
    export TLS_CERT=/app/certs/tls.crt
    export TLS_KEY=/app/certs/tls.key
    TLS_CERTFILE="--certfile /app/certs/tls.crt --keyfile /app/certs/tls.key"
    SCHEME="HTTPS"
else
    SCHEME="HTTP"
fi

python -c "import os, db; from app import app as _; db.init_db(); db.create_default_admin()"

echo "[entrypoint] gunicorn on 0.0.0.0:$PORT ($SCHEME) [build ${BUILD_ID}]"
exec gunicorn \
    --bind "0.0.0.0:${PORT}" \
    --workers "${GUNICORN_WORKERS:-2}" \
    --threads "${GUNICORN_THREADS:-4}" \
    --timeout "${GUNICORN_TIMEOUT:-60}" \
    --access-logfile - \
    --error-logfile - \
    ${TLS_CERTFILE} \
    "app:app"
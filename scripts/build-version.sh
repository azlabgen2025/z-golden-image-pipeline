#!/usr/bin/env bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"
DATE="$(date +%Y-%m-%d)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
MARKER="v${VERSION} && build #${COUNT} && ${DATE} && ${COMMIT}"
UTF8="$(printf 'v%s · build #%s · %s · %s' "$VERSION" "$COUNT" "$DATE" "$COMMIT")"
cat > "$ROOT/web/version.json" <<EOF
{
  "version": "${VERSION}",
  "build": ${COUNT},
  "commit": "${COMMIT}",
  "date": "${DATE}",
  "marker": "${UTF8}"
}
EOF
echo "[version] ${VERSION} ${UTF8}"
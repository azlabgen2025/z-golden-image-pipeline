#!/bin/bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
set -euo pipefail

# Local packer build helper for testing without GitHub Actions
# Usage: ./scripts/packer-build.sh <image> [customer] [extra_packages]
#   image: amazon-linux | ubuntu | debian | rocky | fedora | rhel | almalinux | other

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

IMAGE="${1:-amazon-linux}"
CUSTOMER="${2:-shared}"
EXTRA_PACKAGES="${3:-}"

VALID_IMAGES="amazon-linux ubuntu debian rocky fedora rhel almalinux other"
if [[ ! " $VALID_IMAGES " =~ " $IMAGE " ]]; then
  echo "ERROR: Invalid image '$IMAGE'. Valid options: $VALID_IMAGES" >&2
  exit 1
fi

if [[ ! -d "$PROJECT_ROOT/packer/$IMAGE" ]]; then
  echo "ERROR: Packer directory not found: packer/$IMAGE" >&2
  exit 1
fi

cd "$PROJECT_ROOT/packer/$IMAGE"

echo "Initializing Packer..."
packer init .

echo "Validating template..."
packer validate .

echo "Building image for customer: $CUSTOMER"
ARGS=(-var "customer=$CUSTOMER")
if [[ -n "$EXTRA_PACKAGES" ]]; then
  LIST="$(echo "$EXTRA_PACKAGES" | sed 's/[^,]*/"&"/g' | sed '1s/^/[/; $s/$/]/')"
  ARGS+=(-var "extra_packages=$LIST")
fi

packer build "${ARGS[@]}" .

echo "Build complete! AMI details in packer/manifest.json"
#!/bin/bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
#
# Generate the SSH keypair that the pipeline bakes into every image it builds.
#
# The PUBLIC key is written into ansible/base/vars/golden_user.pub, which the
# playbooks bake into ec2-user's authorized_keys. The PRIVATE key is what you
# use to SSH into the images, and what GitHub Actions needs as the
# GOLDEN_SSH_PRIVATE_KEY secret in order to build customized (layer 2) images.
#
# RSA-2048 on purpose: Debian, AlmaLinux and RHEL 10 cloud images reject
# ED25519 authorized keys, so an ED25519 pair would produce images you cannot
# log into.
#
# Usage:
#   ./scripts/setup-keys.sh                 # default path + print instructions
#   ./scripts/setup-keys.sh ~/.ssh/mykey    # custom path
#   KEY_PATH=~/.ssh/mykey ./scripts/setup-keys.sh
#   ./scripts/setup-keys.sh --force         # overwrite an existing pair
set -euo pipefail

KEY_PATH="${KEY_PATH:-$HOME/.ssh/golden-image}"
FORCE=false
for a in "$@"; do
  case "$a" in
    --force) FORCE=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) KEY_PATH="$a" ;;
  esac
done

case "$KEY_PATH" in
  /*) ;;
  *) KEY_PATH="$PWD/$KEY_PATH" ;;
esac

if [ -e "$KEY_PATH" ] || [ -e "${KEY_PATH}.pub" ]; then
  if [ "$FORCE" != true ]; then
    echo "ERROR: $KEY_PATH already exists. Not overwriting." >&2
    echo "       Re-run with --force if you really mean to replace it." >&2
    echo "       WARNING: existing images were built with the OLD key. They will" >&2
    echo "       still trust it, but this new key will not log into them." >&2
    exit 1
  fi
  rm -f "$KEY_PATH" "${KEY_PATH}.pub"
fi

mkdir -p "$(dirname "$KEY_PATH")"
# Do NOT chmod the parent directory: it may be a shared location we do not own
# (/tmp, a group dir), and failing there would abort key generation. ssh-keygen
# creates the private key 0600 already, and we assert it below.

echo "==> Generating RSA-2048 keypair at ${KEY_PATH}"
ssh-keygen -t rsa -b 2048 -N "" -C "golden-image-pipeline" -f "$KEY_PATH" >/dev/null
chmod 600 "$KEY_PATH"
chmod 644 "${KEY_PATH}.pub"

# Publish the public half where the playbooks expect it for local builds.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARS_DIR="$REPO_ROOT/ansible/base/vars"
if [ -d "$VARS_DIR" ]; then
  mkdir -p "$VARS_DIR"
  # Strip the comment: a trailing "golden-image-pipeline" is harmless in
  # authorized_keys, but keeping the file to exactly "ssh-rsa AAAA..." means the
  # same bytes are used whether they come from here or from the workflow.
  awk '{print $1" "$2}' "${KEY_PATH}.pub" > "$VARS_DIR/golden_user.pub"
  echo "==> Wrote ${VARS_DIR}/golden_user.pub (git-ignored, never commit it)"
fi

echo
echo "==> Key fingerprint:"
ssh-keygen -lf "${KEY_PATH}.pub" | sed 's/^/    /'
echo
echo "Private key : ${KEY_PATH}      (keep this, chmod 600)"
echo "Public key  : ${KEY_PATH}.pub"
echo
echo "SSH into an image built from this key with:"
echo "    ssh -i ${KEY_PATH} ec2-user@<instance-ip>"
echo
echo "NEXT: store the private key as a GitHub Actions secret so the workflow"
echo "can build customized (layer 2) images:"
echo
if command -v gh >/dev/null 2>&1; then
  echo "    gh secret set GOLDEN_SSH_PRIVATE_KEY < ${KEY_PATH}"
else
  echo "    (install the GitHub CLI for 'gh secret set', or paste the contents"
  echo "     of ${KEY_PATH} into your repo's Actions secrets by hand)"
fi
echo
echo "    Repo -> Settings -> Secrets and variables -> Actions -> New repository secret"
echo "    Name: GOLDEN_SSH_PRIVATE_KEY   Value: the single line inside ${KEY_PATH}"
echo
echo "NOTE: never commit ${KEY_PATH}. The .gitignore already excludes *.pem,"
echo "      but keep the key outside the repo to be safe."

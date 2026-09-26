#!/bin/bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
#
# One-shot first-time setup. Run this once in your clone and the pipeline is
# ready to build:
#
#   1. generate the SSH keypair the images will trust
#   2. create the OIDC provider + GitHubActionsPackerRole in YOUR AWS account
#   3. publish the role ARN and the private key as GitHub Actions secrets
#   4. tell you what is left (the web app connection)
#
# Safe to re-run. It will not overwrite your SSH key without --force-keys.
#
# Usage:
#   ./scripts/bootstrap.sh                       # prompts for owner/repo + region
#   ./scripts/bootstrap.sh myname/myrepo         # non-interactive
#   ./scripts/bootstrap.sh myname/myrepo us-east-1
#   ./scripts/bootstrap.sh --dry-run myname/myrepo
#   ./scripts/bootstrap.sh --skip-secrets myname/myrepo   # no gh / manual secrets
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/golden-image}"

DRY_RUN=false
SKIP_SECRETS=false
FORCE_KEYS=false
# Parse flags in any position. A plain `for a in "$@"` loop cannot do this: the
# list is expanded once, so a trailing --dry-run would shift the positional
# arguments and turn "repo us-east-1 --dry-run" into repo=us-east-1.
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=true ;;
        --skip-secrets) SKIP_SECRETS=true ;;
        --force-keys)   FORCE_KEYS=true ;;
        -h|--help)      sed -n '4,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)             shift; POSITIONAL+=("$@"); break ;;
        -*)             echo "ERROR: unknown option: $1" >&2
                         echo "Try: $0 --help" >&2; exit 2 ;;
        *)              POSITIONAL+=("$1") ;;
    esac
    shift
done

# ---- resolve owner/repo + region -------------------------------------------
REPO_FULL="${POSITIONAL[0]:-${GITHUB_REPO:-}}"
REGION="${POSITIONAL[1]:-${AWS_REGION:-us-east-1}}"

if [ -z "$REPO_FULL" ]; then
  if [ ! -t 0 ]; then
    echo "ERROR: no repository given and stdin is not a terminal." >&2
    echo "Usage: $0 <owner/repo> [region]" >&2
    echo "Example: $0 myname/z-golden-image-pipeline" >&2
    exit 2
  fi
  echo "Which GitHub repository holds YOUR copy of this pipeline?"
  echo "  - If you forked it:  yourname/z-golden-image-pipeline"
  echo "  - Not a fork yet?    create it on GitHub first, then re-run."
  read -r -p "owner/repo: " REPO_FULL
fi

GITHUB_OWNER="${REPO_FULL%%/*}"
GITHUB_REPO="${REPO_FULL##*/}"

echo "=============================================="
echo " Golden Image Pipeline - first-time setup"
echo "=============================================="
echo "Repository : ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "Region     : ${REGION}"
echo

# ---- 1. SSH keypair ---------------------------------------------------------
echo "--- [1/3] SSH keypair -------------------------------------"
if { [ -e "$KEY_PATH" ] || [ -e "${KEY_PATH}.pub" ]; } && [ "$FORCE_KEYS" != true ]; then
    echo "    ${KEY_PATH} already exists; keeping it."
    echo "    (use --force-keys to replace; images built earlier keep the old key)"
else
    if [ "$DRY_RUN" = true ]; then
        echo "    would generate ${KEY_PATH}"
    else
        # setup-keys.sh refuses to clobber an existing pair, so clear it first
        # when the user explicitly asked for a replacement.
        rm -f "$KEY_PATH" "${KEY_PATH}.pub"
        "$REPO_ROOT/scripts/setup-keys.sh" "$KEY_PATH" >/dev/null
        echo "    generated ${KEY_PATH}"
        ssh-keygen -lf "${KEY_PATH}.pub" | sed 's/^/    /'
    fi
fi
echo

# ---- 2. AWS OIDC provider + role -------------------------------------------
echo "--- [2/3] AWS IAM + OIDC -------------------------------"
if [ "$DRY_RUN" = true ]; then
  "$REPO_ROOT/scripts/setup-aws.sh" --dry-run "$REPO_FULL" "$REGION"
else
  "$REPO_ROOT/scripts/setup-aws.sh" "$REPO_FULL" "$REGION"
fi
echo

# ---- 3. GitHub secrets ------------------------------------------------------
echo "--- [3/3] GitHub Actions secrets -----------------------"
ROLE_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text 2>/dev/null):role/GitHubActionsPackerRole"

if [ "$SKIP_SECRETS" = true ]; then
  echo "    skipped (--skip-secrets). Add these by hand:"
  echo "      AWS_ROLE_TO_ASSUME     = ${ROLE_ARN}"
  echo "      GOLDEN_SSH_PRIVATE_KEY = contents of ${KEY_PATH}"
elif [ "$DRY_RUN" = true ]; then
  echo "    would set AWS_ROLE_TO_ASSUME and GOLDEN_SSH_PRIVATE_KEY"
  echo "    on ${GITHUB_OWNER}/${GITHUB_REPO} (skipped: dry run)"
elif ! command -v gh >/dev/null 2>&1; then
  echo "    GitHub CLI (gh) not found. Add these two secrets by hand:"
  echo "      repo -> Settings -> Secrets and variables -> Actions"
  echo "        AWS_ROLE_TO_ASSUME     = ${ROLE_ARN}"
  echo "        GOLDEN_SSH_PRIVATE_KEY = contents of ${KEY_PATH}"
  echo
  echo "    Install gh to automate this: https://cli.github.com"
else
  if ! gh auth status >/dev/null 2>&1; then
    echo "    gh is installed but not authenticated. Run: gh auth login"
    echo "    Then add the two secrets by hand as shown above."
  else
    gh secret set AWS_ROLE_TO_ASSUME --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --body "$ROLE_ARN"
    echo "    set AWS_ROLE_TO_ASSUME"
    gh secret set GOLDEN_SSH_PRIVATE_KEY --repo "${GITHUB_OWNER}/${GITHUB_REPO}" < "$KEY_PATH"
    echo "    set GOLDEN_SSH_PRIVATE_KEY"
  fi
fi
echo

# ---- done -------------------------------------------------------------------
echo "=============================================="
echo " Setup finished. Next:"
echo "=============================================="
echo
echo " 1. Confirm Actions are enabled on your repo:"
echo "      ${GITHUB_OWNER}/${GITHUB_REPO} -> Settings -> Actions -> Enable"
echo "      (a fresh fork starts with Actions disabled)"
echo
echo " 2. Start the web app:"
echo "      docker compose up -d --build"
echo "      (or: curl -fsSL https://raw.githubusercontent.com/${GITHUB_OWNER}/${GITHUB_REPO}/main/scripts/run-docker-aws.sh | sudo bash -s <public-ip>)"
echo
echo " 3. Log in, then Settings -> Connect AWS and paste an IAM access key"
echo "    from THIS AWS account (account $( [ -n "$ROLE_ARN" ] && aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '?') )."
echo "    That key is only used to list images and show status; builds use the role above."
echo
echo " 4. Verify everything before your first (slow) build:"
echo "      ./scripts/verify-setup.sh ${GITHUB_OWNER}/${GITHUB_REPO} ${REGION}"
echo
echo " 5. First build: start with amazon-linux. Rocky/AlmaLinux need a one-time"
echo "    free Marketplace subscribe; see README."
echo

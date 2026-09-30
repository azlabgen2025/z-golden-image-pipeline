#!/bin/bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
#
# Check everything the build depends on, WITHOUT launching a build. A build
# takes up to 45 minutes and bills money; this takes seconds.
#
# Usage:
#   ./scripts/verify-setup.sh <owner/repo> [region]
#   GITHUB_REPO=myorg/myrepo ./scripts/verify-setup.sh
set -uo pipefail

REPO_FULL="${1:-${GITHUB_REPO:-}}"
REGION="${2:-${AWS_REGION:-us-east-1}}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/golden-image}"
ROLE_NAME="${ROLE_NAME:-GitHubActionsPackerRole}"
POLICY_NAME="${POLICY_NAME:-GoldenImagePackerPolicy}"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }
info() { printf '        %s\n' "$1"; }

echo "=============================================="
echo " Golden Image Pipeline - setup verification"
echo "=============================================="
[ -n "$REPO_FULL" ] && echo "Repository: ${REPO_FULL}" || echo "Repository: (not given)"
echo "Region:     ${REGION}"
echo

if [ -z "$REPO_FULL" ]; then
  echo "Usage: $0 <owner/repo> [region]" >&2
  exit 2
fi
if ! printf '%s' "$REPO_FULL" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
  bad "repository '${REPO_FULL}' is not a valid owner/repo"
  echo; echo "Cannot continue."; exit 1
fi
OWNER="${REPO_FULL%%/*}"; REPO="${REPO_FULL##*/}"

# ---- 1. local prerequisites -------------------------------------------------
echo "--- [1/5] Local prerequisites ---"
if command -v aws >/dev/null 2>&1; then
  ok "aws CLI present ($(aws --version 2>&1 | head -1 | awk '{print $1}'))"
else
  bad "aws CLI missing - install it, then: aws configure"
fi
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh CLI present and authenticated"
  else
    warn "gh CLI present but not authenticated (gh auth login)"
  fi
else
  warn "gh CLI not installed (only needed to set secrets automatically)"
fi
if command -v ssh-keygen >/dev/null 2>&1; then
  ok "ssh-keygen present"
else
  bad "ssh-keygen missing - needed to derive the golden SSH key"
fi
echo

# ---- 2. SSH keypair ---------------------------------------------------------
echo "--- [2/5] SSH keypair ---"
if [ -f "$KEY_PATH" ] && [ -s "$KEY_PATH" ]; then
  PERM=$(stat -f '%Lp' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null)
  if [ "$PERM" = "600" ]; then
    ok "private key ${KEY_PATH} (mode 600)"
  else
    warn "private key ${KEY_PATH} has mode ${PERM}; chmod 600 it"
  fi
  if ssh-keygen -y -f "$KEY_PATH" >/dev/null 2>&1; then
    ok "private key is valid (derives a public key)"
  else
    bad "private key ${KEY_PATH} is corrupt or passphrase-protected"
    info "The workflow runs ssh-keygen -y non-interactively, so the key MUST have no passphrase."
    info "Regenerate with: ./scripts/setup-keys.sh --force"
  fi
  if ssh-keygen -y -f "$KEY_PATH" 2>/dev/null | grep -q '^ssh-rsa'; then
    ok "key type is RSA (required by Debian/AlmaLinux/RHEL 10)"
  else
    bad "key is not RSA - Debian, AlmaLinux and RHEL 10 images reject ED25519 keys"
    info "Regenerate with: ./scripts/setup-keys.sh --force"
  fi
else
  bad "no private key at ${KEY_PATH}"
  info "Run: ./scripts/setup-keys.sh"
fi
echo

# ---- 3. AWS identity + IAM --------------------------------------------------
echo "--- [3/5] AWS identity and IAM ---"
ACCOUNT=""
if ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  ok "authenticated to AWS account ${ACCOUNT}"
else
  bad "cannot read AWS identity - run 'aws configure'"
  echo; echo "Fix AWS access, then re-run. (Remaining checks need it.)"; echo
  echo "pass=${PASS} warn=${WARN} fail=${FAIL}"
  exit 1
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
if ROLE_JSON=$(aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null); then
  ok "role ${ROLE_NAME} exists in ${ACCOUNT}"
  TRUST=$(printf '%s' "$ROLE_JSON" | python3 -c '
import json,sys
d=json.load(sys.stdin).get("Role",{}).get("AssumeRolePolicyDocument",{})
s=json.dumps(d)
if "sts:AssumeRoleWithWebIdentity" not in s:
    print("NOT_OIDC"); raise SystemExit
import re
print(" ".join(sorted(set(re.findall(r"repo:[^\\\"]+", s)))))
' 2>/dev/null)
  if [ "$TRUST" = "NOT_OIDC" ] || [ -z "$TRUST" ]; then
    bad "role trust policy does not allow sts:AssumeRoleWithWebIdentity"
    info "Re-run: ./scripts/setup-aws.sh ${REPO_FULL} ${REGION}"
  else
    echo "        trusts: ${TRUST}"
    EXPECTED="repo:${OWNER}/${REPO}:"
    if printf '%s' "$TRUST" | grep -qF "$EXPECTED"; then
      ok "trust policy includes this repository"
    else
      bad "trust policy does NOT include ${OWNER}/${REPO}"
      info "Anyone able to run this workflow in the trusted repo can create"
      info "resources in account ${ACCOUNT}. Re-run:"
      info "    ./scripts/setup-aws.sh ${REPO_FULL} ${REGION}"
    fi
    if printf '%s' "$TRUST" | grep -q 'pull_request'; then
      warn "trust policy allows pull_request subjects"
      info "A pull request from a fork could then assume this role. Prefer"
      info "ref-pinned subjects and never add a pull_request trigger."
    fi
  fi
  ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
    --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null)
  if printf '%s' "$ATTACHED" | grep -qF "${POLICY_NAME}"; then
    ok "${POLICY_NAME} attached to the role"
  else
    bad "${POLICY_NAME} not attached to ${ROLE_NAME}"
    info "Re-run: ./scripts/setup-aws.sh ${REPO_FULL} ${REGION}"
  fi
else
  bad "role ${ROLE_NAME} not found in ${ACCOUNT}"
  info "Run: ./scripts/setup-aws.sh ${REPO_FULL} ${REGION}"
fi

OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  ok "OIDC provider present"
else
  bad "OIDC provider missing - GitHub cannot exchange an OIDC token for creds"
  info "Re-run: ./scripts/setup-aws.sh ${REPO_FULL} ${REGION}"
fi
echo

# ---- 4. GitHub secrets + Actions -------------------------------------------
echo "--- [4/5] GitHub secrets and Actions ---"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  if SECRETS=$(gh secret list --repo "${OWNER}/${REPO}" 2>/dev/null); then
    NAMES=$(printf '%s' "$SECRETS" | awk '{print $1}')
    for s in AWS_ROLE_TO_ASSUME GOLDEN_SSH_PRIVATE_KEY; do
      if printf '%s\n' "$NAMES" | grep -qx "$s"; then
        ok "secret ${s} is set"
      else
        bad "secret ${s} is NOT set"
        if [ "$s" = "GOLDEN_SSH_PRIVATE_KEY" ]; then
          info "Base builds still work without it, but customized (layer 2)"
          info "builds will fail. Set it with:"
          info "    gh secret set GOLDEN_SSH_PRIVATE_KEY --repo ${OWNER}/${REPO} < ${KEY_PATH}"
        else
          info "Set it with:"
          info "    gh secret set AWS_ROLE_TO_ASSUME --repo ${OWNER}/${REPO} --body '${ROLE_ARN}'"
        fi
      fi
    done
  else
    warn "could not list secrets on ${OWNER}/${REPO} (check gh repo access)"
  fi
  if gh api "repos/${OWNER}/${REPO}/actions/permissions" >/dev/null 2>&1; then
    ENABLED=$(gh api "repos/${OWNER}/${REPO}/actions/permissions" --jq '.enabled' 2>/dev/null)
    if [ "$ENABLED" = "true" ]; then
      ok "Actions enabled on the repository"
    else
      bad "Actions DISABLED on ${OWNER}/${REPO}"
      info "Enable it: ${OWNER}/${REPO} -> Settings -> Actions -> Enable"
    fi
  else
    warn "could not read Actions permissions (needs repo scope)"
  fi
  if gh api "repos/${OWNER}/${REPO}/actions/workflows/build-image.yml" >/dev/null 2>&1; then
    ok "build-image.yml workflow present"
  else
    bad "build-image.yml not found in ${OWNER}/${REPO}"
    info "A fresh fork keeps workflows, but confirm the file exists on the"
    info "default branch you are dispatching."
  fi
else
  warn "cannot check secrets without an authenticated gh CLI"
  info "Check by hand: ${OWNER}/${REPO} -> Settings -> Secrets and variables -> Actions"
  info "Required: AWS_ROLE_TO_ASSUME, GOLDEN_SSH_PRIVATE_KEY"
fi
echo

# ---- 5. repo hygiene + quota ----------------------------------------------
echo "--- [5/5] Repository hygiene and quota ---"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_ROOT/ansible/base/vars/golden_user.pub" ]; then
  if cd "$REPO_ROOT" && git check-ignore -q ansible/base/vars/golden_user.pub 2>/dev/null; then
    ok "local golden_user.pub is git-ignored (safe to leave on disk)"
  else
    warn "ansible/base/vars/golden_user.pub exists but is NOT git-ignored"
  fi
else
  info "no local golden_user.pub (fine - the workflow supplies the key)"
fi
if cd "$REPO_ROOT" && git ls-files --error-unmatch ansible/base/vars/golden_user.pub >/dev/null 2>&1; then
  bad "ansible/base/vars/golden_user.pub is COMMITTED in this repo"
  info "Whoever holds its private key has root on every image you build."
  info "Run: git rm --cached ansible/base/vars/golden_user.pub"
else
  ok "no committed public key in the repo"
fi
LIMITS=$(aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text 2>/dev/null)
if [ -n "$LIMITS" ] && [ "$LIMITS" != "None" ]; then
  if [ "$LIMITS" -ge 16 ] 2>/dev/null; then
    ok "vCPU limit ${LIMITS} (>=16, enough for parallel builds)"
  else
    warn "vCPU limit is only ${LIMITS} on-instance cores"
    info "A build launches 1 instance (2 vCPU for t2/t3.small). If you see"
    info "VcpuLimitExceeded, terminate instances or request a quota increase."
  fi
else
  info "could not read the vCPU quota (needs ec2:DescribeInstances)"
fi
echo

echo "=============================================="
echo " pass=${PASS}  warn=${WARN}  fail=${FAIL}"
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
  echo
  echo "Fix the FAIL items above, then re-run this script."
  echo "Most are fixed by: ./scripts/bootstrap.sh ${OWNER}/${REPO} ${REGION}"
  exit 1
fi
echo
echo "Ready to build. Start with amazon-linux (free tier, no Marketplace opt-in)."

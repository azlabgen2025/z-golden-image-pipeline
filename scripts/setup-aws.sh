#!/bin/bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
#
# Create (or repair) the IAM pieces the GitHub Actions build needs, in YOUR
# AWS account:
#
#   * GoldenImagePackerPolicy   - what the build role is allowed to do
#   * OIDC provider             - lets GitHub exchange an OIDC token for creds
#   * GitHubActionsPackerRole   - the role the workflow assumes
#
# Idempotent: safe to re-run. If the role already exists its trust policy is
# UPDATED, so fixing a wrong owner/repo is just another run.
#
# Usage:
#   ./scripts/setup-aws.sh <owner/repo> [region] [ref ...]
#   ./scripts/setup-aws.sh --dry-run <owner/repo>
#
# Examples:
#   ./scripts/setup-aws.sh myname/z-golden-image-pipeline
#   ./scripts/setup-aws.sh myname/z-golden-image-pipeline us-east-1 main release
#   ./scripts/setup-aws.sh --dry-run myname/z-golden-image-pipeline
#
# With no arguments it prompts, but only when stdin is a terminal, so it is
# safe to pipe. Alternatively export GITHUB_REPO / AWS_REGION / GITHUB_REFS.
set -euo pipefail

ROLE_NAME="${ROLE_NAME:-GitHubActionsPackerRole}"
POLICY_NAME="${POLICY_NAME:-GoldenImagePackerPolicy}"
OIDC_URL="https://token.actions.githubusercontent.com"
# Retained for create-open-id-connect-provider. AWS now validates OIDC
# providers against GitHub's published root CA and ignores this value, but the
# CLI still requires the argument.
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  shift
fi

# ---- arguments / prompts ---------------------------------------------------
REPO_FULL="${1:-${GITHUB_REPO:-}}"
REGION="${2:-${AWS_REGION:-us-east-1}}"
shift $(( $# > 2 ? 2 : $# )) 2>/dev/null || true
REFS=("$@")
if [ ${#REFS[@]} -eq 0 ] && [ -n "${GITHUB_REFS:-}" ]; then
  # shellcheck disable=SC2206
  REFS=(${GITHUB_REFS})
fi

if [ -z "$REPO_FULL" ]; then
  if [ ! -t 0 ]; then
    echo "ERROR: no repository given and stdin is not a terminal." >&2
    echo "Usage: $0 <owner/repo> [region] [ref ...]" >&2
    exit 2
  fi
  read -r -p "GitHub repository (owner/repo) where the workflow lives: " REPO_FULL
fi

if [ ${#REFS[@]} -eq 0 ]; then
  REFS=("main")
fi

# ---- validate owner/repo ----------------------------------------------------
# Guard against copy-pasting someone else's repo name: the trust policy is what
# stops a third party from running workflows in YOUR account, so a typo here is
# a security problem, not a cosmetic one.
if ! printf '%s' "$REPO_FULL" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
  echo "ERROR: '$REPO_FULL' is not a valid owner/repo." >&2
  echo "       Expected exactly two slash-separated parts, e.g. myname/myrepo" >&2
  echo "       Use YOUR fork, not the upstream project, unless the upstream" >&2
  echo "       project should be able to build into this AWS account." >&2
  exit 2
fi
GITHUB_OWNER="${REPO_FULL%%/*}"
GITHUB_REPO="${REPO_FULL##*/}"

if [ "$GITHUB_OWNER" = "azlabgen2025" ]; then
  cat >&2 <<EOF
WARNING: you are pointing this at the upstream project ($REPO_FULL).
         Anyone who can push to that repository will be able to create
         resources in this AWS account. If this is your own AWS account,
         use your own fork instead.
EOF
  if [ -t 0 ]; then
    read -r -p "         Continue anyway? [y/N] " ans
    case "$ans" in [yY]*) ;; *) echo "Aborted."; exit 1;; esac
  fi
fi

# ---- preflight --------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found." >&2; exit 1; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  echo "ERROR: could not read your AWS identity. Configure credentials first:" >&2
  echo "         aws configure" >&2
  exit 1
}
ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE_NAME}"
OIDC_ARN="arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"

# The exact OIDC subject GitHub will present. Pinned to refs (not a bare "*")
# so that a pull_request from a fork -- whose sub is repo:owner/repo:pull_request
# -- can never satisfy the trust policy. Do not add a pull_request trigger to
# the build workflow while this policy is in place.
SUBS=()
for ref in "${REFS[@]}"; do
  case "$ref" in
    refs/heads/*) SUBS+=("repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:${ref}") ;;
    *)            SUBS+=("repo:${GITHUB_OWNER}/${GITHUB_REPO}:ref:refs/heads/${ref}") ;;
  esac
done

echo "Account : ${ACCOUNT}"
echo "Region  : ${REGION}"
echo "Repo    : ${GITHUB_OWNER}/${GITHUB_REPO}"
echo "Role    : ${ROLE_ARN}"
echo "Trusted OIDC subject(s):"
for s in "${SUBS[@]}"; do echo "           ${s}"; done
echo

if [ "$DRY_RUN" = true ]; then
  echo "Dry run: no changes made."
  echo
  echo "Your IAM user also needs these actions to run this script:"
  echo "  iam:CreatePolicy iam:GetPolicy iam:CreatePolicyVersion"
  echo "  iam:CreateOpenIDConnectProvider iam:GetOpenIDConnectProvider"
  echo "  iam:ListOpenIDConnectProviders iam:CreateRole iam:GetRole"
  echo "  iam:UpdateAssumeRolePolicy iam:AttachRolePolicy"
  echo "  iam:ListAttachedRolePolicies sts:GetCallerIdentity"
  echo
  echo "Attach them to the user, or use a PowerUserAdministrator-equivalent policy."
  exit 0
fi

# ---- managed policy ---------------------------------------------------------
POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeInstanceAttribute",
        "ec2:DescribeRegions",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeKeyPairs",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:StopInstances",
        "ec2:CreateImage",
        "ec2:CopyImage",
        "ec2:DeregisterImage",
        "ec2:ModifyImageAttribute",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:ImportKeyPair",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        "ec2:ModifyInstanceAttribute"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::golden-image-pipeline-*",
        "arn:aws:s3:::golden-image-pipeline-*/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::*:role/*",
      "Condition": {
        "StringLike": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    }
  ]
}
EOF
)

POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "==> Policy ${POLICY_NAME} exists; creating a new version with current permissions."
  VERSION="$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)"
  NEXT=$(( VERSION + 1 ))
  aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document "$POLICY_DOC" --set-as-default >/dev/null
  echo "    Policy ${POLICY_NAME} now at default version v${NEXT}."
else
  echo "==> Creating policy ${POLICY_NAME}..."
  aws iam create-policy --policy-name "$POLICY_NAME" \
    --policy-document "$POLICY_DOC" >/dev/null
  echo "    ${POLICY_ARN}"
fi

# ---- OIDC provider ----------------------------------------------------------
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
  echo "==> OIDC provider already present."
else
  echo "==> Creating OIDC provider for ${OIDC_URL}..."
  aws iam create-open-id-connect-provider \
    --url "$OIDC_URL" \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "$OIDC_THUMBPRINT" >/dev/null
  echo "    ${OIDC_ARN}"
fi

# ---- role + trust policy ----------------------------------------------------
SUB_JSON=""
for s in "${SUBS[@]}"; do
  [ -n "$SUB_JSON" ] && SUB_JSON+=","
  SUB_JSON+="\"${s}\""
done

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [${SUB_JSON}]
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> Role ${ROLE_NAME} exists; updating its trust policy."
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY" >/dev/null
  echo "    Trust policy now trusts only:"
  for s in "${SUBS[@]}"; do echo "      ${s}"; done
  echo "    (any previous owner/repo entries have been removed)"
else
  echo "==> Creating role ${ROLE_NAME}..."
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "Assumed by GitHub Actions to build golden images" >/dev/null
  echo "    ${ROLE_ARN}"
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" >/dev/null
echo "==> Attached ${POLICY_NAME} to ${ROLE_NAME}."

echo
echo "=============================================="
echo "Setup complete."
echo
echo "Add this secret to ${GITHUB_OWNER}/${GITHUB_REPO}:"
echo "  (repo -> Settings -> Secrets and variables -> Actions -> New repository secret)"
echo
echo "  AWS_ROLE_TO_ASSUME = ${ROLE_ARN}"
echo
echo "Then run ./scripts/bootstrap.sh to finish, or set it by hand:"
echo "  gh secret set AWS_ROLE_TO_ASSUME --repo ${GITHUB_OWNER}/${GITHUB_REPO} <<< '${ROLE_ARN}'"
echo "=============================================="

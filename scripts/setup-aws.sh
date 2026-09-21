#!/bin/bash
# Copyright (c) 2026 Deepesh Rajpal. Licensed under the Mozilla Public License 2.0 (MPL-2.0).
# Usage: ./setup-aws.sh [REGION] [GITHUB_ORG] [GITHUB_REPO]
set -euo pipefail

REGION="${1:-us-east-1}"
ROLE_NAME="GitHubActionsPackerRole"
POLICY_NAME="GoldenImagePackerPolicy"

read -r -p "GitHub organisation or username where the workflow repo lives: " GITHUB_ORG
read -r -p "Workflow repo name: " GITHUB_REPO

[ -n "$GITHUB_ORG" ] && [ -n "$GITHUB_REPO" ] || {
  echo "ERROR: both GitHub org and repo are required." >&2
  exit 1
}

echo "Creating IAM policy..."
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

POLICY_ARN=$(aws iam create-policy \
  --policy-name "$POLICY_NAME" \
  --policy-document "$POLICY_DOC" \
  --query 'Policy.Arn' --output text) || {
    echo "Policy may already exist, trying to get ARN..."
    POLICY_ARN=$(aws iam get-policy --policy-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME" --query 'Policy.Arn' --output text)
}

echo "Policy ARN: $POLICY_ARN"

echo "Creating OIDC provider..."
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Ensure OIDC provider exists
if ! aws iam get-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::$AWS_ACCOUNT:oidc-provider/token.actions.githubusercontent.com" 2>/dev/null; then
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
  echo "OIDC provider created."
else
  echo "OIDC provider already exists."
fi

echo "Creating role..."
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:*",
            "repo:${GITHUB_ORG}@*/${GITHUB_REPO}@*:*"
          ]
        }
      }
    }
  ]
}
EOF
)

ROLE_ARN=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --query 'Role.Arn' --output text) || {
    echo "Role may already exist, getting ARN..."
    ROLE_ARN="arn:aws:iam::$AWS_ACCOUNT:role/$ROLE_NAME"
}

echo "Role ARN: $ROLE_ARN"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "$POLICY_ARN"

echo
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo "Add this secret to your GitHub repo:"
echo "  AWS_ROLE_TO_ASSUME = $ROLE_ARN"
echo
echo "Also add these GitHub secrets for the web UI:"
echo "  AWS_REGION = $REGION"
echo "  GITHUB_TOKEN = <a PAT with repo scope>"
echo "  GITHUB_REPO = $GITHUB_ORG/$GITHUB_REPO"
echo "=========================================="
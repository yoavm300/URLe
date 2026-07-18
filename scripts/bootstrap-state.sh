#!/usr/bin/env bash
# One-time, per-AWS-account bootstrap: the Terraform state bucket and the EC2
# Spot service-linked role. These must exist before the first terragrunt apply
# and cannot be managed by Terraform itself (chicken-and-egg: they store the
# state / are needed by Karpenter's first node).
#
# Usage: ./scripts/bootstrap-state.sh
set -euo pipefail

REGION="us-east-1"

for tool in aws; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="urle-tfstate-${ACCOUNT_ID}"

echo "Account: ${ACCOUNT_ID}"
echo "Bucket:  ${BUCKET} (${REGION})"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "State bucket already exists — skipping creation."
else
  # us-east-1 is the one region where CreateBucket must NOT be given a
  # LocationConstraint (the API rejects it); everywhere else requires one.
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET" \
      --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo "Created ${BUCKET}."
fi

aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}, "BucketKeyEnabled": true}]
  }'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "Versioning, encryption, and public-access block configured."

# Needed once per account for Karpenter to launch Spot instances.
# "Role already exists" is the expected error on re-runs — harmless.
if aws iam create-service-linked-role --aws-service-name spot.amazonaws.com 2>/dev/null; then
  echo "EC2 Spot service-linked role created."
else
  echo "EC2 Spot service-linked role already exists — skipping."
fi

echo "Done. Next: docs/BOOTSTRAP.md step 2 (apply terraform/terragrunt/global)."

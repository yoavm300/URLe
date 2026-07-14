#!/usr/bin/env bash
# Destroy ALL infrastructure for one environment: ./destroyinfra.sh <dev|prod>
set -euo pipefail
cd "$(dirname "$0")"

ENV="${1:-}"
if [ -z "$ENV" ] || [ ! -d "infra/live/$ENV" ]; then
  echo "Usage: ./destroyinfra.sh <dev|prod>" >&2
  exit 1
fi

for tool in terraform terragrunt aws; do
  command -v "$tool" > /dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

echo "!!! This DESTROYS all '$ENV' infrastructure: EKS cluster, VPC, load balancers."
echo "!!! Survivors by design: ECR images, ACM cert, Route53 zones (global/ or"
echo "!!! destroy-excluded units)."
if [ "$ENV" = "prod" ]; then
  echo "!!! prod RDS is excluded from run --all destroy; tearing it down is a"
  echo "!!! deliberate manual act (disable deletion_protection first)."
fi
echo "Destroying as AWS identity:"
aws sts get-caller-identity --output text --query Arn

read -r -p "Type the environment name ('$ENV') to confirm: " CONFIRM
if [ "$CONFIRM" != "$ENV" ]; then
  echo "Aborted — nothing destroyed."
  exit 1
fi

cd "infra/live/$ENV"
exec terragrunt run --all destroy

#!/usr/bin/env bash
# Apply the Terragrunt stack for one environment: ./startinfra.sh [dev|prod]
# Never auto-approves — terragrunt shows the plan and asks before applying.
set -euo pipefail
cd "$(dirname "$0")"

ENV="${1:-dev}"
if [ ! -d "infra/live/$ENV" ]; then
  echo "Unknown environment '$ENV' — expected one of: $(ls infra/live/ | grep -v terragrunt.hcl | tr '\n' ' ')" >&2
  exit 1
fi

for tool in terraform terragrunt aws; do
  command -v "$tool" > /dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

echo "Applying as AWS identity:"
aws sts get-caller-identity --output text --query Arn || { echo "No AWS credentials configured" >&2; exit 1; }

# Note: the state bucket (urle-tfstate-<account-id>) and lock table
# (urle-tfstate-locks) must exist; terragrunt offers to create them on first run.
cd "infra/live/$ENV"
exec terragrunt run-all apply

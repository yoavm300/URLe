# terraform — platform infrastructure (modules + Terragrunt live tree)

Terraform builds the *platform*; it never deploys application workloads.
The boundary is the Argo CD root Application: Terraform installs Argo CD and
plants that one seed, and everything application-shaped from there down is
managed from git (see `helm/git-ops/README.md`).

```
terraform/
  modules/       # reusable, typed-variable modules — one concern each
                 #   (vpc, eks, karpenter, ingress-nginx, argocd, rds-postgres,
                 #    cloudfront, vpn, external-secrets, cert-manager, ...)
  terragrunt/    # the live tree: what actually exists, per tier
    global/      # survives environment teardown: OIDC roles, ECR repos,
                 #   public Route53 zone. Applied locally once (BOOTSTRAP §2).
    dev/         # VPN-only environment: private ingress, in-cluster postgres
    prod/        # public edge: CloudFront → ALB → nginx, RDS, external-dns
```

Each `terragrunt/<env>/<unit>/terragrunt.hcl` instantiates one module with
that environment's inputs and declares its dependencies, so `run --all apply`
resolves the whole environment in order. Remote state lives in the S3 bucket
created in `docs/BOOTSTRAP.md` §1.

## How changes flow

- PR touching `terraform/**` → `infra-ci` runs plan per affected unit, gated
  by the `DEV_UP`/`PROD_UP` flags (plan genuinely fails against a torn-down
  environment).
- Applies are never automatic: `infra-apply` (live env, replans first),
  `infra-bootstrap` (cold start, ordered apply without plan), and
  `infra-destroy` (typed confirmation; global/ units and destroy-excluded
  resources survive) are all human dispatches.

Standards: `.claude/standards.md` §6 — typed variables, no hardcoded values,
outputs for cross-unit wiring, no inline credentials (secrets go through SSM,
see BOOTSTRAP §4).

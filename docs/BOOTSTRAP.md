# Bootstrap — one-time setup per AWS account

Everything here is done **once, manually, with your personal AWS credentials**.
After it, day-to-day infra work runs entirely through GitHub Actions
(`infra-ci` plans PRs, `infra-bootstrap`/`infra-apply`/`infra-destroy` are
dispatched by hand). Nothing below is managed by Terraform — these are the
resources Terraform itself needs before it can run, plus the secrets Terraform
only ever *reads*.

## 0. Prerequisites

- AWS CLI authenticated as an admin principal (`aws sts get-caller-identity`)
- `terraform` and `terragrunt` at the versions pinned in
  `.github/workflows/infra-ci.yaml`
- `gh` CLI authenticated against the `yoavm300/URLe` repo
- A domain you own (public Route53 zone delegation — step 5)

## 1. State bucket + Spot service-linked role

```bash
./scripts/bootstrap-state.sh
```

Creates `urle-tfstate-<account-id>` in `us-east-1` (versioned, encrypted,
public access blocked) and the EC2 Spot service-linked role Karpenter needs.
Safe to re-run.

> **State-key migration note (2026-07):** the backend key is now normalized
> with `replace(path_relative_to_include(), "\\", "/")` — an apply from
> Windows used to write keys containing backslashes, a different S3 object
> than the same unit applied from WSL/CI. If you ever applied from Windows,
> check for split state and migrate before the next apply:
>
> ```bash
> aws s3api list-objects-v2 --bucket urle-tfstate-<account-id> \
>   --query "Contents[?contains(Key, '\\\\')].Key"
> # for each hit: copy-object to the forward-slash key, verify ETag, delete-object
> ```
>
> Run the migration from WSL or PowerShell — **never Git Bash/MSYS**, which
> mangles S3 URIs containing backslashes.

## 2. Apply the global units (locally — CI can't bootstrap its own identity)

**First** set your real domain in
`terraform/environments/global/route53-public-zone/terragrunt.hcl` (it ships with an
`example.com` placeholder — applying that as-is creates a useless zone).
Then:

```bash
cd terraform/environments/global
terragrunt run --all apply
```

This creates, account-wide (never part of an environment teardown):

- **`github-oidc`** — the GitHub Actions OIDC provider and three IAM roles:
  `urle-dev-cicd` / `urle-prod-cicd` (trusted for jobs running in the matching
  GitHub Environment) and `urle-release` (trusted for `v*` tag builds, ECR
  push only). If the account already has an OIDC provider for
  `token.actions.githubusercontent.com`, import it first:
  `terragrunt import aws_iam_openid_connect_provider.github <arn>`
- **`ecr-auth` / `ecr-dashboard` / `ecr-redirect`** — image repositories
  (`urle-<service>`). Account-wide because one SemVer release feeds every
  environment, and so teardowns never delete released images.
- **`route53-public-zone`** — the public hosted zone for your domain (step 5).

Capture the role ARNs for step 3:

```bash
cd github-oidc && terragrunt output
```

## 3. GitHub repository configuration

```bash
# Variables (role ARNs are safe as plain variables — they only pair the
# account ID with a role name, no personal identity)
gh variable set AWS_REGION            --body "us-east-1"
gh variable set AWS_DEV_CI_ROLE_ARN   --body "arn:aws:iam::<account-id>:role/urle-dev-cicd"
gh variable set AWS_PROD_CI_ROLE_ARN  --body "arn:aws:iam::<account-id>:role/urle-prod-cicd"
gh variable set AWS_RELEASE_ROLE_ARN  --body "arn:aws:iam::<account-id>:role/urle-release"

# Environment-up flags — flipped automatically by the bootstrap/destroy
# workflows; they gate the plan job (plan genuinely fails against a
# torn-down environment)
gh variable set DEV_UP  --body "false"
gh variable set PROD_UP --body "false"

# Secret, not a variable: pairs the account ID with your personal IAM
# username — more targeted information than the account ID alone. Without it
# a CI apply would see the personal EKS access entry missing from desired
# state and destroy it.
gh secret set ADMIN_PRINCIPAL_ARN --body "$(aws sts get-caller-identity --query Arn --output text)"
```

Then in the GitHub UI (no CLI equivalent for all of it):

1. **Settings → Environments** — create `dev` and `prod`. The OIDC trust
   policies match `sub = repo:yoavm300/URLe:environment:<env>`, so the roles
   are unusable until these exist. Optionally add a required reviewer on
   `prod` — that gates every prod apply behind a human click.
2. **Settings → Branches** — protect `main`; require the `fmt-validate` check
   (and the existing charts/app CI checks). Don't require the `plan` jobs —
   they are skipped while an environment is torn down (`*_UP=false`).

## 4. Manual SSM parameters (Terraform reads these, never creates them)

Bootstrap secrets can't be managed by the tool that needs them to
authenticate; these are also credentials you choose and rotate yourself, so
the human-readable source of truth stays outside Terraform state.

| Parameter (SecureString) | Used by | How to generate |
|---|---|---|
| `/urle/dev/vpn/wg-easy-password-hash` | dev VPN admin UI | `docker run ghcr.io/wg-easy/wg-easy wgpw '<password>'` |
| `/urle/prod/vpn/wg-easy-password-hash` | prod VPN admin UI | same |
| `/urle/prod/rds/master-password` | RDS master user | plain value, your choice |
| `/urle/prod/secret-key` | Flask `SECRET_KEY` | `python -c "import secrets; print(secrets.token_hex(32))"` |
| `/urle/prod/redis-password` | in-cluster Redis auth | plain value, your choice |

```bash
aws ssm put-parameter --type SecureString --name '/urle/prod/rds/master-password' --value '<value>'
# ... repeat per row
```

The `rds-postgres` module composes these into the Secrets Manager secret
`urle/prod/app` that the chart's ExternalSecret consumes — nothing else
writes that secret.

## 5. Domain / public zone delegation

`terraform/environments/global/route53-public-zone` creates the public hosted zone for
your domain. After the first apply, copy the zone's NS records to your
registrar (one-time delegation):

```bash
cd terraform/environments/global/route53-public-zone && terragrunt output name_servers
```

ACM validation, the `urle.<domain>` app record (written by ExternalDNS), and
the optional `vpn-<env>.<domain>` records all live in this zone.

## 6. One-time chart values fill

Replace the placeholders in `helm/urle-chart/values-prod.yaml` **and**
`helm/urle-chart/values-dev.yaml` with real values. Both are name-deterministic,
so they survive teardown/bootstrap cycles:

- `111111111111` → your account ID (ECR image repositories, IRSA role ARN)
- `urle.example.com` → `urle.<your-domain>` (prod only; dev's host is the
  private `app.urle-dev.internal` and needs no fill)
- `urle-origin.example.com` → `urle-origin.<your-domain>` (prod
  `ingress.extraHosts` — the CloudFront origin hostname; the infra side
  derives it from the zone automatically, only this chart value is filled
  by hand and must match)

Cross-check against `terragrunt output` or the `/urle/...` SSM parameters the
modules publish.

## 7. Cold start

Dispatch **`infra-bootstrap`** (Actions → infra-bootstrap → Run workflow →
pick `dev` or `prod`). It applies the whole environment in dependency order
— deliberately without a plan step, because `terragrunt plan` genuinely fails
against a torn-down environment (units that do real AWS lookups get mock
dependency values that then 404), while an ordered apply resolves each
dependency before its consumers. On success it flips `<ENV>_UP=true`, which
re-enables plan-on-PR for that environment.

Teardown is **`infra-destroy`** (typed confirmation required). ECR images,
the ACM certificate, and the public zone survive by design (global/ units or
`exclude`-from-destroy blocks). Prod RDS is destroyed with the rest of the
environment — it lives inside the prod VPC, so sparing it would leave the
teardown half-done — but a final snapshot (`urle-prod-final`) is always taken,
and the master password/app secrets live on in SSM for the next bootstrap.

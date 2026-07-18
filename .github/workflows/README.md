# workflows — one workflow per concern

CI never touches the cluster: application deploys happen only through Argo CD
watching `main`, and infrastructure applies are always explicit human
dispatches. Every workflow authenticates to AWS via OIDC role assumption —
no long-lived keys (roles from `terraform/terragrunt/global/github-oidc`).

## Application

- **`app-ci`** — PRs touching `services/**` / `shared/**` / Nx config.
  Runs `nx affected` so only impacted services are linted (Ruff) and tested.
- **`app-release`** — `vX.Y.Z` tag push. Builds all three service images,
  pushes SemVer + SHA tags to ECR, then opens an automated PR bumping the
  chart versions. Merging that PR is the deploy action (Argo CD syncs it).
- **`charts-ci`** — any `helm/**` change. Lints and templates the charts.

## Infrastructure

- **`infra-ci`** — plan-on-PR for `terraform/**`, gated by the
  `DEV_UP`/`PROD_UP` repo variables (plan fails against a torn-down
  environment, so the gate skips it rather than reporting noise).
- **`infra-apply`** — human dispatch against a *live* environment; runs a
  fresh per-unit plan as a mandatory gate in the same run.
- **`infra-bootstrap`** — cold-starts a torn-down environment with an ordered
  `run --all apply` (deliberately no plan step — see the file header). Flips
  `<ENV>_UP=true` on success. Prerequisites: `docs/BOOTSTRAP.md`.
- **`infra-destroy`** — teardown with typed confirmation. `global/` units,
  ECR images, ACM, and the public zone survive by design; prod RDS is
  destroyed but leaves a final snapshot.

The UP flags are the handshake between these: bootstrap/destroy flip them,
and they gate whether plan-on-PR runs for that environment.

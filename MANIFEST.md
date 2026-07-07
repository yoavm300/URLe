# URLe — Infrastructure Manifest

> **Audience:** this manifest is the single entry-point spec for an implementing
> agent (written to be consumed by Claude Opus 4.8 or any later model). It is
> self-contained: everything needed to build the infrastructure is stated here
> or referenced by exact file path. Read `README.md` and `k8s/README.md` before
> changing anything — they are the source of truth for application behavior;
> this file is the source of truth for the target infrastructure.

---

## 1. What is being deployed

**URLe** is a stateless Flask URL shortener (application-factory pattern,
gunicorn in production). All state lives outside the app pods:

| Service | Role | State |
|---|---|---|
| `urlshortener` (app) | Flask web app, port **5000**, health probe `GET /healthz` (no DB) | stateless — scale by replicas |
| `postgres` | Primary database | StatefulSet + PVC in-cluster, or managed (RDS) in prod |
| `redis` | Shared rate-limit counters (`RATELIMIT_STORAGE_URI`) | ephemeral is acceptable |
| `init-db` | One-shot Job: `flask --app run init-db` creates missing tables **before** app rollout | none |

Runtime contract (from `README.md` → Configuration):

- `SECRET_KEY` — **required**; app fails closed without it; must be identical across replicas.
- `DATABASE_URL` — `postgres://`/`postgresql://` auto-normalized to psycopg 3.
- `RATELIMIT_STORAGE_URI` — set to `redis://…` so limits are shared across replicas.
- `TRUST_PROXY=1` — required behind the ingress/ALB (trusts `X-Forwarded-*`).
- Container runs as non-root UID 1000 (`runAsNonRoot` must pass).
- Existing raw manifests live in `k8s/` (see `k8s/README.md` for apply order and
  the init-db-before-rollout constraint). They are the **reference behavior**
  the Helm charts must reproduce.

---

## 2. Target platform

| Layer | Choice |
|---|---|
| Cloud | **AWS** |
| Cluster | **EKS** (managed node groups) |
| Registry | **ECR** — repo `urlshortener` |
| IaC | **Terraform** modules, orchestrated by **Terragrunt** (one live tree per environment) |
| GitOps / CD | **Argo CD** — syncs Helm releases from this repo; no `kubectl apply` in CI |
| Packaging | **Helm charts**, one per service, composed by an **umbrella chart** |
| CI | **GitHub Actions**, **separate workflow per service** |
| Lint | **Ruff** (check + format) gating every Python change |
| Versioning | **Semantic Versioning only** (see §6) |

---

## 3. Target repository layout

```
Project_URLe/
├── app/ …, run.py, Dockerfile, requirements.txt   # existing application (do not restructure)
├── k8s/                                           # legacy raw manifests — keep until Helm parity is validated
├── pyproject.toml                                 # ruff configuration (§7)
├── charts/
│   ├── urlshortener/          # app chart: Deployment, Service, Ingress, ConfigMap,
│   │                          #   init-db Job as a Helm pre-install/pre-upgrade hook
│   ├── postgres/              # StatefulSet + headless Service + PVC (dev/local only)
│   ├── redis/                 # Deployment + Service
│   └── urle/                  # UMBRELLA chart: depends on the three above;
│                              #   postgres subchart disabled where RDS is used
├── infra/
│   ├── modules/               # plain Terraform, no env-specific values
│   │   ├── vpc/
│   │   ├── eks/
│   │   ├── ecr/
│   │   ├── rds-postgres/      # prod database (replaces in-cluster postgres chart)
│   │   └── argocd/            # Argo CD install + bootstrap Application
│   └── live/                  # Terragrunt live tree
│       ├── terragrunt.hcl     # root: remote state (S3 + DynamoDB lock), provider generation
│       ├── dev/
│       │   └── {vpc,eks,ecr,argocd}/terragrunt.hcl
│       └── prod/
│           └── {vpc,eks,ecr,rds-postgres,argocd}/terragrunt.hcl
├── argocd/
│   ├── projects/urle-project.yaml
│   └── apps/                  # one Application per env pointing at charts/urle
│       ├── dev.yaml
│       └── prod.yaml
└── .github/workflows/         # one workflow per service (§5)
    ├── app-ci.yaml
    ├── app-release.yaml
    ├── charts-ci.yaml
    └── infra-ci.yaml
```

---

## 4. Helm charts

- **One chart per service** (`urlshortener`, `postgres`, `redis`); the `urle`
  **umbrella chart** lists them as dependencies in `Chart.yaml` and is the only
  thing Argo CD deploys.
- The app chart must reproduce `k8s/` behavior exactly: 3 replicas default,
  `/healthz` liveness+readiness, non-root security context, resource limits,
  ConfigMap for `RATELIMIT_STORAGE_URI`/`TRUST_PROXY`, Secret **referenced by
  name, never templated with real values** (create out-of-band or via
  External Secrets — mirrors `k8s/README.md`).
- The init-db Job becomes a Helm **`post-install,pre-upgrade` hook** with
  `hook-delete-policy: before-hook-creation` (pre-install would deadlock on a
  fresh install: the in-cluster Postgres is part of the same release). Under
  Argo CD the job instead runs as a Sync hook in **sync wave 1** — after the
  datastores (wave 0), before the app Deployment (wave 2) — which preserves the
  documented "schema exists before rollout" ordering.
- Umbrella `values.yaml` toggles: `postgres.enabled` (true for dev/minikube,
  **false in prod** where `DATABASE_URL` points at RDS), image repository/tag,
  ingress host per environment.
- Every `Chart.yaml` carries SemVer `version` and `appVersion` (§6).

## 5. CI/CD — separate workflow per service

All workflows trigger on `paths:` filters so a change to one service never runs
another service's pipeline.

| Workflow | Paths | Jobs |
|---|---|---|
| `app-ci.yaml` | `app/**`, `run.py`, `requirements.txt`, `Dockerfile`, `pyproject.toml` | **ruff check** + **ruff format --check** → smoke-test (`create_app()` boots, `/healthz` returns 200) → docker build |
| `app-release.yaml` | tag push `v*.*.*` | build image → push to ECR tagged `MAJOR.MINOR.PATCH` (+ git SHA) → bump umbrella chart `appVersion`/values tag via PR |
| `charts-ci.yaml` | `charts/**` | `helm lint` + `helm template` all charts; verify chart `version` was bumped |
| `infra-ci.yaml` | `infra/**` | `terraform fmt -check`, `terraform validate`, `terragrunt plan` per changed env (plan-only in CI; apply is manual/protected) |

**CD is Argo CD, not CI:** workflows only build/push images and bump chart
versions; Argo CD watches `argocd/apps/*` → `charts/urle` and syncs the cluster.
Sync order inside a release is handled by the Helm hook (init-db) — no manual
apply order.

## 6. Versioning policy — SemVer only

- **All versions are `MAJOR.MINOR.PATCH`** (git tags prefixed `v`).
- Application releases: git tag `vX.Y.Z` → image `ECR/urlshortener:X.Y.Z`.
- **No `latest`, no `local`, no branch-name tags** in any deployable reference
  (the `:latest`/`:local` tags in `k8s/` and `README.md` are legacy dev-only).
- Helm: every chart change bumps that chart's `version`; app releases bump the
  app chart's `appVersion` and the umbrella chart's dependency version.
- Terraform module releases (if split out later): `vX.Y.Z` tags as well.

## 7. Ruff

Add `pyproject.toml` at the repo root:

```toml
[tool.ruff]
target-version = "py312"        # matches the Dockerfile base image
line-length = 100
extend-exclude = [".venv"]

[tool.ruff.lint]
select = ["E", "F", "W", "I", "B", "UP"]
```

- `ruff check .` and `ruff format --check .` run in `app-ci.yaml` and block merge.
- First adoption pass: fix violations in a dedicated commit; do not change behavior.

## 8. Environments

| | dev | prod |
|---|---|---|
| Cluster | EKS (small node group) or minikube (see `README.md` → Local cluster) | EKS |
| Postgres | in-cluster chart (`postgres.enabled: true`) | **RDS** via `infra/modules/rds-postgres` (`postgres.enabled: false`) |
| Redis | in-cluster chart | in-cluster chart (ElastiCache is a later option) |
| Secrets | `kubectl create secret` per `k8s/README.md` | AWS Secrets Manager + External Secrets (or SSM), never in git |
| Ingress host | dev DNS name | `urlshortener.example.com` placeholder — real host set in umbrella values |

## 9. Implementation order (for the executing agent)

1. `pyproject.toml` + ruff pass → verify: `ruff check .` clean.
2. `charts/` (3 service charts + umbrella) → verify: `helm lint` + `helm template`
   output matches `k8s/` resources; validate on minikube per `README.md`.
3. `.github/workflows/` (4 workflows, path-filtered) → verify: each triggers only
   on its own paths; ruff gate fails on an injected violation.
4. `infra/modules/` + `infra/live/` → verify: `terragrunt plan` succeeds per env.
5. `argocd/` project + per-env Applications → verify: dev Application syncs the
   umbrella chart and the init-db hook runs before the app rollout.
6. Only after Helm parity is validated in a cluster: mark `k8s/` as deprecated
   in its README (do not delete without user approval).

**Hard constraints:** never commit real secrets (`k8s/README.md` policy),
never serve `run.py` in production (gunicorn + factory only), keep the app's
`SECRET_KEY` fail-closed guard intact, and keep every deployable reference on
SemVer.

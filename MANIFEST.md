# URLe — Infrastructure Manifest

> **Audience:** this manifest is the single entry-point spec for an implementing
> agent (written to be consumed by Claude Opus 4.8 or any later model). It is
> self-contained: everything needed to build the infrastructure is stated here
> or referenced by exact file path. Read `README.md` and `k8s/README.md` before
> changing anything — they are the source of truth for application behavior;
> this file is the source of truth for the target infrastructure.

---

## 1. What is being deployed

**URLe** is a stateless Flask URL shortener, split into **3 independently
deployable services** (application-factory pattern per service, gunicorn in
production), sharing one Postgres database. All state lives outside the app
pods:

| Service | Role | State |
|---|---|---|
| `urle-auth` | `/register`, `/login`, `/logout` — owns the `users` table | stateless — scale by replicas |
| `urle-dashboard` | `/`, `/shorten`, `/urls`, `/url/*`, static assets — reads/writes both tables | stateless — scale by replicas |
| `urle-redirect` | Public `GET /<short_code>` lookup + click-increment + redirect. No auth. The hottest, most latency-sensitive path — the reason for the split, so it can scale independently of the other two | stateless — scale by replicas |
| `postgres` | Primary database, shared by all 3 services | StatefulSet + PVC in-cluster, or managed (RDS) in prod |
| `redis` | Shared rate-limit counters (`RATELIMIT_STORAGE_URI`) — used by `urle-auth` and `urle-dashboard` only | ephemeral is acceptable |
| `init-db` | One-shot Job, runs the `urle-dashboard` image (only service importing both the `User` and `Url` models): `flask --app run init-db` creates missing tables **before** the app rollout | none |

Runtime contract (from `README.md` / `k8s/README.md`):

- `SECRET_KEY` — **required** on `urle-auth` and `urle-dashboard`; fails
  closed without it; must be **identical** across both services (and their
  replicas) since it signs the session cookie that has to validate across
  service boundaries. `urle-redirect` also requires it (Flask's own
  boot-time check) but never uses it for anything beyond that.
- `DATABASE_URL` — `postgres://`/`postgresql://` auto-normalized to psycopg
  3; identical across all 3 services (same DB, same tables).
- `RATELIMIT_STORAGE_URI` — set to `redis://…` so limits are shared across
  `urle-auth`/`urle-dashboard` replicas. `urle-redirect` doesn't rate-limit;
  harmless if the env var is present anyway.
- `TRUST_PROXY=1` — required behind the ingress/ALB (trusts `X-Forwarded-*`)
  on all 3 services.
- Containers run as non-root UID 1000 (`runAsNonRoot` must pass) on all 3.
- One shared Ingress routes by path: `urle-auth` owns exact
  `/login`/`/register`/`/logout`; `urle-dashboard` owns exact
  `/`/`/shorten`/`/urls` plus prefix `/url`/`/static`; `urle-redirect` is the
  prefix catch-all `/` for everything else (short codes).
  `RESERVED_SHORT_CODES` in `services/dashboard/app/utils/validators.py`
  blocks a user from picking a custom short code that would collide with a
  reserved path segment.
- Existing raw manifests live in `k8s/` (see `k8s/README.md` for apply order
  and the init-db-before-rollout constraint). They are the **reference
  behavior** the Helm charts must reproduce.

---

## 2. Target platform

| Layer | Choice |
|---|---|
| Cloud | **AWS** |
| Cluster | **EKS** (managed node groups) |
| Registry | **ECR** — one repo per service: `urle-<env>/urle-auth`, `urle-<env>/urle-dashboard`, `urle-<env>/urle-redirect` |
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
├── shared/                                        # DB models/extensions/config shared by all 3 services
├── services/
│   ├── auth/          …, run.py, Dockerfile, requirements.txt
│   ├── dashboard/      …, run.py, Dockerfile, requirements.txt
│   └── redirect/       …, run.py, Dockerfile, requirements.txt
├── k8s/                                           # legacy raw manifests — keep until Helm parity is validated
├── pyproject.toml                                 # ruff configuration (§7)
├── charts/
│   ├── urle-auth/              # Deployment, Service, _helpers.tpl
│   ├── urle-dashboard/         # Deployment, Service, init-db Job (hook), _helpers.tpl
│   ├── urle-redirect/          # Deployment, Service, _helpers.tpl
│   ├── postgres/                # StatefulSet + headless Service + PVC (dev/local only)
│   ├── redis/                   # Deployment + Service
│   └── urle/                    # UMBRELLA chart: depends on the five above;
│                                 #   owns the cross-cutting shared ConfigMap and
│                                 #   the single Ingress that routes to all 3
│                                 #   app services (see §4); postgres subchart
│                                 #   disabled where RDS is used
├── infra/
│   ├── modules/                 # plain Terraform, no env-specific values
│   │   ├── vpc/
│   │   ├── eks/
│   │   ├── ecr/                 # generic, parameterized by `name` — one instance per service per env
│   │   ├── rds-postgres/        # prod database (replaces in-cluster postgres chart)
│   │   └── argocd/              # Argo CD install + bootstrap Application
│   └── live/                    # Terragrunt live tree
│       ├── terragrunt.hcl       # root: remote state (S3 + DynamoDB lock), provider generation
│       ├── dev/
│       │   └── {vpc,eks,ecr-auth,ecr-dashboard,ecr-redirect,argocd}/terragrunt.hcl
│       └── prod/
│           └── {vpc,eks,ecr-auth,ecr-dashboard,ecr-redirect,rds-postgres,argocd}/terragrunt.hcl
├── argocd/
│   ├── projects/urle-project.yaml
│   └── apps/                    # one Application per env pointing at charts/urle (unchanged by the split —
│       ├── dev.yaml             #   the umbrella chart path is stable regardless of what it composes)
│       └── prod.yaml
└── .github/workflows/           # one CI + one release workflow per service (§5)
    ├── app-auth-ci.yaml
    ├── app-auth-release.yaml
    ├── app-dashboard-ci.yaml
    ├── app-dashboard-release.yaml
    ├── app-redirect-ci.yaml
    ├── app-redirect-release.yaml
    ├── charts-ci.yaml
    └── infra-ci.yaml
```

---

## 4. Helm charts

- **One chart per service** (`urle-auth`, `urle-dashboard`, `urle-redirect`,
  `postgres`, `redis`); the `urle` **umbrella chart** lists them all as
  dependencies in `Chart.yaml` and is the only thing Argo CD deploys.
- Each app chart reproduces its service's `k8s/deployment-*.yaml` /
  `k8s/service-*.yaml` behavior exactly: replicas, `/healthz`
  liveness+readiness, non-root security context, resource limits, Secret
  **referenced by name, never templated with real values** (create out of
  band or via External Secrets — mirrors `k8s/README.md`).
- **Cross-cutting resources live in the umbrella chart's own
  `templates/`**, not in any one service's subchart, because they reference
  all 3 services or apply uniformly to more than one:
  - `charts/urle/templates/configmap.yaml` — the shared
    `RATELIMIT_STORAGE_URI`/`TRUST_PROXY` ConfigMap, referenced by name from
    `urle-auth` and `urle-dashboard`'s Deployments (mirrors
    `k8s/configmap.yaml`).
  - `charts/urle/templates/ingress.yaml` — the single Ingress with the path
    rules from §1, pointing at `urle-auth`/`urle-dashboard`/`urle-redirect`
    Service names (mirrors `k8s/ingress.yaml`).
- The init-db Job is owned by **`charts/urle-dashboard`** specifically (not
  a generic app-chart concern anymore) — it's the only service importing
  both models. It's a Helm **`post-install,pre-upgrade` hook** with
  `hook-delete-policy: before-hook-creation` (pre-install would deadlock on
  a fresh install: the in-cluster Postgres is part of the same release).
  Under Argo CD the job instead runs as a Sync hook in **sync wave 1** —
  after the datastores (wave 0), before the app Deployments (wave 2) —
  which preserves the documented "schema exists before rollout" ordering.
- Umbrella `values.yaml` toggles: `postgres.enabled` (true for dev/minikube,
  **false in prod** where `DATABASE_URL` points at RDS), each service's
  `image.repository`/`image.tag`, the shared Ingress host per environment.
- Every `Chart.yaml` carries SemVer `version` and `appVersion` (§6).

## 5. CI/CD — separate workflow per service

All workflows trigger on `paths:` filters so a change to one service never
runs another service's pipeline. Every service's workflow also triggers on
`shared/**`, since a change there can affect all 3 services' correctness.

| Workflow | Paths | Jobs |
|---|---|---|
| `app-<service>-ci.yaml` (×3) | `services/<service>/**`, `shared/**`, `pyproject.toml` | **ruff check** + **ruff format --check** (on `shared/` + `services/<service>/`) → smoke-test (`create_app()` boots, `/healthz` returns 200) → docker build (`-f services/<service>/Dockerfile .`, repo root context) |
| `app-<service>-release.yaml` (×3) | tag push `v*.*.*` (all 3 fire together — a release tag ships all 3 images at a matching version) | build image → push to that service's ECR repo tagged `MAJOR.MINOR.PATCH` (+ git SHA) → bump `charts/urle-<service>` `appVersion`/`version` and the umbrella chart's dependency version + umbrella `version`/`appVersion`, via PR |
| `charts-ci.yaml` | `charts/**` | `helm lint` + `helm template` all charts; verify chart `version` was bumped |
| `infra-ci.yaml` | `infra/**` | `terraform fmt -check`, `terraform validate`, `terragrunt plan` per changed env (plan-only in CI; apply is manual/protected) — already generic over however many Terragrunt units exist, no changes needed for the 3-repo ECR split |

**Known tradeoff:** since all 3 release workflows fire on the same tag and
each opens its own PR bumping `charts/urle/Chart.yaml`'s dependency list and
version, those 3 PRs can conflict with each other if merged out of order.
This is accepted as equivalent to normal automated-PR conflicts (e.g.
Dependabot) — a human merges them, rebasing if needed. Not solved by a
single combined "bump all 3" workflow, since that would blur the "one
workflow per service" separation this repo intentionally keeps.

**CD is Argo CD, not CI:** workflows only build/push images and bump chart
versions; Argo CD watches `argocd/apps/*` → `charts/urle` and syncs the
cluster. Sync order inside a release is handled by the Helm hooks (datastores
→ init-db → app Deployments) — no manual apply order.

## 6. Versioning policy — SemVer only

- **All versions are `MAJOR.MINOR.PATCH`** (git tags prefixed `v`).
- Application releases: git tag `vX.Y.Z` → all 3 images
  `ECR/urle-auth:X.Y.Z`, `ECR/urle-dashboard:X.Y.Z`,
  `ECR/urle-redirect:X.Y.Z` — the 3 services move in lockstep on the same
  version number (no independent per-service tag prefixes; see the CI
  tradeoff note in §5).
- **No `latest`, no `local`, no branch-name tags** in any deployable
  reference (the `:dev`/`:latest` tags in `k8s/` and `README.md` are legacy
  dev-only).
- Helm: every chart change bumps that chart's `version`; app releases bump
  the relevant app chart's `appVersion` and the umbrella chart's dependency
  version.
- Terraform module releases (if split out later): `vX.Y.Z` tags as well.

## 7. Ruff

`pyproject.toml` at the repo root:

```toml
[tool.ruff]
target-version = "py312"        # matches the Dockerfile base image
line-length = 100
extend-exclude = [".venv"]

[tool.ruff.lint]
select = ["E", "F", "W", "I", "B", "UP"]
```

- `ruff check .` and `ruff format --check .` run in every `app-<service>-ci.yaml`
  (scoped to `shared/` + that service's `services/<service>/`) and block merge.

## 8. Environments

| | dev | prod |
|---|---|---|
| Cluster | EKS (small node group) or minikube (see `README.md` → Local cluster) | EKS |
| Postgres | in-cluster chart (`postgres.enabled: true`) | **RDS** via `infra/modules/rds-postgres` (`postgres.enabled: false`) |
| Redis | in-cluster chart | in-cluster chart (ElastiCache is a later option) |
| Secrets | `kubectl create secret` per `k8s/README.md` | AWS Secrets Manager + External Secrets (or SSM), never in git |
| Ingress host | dev DNS name | real host set in umbrella values |

## 9. Implementation order (for the executing agent)

Historical note: steps 1–6 describe the *original* single-service buildout
and are complete. The 3-service split (this revision) followed as a
subsequent pass over an already-working single-service infra stack, in this
order:

1. Split `app/` into `shared/` + `services/{auth,dashboard,redirect}/`,
   verify locally and on a real cluster (raw `k8s/` manifests) end to end.
2. `charts/` — replace the single app chart with 3 service charts + move
   the shared ConfigMap/Ingress into the umbrella chart's own templates →
   verify: `helm lint` + `helm template` output matches `k8s/` resources.
3. `.github/workflows/` — replace the single app-ci/app-release pair with 3
   pairs, path-filtered per service (plus `shared/**`) → verify: each
   triggers only on its own paths; ruff gate fails on an injected violation.
4. `infra/modules/`/`infra/live/` — add 2 more ECR Terragrunt units per env
   (3 total, one per service) → verify: `terragrunt plan` succeeds per env.
5. `argocd/` — no changes needed; the per-env Applications already point at
   `charts/urle` regardless of what it composes internally.
6. Only after Helm parity is validated in a cluster: mark `k8s/` as
   deprecated in its README (do not delete without user approval).

**Hard constraints:** never commit real secrets (`k8s/README.md` policy),
never serve `run.py` in production (gunicorn + factory only), keep
`SECRET_KEY`'s fail-closed guard intact on `urle-auth`/`urle-dashboard`, and
keep every deployable reference on SemVer.

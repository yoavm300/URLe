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
- `TRUST_PROXY=<hops>` — number of proxy hops to trust for `X-Forwarded-*`
  on all 3 services: `1` behind one ingress/ALB (dev), `2` behind
  CloudFront → ALB (prod). Unset/0 = headers ignored (direct, unspoofable).
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
| Registry | **ECR** — one account-wide repo per service (`urle-auth`, `urle-dashboard`, `urle-redirect`): one SemVer release feeds every environment, and repos live in `terraform/environments/global/` so teardowns never delete released images |
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
├── helm/
│   ├── auth/                   # chart urle-auth: Deployment, Service, _helpers.tpl
│   ├── dashboard/              # chart urle-dashboard: Deployment, Service, init-db Job (hook), _helpers.tpl
│   ├── redirect/               # chart urle-redirect: Deployment, Service, _helpers.tpl
│   ├── postgres/                # StatefulSet + headless Service + PVC (dev/local only)
│   ├── redis/                   # Deployment + Service
│   ├── git-ops/                 # Argo CD: projects/urle-project.yaml + one Application per env
│   │                            #   (dev.yaml, prod.yaml) pointing at helm/urle-chart
│   └── urle-chart/              # UMBRELLA chart: depends on the five above;
│                                 #   owns the cross-cutting shared ConfigMap and
│                                 #   the single Ingress that routes to all 3
│                                 #   app services (see §4); postgres subchart
│                                 #   disabled where RDS is used
├── terraform/
│   ├── modules/                 # plain Terraform, no env-specific values
│   │   ├── vpc/
│   │   ├── eks/                 # cluster + explicit access entries (admin + CI role)
│   │   ├── ecr/                 # generic, parameterized by `name` — one instance per service (global)
│   │   ├── rds-postgres/        # prod database + composer of the urle/prod/app secret
│   │   ├── argocd/              # Argo CD install + bootstrap Application + VPN-only ingress
│   │   ├── github-oidc/         # GitHub Actions OIDC provider + urle-{dev,prod}-cicd + urle-release roles
│   │   ├── vpn/                 # wg-easy + Caddy on EC2 (SSM-only, split-tunnel)
│   │   ├── route53-private/     # urle-<env>.internal zone → internal nginx NLB
│   │   ├── route53-public-zone/ # the app domain (single source of truth)
│   │   ├── acm/                 # DNS-validated cert for the apex <domain>
│   │   ├── alb-controller/      # AWS Load Balancer Controller (IRSA + Helm) + CloudFront-only ALB SG
│   │   ├── external-dns/        # writes the origin record → ALB once the Ingress exists
│   │   └── cloudfront/          # edge: TLS, /static/* caching, owns the public apex <domain> record
│   └── environments/            # Terragrunt live tree
│       ├── root.hcl             # root: S3 remote state (native lockfile), provider generation
│       ├── global/              # account-wide, never part of an env teardown
│       │   └── {github-oidc,ecr-auth,ecr-dashboard,ecr-redirect,route53-public-zone}/terragrunt.hcl
│       ├── dev/                 # VPN-only (internal NLB)
│       │   └── {vpc,eks,vpn,route53-private,argocd,...}/terragrunt.hcl
│       └── prod/                # public app via ALB+ACM; admin surfaces VPN-only
│           └── {vpc,eks,vpn,route53-private,acm,alb-controller,external-dns,cloudfront,rds-postgres,argocd,...}/terragrunt.hcl
└── .github/workflows/           # one CI + one release workflow per service (§5)
    ├── app-auth-ci.yaml
    ├── app-auth-release.yaml
    ├── app-dashboard-ci.yaml
    ├── app-dashboard-release.yaml
    ├── app-redirect-ci.yaml
    ├── app-redirect-release.yaml
    ├── charts-ci.yaml
    ├── infra-ci.yaml            # fmt/validate + per-unit plan on PRs
    ├── infra-apply.yaml         # dispatch-only apply (plan-gated)
    ├── infra-bootstrap.yaml     # dispatch-only cold start (no plan by design)
    └── infra-destroy.yaml       # dispatch-only teardown (typed confirmation)
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
  - `helm/urle-chart/templates/configmap.yaml` — the shared
    `RATELIMIT_STORAGE_URI`/`TRUST_PROXY` ConfigMap, referenced by name from
    `urle-auth` and `urle-dashboard`'s Deployments (mirrors
    `k8s/configmaps/urle-configmap.yaml`).
  - `helm/urle-chart/templates/ingress.yaml` — the single Ingress with the path
    rules from §1, pointing at `urle-auth`/`urle-dashboard`/`urle-redirect`
    Service names (mirrors `k8s/ingress/main-ingress.yaml`).
- The init-db Job is owned by **`helm/dashboard`** specifically (not
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
| `app-<service>-release.yaml` (×3) | tag push `v*.*.*` (all 3 fire together — a release tag ships all 3 images at a matching version) | build image → push to that service's ECR repo tagged `MAJOR.MINOR.PATCH` (+ git SHA) → bump `helm/<service>` `appVersion`/`version` and the umbrella chart's dependency version + umbrella `version`/`appVersion`, via PR |
| `charts-ci.yaml` | `helm/**` | `helm lint` + `helm template` all charts; verify chart `version` was bumped |
| `infra-ci.yaml` | `terraform/**` | `terraform fmt -check`, `terraform validate` (always-on check) + per-unit `terragrunt plan` per env on PRs, gated by `DEV_UP`/`PROD_UP` repo variables (plan fails against a torn-down env by nature) |
| `infra-apply.yaml` | `workflow_dispatch` (env choice) | fresh per-unit plan → `terragrunt run --all apply`; prod gated by the `prod` GitHub Environment's required reviewer |
| `infra-bootstrap.yaml` | `workflow_dispatch` (env choice) | cold-start apply in dependency order, deliberately no plan step; flips `<ENV>_UP=true` on success |
| `infra-destroy.yaml` | `workflow_dispatch` (env + typed confirmation) | `terragrunt run --all destroy`; ECR/ACM/public zone survive (global/ or destroy-excluded); flips `<ENV>_UP=false` |

**Known tradeoff:** since all 3 release workflows fire on the same tag and
each opens its own PR bumping `helm/urle-chart/Chart.yaml`'s dependency list and
version, those 3 PRs can conflict with each other if merged out of order.
This is accepted as equivalent to normal automated-PR conflicts (e.g.
Dependabot) — a human merges them, rebasing if needed. Not solved by a
single combined "bump all 3" workflow, since that would blur the "one
workflow per service" separation this repo intentionally keeps.

**CD is Argo CD, not CI:** workflows only build/push images and bump chart
versions; Argo CD watches `helm/git-ops/*` → `helm/urle-chart` and syncs the
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
| Postgres | in-cluster chart (`postgres.enabled: true`) | **RDS** via `terraform/modules/rds-postgres` (`postgres.enabled: false`) |
| Redis | in-cluster chart | in-cluster chart (ElastiCache is a later option) |
| Secrets | `kubectl create secret` per `k8s/README.md` | AWS Secrets Manager + External Secrets (or SSM), never in git |
| Ingress | internal nginx NLB, **VPN-only** (`app.urle-dev.internal`) | public **ALB + ACM** at `urle.<domain>`; ArgoCD/Grafana stay VPN-only |

## 8a. AWS-compatibility & automation goals (2026-07 pass)

Reference architecture: `shyrimon2000-tech/chess-infrastructure`. The goal is
that **the entire AWS lifecycle runs from GitHub Actions** — a torn-down
environment comes back with one workflow dispatch, and nothing but the
one-time bootstrap (`docs/BOOTSTRAP.md`) ever requires a laptop.

1. **CI identity is provisioned, not assumed.** `terraform/environments/global/github-oidc`
   creates the OIDC provider + `urle-dev-cicd`/`urle-prod-cicd` (trust scoped
   per GitHub Environment — single-branch repo, so no per-branch trust) and
   `urle-release` (trust scoped to `v*` tags, ECR-push-only). No long-lived
   AWS keys anywhere.
2. **Teardown cycles are first-class.** This project is destroyed between
   sessions for cost. Everything that must survive lives in
   `terraform/environments/global/` (OIDC roles, ECR repos + released images, public
   zone) or carries an `exclude`-from-destroy block (prod ACM). Prod RDS is
   deliberately NOT excluded — it lives inside the prod VPC, so sparing it
   would leave a half-destroyed, still-billing environment; the final
   snapshot + typed confirmation + prod reviewer are the guard rails.
3. **Plan-on-PR, apply-on-dispatch.** Per-unit `terragrunt plan` on PRs
   (never `run --all plan` — mock-outputs break helm/kubectl provider units),
   gated by `DEV_UP`/`PROD_UP` repo variables because plan genuinely fails
   against a cold environment. Applies only via `workflow_dispatch`
   (`infra-apply`), cold starts via `infra-bootstrap` (no plan by design),
   teardown via `infra-destroy` (typed confirmation).
4. **Single source of truth for cross-cutting values.** The app domain lives
   only in `terraform/environments/global/route53-public-zone`; modules publish their
   outputs (ECR URLs, IRSA role ARN, RDS endpoint, cert ARN, zone id) as
   `/urle/...` SSM parameters. The only hand-filled values are the
   name-deterministic account id + domain in the chart values (one-time,
   teardown-stable).
5. **Secrets: Terraform reads, never creates, bootstrap credentials.** Manual
   SSM SecureStrings (VPN hash, RDS master password, SECRET_KEY, Redis
   password) are composed by `terraform/modules/rds-postgres` into the single
   `urle/prod/app` Secrets Manager secret the chart's ExternalSecret consumes.
6. **Private-by-default access.** Dev and all admin surfaces (ArgoCD,
   Grafana) are reachable only over WireGuard (`vpn` module — SSM-managed
   EC2, no SSH) + `urle-<env>.internal` private zones. Only prod app traffic
   is public, via ALB + ACM auto-discovery + ExternalDNS.
7. **Cold-start is single-pass.** ArgoCD units carry ordering-only
   dependencies on everything the auto-synced chart needs (ALB controller,
   ESO, RDS, monitoring CRDs); ExternalDNS resolves the "ALB doesn't exist at
   apply time" sequencing autonomously.

## 9. Implementation order (for the executing agent)

Historical note: steps 1–6 describe the *original* single-service buildout
and are complete. The 3-service split (this revision) followed as a
subsequent pass over an already-working single-service infra stack, in this
order:

1. Split `app/` into `shared/` + `services/{auth,dashboard,redirect}/`,
   verify locally and on a real cluster (raw `k8s/` manifests) end to end.
2. `helm/` — replace the single app chart with 3 service charts + move
   the shared ConfigMap/Ingress into the umbrella chart's own templates →
   verify: `helm lint` + `helm template` output matches `k8s/` resources.
3. `.github/workflows/` — replace the single app-ci/app-release pair with 3
   pairs, path-filtered per service (plus `shared/**`) → verify: each
   triggers only on its own paths; ruff gate fails on an injected violation.
4. `terraform/modules/`/`terraform/environments/` — add 2 more ECR Terragrunt units per env
   (3 total, one per service) → verify: `terragrunt plan` succeeds per env.
5. `helm/git-ops/` — no changes needed; the per-env Applications already point at
   `helm/urle-chart` regardless of what it composes internally.
6. Only after Helm parity is validated in a cluster: mark `k8s/` as
   deprecated in its README (do not delete without user approval).

**Hard constraints:** never commit real secrets (`k8s/README.md` policy),
never serve `run.py` in production (gunicorn + factory only), keep
`SECRET_KEY`'s fail-closed guard intact on `urle-auth`/`urle-dashboard`, and
keep every deployable reference on SemVer.

## 10. Hardening backlog (punch list for the executing agent)

Gap audit of the current `helm/` + `terraform/` state against production
readiness. Already-verified as **not** gaps, do not redo: ECR repos are
`image_tag_mutability = IMMUTABLE` with `scan_on_push` (`terraform/modules/ecr`),
prod RDS has `multi_az = true` and 7-day backups
(`terraform/environments/prod/rds-postgres`), and all 3 app Deployments already run
non-root with `/healthz` liveness+readiness. Ask before starting per
`.claude/bootcamp-CLAUDE.md` (security/networking/infra changes need
sign-off) — this section is the brief to get that sign-off against, not a
green light to start.

Ordered by **build dependency**, not by theme: within a phase, items have no
dependency on each other and can ship in any order; across phases, each
phase assumes every earlier phase is done. Items originally grouped as
P0/P1/P2/P3 are preserved via the `[P#]` tag on each item.

### Phase 0 — cluster-level prerequisites (install once; several later items are no-ops without these)

1. `[P0]` **cert-manager install.** Not installed anywhere in `terraform/`.
   Add `terraform/modules/cert-manager` (mirror `terraform/modules/argocd`'s
   Helm-install pattern), wired into `terraform/environments/{dev,prod}`. Unblocks
   item 8. Verify: `kubectl get pods -n cert-manager` all `Running`.
2. `[P0]` **ingress-nginx controller install.**
   `helm/urle-chart/templates/ingress.yaml` sets `ingressClassName: nginx`, but
   **no module installs the controller** — a repo-wide search finds nginx
   only in a code comment, so the existing Ingress is undeployed today
   regardless of any other item here. Add `terraform/modules/ingress-nginx`
   (same Helm-install pattern, `https://kubernetes.github.io/ingress-nginx`,
   `namespace = "ingress-nginx"`), wired into `terraform/environments/{dev,prod}`.
   Unblocks the existing Ingress plus items 8 (TLS) and 9 (the NetworkPolicy
   ingress allow-rule targets this namespace). Verify:
   `kubectl get pods -n ingress-nginx` all `Running`; the controller Service
   gets an external address.
3. `[P1]` **Metrics Server EKS addon.** Not installed anywhere in
   `terraform/modules/eks`. Add it as an EKS addon
   (`aws_eks_addon "metrics-server"`) or, if the managed addon isn't in the
   catalog for this cluster's `cluster_version`/region, a Helm install in the
   argocd pattern (keep that fallback ready — don't assume the addon
   resolves). Unblocks item 12. Verify: `kubectl top pods` returns data
   instead of erroring.
4. `[P1]` **Cluster/node autoscaler (Karpenter).** `terraform/modules/eks`
   node groups (`eks_managed_node_groups` in `terraform/modules/eks/main.tf`)
   have fixed `node_min_size`/`node_max_size`/`node_desired_size` but
   nothing watches for unschedulable pods and grows the group — confirmed
   no Karpenter, Cluster Autoscaler, or equivalent anywhere in `terraform/`
   (this is the "carpenter" gap from earlier in this session: genuinely
   absent, on minikube *and* in the EKS Terraform). Add
   `terraform/modules/karpenter` (controller IAM/IRSA role, **node IAM role +
   instance profile, interruption SQS queue**, Helm install, a
   `NodePool`/`EC2NodeClass` scoped to the node types/AZs from
   `terraform/modules/vpc`). **Also edit `terraform/modules/vpc/main.tf`** to add a
   `karpenter.sh/discovery = <cluster_name>` tag to the private subnets and
   node security group — the `EC2NodeClass` selectors resolve against those
   tags, and the VPC module currently tags subnets only with
   `kubernetes.io/cluster/<name>=shared`, so Karpenter is **not**
   self-contained in its own module. Preferred over Cluster Autoscaler for
   new builds since it provisions per-pod rather than per-ASG. Without this,
   item 12's HPA can request replicas that then sit `Pending` forever once
   the fixed node group is full — do this **before** item 12. Verify: scale
   a Deployment past current node capacity and confirm a new node joins
   within Karpenter's provisioning window.
5. `[P0]` **External Secrets Operator + IRSA install.** No
   `terraform/modules/external-secrets` and no IRSA role for it exist anywhere
   in the repo. Add the operator install (Helm-installed like `argocd`)
   and an IRSA role scoped to read only the `urle/prod/*` Secrets Manager
   path. Unblocks item 10. Verify: `kubectl get pods -n external-secrets`
   all `Running`; the IRSA role's trust policy resolves to the operator's
   ServiceAccount.
6. `[P2]` **kube-prometheus-stack install.** Zero references to
   `prometheus`/`grafana` anywhere in this repo outside this manifest. Add
   a self-contained `terraform/modules/kube-prometheus-stack` (same Helm-install
   pattern) + `terraform/environments/{dev,prod}/monitoring/terragrunt.hcl` — gives
   Prometheus, Alertmanager, node-exporter, kube-state-metrics, and Grafana
   in one shot. A GitOps `helm/git-ops/monitoring.yaml` route is **not**
   reachable as-is: the app-of-apps bootstrap in `terraform/modules/argocd/main.tf`
   includes only `{projects/*.yaml,apps/${var.environment}.yaml}`, so a new
   Application file is never synced unless that glob is widened first —
   default to the self-contained module unless you widen the glob
   deliberately. Unblocks items 15–16. Verify: `kubectl get pods -n
   monitoring` all `Running`; Grafana reachable via port-forward with the
   default dashboards loaded.
7. `[P0]` **VPC-CNI NetworkPolicy enforcement.** The AWS VPC CNI does **not**
   enforce `NetworkPolicy` objects unless `enableNetworkPolicy=true` is set on
   the `vpc-cni` addon (or Calico is installed) — so item 9's policies would
   be accepted and silently ignored, and its verify step would falsely "pass
   by omission." Set `cluster_addons.vpc-cni.configuration_values` with
   `enableNetworkPolicy = "true"` in `terraform/modules/eks/main.tf`. Unblocks
   item 9. Verify: after item 9 lands, a disallowed pod actually **fails** to
   reach `postgres:5432` (rather than succeeding because nothing enforces).

### Phase 1 — security hardening

8. `[P0]` **TLS on the Ingress.** `helm/urle-chart/templates/ingress.yaml` has
   no `tls:` block; `helm/urle-chart/values.yaml` `ingress.annotations` has no
   `cert-manager.io/cluster-issuer`. Add a `tls.enabled`/`secretName`
   value, the `tls:` stanza, and the cluster-issuer annotation. Depends on
   items 1 (cert-manager) and 2 (an actual ingress controller to terminate
   TLS). Verify: `helm template helm/urle-chart -f helm/urle-chart/values-prod.yaml`
   shows a populated `tls:` block; `kubectl get certificate` is `Ready`
   post-apply.
9. `[P0]` **NetworkPolicy — default-deny + explicit allows.** No
   `NetworkPolicy` object exists anywhere under `helm/`. Add
   default-deny-ingress per namespace plus allow rules: ingress-nginx →
   `urle-{auth,dashboard,redirect}`; `urle-{auth,dashboard,redirect}` →
   `postgres:5432`; `urle-{auth,dashboard}` → `redis:6379`. Owned by the
   umbrella chart (`helm/urle-chart/templates/`, same reasoning as the shared
   ConfigMap/Ingress — these span multiple subcharts). Depends on item 7
   (without CNI enforcement the policy is a silent no-op) and assumes item
   2's `ingress-nginx` namespace for the ingress allow-rule. Verify: a pod
   outside the allow list (e.g. `kubectl run test --rm -it --image=busybox`)
   can't reach `postgres:5432`.
10. `[P0]` **Prod secrets path.** No `ExternalSecret` CRD usage anywhere —
    today prod has no documented way to actually get `urlshortener-secrets`
    into the cluster. Add **both** an `ExternalSecret` template **and** a
    `(Cluster)SecretStore` (the `ExternalSecret`'s `secretStoreRef` must
    point at a store wired to Secrets Manager via item 5's IRSA SA, or the
    CRD reconciles to an error) in `helm/urle-chart`, gated by a values flag
    (off for dev, on for prod where `postgres.enabled: false`). Depends on
    item 5. Verify: deleting the K8s Secret in prod causes External Secrets
    to recreate it within its refresh interval, no manual `kubectl create
    secret` needed.
11. `[P0]` **Redis auth.** `helm/redis` has no `requirepass`; anything
    in-cluster can read/flush the rate-limit store. Add `requirepass`
    sourced from `existingSecret` (extend `urlshortener-secrets` with a
    `REDIS_PASSWORD` key) and pass `--requirepass` in
    `helm/redis/templates/deployment.yaml`. **Two things the naive
    approach gets wrong:** (1) the readiness probe (`redis-cli ping`) will
    return `NOAUTH` once auth is on and the pod never goes Ready — make it
    auth-aware (`redis-cli -a $(REDIS_PASSWORD) ping` or set `REDISCLI_AUTH`);
    (2) do **not** put `redis://:$(REDIS_PASSWORD)@redis:6379/0` in the
    umbrella ConfigMap — `$(VAR)` is never expanded for `envFrom`-injected
    ConfigMap values (only for `env:` entries with an explicit `value:`), so
    the app would receive a literal, unexpanded string. Instead carry the
    fully-formed URI in the Secret (it already flows through each app
    Deployment's `secretRef` envFrom): in prod via item 10's ExternalSecret,
    in dev via the manually-created Secret. Bump `helm/redis/Chart.yaml`
    and the umbrella. Verify: `redis-cli -h redis ping` without auth fails
    with `NOAUTH`; app rate-limiting still works.

### Phase 2 — resilience & scale

12. `[P1]` **HorizontalPodAutoscaler for the 3 app charts.** Replica
    counts are static (`replicaCount` in each `values-{dev,prod}.yaml`);
    nothing reacts to load, and `urle-redirect` is the stated hot path.
    Add `templates/hpa.yaml` to each of
    `helm/{auth,dashboard,redirect}`, gated by an
    `autoscaling.enabled`/`minReplicas`/`maxReplicas`/`targetCPUUtilization`
    value block. Depends on items 3 (Metrics Server, for CPU metrics) and 4
    (Karpenter, or scaled-up replicas sit `Pending`). Verify: `kubectl get
    hpa` shows non-zero current/target metrics.
13. `[P1]` **PodDisruptionBudget for the 3 app charts.** A node drain can
    currently evict every replica of a service at once. Add
    `templates/pdb.yaml` (`minAvailable: 1` or `50%`) to each app chart.
    No dependency. Verify: `kubectl drain` on a node running all replicas
    of one service is blocked until it can maintain the budget.
14. `[P1]` **Spread replicas across nodes.** No `podAntiAffinity` or
    `topologySpreadConstraints` in any of the 3 Deployment templates —
    replicas can land on the same node. Add a `topologySpreadConstraints`
    block keyed on `topology.kubernetes.io/zone` (or
    `kubernetes.io/hostname` on minikube-sized clusters where zone spread
    doesn't apply) with `whenUnsatisfiable: ScheduleAnyway` so it doesn't
    block scheduling on a small dev cluster. No dependency. Verify:
    `kubectl get pods -o wide` shows replicas on distinct nodes in a
    multi-node cluster.

### Phase 3 — observability

15. `[P2]` **Metrics endpoint + ServiceMonitor.** None of the 3 Flask
    services expose `/metrics` (grepped `services/` — no
    `prometheus_flask_exporter` or equivalent). App-code change, not just
    a chart change: add the exporter to each service's `requirements.txt`
    and wire it in each `create_app()`, then add a `ServiceMonitor`
    template per app chart gated by a `metrics.serviceMonitor.enabled`
    flag. Depends on item 6. Verify: `curl` the pod's `/metrics` returns
    Prometheus-format output; `kubectl get servicemonitor` picks it up
    when the flag is on.
16. `[P2]` **Grafana dashboards for URLe.** Add per-service dashboards
    (request rate/latency/error rate for the 3 app services, redirect
    click-through) as ConfigMaps carrying the `grafana_dashboard: "1"`
    label so kube-prometheus-stack's sidecar auto-loads them — versioned
    in `helm/urle-chart/templates/`, not hand-imported through the UI.
    Depends on items 6 and 15 (dashboards need real `/metrics` data to be
    worth building).

### Phase 4 — policy & access hardening

17. `[P2]` **Namespace Pod Security Standards.**
    `helm/git-ops/{dev,prod}.yaml` use `syncOptions: [CreateNamespace=true]`,
    which creates a bare namespace with no
    `pod-security.kubernetes.io/enforce` label — non-root today is
    convention (each Deployment's own `securityContext`), not
    cluster-enforced. Add `spec.syncPolicy.managedNamespaceMetadata.labels:
    {pod-security.kubernetes.io/enforce: restricted}` to both Application
    manifests. No dependency, but do this **last** among the chart changes
    so it enforces against an already-compliant final state rather than
    blocking earlier phases mid-rollout. Verify: a manifest with a
    root-running container is rejected at apply time, not just at
    chart-review time.
18. `[P2]` **Dedicated ServiceAccounts.** All pods currently run under
    each namespace's `default` ServiceAccount. Add a `ServiceAccount` per
    app chart (`templates/serviceaccount.yaml`) with
    `automountServiceAccountToken: false` (none of the 3 services call the
    K8s API), referenced from each Deployment's
    `spec.template.spec.serviceAccountName`. No dependency. Verify:
    `kubectl get sa` shows one per service, not just `default`.

### Phase 5 — process (not chart/infra work — flag for the user, don't just do it)

19. `[P3]` **The documented PR-based release flow has never run.** §5 says
    `app-<service>-release.yaml` opens a PR to bump chart versions on
    every `vX.Y.Z` tag push, but `git tag -l` is empty and `git log` shows
    every commit going straight to `main` — no branch has ever existed, so
    this path is unverified. Needs: branch protection on `main` requiring
    the CI workflows as required status checks, then an actual `v0.1.0`
    tag push to confirm the 3 release workflows open working PRs and that
    the "3 conflicting PRs" tradeoff noted in §5 behaves as described.
20. `[P3]` **Git/GitHub collaboration practice is untested** — no merge
    conflict has ever been resolved in this repo, no PR has ever been
    reviewed (bootcamp modules `01-git/*/03.1-commit-fixes`,
    `01-git/*/04.1-merge-conflicts`, `02-github/*/03.1-pr-conflicts`).
    Informational only — nothing to build, just noting the subject has no
    footprint here the way the tooling-heavy domains do.

## 11. Execution plan for §10 items 1–18 (implemented by Opus 4.8)

**Build status:** items 1–18 implemented. Chart-level items (8–18) were
verified locally with `helm lint`/`helm template` (+ `py_compile` for the app
code); charts bumped to 1.1.0. Phase 0 Terraform (items 1–7) was written and
is `terraform fmt`-clean, but is **not** `validate`/`plan`/`apply`-verified —
that needs an AWS-connected machine with terraform (module output names,
provider wiring, and the version-sensitive Karpenter submodule are the things
to check on first `terragrunt plan`). Items 19–20 are excluded (process
decisions, not engineering work). All corrections from the earlier callout
audit (A–G) are folded into the numbered items below.

**Conventions this plan follows**, derived from reading the actual repo:

- Cluster-level installs mirror `terraform/modules/argocd/`: a module with
  `main.tf` (a pinned `helm_release`), `variables.tf`, `versions.tf`
  (`hashicorp/helm ~> 2.16`), `providers.tf` (the `helm` provider
  authenticated via `aws eks get-token` exec), `outputs.tf` — plus one
  Terragrunt unit per env under `terraform/environments/{dev,prod}/<name>/terragrunt.hcl`
  with a `dependency "eks"` block (and `mock_outputs` for `validate`/`plan`).
  The AWS provider is auto-generated by the root `terraform/environments/root.hcl`
  `generate "provider"` block, so IAM-creating modules don't declare it
  themselves.
- Cross-cutting K8s objects (span more than one subchart) live in
  `helm/urle-chart/templates/`, gated by a `values.yaml` flag, exactly like
  `ingress.yaml`/`configmap.yaml`.
- Per-service K8s objects live in `helm/{auth,dashboard,redirect}/templates/`,
  gated by that chart's own `values.yaml`, using the existing helpers
  (`include "urle-auth.fullname"`, the `app: <fullname>` selector label).
- Pod selector label is `app: urle-auth` / `app: urle-dashboard` /
  `app: urle-redirect` / `app: postgres` / `app: redis` (from `_helpers.tpl`
  + `fullnameOverride`s).
- Every chart edit must bump that chart's `version` in `Chart.yaml` (§6 +
  `charts-ci.yaml` enforces it); umbrella-chart template edits bump
  `helm/urle-chart/Chart.yaml`.

### Phase 0 — cluster-level prerequisites

Items 1–7 touch different modules/live units — fully parallelizable.

- **Item 1 (cert-manager).** New `terraform/modules/cert-manager/{main,variables,versions,providers,outputs}.tf`
  — `helm_release "cert-manager"` (`https://charts.jetstack.io`, pinned
  version, `namespace = "cert-manager"`, `create_namespace = true`, values
  `installCRDs: true`). Copy `providers.tf` verbatim from
  `terraform/modules/argocd/providers.tf`. New
  `terraform/environments/{dev,prod}/cert-manager/terragrunt.hcl` mirroring
  `terraform/environments/dev/argocd/terragrunt.hcl` (`dependency "eks"` with mock
  outputs). Add a `ClusterIssuer` via `helm/urle-chart/templates/clusterissuer.yaml`
  gated by a flag (keeps the ACME email/host env-valued, GitOps-consistent)
  rather than templating it into the Helm release. Verify:
  `kubectl get pods -n cert-manager` all `Running`;
  `kubectl get clusterissuer` `Ready=True`. Unblocks item 8.
- **Item 2 (ingress-nginx controller).** New
  `terraform/modules/ingress-nginx/{main,variables,versions,providers,outputs}.tf`
  — `helm_release "ingress-nginx"` (`https://kubernetes.github.io/ingress-nginx`,
  pinned, `namespace = "ingress-nginx"`, `create_namespace = true`). New
  `terraform/environments/{dev,prod}/ingress-nginx/terragrunt.hcl` (argocd pattern).
  The existing `helm/urle-chart/templates/ingress.yaml` sets
  `ingressClassName: nginx` but nothing installs the controller — a repo-wide
  search finds nginx only in a code comment, so the Ingress is undeployed
  today. Unblocks the existing Ingress plus items 8 (TLS termination) and 9
  (its ingress allow-rule targets the `ingress-nginx` namespace). Verify:
  `kubectl get pods -n ingress-nginx` all `Running`; the controller Service
  gets an external address.
- **Item 3 (Metrics Server).** Edit `terraform/modules/eks/main.tf` — add
  `cluster_addons = { metrics-server = { most_recent = true } }` to the
  `terraform-aws-modules/eks` module block. The managed addon is
  version/region-dependent — if it isn't in the catalog for this cluster's
  `cluster_version`, fall back to a Helm module in the argocd pattern (keep
  that fallback ready rather than assuming the addon resolves). Verify:
  `kubectl top pods` returns data. Unblocks item 12.
- **Item 4 (Karpenter).** New `terraform/modules/karpenter/{main,variables,versions,providers,outputs}.tf`
  — controller IRSA role (via `dependency.eks.outputs.oidc_provider_arn`,
  already an EKS output), node IAM role + instance profile, interruption
  SQS queue, `helm_release "karpenter"` (OCI
  `oci://public.ecr.aws/karpenter/karpenter`, pinned), a `NodePool` +
  `EC2NodeClass` scoped to instance types/AZs from `terraform/environments/*/env.hcl`.
  Karpenter is **not** self-contained in its own module: also edit
  `terraform/modules/vpc/main.tf` to add `karpenter.sh/discovery = var.cluster_name`
  to `private_subnet_tags` and the node security group — the `EC2NodeClass`
  `subnetSelectorTerms`/`securityGroupSelectorTerms` resolve against those
  tags, and the VPC module currently tags subnets only with
  `kubernetes.io/cluster/<name>=shared`. New
  `terraform/environments/{dev,prod}/karpenter/terragrunt.hcl` with `dependency "eks"`
  and `dependency "vpc"`. Verify: scale a Deployment past current node
  capacity, confirm a new node joins (`kubectl get nodes -w`). Must precede
  item 12 — otherwise HPA replicas sit `Pending`.
- **Item 5 (External Secrets Operator + IRSA).** New
  `terraform/modules/external-secrets/{main,variables,versions,providers,outputs}.tf`
  — `helm_release "external-secrets"` (`https://charts.external-secrets.io`,
  pinned, `namespace = "external-secrets"`, `create_namespace = true`) +
  IRSA role (OIDC trust to the operator's SA, policy scoped to
  `secretsmanager:GetSecretValue` on `arn:aws:secretsmanager:*:*:secret:urle/prod/*`),
  SA annotation `eks.amazonaws.com/role-arn` set via Helm values. New
  `terraform/environments/{dev,prod}/external-secrets/terragrunt.hcl`. Verify:
  `kubectl get pods -n external-secrets` all `Running`; IRSA trust policy
  resolves (`aws iam get-role`). Unblocks item 10.
- **Item 6 (kube-prometheus-stack).** New self-contained
  `terraform/modules/kube-prometheus-stack/` Helm module +
  `terraform/environments/{dev,prod}/monitoring/terragrunt.hcl` (same pattern as item
  1). Do **not** use an `helm/git-ops/monitoring.yaml` route unless you first
  widen the app-of-apps bootstrap glob in `terraform/modules/argocd/main.tf`
  (currently `{projects/*.yaml,apps/${var.environment}.yaml}`, so a new
  Application file is never synced). Verify: `kubectl get pods -n monitoring`
  all `Running`; Grafana reachable via port-forward with default dashboards
  loaded. Unblocks items 15, 16.
- **Item 7 (VPC-CNI NetworkPolicy enforcement).** Edit
  `terraform/modules/eks/main.tf` — set `cluster_addons.vpc-cni.configuration_values`
  to `jsonencode({ enableNetworkPolicy = "true" })`. The AWS VPC CNI does not
  enforce `NetworkPolicy` objects without this (or Calico), so item 9's
  policies would be accepted and silently ignored. Verify: after item 9
  lands, a disallowed pod genuinely fails to reach `postgres:5432` (not
  "passes" because nothing enforces). Unblocks item 9.

### Phase 1 — security hardening

Items 8–11 touch different files — parallelizable, subject to the noted
dependencies.

- **Item 8 (TLS on Ingress, needs items 1 + 2).** Edit
  `helm/urle-chart/templates/ingress.yaml` — add a
  `{{- if .Values.ingress.tls.enabled }}` `tls:` stanza
  (`hosts: [{{ .Values.ingress.host }}]`,
  `secretName: {{ .Values.ingress.tls.secretName }}`). Edit
  `helm/urle-chart/values.yaml` (`ingress.tls.enabled: false` + `secretName`)
  and `helm/urle-chart/values-prod.yaml` (`enabled: true`,
  `secretName: urle-tls`, `cert-manager.io/cluster-issuer` annotation —
  prod only, dev stays off). Bump `helm/urle-chart/Chart.yaml`. Verify:
  `helm template helm/urle-chart -f helm/urle-chart/values.yaml -f helm/urle-chart/values-prod.yaml`
  shows a populated `tls:` block; post-apply `kubectl get certificate` is
  `Ready`.
- **Item 9 (NetworkPolicy default-deny + allows, needs item 7).** New
  `helm/urle-chart/templates/networkpolicy.yaml` (umbrella-owned) gated by
  `networkPolicy.enabled`: default-deny-ingress (empty `podSelector`,
  `policyTypes: [Ingress]`) plus allows — ingress-nginx namespace → `app in
  {urle-auth,urle-dashboard,urle-redirect}:5000`; app pods → `app:
  postgres:5432`; `urle-auth`/`urle-dashboard` → `app: redis:6379`. Edit
  `helm/urle-chart/values.yaml` + enable in `values-prod.yaml`. Bump
  `helm/urle-chart/Chart.yaml`. Enforcement requires item 7 (the VPC-CNI addon
  setting) — without it the policy is a silent no-op — and the ingress
  allow-rule assumes item 2's `ingress-nginx` namespace. Verify:
  `kubectl run test --rm -it --image=busybox -n urle-prod -- nc -zv postgres
  5432` fails/times out.
- **Item 10 (prod secrets path, needs item 5).** New
  `helm/urle-chart/templates/externalsecret.yaml` gated by
  `externalSecrets.enabled` (off dev, on prod), templating **both** an
  `ExternalSecret` (target `urlshortener-secrets`, keys `SECRET_KEY`,
  `DATABASE_URL`, and — with item 11 — the password-bearing
  `RATELIMIT_STORAGE_URI` / `REDIS_PASSWORD`, from `urle/prod/*` in Secrets
  Manager) **and** a `(Cluster)SecretStore` wired to Secrets Manager via
  item 5's IRSA SA. The store is not optional — the `ExternalSecret`'s
  `secretStoreRef` has nothing to point at without it and the CRD reconciles
  to an error. Edit `helm/urle-chart/values.yaml` + `values-prod.yaml`. Bump
  `helm/urle-chart/Chart.yaml`. Verify: `kubectl delete secret
  urlshortener-secrets -n urle-prod` → ESO recreates it within the refresh
  interval.
- **Item 11 (Redis auth).** Edit `helm/redis/templates/deployment.yaml` —
  `args: [--requirepass, $(REDIS_PASSWORD)]` sourced via `secretKeyRef`
  from the extended `urlshortener-secrets`, and **fix the readiness probe**:
  `redis-cli ping` returns `NOAUTH` once auth is on and the pod never goes
  Ready, so make it auth-aware (`redis-cli -a $(REDIS_PASSWORD) ping` or set
  `REDISCLI_AUTH`). Edit `helm/redis/values.yaml`
  (`auth.enabled`/`existingSecret`/`passwordKey`). **Do not** put the
  password-bearing `RATELIMIT_STORAGE_URI` in the umbrella ConfigMap —
  `$(VAR)` is never expanded for `envFrom`-injected ConfigMap values (only
  for `env:` entries with an explicit `value:`), so the app would receive a
  literal `$(REDIS_PASSWORD)` string. Carry the fully-formed URI in the
  Secret instead (it already flows through each app Deployment's `secretRef`
  envFrom): in prod via item 10's ExternalSecret, in dev via the
  manually-created Secret. Bump `helm/redis/Chart.yaml` and the umbrella.
  Verify: unauthenticated `redis-cli -h redis ping` returns `NOAUTH`; app
  rate-limiting still works.

### Phase 2 — resilience & scale

Items 12–14 add new per-service template files to independent charts —
parallelizable once item 12's Phase 0 dependencies (3, 4) are met.

- **Item 12 (HPA, needs items 3 + 4).** New
  `helm/{auth,dashboard,redirect}/templates/hpa.yaml` gated by
  `autoscaling.enabled`, targeting each chart's Deployment,
  `minReplicas`/`maxReplicas`/`averageUtilization`. Edit each `values.yaml`
  (default off) — existing `100m` CPU requests make
  `targetCPUUtilization` valid immediately. Bump each `Chart.yaml` +
  umbrella dependency versions. Verify: `kubectl get hpa` shows non-`<unknown>`
  current/target metrics.
- **Item 13 (PodDisruptionBudget).** New
  `helm/{auth,dashboard,redirect}/templates/pdb.yaml`
  (`minAvailable: 1` or `50%`, selector `app: <fullname>`), gated by
  `pdb.enabled`. Edit each `values.yaml`; bump each `Chart.yaml` +
  umbrella. Verify: `kubectl drain` on a node running all replicas of one
  service is blocked until the budget can be maintained.
- **Item 14 (topology spread).** Edit each
  `helm/{auth,dashboard,redirect}/templates/deployment.yaml` — add
  `topologySpreadConstraints` under `spec.template.spec`, keyed on
  `topology.kubernetes.io/zone` (values-driven fallback to
  `kubernetes.io/hostname` for single-zone dev), `whenUnsatisfiable:
  ScheduleAnyway`, `labelSelector: {app: <fullname>}`. Edit each
  `values.yaml` (so dev can differ from prod); bump each `Chart.yaml` +
  umbrella. Verify: `kubectl get pods -o wide` shows replicas on distinct
  nodes in a multi-node cluster.

### Phase 3 — observability

- **Item 15 (/metrics + ServiceMonitor, needs item 6).** App code first:
  edit `services/{auth,dashboard,redirect}/requirements.txt` — add
  `prometheus-flask-exporter` (pinned); edit
  `services/{auth,dashboard,redirect}/app/__init__.py` — instantiate the
  exporter inside `create_app()` (the redirect service has no extensions
  today beyond `db` — add it there too since it's the stated hot path).
  Watch `ruff` import-sort in `app-<service>-ci.yaml`. Then chart: new
  `helm/{auth,dashboard,redirect}/templates/servicemonitor.yaml`
  gated by `metrics.serviceMonitor.enabled`; edit each `values.yaml`; bump
  each `Chart.yaml` + umbrella. Verify: `curl` a pod's `:5000/metrics`
  returns Prometheus text; `kubectl get servicemonitor` lists all three
  when enabled.
- **Item 16 (Grafana dashboards, needs items 6 + 15).** New
  `helm/urle-chart/templates/grafana-dashboards.yaml` — ConfigMap(s) labeled
  `grafana_dashboard: "1"` (sidecar auto-load), one panel set per service
  (rate/latency/error) plus redirect click-through, gated by
  `grafana.dashboards.enabled`. Edit `helm/urle-chart/values.yaml`/`values-prod.yaml`;
  bump `helm/urle-chart/Chart.yaml`. Verify: dashboards appear in Grafana
  without manual import, populated from real `/metrics` data.

### Phase 4 — policy & access hardening

- **Item 17 (namespace Pod Security Standards) — do last among chart
  changes.** Edit `helm/git-ops/dev.yaml` and `helm/git-ops/prod.yaml` — add
  `spec.syncPolicy.managedNamespaceMetadata.labels: {pod-security.kubernetes.io/enforce: restricted}`.
  Apply only after Phases 1–3 land: `restricted` also requires
  `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, and
  dropped capabilities beyond just non-root — verify the app Deployments'
  `securityContext` satisfies these first or the label will block the
  rollout. Verify: a manifest with a root/privileged container is rejected
  at apply time.
- **Item 18 (dedicated ServiceAccounts) — parallel with 17, no
  dependency.** New `helm/{auth,dashboard,redirect}/templates/serviceaccount.yaml`
  (`automountServiceAccountToken: false`), gated by `serviceAccount.create`.
  Edit each `deployment.yaml` (set `spec.template.spec.serviceAccountName`)
  and `values.yaml`; bump each `Chart.yaml` + umbrella. Also add
  `serviceAccountName` to `helm/dashboard/templates/init-db-job.yaml`
  for consistency. Verify: `kubectl get sa -n urle-prod` shows one per
  service, not just `default`.

### Corrections folded in (resolved)

The grounding pass found seven places where the original punch list was
wrong, incomplete, or improvable. All are now incorporated into the numbered
items above — this list is kept only as a record of what changed:

- **A — no ingress-nginx controller anywhere in `terraform/`.** Now its own
  Phase 0 item (item 2); the existing Ingress, TLS (item 8), and the
  NetworkPolicy ingress allow-rule (item 9) all depend on it.
- **B — NetworkPolicy is a silent no-op on default EKS.** Now its own Phase
  0 item (item 7, the `vpc-cni` `enableNetworkPolicy` addon setting); item 9
  depends on it.
- **C — Redis auth had two concrete bugs** (`$(VAR)` not expanded from a
  ConfigMap via `envFrom`; readiness probe breaks under `requirepass`). Both
  fixes are in item 11.
- **D — Karpenter needs a VPC edit** (`karpenter.sh/discovery` tags) it
  didn't own. Now part of item 4.
- **E — the `helm/git-ops/monitoring.yaml` route is unreachable** until the
  bootstrap glob is widened. Item 6 now defaults to a self-contained module.
- **F — Metrics Server as a managed addon is version/region-dependent.**
  Item 3 keeps the Helm fallback.
- **G — item 10 needs a `(Cluster)SecretStore`, not just an
  `ExternalSecret`.** Item 10 now templates both.

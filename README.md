# URLe — URL Shortener

A production-structured URL shortener built with Flask. Users register, log in,
shorten URLs, share the short links, and track how many times each link is
clicked.

The app is split into **3 independently deployable microservices** — `auth`,
`dashboard`, and `redirect` — each its own Flask application-factory process,
its own container image, and its own Kubernetes Deployment, all sharing one
Postgres database. The split exists so the public, unauthenticated redirect
path (the hottest, most latency-sensitive route — every short-link click hits
it) can scale independently of the authenticated dashboard and the
low-traffic auth flows.

---

## What it does

- **Accounts** — register / log in / log out (session-based auth).
- **Shorten** — turn a long URL into a short 6-character code, scoped to your account.
- **Redirect** — visiting `/<code>` redirects to the original URL and increments a click counter.
- **Dashboard** — list your links with original URL, short link, click count, copy button, and delete.
- **API** — `POST /shorten` and `DELETE /url/<id>` also accept/return JSON for programmatic use.

---

## How it works

### Architecture

Each service uses the **application-factory pattern** (`create_app()` in its
own `services/<name>/app/__init__.py`), just like the original monolith did —
the split didn't change that pattern, it just gave each service its own
factory instead of one shared one. What *is* shared — the DB models, the
Flask extension singletons, and config — lives in a small `shared/` package
that every service imports (not pip-installed; each Dockerfile `COPY`s it in
at build time, with the repo root as build context).

```
Project_URLe/
├── shared/                        # imported by all 3 services — single source of truth for schema
│   ├── config.py                  # Config from env (SECRET_KEY, DATABASE_URL with postgres:// normalization)
│   ├── extensions.py               # db, login_manager, csrf, limiter (singletons)
│   └── models/
│       ├── user.py                # User (UserMixin): id, username, email, password_hash + scrypt helpers
│       └── url.py                 # Url: id, original_url, short_code, clicks, created_at, user_id (FK)
│                                   #   (__init__.py imports both submodules unconditionally — see note below)
│
├── services/
│   ├── auth/app/
│   │   ├── __init__.py            # create_app() — auth-only: db, login_manager, csrf, limiter
│   │   └── routes/
│   │       ├── auth.py            # /register, /login, /logout
│   │       └── health.py          # /healthz
│   │
│   ├── dashboard/app/
│   │   ├── __init__.py            # create_app() — dashboard-only: db, login_manager, csrf, limiter
│   │   ├── routes/
│   │   │   ├── main.py            # / (landing page or dashboard)
│   │   │   ├── urls.py            # /shorten, /urls, /url/<id>
│   │   │   └── health.py          # /healthz
│   │   ├── utils/
│   │   │   ├── shortener.py       # generate_short_code(): collision-safe random code
│   │   │   └── validators.py      # normalize_url(), normalize_custom_code(), RESERVED_SHORT_CODES
│   │   ├── templates/             # Jinja2: base, index, login, register, dashboard
│   │   └── static/                # css/style.css, js/app.js — the ONLY copy; auth's pages reference these too
│   │
│   └── redirect/app/
│       ├── __init__.py            # create_app() — minimal: only db (no auth/CSRF/rate-limit needed)
│       └── routes/
│           ├── redirect.py        # GET /<short_code>
│           └── health.py          # /healthz
│
├── k8s/                            # raw Kubernetes manifests (see Infrastructure)
├── charts/                         # Helm charts (see Infrastructure)
├── infra/                          # Terraform/Terragrunt (see Infrastructure)
├── argocd/                         # Argo CD Application/Project definitions
└── .github/workflows/              # CI/CD, one pipeline pair per service
```

**A subtlety worth knowing if you touch `shared/models/`:** `User.urls =
db.relationship("Url", backref="user", ...)` resolves the string `"Url"`
against SQLAlchemy's class registry lazily, the first time any query touches
`User`. Since the `auth` service only ever imports `User` (it never needs
`Url`), that resolution would crash with `InvalidRequestError` unless `Url` is
*also* registered in that process. `shared/models/__init__.py` fixes this by
importing both models unconditionally — so importing either one always
registers both, regardless of which service does the importing. If you add
more cross-model relationships later, they need the same treatment.

**Cross-service auth:** all 3 services read the same `SECRET_KEY` and
`DATABASE_URL` from one Secret. Flask-Login's session cookie, signed with that
shared key, is set by `auth` on login and read by `dashboard` on every
authenticated request — no server-side session store, no inter-service API
calls, just a shared signing key and a shared `users` table. This only works
because all 3 services sit behind one Ingress/host (path-based routing, not
subdomains), so the browser sends the same cookie to all of them.
`login_manager.login_view` is set to the *absolute* path `"/login"` (not the
blueprint-relative `"auth.login"`) in both `auth` and `dashboard`, since
`dashboard`'s process has no `auth` blueprint registered to resolve that
endpoint name against.

### Request flows

- **Register** (`auth`) → validates fields + password length (≥ 8), checks
  username/email uniqueness, hashes the password (Werkzeug **scrypt**),
  stores the user.
- **Login** (`auth`) → verifies the password hash, starts a Flask-Login
  session (signed cookie, valid across all 3 services).
- **Shorten** (`dashboard`) → validates/normalizes the URL (`normalize_url`),
  generates a unique short code (retrying on the unique-constraint race),
  stores it against the user. Returns a redirect (form) or `201` JSON (API);
  the JSON response's `short_url` is built as a hardcoded
  `request.host_url + short_code` rather than `url_for(...)`, since the
  redirect route no longer lives in this service's URL map.
- **Redirect** (`redirect`, `GET /<code>`) → looks up the code; on hit,
  performs an **atomic** `clicks = clicks + 1` SQL update and 302-redirects
  to the original URL; unknown codes return `404`. No auth, no CSRF, no rate
  limiting — this route is deliberately as cheap as possible.
- **Delete** (`dashboard`) → form `POST /url/<id>/delete` (redirect) or
  `DELETE /url/<id>` (JSON); both are scoped to the owner.

### Endpoints

| Method | Path | Service | Purpose |
|---|---|---|---|
| GET | `/` | `dashboard` | Landing page (anon) / dashboard (logged in) |
| GET·POST | `/register` | `auth` | Registration form + submit |
| GET·POST | `/login` | `auth` | Login form + submit |
| GET | `/logout` | `auth` | End session |
| POST | `/shorten` | `dashboard` | Create a short link (form → redirect, JSON → 201) |
| GET | `/urls` | `dashboard` | List the current user's links (JSON) |
| DELETE | `/url/<id>` | `dashboard` | Delete a link (JSON, used by the dashboard AJAX) |
| POST | `/url/<id>/delete` | `dashboard` | Delete a link (no-JS form fallback) |
| GET | `/static/*` | `dashboard` | CSS/JS — the canonical copy; `auth`'s pages reference these via the Ingress, not locally |
| GET | `/<short_code>` | `redirect` | Redirect to the original URL + count the click |
| GET | `/healthz` | all 3 | Liveness/readiness probe (no DB), per service |

In production/minikube a single Ingress routes by path to the right service
(see Infrastructure → Kubernetes below); locally without an Ingress, each
service just listens on its own port (see Running locally).

---

## Tech stack

| Concern | Choice |
|---|---|
| Web framework | Flask (application factory + blueprints), 3 independent processes |
| ORM / DB | SQLAlchemy; SQLite (local) / PostgreSQL (prod, via psycopg 3) — one shared DB across all 3 services |
| Auth | Flask-Login (session cookies, shared `SECRET_KEY` across services), Werkzeug scrypt password hashing |
| CSRF | Flask-WTF (`CSRFProtect`) — tokens on all forms + AJAX header; `redirect` service doesn't need it (no forms) |
| Rate limiting | Flask-Limiter (in-memory local / Redis in prod), used by `auth` and `dashboard` only |
| WSGI server | gunicorn (production), one process per service |
| Frontend | Jinja2 templates, vanilla JS, hand-written CSS — served entirely by `dashboard` and `auth` |

---

## Running locally

Each service is a separate Flask app with its own `run.py`, but they all
import `shared/` from the repo root, so run them **from the repo root** with
`PYTHONPATH` pointing at both the repo root and that service's directory.
Since all 3 default to port 5000, give each a different `PORT` if running
them side by side:

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r services/auth/requirements.txt      # same deps across all 3 (see shared/extensions.py note)

# one terminal per service:
PYTHONPATH=.:services/auth      PORT=5001 python services/auth/run.py
PYTHONPATH=.:services/dashboard PORT=5000 python services/dashboard/run.py
PYTHONPATH=.:services/redirect  PORT=5002 python services/redirect/run.py
```

Open http://localhost:5000 for the dashboard/landing page, http://localhost:5001
for login/register. A short link created via the dashboard will show as
`http://localhost:5000/<code>` (it doesn't know it's running standalone
without an Ingress) — to actually follow it, swap the port to `5002`
(the redirect service) by hand, e.g. `http://localhost:5002/<code>`.

Each `run.py` is **dev-only**: it injects a development `SECRET_KEY`, and
(for `auth`/`dashboard`) creates the SQLite schema on startup. `redirect`
doesn't run schema creation itself — see Database schema below. The SQLite
file (`app.db`, at the repo root) is shared across all 3 processes since
`shared/config.py`'s default `DATABASE_URL` resolves to the same path
regardless of which service imports it.

### Configuration (environment variables)

| Variable | Default | Used by | Notes |
|---|---|---|---|
| `SECRET_KEY` | — | all 3 | **Required in production** (each service refuses to boot without it). `run.py` injects a dev value locally. Must be **identical** across `auth` and `dashboard` (and all their replicas) — it signs the session cookie that has to validate across both. |
| `DATABASE_URL` | `sqlite:///app.db` | all 3 | `postgres://` / `postgresql://` are normalized to the psycopg driver automatically. Must be identical across all 3 — same DB, same tables. |
| `RATELIMIT_STORAGE_URI` | `memory://` | `auth`, `dashboard` | Set to `redis://host:6379/0` so limits are shared across replicas. Harmless if set on `redirect` too (unused there). |
| `TRUST_PROXY` | unset | all 3 | Set to `1` behind a proxy/ingress to trust `X-Forwarded-*` (real client IP). |
| `FLASK_DEBUG` | `0` | all 3 | `1` enables the dev-server debugger (never in prod). |
| `PORT` | `5000` | all 3 | Dev-server port — set explicitly per service when running more than one locally (see above). |

### Production server

Production serves each service's **factory** directly (so the `SECRET_KEY`
guard is enforced), same gunicorn invocation shape for all 3, different image:

```bash
gunicorn -w 4 -b 0.0.0.0:5000 "app:create_app()"
```

### Database schema

Schema creation is a one-shot command, kept out of the request/worker path so
it doesn't race across workers or replicas. Run it via the **dashboard**
service specifically — it's the only one of the 3 that imports both the
`User` and `Url` models, so a single `db.create_all()` call there creates
both tables in one shot:

```bash
PYTHONPATH=.:services/dashboard flask --app services/dashboard/run init-db
```

> Note: `init-db` only creates missing tables. Ongoing schema changes need a
> migration tool (e.g. Flask-Migrate).

---

## Security

- **Passwords**: hashed with Werkzeug scrypt; minimum length 8 enforced at registration.
- **Sessions**: signed cookies (no server-side session store needed; scales horizontally, and is what lets 3 separate services share one login state).
- **CSRF**: every state-changing form carries a token; the AJAX delete sends `X-CSRFToken`. Not needed on `redirect` — no forms, GET-only.
- **Rate limiting**: `5/min` on login & register (`auth`), `20/min` on shorten (`dashboard`). None on `redirect` — deliberately, it's meant to absorb click traffic.
- **URL validation**: only `http`/`https` with a host accepted; `javascript:`/`data:`
  and malformed input rejected; length capped to the DB column (2048).
- **Reserved short codes**: a custom short code can't collide with a real route segment (`login`, `register`, `shorten`, `urls`, `url`, `healthz`, `static`) — enforced in `services/dashboard/app/utils/validators.py`, and doubles as documentation of exactly which path segments the Ingress reserves for `auth`/`dashboard`.
- **SECRET_KEY**: no insecure default — every service fails closed if it isn't set.
- **Container**: all 3 images run as a non-root numeric UID.

---

## Infrastructure

### Containers

Each service has its own `Dockerfile` under `services/<name>/`, all
structurally identical: `python:3.12-slim`, installs that service's own
`requirements.txt`, `COPY`s in `shared/` plus its own `app/`, runs as
non-root (UID 1000), serves gunicorn on port 5000. **Build context must be
the repo root** (not the service subdirectory), so the Dockerfile can reach
`shared/`:

```bash
docker build -f services/auth/Dockerfile      -t your-registry/urle-auth:latest      .
docker build -f services/dashboard/Dockerfile -t your-registry/urle-dashboard:latest .
docker build -f services/redirect/Dockerfile  -t your-registry/urle-redirect:latest  .
docker push your-registry/urle-auth:latest
docker push your-registry/urle-dashboard:latest
docker push your-registry/urle-redirect:latest
```

### Kubernetes (`k8s/`)

All 3 services are **stateless** — all state lives in Postgres (data) and
Redis (rate-limit counters) — so each scales horizontally by its own replica
count, independent of the other two.

```
                          ┌─────────────┐
       Internet ───────▶  │   Ingress   │  (urle.local — path-routed)
                          └──────┬──────┘
              ┌──────────────────┼──────────────────┐
   /login,/register,/logout   /,/shorten,/urls,      /  (catch-all: short codes)
              │               /url/*, /static/*                  │
              ▼                       ▼                           ▼
        ┌───────────┐          ┌─────────────┐            ┌──────────────┐
        │ urle-auth │          │urle-dashboard│           │ urle-redirect│
        │ (3 pods)  │          │  (3 pods)    │           │   (3 pods)   │
        └─────┬─────┘          └──────┬───────┘            └──────┬───────┘
              └───────────────┬───────┴────────────┬──────────────┘
                               ▼                    ▼
                        ┌────────────┐        ┌─────────┐
                        │  Postgres  │        │  Redis  │
                        │ StatefulSet│        │ (limits)│
                        │   + PVC    │        └─────────┘
                        └────────────┘
       (one-shot init-db Job, using the urle-dashboard image, creates the
        schema before any app rollout)
```

| Manifest | Resource | Purpose |
|---|---|---|
| `namespace.yaml` | Namespace | `urle` — everything else lives here, never `default` |
| `secret.example.yaml` | Secret | `SECRET_KEY`, `DATABASE_URL`, Postgres creds — shared by all 3 services (template — do not commit real values) |
| `configmap.yaml` | ConfigMap | `RATELIMIT_STORAGE_URI`, `TRUST_PROXY` — shared by all 3 |
| `postgres.yaml` | StatefulSet + headless Service + PVC | In-cluster database (swap for managed Postgres in prod) |
| `redis.yaml` | Deployment + Service | Shared rate-limit store |
| `init-db-job.yaml` | Job | Runs `flask init-db` once, via the `urle-dashboard` image |
| `deployment-auth.yaml`, `deployment-dashboard.yaml`, `deployment-redirect.yaml` | Deployment (3 replicas each) | `/healthz` probes, non-root, resource limits — one per service |
| `service-auth.yaml`, `service-dashboard.yaml`, `service-redirect.yaml` | Service (ClusterIP) | Stable in-cluster address (80 → 5000) — one per service |
| `ingress.yaml` | Ingress | Single external HTTP entry point, path-routed to the 3 Services above |

See **`k8s/README.md`** for the exact build → secrets → apply order and
operational notes.

### Local cluster (minikube)

This project has been validated end-to-end on a local minikube cluster
(Docker driver, ingress-nginx addon): all 3 images built and loaded, all
manifests applied, the init-db Job creating the schema, all 3 services
reaching `Ready`, and the full user flow (register → login → shorten →
redirect → click-increment → delete → logout) working through the real
Ingress against Postgres + Redis.

```bash
minikube start --driver=docker
minikube addons enable ingress
eval $(minikube docker-env)

docker build -f services/auth/Dockerfile      -t urle-auth:dev      .
docker build -f services/dashboard/Dockerfile -t urle-dashboard:dev .
docker build -f services/redirect/Dockerfile  -t urle-redirect:dev  .

# create a real Secret, then apply k8s/ in the documented order (see k8s/README.md)

echo "$(minikube ip) urle.local" | sudo tee -a /etc/hosts
# then open http://urle.local
```

**A note on resource sizing:** minikube's default docker-driver allocation
(often 2 CPU / ~3GB memory) is tight for 3 services × 3 replicas + Postgres +
Redis + ingress-nginx running simultaneously — under memory pressure, probe
timeouts (`pg_isready`, ingress-nginx `/healthz`, even API-server TLS
handshakes) can cascade and look like real failures when they're actually
just resource starvation. If you hit mysterious timeouts, check `docker
stats <minikube-container>` before debugging manifests; scaling replicas
down to 1 per service (`kubectl scale deployment ... --replicas=1 -n urle`)
is a quick, reversible way to confirm that's the cause.

### Helm charts (`charts/`)

- **One chart per service** (`urle-auth`, `urle-dashboard`, `urle-redirect`,
  `postgres`, `redis`), composed by an **umbrella chart** (`urle`) that's the
  only thing Argo CD ever deploys directly.
- Resources that reference more than one service — the shared ConfigMap and
  the single path-routed Ingress — live in the **umbrella chart's own
  `templates/`**, not in any one service's subchart.
- The init-db Job is a Helm `post-install,pre-upgrade` hook owned by
  `charts/urle-dashboard` (same reasoning as the raw manifests: it's the only
  chart whose image has both models). Under Argo CD it runs as a sync-wave-1
  hook, after the datastores (wave 0) and before the app Deployments (wave 2).
- No `Chart.lock` is committed (it's `.gitignore`d) — `helm dependency
  update charts/urle` regenerates it and the vendored subchart archives from
  `Chart.yaml` on demand, so there's nothing to keep in sync by hand.

```bash
helm dependency update charts/urle
helm template urle-dev charts/urle -f charts/urle/values-dev.yaml
```

### CI/CD (`.github/workflows/`)

One CI + one release workflow **per service** (`app-auth-*`,
`app-dashboard-*`, `app-redirect-*`), each path-filtered to its own
`services/<name>/**` plus `shared/**` (so a shared-code change re-validates
all 3, but a change to one service never triggers another's pipeline):

- **`app-<service>-ci.yaml`** — ruff check + format → smoke test (`create_app()` boots, `/healthz` returns 200) → docker build. Runs on every PR/push touching that service.
- **`app-<service>-release.yaml`** — on a `vX.Y.Z` tag (all 3 fire together, shipping matching versions): build + push that service's image to its ECR repo, then open a PR bumping that service's chart version and the umbrella chart's dependency entry.
- **`charts-ci.yaml`** — `helm lint` + `helm template` across all charts; verifies any changed chart bumped its `version`.
- **`infra-ci.yaml`** — `terraform fmt`/`validate` (always-on branch-protection check) + per-unit `terragrunt plan` per environment on PRs. Plan jobs are gated by the `DEV_UP`/`PROD_UP` repo variables — plan genuinely fails against a torn-down environment, so a hard-required plan check would block every infra PR while an environment is down for cost.
- **`infra-apply.yaml`** — `workflow_dispatch` only (pick dev/prod): fresh per-unit plan, then `terragrunt run --all apply`. A required reviewer on the `prod` GitHub Environment gates prod applies.
- **`infra-bootstrap.yaml`** — `workflow_dispatch`, cold-starts a torn-down environment with **no plan step** (an ordered apply resolves dependencies a plan can only 404 against), then flips `<ENV>_UP=true`.
- **`infra-destroy.yaml`** — `workflow_dispatch` with typed confirmation; ECR images, the ACM cert, and the public zone survive by design.

All AWS access is OIDC-federated — no long-lived keys. The provider and the
three roles (`urle-dev-cicd`/`urle-prod-cicd`, trust scoped per GitHub
Environment; `urle-release`, trust scoped to `v*` tags, ECR-push-only
permissions) are provisioned by `infra/live/global/github-oidc`. One-time
account setup lives in **`docs/BOOTSTRAP.md`**.

See **`MANIFEST.md`** for the full CI/CD contract, including the known
tradeoff of 3 independent release PRs touching the same umbrella
`Chart.yaml` on the same tag (they can conflict if merged out of order —
accepted as equivalent to any other automated-PR conflict).

### Terraform / Terragrunt (`infra/`)

- `infra/modules/` — plain, environment-agnostic Terraform: `vpc`, `eks`,
  `ecr` (generic, parameterized by repo name), `rds-postgres` (prod only),
  `argocd` (bootstrap install + app-of-apps), `ingress-nginx` (internal NLB),
  `cert-manager`, `external-secrets`, `karpenter`, `kube-prometheus-stack`,
  plus the AWS edge/automation set: `github-oidc` (CI identity), `vpn`
  (wg-easy + Caddy on EC2, SSM-only), `route53-private` (`urle-<env>.internal`
  admin zone), `route53-public-zone`, `acm`, `alb-controller`, and
  `external-dns` (prod public edge).
- `infra/live/global/` — account-wide units outside any environment teardown:
  `github-oidc`, the **3 ECR units** (`ecr-auth`, `ecr-dashboard`,
  `ecr-redirect` — account-wide because one SemVer release feeds every
  environment, and so teardowns never delete released images), and
  `route53-public-zone` (the single source of truth for the app domain).
- `infra/live/{dev,prod}/` — one Terragrunt unit per module instance. Dev is
  VPN-only (internal NLB); prod serves the public app via ALB + ACM +
  ExternalDNS while ArgoCD/Grafana stay VPN-gated.
- Remote state is S3 with native lockfile locking (`use_lockfile`), configured
  once at the root `infra/live/root.hcl` and inherited by every unit; the
  legacy DynamoDB lock table rides along until one full cycle confirms the
  migration (see `docs/BOOTSTRAP.md`).

### Argo CD (`argocd/`)

One `Application` per environment (`argocd/apps/dev.yaml`,
`argocd/apps/prod.yaml`), both pointing at `charts/urle` — this didn't need
any changes for the microservices split, since the umbrella chart's path is
stable regardless of what it composes internally. `argocd/projects/
urle-project.yaml` scopes both to `urle-*` namespaces with least-privilege
cluster-resource access (only `Namespace` creation cluster-wide).

---

## Project history / session reference

This codebase was hardened from a working-but-not-production app through
three passes — runtime correctness, security, and infrastructure — plus a
live Kubernetes validation that surfaced and fixed container/runtime issues.
It was later split from a single Flask app into the 3-service architecture
described above (`shared/` + `services/{auth,dashboard,redirect}/`), with a
matching follow-up pass across the Helm charts, CI/CD, and Terraform to
describe 3 images instead of 1._

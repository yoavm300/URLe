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
├── k8s/                            # raw Kubernetes manifests by kind — minikube-local reference (see Infrastructure)
├── helm/                           # Helm charts + git-ops/ Argo CD definitions (see Infrastructure)
├── terraform/                      # Terraform/Terragrunt: modules + terragrunt/{global,dev,prod} (see Infrastructure)
├── docs/BOOTSTRAP.md               # one-time AWS/GitHub account setup
├── scripts/bootstrap-state.sh      # creates the Terraform state bucket (step 1 of BOOTSTRAP.md)
└── .github/workflows/              # CI/CD per service + infra plan/apply/bootstrap/destroy
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
| `TRUST_PROXY` | unset | all 3 | Number of proxy hops to trust for `X-Forwarded-*` (`0`/unset = direct): `1` behind one ingress/ALB, `2` behind CloudFront → ALB (prod). Wrong count = rate limiting keys on the wrong hop's IP. |
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
- **Prod edge (see Infrastructure)**: AWS WAF ahead of everything — a
  2000 req/5min/IP rate block plus AWS managed rule groups, with the
  `GenericRFI_*` rules set to count-only because a URL shortener's core
  input (a URL in the POST body) is exactly what they'd false-positive on;
  HSTS and friends via CloudFront's managed security-headers policy; the
  ALB unreachable except from CloudFront.

---

## Infrastructure

### Deploying to AWS — the lifecycle at a glance

After a **one-time account bootstrap** (`docs/BOOTSTRAP.md`: state bucket →
`terraform/terragrunt/global` applied locally → GitHub variables/secret/Environments →
manual SSM SecureStrings → domain NS delegation), the entire lifecycle runs
from the GitHub Actions tab — this project is torn down between sessions for
cost, and that cycle is a first-class operation:

| I want to… | Do this |
|---|---|
| Stand up a torn-down environment | Dispatch **`infra-bootstrap`** (pick `dev`/`prod`) |
| Change live infrastructure | Open a PR (plan runs on it) → merge → dispatch **`infra-apply`** |
| Ship a new app version | Push a `vX.Y.Z` tag → images reach ECR, chart-bump PRs open → merge → Argo CD deploys |
| Tear an environment down | Dispatch **`infra-destroy`** (type the env name to confirm) |

What survives a teardown: ECR images, the ACM certificate, the Route53 public
zone, and everything in `terraform/terragrunt/global/` — so the next bootstrap comes
back with the previously released images and the same domain/cert.

**Access model:** prod's app is public at `urle.<domain>` — CloudFront at
the edge (TLS, `/static/*` caching, security headers) with **AWS WAF** in
front of it (rate-limit block + the AWS managed IP-reputation / Common /
Known-Bad-Inputs rule groups), backed by an ALB that only admits
CloudFront's origin-facing address ranges (managed prefix-list SG, so
neither WAF nor the edge can be bypassed). DDoS at L3/L4 is covered by
Shield Standard, automatic and free on CloudFront. Everything else — the
dev app (`app.urle-dev.internal`) and ArgoCD/Grafana in both envs
(`argocd.urle-<env>.internal`) — resolves only over the WireGuard VPN
(`vpn-<env>.<domain>`, wg-easy admin UI on 443).

### Network & port map — edge to container

The full hop-by-hop path of a request, from the internet to a gunicorn
worker. Prod's public path first:

| # | Hop | Listens on | Admits traffic from | Notes |
|---|---|---|---|---|
| 1 | **CloudFront + WAF** | 443 (80 redirects to HTTPS) | the internet | WAF rate-limit + AWS managed rule groups; Shield Standard L3/L4 |
| 2 | **ALB** (`urle-origin.<domain>`) | 443, `https-only` from CloudFront | CloudFront's managed prefix list only (SG) | origin cloaking — hitting the ALB directly bypasses nothing, it refuses non-CloudFront sources |
| 3 | **ALB → pod IPs** (`target-type: ip`) | pod port 5000 | ALB in-VPC (`10.20.0.0/16`) | no NodePort hop; path rules pick the service: `auth` gets exact `/login`/`/register`/`/logout`, `dashboard` gets `/`,`/shorten`,`/urls` + prefixes `/url`,`/static`, `redirect` is the `/` catch-all |
| 4 | **Container** (gunicorn) | 5000 | NetworkPolicy: default-deny + explicit allows (incl. `albSourceCidr`) | non-root UID 1000, `/healthz` probes |

Dev has no public path at all — same cluster shape, different front door:

| # | Hop | Listens on | Admits traffic from |
|---|---|---|---|
| 1 | **WireGuard VPN** (EC2, public subnet) | UDP 51820 (tunnel), TCP 443 (wg-easy admin UI behind Caddy) | the internet (auth: WireGuard keys / bcrypt-hashed UI password); **no port 22 — management is SSM-only** |
| 2 | **Private DNS** `urle-dev.internal` | — | resolves only inside the VPC, i.e. only over the VPN |
| 3 | **internal NLB → ingress-nginx** | 80/443, `scheme: internal` | VPC + VPN clients |
| 4 | **ClusterIP Services** | 80 → `targetPort` 5000 | in-cluster |

Shared plumbing, both environments:

- **Datastores** — Postgres on 5432 (dev: in-cluster StatefulSet behind a
  headless Service; prod: RDS, SG admits only the cluster, credentials
  composed into the `urle/prod/app` Secrets Manager secret and delivered by
  ExternalSecrets). Redis on 6379, in-cluster, rate-limit counters only.
- **Admin surfaces** — Argo CD and Grafana live at
  `argocd.urle-<env>.internal` / `grafana.urle-<env>.internal`: VPN-only in
  **both** environments, prod included.
- **Egress** — pods reach the internet through the NAT gateway; nothing
  inbound ever arrives that way.
- **DNS split** — one public zone (`url-e.online`, delegated to Route53)
  for CloudFront/ACM/VPN endpoints; one private zone per env
  (`urle-<env>.internal`) for everything VPN-gated.

**A deliberate tradeoff, recorded:** the EKS API endpoint is **public**
(`cluster_endpoint_public_access = true`). This is not an open door — every
request requires AWS SigV4 credentials matching an explicit cluster access
entry; anonymous traffic dies before reaching the Kubernetes API. It is
still a larger exposure than a private endpoint, and it's kept deliberately:
the CI/CD workflows run on GitHub-hosted runners, which must reach the API
to install Argo CD and the addon stack during bootstrap. A private endpoint
would require a self-hosted runner inside the VPC — real cost and upkeep
this project doesn't justify. The compensating controls are the standard
ones: IAM-gated access entries (only the admin principal and the CI roles),
plus everything *workload-facing* (app ingress, Argo CD, Grafana) staying
internal/VPN-only as described above.

### Containers

Each service has its own `Dockerfile` under `services/<name>/`, all
structurally identical: `python:3.12-slim`, installs that service's own
`requirements.txt`, `COPY`s in `shared/` plus its own `app/`, runs as
non-root (UID 1000), serves gunicorn on port 5000. **Build context must be
the repo root** (not the service subdirectory), so the Dockerfile can reach
`shared/`:

```bash
docker build -f services/auth/Dockerfile      -t your-registry/urle-auth:1.0.0      .
docker build -f services/dashboard/Dockerfile -t your-registry/urle-dashboard:1.0.0 .
docker build -f services/redirect/Dockerfile  -t your-registry/urle-redirect:1.0.0  .
```

Manual builds are for local experiments only — real images reach ECR
exclusively through the tag-triggered release workflows (SemVer tags,
`IMMUTABLE` repos, never `latest`; see CI/CD below).

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
| `namespaces/urle-namespace.yaml` | Namespace | `urle` — everything else lives here, never `default` |
| `secrets.example/urle-secret.yaml` | Secret | `SECRET_KEY`, `DATABASE_URL`, Postgres creds — shared by all 3 services (template — do not commit real values) |
| `configmaps/urle-configmap.yaml` | ConfigMap | `RATELIMIT_STORAGE_URI`, `TRUST_PROXY` — shared by all 3 |
| `statefulsets/postgres.yaml`, `services/postgres-service.yaml` | StatefulSet + headless Service + PVC | In-cluster database (swap for managed Postgres in prod) |
| `deployments/redis-deployment.yaml`, `services/redis-service.yaml` | Deployment + Service | Shared rate-limit store |
| `jobs/init-db-job.yaml` | Job | Runs `flask init-db` once, via the `urle-dashboard` image |
| `deployments/{auth,dashboard,redirect}-deployment.yaml` | Deployment (3 replicas each) | `/healthz` probes, non-root, resource limits — one per service |
| `services/{auth,dashboard,redirect}-service.yaml` | Service (ClusterIP) | Stable in-cluster address (80 → 5000) — one per service |
| `ingress/main-ingress.yaml` | Ingress | Single external HTTP entry point, path-routed to the 3 Services above |

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

### Helm charts (`helm/`)

- **One chart per service** (`helm/urle-chart/charts/urle-auth`,
  `helm/urle-chart/charts/urle-dashboard`, `helm/urle-chart/charts/urle-redirect`,
  `helm/urle-chart/charts/postgres`, `helm/urle-chart/charts/redis`), vendored
  directly under the **umbrella chart** (`helm/urle-chart`) that's the only
  thing Argo CD ever deploys directly.
- Resources that reference more than one service — the shared ConfigMap and
  the single path-routed Ingress — live in the **umbrella chart's own
  `templates/`**, not in any one service's subchart.
- The init-db Job is a Helm `post-install,pre-upgrade` hook owned by
  `helm/urle-chart/charts/urle-dashboard` (same reasoning as the raw manifests: it's the only
  chart whose image has both models). Under Argo CD it runs as a sync-wave-1
  hook, after the datastores (wave 0) and before the app Deployments (wave 2).
- `Chart.lock` **is committed** (Argo CD needs it to run `helm dependency
  build` reproducibly); only the vendored `helm/urle-chart/charts/*.tgz` archives
  are `.gitignore`d — `helm dependency update helm/urle-chart` rebuilds those
  from the `file://` paths on demand.

```bash
helm dependency update helm/urle-chart
helm template urle-dev helm/urle-chart -f helm/urle-chart/values-dev.yaml
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
permissions) are provisioned by `terraform/terragrunt/global/github-oidc`. One-time
account setup lives in **`docs/BOOTSTRAP.md`**.

See **`MANIFEST.md`** for the full CI/CD contract, including the known
tradeoff of 3 independent release PRs touching the same umbrella
`Chart.yaml` on the same tag (they can conflict if merged out of order —
accepted as equivalent to any other automated-PR conflict).

### Terraform / Terragrunt (`terraform/`)

- `terraform/modules/` — plain, environment-agnostic Terraform: `vpc`, `eks`,
  `ecr` (generic, parameterized by repo name), `rds-postgres` (prod only),
  `argocd` (bootstrap install + app-of-apps), `ingress-nginx` (internal NLB),
  `cert-manager`, `external-secrets`, `karpenter`, `kube-prometheus-stack`,
  plus the AWS edge/automation set: `github-oidc` (CI identity), `vpn`
  (wg-easy + Caddy on EC2, SSM-only), `route53-private` (`urle-<env>.internal`
  admin zone), `route53-public-zone`, `acm`, `alb-controller`,
  `external-dns`, and `cloudfront` (prod public edge: distribution + WAF web
  ACL + security-headers policy).
- `terraform/terragrunt/global/` — account-wide units outside any environment teardown:
  `github-oidc`, the **3 ECR units** (`ecr-auth`, `ecr-dashboard`,
  `ecr-redirect` — account-wide because one SemVer release feeds every
  environment, and so teardowns never delete released images), and
  `route53-public-zone` (the single source of truth for the app domain).
- `terraform/terragrunt/{dev,prod}/` — one Terragrunt unit per module instance. Dev is
  VPN-only (internal NLB); prod serves the public app via ALB + ACM +
  ExternalDNS while ArgoCD/Grafana stay VPN-gated.
- Remote state is S3 with native lockfile locking (`use_lockfile`), configured
  once at the root `terraform/terragrunt/root.hcl` and inherited by every unit.
  (The legacy DynamoDB lock table belonged to the previous AWS account and
  was dropped with the account move — S3-native locking only.)

### Argo CD (`helm/git-ops/`)

One `Application` per environment (`helm/git-ops/dev.yaml`,
`helm/git-ops/prod.yaml`), both pointing at `helm/urle-chart` — this didn't need
any changes for the microservices split, since the umbrella chart's path is
stable regardless of what it composes internally. `helm/git-ops/projects/
urle-project.yaml` scopes both to `urle-*` namespaces with least-privilege
cluster-resource access (only `Namespace` creation cluster-wide).

## Full repository tree

Every tracked file in the repo, directory by directory, with what it is and
how it connects to the rest of the project — the goal is to be able to point
at any file here and say what breaks if it's missing. Generated files
(`.venv/`, `.nx/cache/`, `.ruff_cache/`, `.terragrunt-cache/`) and this
README itself are omitted.

### Root

- `CLAUDE.md` — Guidance file Claude Code reads at session start: imports the
  bootcamp reference repo's standards (`.claude/standards.md` §6/§7,
  `.claude/bootcamp-CLAUDE.md`'s operating policies) scoped to this app repo,
  plus generic anti-overengineering rules and Nx-usage notes. Consumed only
  by the AI tool — no build/deploy step depends on it — but it's why Claude
  treats `MANIFEST.md` as the infra source of truth and never runs
  `terraform apply/destroy`, `kubectl delete`, `helm install/upgrade`, or
  force-pushes without being asked.
- `MANIFEST.md` — The authoritative infrastructure spec: what's deployed,
  target platform choices (AWS/EKS/ECR/Terraform+Terragrunt/Argo
  CD/Helm/GitHub Actions), the target repo layout, Helm chart composition
  rules, the CI/CD workflow table, versioning policy, environments table,
  AWS-automation goals, and a large hardening backlog (most of it now
  implemented — Karpenter, cert-manager, ingress-nginx, External Secrets,
  monitoring, HPA, PDB, NetworkPolicy, ServiceAccounts). Every file under
  `terraform/`, `helm/`, and `.github/workflows/` traces back to a
  requirement stated here.
- `README.md` — This file: app architecture, request flows, endpoints, tech
  stack, local-run instructions, security notes, and the Infrastructure
  section this tree appendix extends.
- `destroyinfra.sh` — Local convenience wrapper: `./destroyinfra.sh <dev|prod>`.
  Validates tooling + AWS identity, requires typing the environment name to
  confirm, then `cd`s into `terraform/terragrunt/<env>` and execs
  `terragrunt run --all destroy`. Same destroy path as `infra-destroy.yaml`
  but for manual/local use — critically, **without** that workflow's
  Karpenter node-drain step, so running this by hand can hit the same
  orphaned-node failure the workflow was patched for on 2026-07-19.
- `startinfra.sh` — Local counterpart: `./startinfra.sh [dev|prod]` (defaults
  `dev`). Validates tooling/identity, then execs `terragrunt run --all apply`
  (interactive — Terragrunt itself prompts before applying). Local equivalent
  of `infra-apply`/`infra-bootstrap.yaml`, but doesn't distinguish cold-start
  vs. live-environment apply the way the two separate workflows do.
- `nx.json` — Nx workspace config: pins the Nx version, declares
  `pyproject.toml` as a shared-global input (so any Ruff config change
  invalidates every cached lint result), enables caching, sets the Nx Cloud
  workspace ID. Read by every `./nx` invocation — most directly `app-ci.yaml`'s
  `nx affected -t lint smoke-test docker-build`.
- `nx` — POSIX wrapper: checks `node`/`npm` on PATH, execs
  `node .nx/nxw.js "$@"`. The actual command every CI job and local dev
  invocation runs.
- `nx.bat` — Windows CMD equivalent of `nx`, same delegation to `.nx/nxw.js`.
  Irrelevant to CI (Ubuntu runners use `./nx`).
- `pyproject.toml` — Ruff configuration: Python 3.12 target (matches the
  Dockerfile base image), 100-char lines, excludes `.venv`, rule set
  `E,F,W,I,B,UP`, pinned first-party import list (`shared`, `app`) for
  deterministic import ordering. Every `ruff check`/`ruff format --check` in
  CI and locally reads this; it's also `nx.json`'s `sharedGlobals` input, so
  editing it invalidates every service's cached lint result.
- `.dockerignore` — Build-context excludes for all 3 service Dockerfiles
  (`.venv`, `__pycache__`, local SQLite DBs, `.git`, `k8s/`, `*.md`, `.env`).
  Applies to every `docker build -f services/<svc>/Dockerfile .` (repo-root
  context).
- `.gitignore` — Excludes `k8s/secrets/` (filled secrets never committed —
  `secrets.example/` is the safe template), `helm/urle-chart/charts/*.tgz`
  (vendored subchart archives — `Chart.lock` **is** committed, archives
  rebuild on demand via `helm dependency update`), Terraform/Terragrunt
  state/cache artifacts, `.claude/settings.local.json`.
- `.nxignore` — Tells Nx's project-graph walker to skip `terraform/`,
  `helm/`, `k8s/`, `docs/`, `.venv/`, `.claude/` — directories Nx never
  reasons about for the Python service graph. Keeps `nx affected` fast.
- `.nx/nxw.js` — Committed Nx wrapper: ensures a local Nx install matching
  `nx.json`'s pinned version exists under `.nx/installation/`, installing it
  via `npm i` if missing/stale, then delegates to the real Nx CLI. What `nx`
  and `nx.bat` actually invoke — this is why the workspace needs no
  top-level `package.json`/`node_modules` checked in.

### `.claude/`

Imported best-practice reference material from the maintainer's separate
bootcamp curriculum repo — not project-specific content, kept here so Claude
Code has a local standards doc to defer to.

- `.claude/bootcamp-CLAUDE.md` — The bootcamp repo's own `CLAUDE.md`, copied
  verbatim. Documents that repo's curriculum-authoring conventions (not
  followed here) and the maintainer's global operating policies — no
  unsolicited docs, ask before major changes, answer solution-first, **never
  run destructive commands autonomously**. This repo's `CLAUDE.md` explicitly
  imports that last policy, which is the direct source of the "workflow
  dispatches and `kubectl create secret` need the user's own `!` command"
  behavior seen throughout this project's sessions.
- `.claude/context.md` — Bootcamp audience profile (junior DevOps engineers,
  12-week course). Curriculum-authoring context only; `CLAUDE.md` explicitly
  says this does **not** apply to this repo.
- `.claude/prompts/generate-concept.md` — Bootcamp-repo prompt template for
  generating a full curriculum module. Not used by anything in this repo.
- `.claude/prompts/review-module.md` — Bootcamp-repo prompt template for
  reviewing a curriculum module against standards. Not invoked here.
- `.claude/settings.json` — Claude Code settings: registers the
  `nx-claude-plugins` marketplace and enables the `nx` plugin, plus a sandbox
  network allowlist. Makes the Nx-specific skills available in Claude Code
  sessions on this repo.
- `.claude/standards.md` — The bootcamp curriculum repo's engineering
  standards. **§6 Code Standards** (Kubernetes/Terraform/Docker/CI-CD) and
  **§7 Security Standards** are explicitly load-bearing for this app repo —
  no `default` namespace, no `latest` tags, resource requests/limits
  everywhere, typed Terraform variables, no hardcoded values/inline
  credentials, pinned Docker base images, non-root, least privilege. Visible
  throughout `helm/` and `terraform/` in practice.

### `.github/workflows/`

All CI/CD automation — application build/test/release and the full
infrastructure lifecycle (plan, apply, cold-start bootstrap, teardown), each
authenticating via OIDC (no long-lived AWS keys). Deploys never happen from
here directly — Argo CD watches `main` and applies changes itself.

- `.github/workflows/README.md` — Directory-local doc: explains CI never
  touches the cluster, every workflow authenticates via OIDC (roles from
  `terraform/terragrunt/global/github-oidc`), and summarizes each of the 7
  workflows plus the `DEV_UP`/`PROD_UP` repo-variable handshake between them.
- `app-ci.yaml` — Triggers on PRs/pushes touching `services/**`, `shared/**`,
  `pyproject.toml`, `nx.json`, or itself. Uses `nx affected -t lint
  smoke-test docker-build`, scoped only to services actually touched by the
  diff (a `shared/**` change affects all 3, a single-service change affects
  only that one). Ends with `./nx fix-ci` — Self-Healing CI, proposes a fix
  on the PR if the affected step failed. Gates every PR touching app code.
- `app-release.yaml` — Triggers only on `vX.Y.Z` tag pushes. `push-image`
  (3-way matrix over auth/dashboard/redirect) builds and pushes each
  service's image to its own ECR repo, tagged with the SemVer version and a
  short git-SHA. `bump-chart` then bumps each service chart's `appVersion`/
  `version`, syncs the umbrella chart's dependency pin, patch-bumps the
  umbrella itself, runs `helm dependency update`, and opens one PR bundling
  all the bumps. Merging that PR is the actual deploy action, since Argo CD
  watches `main`.
- `charts-ci.yaml` — Triggers on `helm/**` changes. `lint-template`: `helm
  lint` on all 5 leaf charts, `helm dependency update` + `helm lint` on the
  umbrella, then `helm template` renders it against both
  `values-dev.yaml`/`values-prod.yaml` to catch per-environment template
  errors. `version-bump-check` (PRs only): for each of the 6 charts, if its
  directory changed, asserts `Chart.yaml`'s `version` field actually changed
  too — this is what enforces "every chart edit must bump `version`" so Argo
  CD/Helm dependency resolution actually notices the change.
- `infra-apply.yaml` — `workflow_dispatch` (env choice: dev/prod), for
  applying changes to an **already-live** environment. `plan` job loops
  every Terragrunt unit running `terragrunt plan` individually (not `run
  --all plan`, since batched plan substitutes mock outputs even for units
  with real state); `apply` (gated by the `prod` GitHub Environment's
  required reviewer) runs `terragrunt run --all --non-interactive -- apply
  -auto-approve`. Fails closed off `main`.
- `infra-bootstrap.yaml` — `workflow_dispatch` (env choice), for cold-starting
  a torn-down environment. Skips the plan step (a plan against a cold
  environment 404s on real AWS lookups) and goes straight to `terragrunt run
  --all --non-interactive -- apply -auto-approve`. On success, flips the
  `<ENV>_UP` GitHub repo variable to `true`, re-enabling `infra-ci.yaml`'s
  plan-on-PR gate for that environment. The workflow that brought `urle-dev`
  up for the book's Argo CD/Grafana screenshots on 2026-07-19.
- `infra-ci.yaml` — Triggers on PRs touching `terraform/**`. `fmt-validate`
  (always runs, no AWS access): `terraform fmt -check -recursive` +
  `validate` on every module. Three env-scoped plan jobs (`plan-dev`,
  `plan-prod`, `plan-global`), each gated by the matching `DEV_UP`/`PROD_UP`
  repo variable — this is why a dev/prod PR's plan silently skips while that
  environment is torn down, rather than failing loudly.
- `infra-destroy.yaml` — `workflow_dispatch` (env choice + typed-confirmation
  string matching the env name, or the job fails before doing anything).
  OIDC-authenticates, then runs the **Karpenter node-drain step added on
  2026-07-20**: `kubectl delete nodepools.karpenter.sh --all --wait` while
  the controller is still alive, plus a fallback `aws ec2
  terminate-instances` on any Karpenter-tagged, cluster-owned instance still
  standing — before `terragrunt run --all --non-interactive -- destroy
  -auto-approve`. Always flips `<ENV>_UP` to `false` afterward, even on
  partial failure. Global units and destroy-`exclude`d units (prod ACM,
  CloudFront) survive by design. Patched after this exact workflow failed on
  2026-07-19 with orphaned Karpenter EC2 instances blocking the EKS security
  group's deletion (`DependencyViolation`).

### `docs/`

One-time, human-run setup instructions outside the automated Terraform/CI
lifecycle — what a fresh AWS account needs before any workflow above can run.

- `docs/BOOTSTRAP.md` — Step-by-step one-time account setup, run manually
  with personal AWS credentials: (1) `scripts/bootstrap-state.sh` for the
  state bucket + Spot service-linked role; (2) apply
  `terraform/terragrunt/global` locally (creates the GitHub OIDC provider +
  3 CI IAM roles, the 3 ECR repos, the public Route53 zone) — can't run in
  CI because CI's own identity doesn't exist yet; (3) configure GitHub repo
  variables/secrets/Environments/branch protection; (4) manually-created SSM
  SecureString parameters Terraform only ever reads (VPN admin password
  hashes, RDS master password, Argo CD's GitOps read token, Flask
  `SECRET_KEY`, Redis password); (5) domain NS delegation to Route53; (6)
  fill placeholder values in `values-prod.yaml`/`values-dev.yaml`; (7)
  dispatch `infra-bootstrap`. This is the origin story of the entire AWS
  side of the project — the OIDC identity behind every workflow and the SSM
  parameters `rds-postgres` composes into the prod app secret both trace
  back here.

### `scripts/`

- `scripts/bootstrap-state.sh` — Idempotent, account-scoped, run once per AWS
  account. Creates (or confirms) an S3 bucket `urle-tfstate-<account-id>`
  with versioning + KMS encryption + a full public-access block, then
  creates the EC2 Spot service-linked role Karpenter needs to launch Spot
  instances. This bucket is the remote-state backend every Terragrunt unit
  writes to (`terraform/terragrunt/root.hcl`); nothing in `terraform/` can
  `apply` until this has run once.

### `shared/`

The one common package all three services import — never runs standalone.
Keeps the DB schema and config contract in one place instead of drifting per
service.

- `shared/README.md` — Directory doc: models live here, business logic never
  does.
- `shared/__init__.py` — Empty; makes `shared/` an importable package. Every
  `from shared.X import Y` across all three services depends on this.
- `shared/config.py` — Defines `Config`, the Flask config class all three
  `create_app()` factories load. Builds `SQLALCHEMY_DATABASE_URI` from
  `DATABASE_URL` (defaulting to local SQLite), rewriting any
  `postgres://`/`postgresql://` prefix to `postgresql+psycopg://` — this is
  what lets the same code run against SQLite locally, in-cluster Postgres in
  dev, and RDS in prod. Reads `SECRET_KEY` with no hardcoded fallback; each
  `create_app()` raises `RuntimeError` at boot if it's unset outside tests —
  the guard that stops the app ever silently signing sessions with a
  guessable key in production.
- `shared/extensions.py` — Instantiates the five Flask extension objects used
  everywhere: `db` (SQLAlchemy), `login_manager` (Flask-Login), `csrf`
  (Flask-WTF CSRFProtect), `limiter` (Flask-Limiter, keyed by remote
  address), `metrics` (prometheus-flask-exporter). Each service's
  `create_app()` calls `.init_app(app)` on the subset it needs (redirect
  skips `login_manager`/`csrf`/`limiter`, since it's public GET-only).
- `shared/models/__init__.py` — Imports both `Url` and `User` so importing
  either submodule registers both mapped classes. Exists because
  `User.urls` uses a lazy string reference (`db.relationship("Url", ...)`)
  resolved at first mapper configuration — a service that only imports
  `User` would otherwise hit `InvalidRequestError` on its first query. A
  real cross-service coupling point.
- `shared/models/url.py` — `Url` model (`urls` table): `id`, `original_url`
  (≤2048 chars), `short_code` (unique, indexed, ≤16 chars), `clicks`,
  `created_at`, `user_id` (FK to `users.id`). Written/read by dashboard,
  read-and-incremented by redirect; the `short_code` unique constraint is
  the real concurrency guard `services/dashboard/app/utils/shortener.py`
  relies on.
- `shared/models/user.py` — `User` model (`users` table, owned by auth):
  `id`, `username`, `email` (unique/indexed), `password_hash`, plus
  `set_password`/`check_password` (Werkzeug hashing), and the `urls`
  relationship (cascade delete-orphan). Also registers the
  `@login_manager.user_loader` callback that makes `current_user` work in
  auth and dashboard.
- `shared/project.json` — Nx project config (`library`, `scope:python`). No
  build/test targets of its own; its role in the Nx graph is as a dependency
  node — every service's `project.json` declares `implicitDependencies:
  ["shared"]`, so `nx affected` knows a `shared/**` change affects all three
  services.

### `services/`

The three independently deployable Flask microservices, split by route
ownership, sharing one database schema from `shared/` but never calling each
other's code directly.

- `services/README.md` — Table of the 3-way route split and why it exists
  (redirect takes nearly all traffic and must scale independently); the path
  from code change to production (app-ci → app-release → Argo CD).

**`services/auth/`** — owns the `users` table and all session
authentication; the only service where `login_manager`/`csrf`/`limiter`
gate every route.

- `services/auth/Dockerfile` — Multi-purpose single-stage build from
  `python:3.12-slim`. Build context must be the repo root (to `COPY
  shared/`). Installs `requirements.txt` first for layer-cache efficiency,
  then copies `shared/`, `app/`, `run.py`. Non-root user, numeric UID 1000
  (required for Kubernetes's `runAsNonRoot` check to actually verify
  non-root). `CMD` serves via `gunicorn -w 4` invoking `app:create_app()`
  directly — not `run.py`, since `run.py` injects a throwaway dev
  `SECRET_KEY` and skipping it forces production to supply a real one.
- `services/auth/app/__init__.py` — Defines `create_app()`. Loads
  `shared.config.Config`; wires `ProxyFix` behind `TRUST_PROXY` hop count;
  enforces the `SECRET_KEY` fail-closed guard; initializes `db`,
  `login_manager` (`login_view = "/login"` as an absolute path, not an
  endpoint name — needed because `@login_required` redirects can originate
  from the dashboard service, which has no `auth` blueprint registered),
  `csrf`, `limiter`, `metrics`. Registers `auth_bp` and `health_bp`. Also
  defines the `flask --app run init-db` CLI command, kept out of the request
  path deliberately so schema DDL runs once via a Job, not racing across
  replicas.
- `services/auth/app/routes/__init__.py` — Empty; makes `app/routes/`
  importable.
- `services/auth/app/routes/auth.py` — The entire authentication logic.
  `/register` (GET+POST, 5/min rate limit): validates presence, min-8-char
  password, username/email uniqueness, creates and commits a `User` with
  `set_password()` hashing. `/login` (GET+POST, 5/min): looks up the user,
  checks the password, calls Flask-Login's `login_user()`, redirects to
  `?next=` or `/` (served by the dashboard service — this cross-service
  redirect only works because both sit behind one Ingress/host). `/logout`
  (`@login_required`): `logout_user()` + redirect to login.
- `services/auth/app/routes/health.py` — `GET /healthz` → `{"status": "ok"}`.
  Used by Kubernetes liveness/readiness probes; if it ever returns non-200,
  Kubernetes stops routing traffic to / restarts the pod.
- `services/auth/app/templates/base.html` — Jinja2 layout: HTML shell,
  navbar, CSRF meta tag, flash-message rendering, `{% block content
  %}`/`{% block scripts %}` hooks. `login.html`/`register.html` both extend
  it.
- `services/auth/app/templates/login.html` — Login form (username, password,
  hidden CSRF token), POSTs to `auth.login`.
- `services/auth/app/templates/register.html` — Registration form (username,
  email, password, hidden CSRF token), POSTs to `auth.register`.
- `services/auth/project.json` — Nx targets: `lint` (Ruff over `shared/` +
  this service), `smoke-test` (imports `create_app`, hits `/healthz`,
  asserts 200 — what `app-ci` runs per service), `docker-build` (tags
  `urle-auth:ci`). `implicitDependencies: ["shared"]`.
- `services/auth/requirements.txt` — Pinned: Flask 3.1.3,
  Flask-SQLAlchemy 3.1.1, Flask-Login 0.6.3, Flask-WTF 1.3.0,
  Flask-Limiter 4.1.1, redis 8.0.1 (rate-limit storage backend),
  psycopg[binary] 3.3.4 (matches `shared/config.py`'s driver rewrite),
  gunicorn 23.0.0, prometheus-flask-exporter 0.23.1. Identical set across
  all three services by design.
- `services/auth/run.py` — Dev-only entrypoint. Sets a default `SECRET_KEY`
  (never reached in production, since the Dockerfile's `CMD` calls
  `create_app()` directly, bypassing this file). Calls `create_app()`, then
  under `__main__` creates the DB schema via `db.create_all()` (safe here —
  single dev process, unlike gunicorn's multiple workers) and runs Flask's
  dev server with debug off unless explicitly opted in.

**`services/dashboard/`** — the URL-management UI: owns link creation/
listing/deletion, the only service with templates/static assets, and the
image used to initialize the full DB schema in Kubernetes.

- `services/dashboard/Dockerfile` — Structurally identical to auth's
  (same base image, layer order, non-root UID 1000, gunicorn `CMD`), copying
  `services/dashboard/app`.
- `services/dashboard/app/__init__.py` — `create_app()` factory,
  near-identical to auth's. Registers `urls_bp`, `main_bp`, `health_bp`. Its
  `init-db` CLI command is *the* one used by `k8s/jobs/init-db-job.yaml` /
  `helm/urle-chart/charts/urle-dashboard/templates/init-db-job.yaml` to create the full schema,
  since this is the only service importing both `User` (indirectly, via
  Flask-Login) and `Url` — auth never imports `Url`, redirect never imports
  `User`.
- `services/dashboard/app/routes/__init__.py` — Empty; makes `app/routes/`
  importable.
- `services/dashboard/app/routes/health.py` — Identical `/healthz` pattern.
- `services/dashboard/app/routes/main.py` — `main_bp`, single `/` route: if
  `current_user.is_authenticated`, queries that user's `Url` rows (newest
  first) and renders `dashboard.html`; otherwise renders the marketing
  `index.html`. The landing page every visitor hits.
- `services/dashboard/app/routes/urls.py` — All URL-management logic
  (`urls_bp`, all four routes `@login_required`). `/shorten` (POST, 20/min):
  validates/normalizes the target URL via `normalize_url()`, optionally
  validates a custom code via `normalize_custom_code()`, checks collisions,
  commits (catching `IntegrityError` on race — the DB's unique constraint on
  `short_code` is the real guard). `/urls` (GET): JSON list of the user's
  URLs with click counts. `/url/<id>` (DELETE) and `/url/<id>/delete`
  (POST): delete a URL owned by the current user — DELETE is the AJAX path
  `app.js` uses, POST is the no-JS form fallback.
- `services/dashboard/app/utils/__init__.py` — Empty; makes `app/utils/`
  importable.
- `services/dashboard/app/utils/shortener.py` — `generate_short_code`:
  cryptographically strong random code (`secrets.choice`), retries until one
  isn't already taken — narrows the race window but doesn't eliminate it,
  which is why `urls.py` still wraps the insert in a try/except.
- `services/dashboard/app/utils/validators.py` — `MAX_URL_LENGTH = 2048`
  (kept in sync with the `original_url` column). `RESERVED_SHORT_CODES` — a
  set of every real route segment across all three services (`register`,
  `login`, `logout`, `shorten`, `urls`, `url`, `healthz`, `static`) — since
  the Ingress always routes those exact segments to auth/dashboard rather
  than redirect's catch-all, a user-chosen custom code matching one would
  silently be unreachable; this set is the single source of truth
  preventing that. `normalize_url()`/`normalize_custom_code()` do the actual
  validation.
- `services/dashboard/app/templates/base.html` — Same layout pattern as
  auth's, but here `url_for('static', ...)` resolves against real files,
  since this service owns `app/static/`.
- `services/dashboard/app/templates/dashboard.html` — Logged-in view: link
  count pill, shorten form (with optional custom-code field), table of the
  user's URLs (original URL, short link with copy button, click badge,
  delete button wired to AJAX). Loads `app.js`.
- `services/dashboard/app/templates/index.html` — Logged-out marketing/hero
  page with Register/Log in CTAs.
- `services/dashboard/app/static/css/style.css` — The entire app's
  stylesheet (all three services' templates reference it; only dashboard
  ships the file). Light/dark theme via CSS custom properties, styling for
  navbar, hero, flash messages, forms, buttons, the auth card, the dashboard
  header, the URL table, the copy button, toast feedback, mobile breakpoint.
- `services/dashboard/app/static/img/logo-mark.svg` — Square icon-only logo
  (favicon + compact navbar logo), referenced across all three services'
  `base.html` templates.
- `services/dashboard/app/static/img/logo.svg` — Full wordmark logo; present
  but not referenced by any template read in this pass — likely reserved
  for external use (README, project book).
- `services/dashboard/app/static/js/app.js` — Vanilla JS, progressive
  enhancement (server-rendered forms work without it). Copy-to-clipboard for
  short links (Clipboard API with a hidden-textarea fallback), AJAX delete
  (`DELETE /url/<id>` with the CSRF token from the meta tag, removes the row
  on success, reloads if the table becomes empty).
- `services/dashboard/project.json` — Same Nx shape as auth's: `lint`,
  `smoke-test`, `docker-build` (tags `urle-dashboard:ci`),
  `implicitDependencies: ["shared"]`.
- `services/dashboard/requirements.txt` — Identical pinned set to auth's.
- `services/dashboard/run.py` — Same dev-entrypoint pattern as auth's.

**`services/redirect/`** — the hot public path: a single GET route, no
auth/CSRF/rate-limiting machinery, kept deliberately minimal so it can scale
independently of the other two.

- `services/redirect/Dockerfile` — Same structural pattern as the other two
  Dockerfiles, copying `services/redirect/app`.
- `services/redirect/app/__init__.py` — `create_app()`, deliberately thinner
  than auth's/dashboard's: same `ProxyFix`/`SECRET_KEY` guard, but
  initializes only `db` and `metrics` — no `login_manager`, `csrf`, or
  `limiter`, intentionally, since the service is public, unauthenticated,
  GET-only.
- `services/redirect/app/routes/__init__.py` — Empty; makes `app/routes/`
  importable.
- `services/redirect/app/routes/health.py` — Identical `/healthz` pattern.
- `services/redirect/app/routes/redirect.py` — The entire business logic of
  this service: `GET /<short_code>`. Looks up the `Url`, `abort(404)` if not
  found, atomically increments `clicks` via a DB-level `UPDATE ... SET
  clicks = clicks + 1` (`synchronize_session=False`, to avoid lost updates
  under concurrent hits), commits, redirects to `original_url`. The
  single highest-traffic code path in the entire system.
- `services/redirect/project.json` — Same Nx shape as the other two: `lint`,
  `smoke-test`, `docker-build` (tags `urle-redirect:ci`),
  `implicitDependencies: ["shared"]`.
- `services/redirect/requirements.txt` — Identical pinned set (even though
  this service doesn't use Flask-Login/Flask-WTF/Flask-Limiter at runtime —
  kept in sync for simplicity).
- `services/redirect/run.py` — Same dev-entrypoint pattern, but does **not**
  call `db.create_all()` under `__main__` — this service only imports `Url`,
  whose `user_id` column FKs to `users`, so `create_all()` here would fail
  against real Postgres unless dashboard's `init-db` already created
  `users` first.

### `helm/`

Umbrella-chart pattern — 5 leaf charts hold the real workloads/datastores,
one umbrella (`urle-chart`) composes them via `file://` dependencies, and
Argo CD deploys only the umbrella.

- `helm/README.md` — Top-level map: postgres/redis conditional via
  `.enabled` (dev runs them in-cluster, prod uses RDS and disables them),
  Argo CD never touches leaf charts directly, `app-release.yaml` automates
  chart version bumps via PR, `.claude/standards.md` §6 applies repo-wide,
  checked by `charts-ci`.

**`helm/urle-chart/charts/urle-auth/`** — the auth microservice's chart (register/login/logout), a
3-replica Deployment with no persistent state.

- `Chart.yaml` — `urle-auth`, chart version `1.1.0`, `appVersion "1.0.0"`
  (the default image tag when `values.image.tag` is empty). Bumped
  automatically by `app-release.yaml`; the umbrella pins this exact version.
- `templates/_helpers.tpl` — `urle-auth.fullname`, `urle-auth.image`
  (repo:tag, falls back to `Chart.AppVersion`), `urle-auth.labels`. Every
  other template in this chart depends on these three helpers.
- `templates/deployment.yaml` — `argocd.argoproj.io/sync-wave: "2"` (rolls
  out after datastores wave 0 and the init-db Job wave 1). Non-root
  (uid 1000, `RuntimeDefault` seccomp); `envFrom` [Secret, ConfigMap];
  `/healthz` probes. If `existingSecret` is missing in-cluster, the pod
  fails with `CreateContainerConfigError` — exactly what happened during the
  2026-07-19 dev bootstrap before the secret was created manually.
- `templates/hpa.yaml` — Conditional `HorizontalPodAutoscaler` on CPU.
  Requires Metrics Server in-cluster or it reports `<unknown>` and never
  scales; off by default, left off even in prod until Metrics Server is
  confirmed.
- `templates/pdb.yaml` — Conditional `PodDisruptionBudget`. Off in
  base/dev, on in `values-prod.yaml`.
- `templates/service.yaml` — `ClusterIP` on port 80 → container 5000. The
  DNS name (`urle-auth`) other Ingress backends/services reference.
- `templates/serviceaccount.yaml` — Conditional dedicated ServiceAccount
  with `automountServiceAccountToken: false` (this service never calls the
  K8s API). Off by default, on in prod.
- `templates/servicemonitor.yaml` — Conditional Prometheus `ServiceMonitor`
  scraping `/metrics`. Requires kube-prometheus-stack CRDs; off in
  base/dev (this gap caused the dev Grafana dashboard to show no data until
  session-created ServiceMonitors were added by hand on 2026-07-19), on in
  prod with the `release: kube-prometheus-stack` label the operator selects
  on.
- `values.yaml` — Defaults: `replicaCount: 3`; `image.tag: ""` (SemVer only,
  never `latest`); `existingSecret: urlshortener-secrets` /
  `existingConfigMap: urlshortener-config` (both created out-of-band, never
  templated here); resources `100m/256Mi` request, `500m/512Mi` limit
  (memory sized for 4 gunicorn workers plus scrypt password hashing — a
  lower ceiling OOM-kills on register/login); the five off-by-default blocks
  (`autoscaling`, `pdb`, `topologySpread`, `serviceAccount.create`,
  `metrics.serviceMonitor`) each env's values file turns on selectively.

**`helm/urle-chart/charts/urle-dashboard/`** — the dashboard microservice's chart, identical
pattern to auth plus a one-shot database-schema-init Job.

- `Chart.yaml` — `urle-dashboard`, chart version `1.1.0`, `appVersion "1.0.0"`.
- `templates/_helpers.tpl` — Same three helpers scoped to `urle-dashboard`.
- `templates/deployment.yaml` — Structurally identical to auth's (sync-wave
  2, non-root, `envFrom`, `/healthz` probes). The service that imports both
  `User` and `Url` — why the init-db Job below uses this chart's image.
- `templates/hpa.yaml` / `pdb.yaml` / `service.yaml` / `serviceaccount.yaml`
  / `servicemonitor.yaml` — Same roles as auth's equivalents, scoped to
  `urle-dashboard`.
- `templates/init-db-job.yaml` — Helm hook Job (`post-install,pre-upgrade`,
  `hook-delete-policy: before-hook-creation`) running `flask --app run
  init-db` → `db.create_all()` — idempotent, re-runnable.
  `argocd.argoproj.io/hook: Sync` at `sync-wave: "1"`, strictly after
  datastores (wave 0) and before the app Deployments (wave 2). The **only**
  place the database schema gets created — if it never completes (e.g. the
  PVC never bound, as happened in the first dev bootstrap), every app pod
  that starts before it finishes crash-loops until the schema exists.
- `values.yaml` — Same shape as auth's, plus `initDb.backoffLimit: 5`.

**`helm/urle-chart/charts/urle-redirect/`** — the public hot-path microservice's chart, the
leanest of the three app charts and the one most likely to be autoscaled.

- `Chart.yaml` — `urle-redirect`, chart version `1.1.0`, `appVersion "1.0.0"`.
- `templates/_helpers.tpl` — Same three helpers scoped to `urle-redirect`.
- `templates/deployment.yaml` — Same shape as auth/dashboard's; `envFrom`
  only really needs `DATABASE_URL` (no session-signing need here).
- `templates/hpa.yaml` — Same conditional pattern; flagged in-comment as
  "the public hot path — the service most worth autoscaling."
- `templates/pdb.yaml` / `service.yaml` / `serviceaccount.yaml` /
  `servicemonitor.yaml` — Same roles as the other app charts.
- `values.yaml` — Same shape; lightest resources of the three (`100m/128Mi`
  request, `500m/256Mi` limit — no scrypt work here).

**`helm/urle-chart/charts/postgres/`** — in-cluster PostgreSQL chart, dev/local only — prod
replaces this entirely with RDS.

- `Chart.yaml` — `postgres`, chart version `1.1.1`, `appVersion "16.6"`;
  description explicitly says "dev/local; use RDS in production."
- `templates/_helpers.tpl` — `fullname`/`labels` helpers.
- `templates/service.yaml` — Headless (`clusterIP: None`) Service, required
  for StatefulSet DNS (`postgres-0.postgres`); plain `postgres` also
  resolves. This hostname is hardcoded into every app chart's `DATABASE_URL`.
- `templates/statefulset.yaml` — The only StatefulSet in the project.
  `sync-wave: "0"` (comes up first). Runs as uid/gid 999 (the official
  postgres image's user) with `fsGroup: 999`. `envFrom` pulls
  `POSTGRES_USER/PASSWORD/DB` from `existingSecret`; readiness via
  `pg_isready`. `volumeClaimTemplates` requests `persistence.size` (1Gi
  default) — **this is the exact PVC that hung `Pending` in the first dev
  bootstrap** because the EKS module installs no EBS CSI driver/StorageClass,
  and the volume that later orphaned on `infra-destroy` because the cluster
  was deleted before the namespace drained.
- `values.yaml` — Pinned `postgres:16.14` (no floating major tag);
  `existingSecret: urlshortener-secrets`; `readinessUser: urlshortener`
  (must match `POSTGRES_USER`); `persistence.size: 1Gi`; resources
  `100m/128Mi` / `500m/256Mi`.

**`helm/urle-chart/charts/redis/`** — shared, disposable rate-limit-counter store — no
persistence, since losing the counters is harmless.

- `Chart.yaml` — `redis`, chart version `1.1.1`, `appVersion "7.4.2"`.
- `templates/_helpers.tpl` — `fullname`/`labels` helpers.
- `templates/deployment.yaml` — Plain Deployment (not a StatefulSet — no
  PVC). `sync-wave: "0"`. Runs as uid 999/gid 1000. Conditional
  (`auth.enabled`) block adds `--requirepass $(REDIS_PASSWORD)` to the
  startup args and sets `REDISCLI_AUTH` so the readiness probe's
  `redis-cli ping` still authenticates. Off by default (dev/minikube), on
  in prod.
- `templates/service.yaml` — ClusterIP on port 6379; this hostname (`redis`)
  is hardcoded into the shared rate-limit URI.
- `values.yaml` — Pinned `redis:7.4.9-alpine`; resources `50m/64Mi` /
  `200m/128Mi` (lightest workload in the project); `auth` block (off by
  default) referencing `existingSecret`/`passwordKey: REDIS_PASSWORD`.

**`helm/urle-chart/`** — the umbrella chart — the only thing Argo CD ever
deploys, composing all 5 leaf charts plus namespace-level policy objects
(Ingress, NetworkPolicy, ResourceQuota, LimitRange, ConfigMap,
ExternalSecret, ClusterIssuer, Grafana dashboards) that belong to no single
service.

- `Chart.lock` — Resolved dependency digest for the 5 `file://` subchart
  deps, auto-generated by `helm dependency update`; regenerated whenever
  `app-release.yaml` bumps a subchart version.
- `Chart.yaml` — `urle`, version `1.3.1`, `appVersion "1.0.0"`, the same 5
  dependencies with `condition:` gates on postgres/redis so they can be
  switched off entirely in prod.
- `templates/clusterissuer.yaml` — Conditional cert-manager `ClusterIssuer`
  (ACME/Let's Encrypt, HTTP-01). Off in dev (no cert-manager CRDs on
  minikube) and off in prod (ALB/CloudFront terminates TLS with an ACM cert
  instead) — renders nothing in either shipped environment today; exists
  for a future TLS-via-cert-manager path.
- `templates/configmap.yaml` — Renders `urlshortener-config`, shared by name
  across auth and dashboard. Conditionally includes `RATELIMIT_STORAGE_URI`
  only `if not .Values.redis.auth.enabled` — since the app Deployments'
  `envFrom` lists `[secretRef, configMapRef]` in that order and later
  sources win, if this key were present while Redis auth is on, it would
  silently override the Secret's password-bearing URI with a plaintext one.
  Also renders `TRUST_PROXY` (differs between dev's `"1"` and prod's `"3"`).
- `templates/externalsecret.yaml` — Conditional (prod only) 3-object bundle:
  a ServiceAccount annotated with an IRSA role ARN, a `SecretStore`
  authenticating as that SA, and an `ExternalSecret` pulling one JSON secret
  (`urle/prod/app`) into the `urlshortener-secrets` K8s Secret every app
  chart reads. Off in dev — exactly the gap the 2026-07-19 session hit,
  since dev has no equivalent path and the Secret had to be created by hand.
- `templates/grafana-dashboards.yaml` — Conditional (prod only) ConfigMap
  labeled `grafana_dashboard: "1"` so the Grafana sidecar auto-loads it;
  one hardcoded dashboard ("URLe — Service Overview": request rate by
  service, p95 latency, 5xx error rate, redirect click-through), built on
  `flask_http_request_total`/`_duration_seconds_bucket` metrics.
- `templates/ingress.yaml` — Conditional single Ingress routing **all
  three** app services by path — why it lives in the umbrella and not any
  one service chart. Auth gets exact-match-only routes so it can never
  swallow redirect's catch-all; dashboard gets exact + prefix routes;
  redirect is a bare `/` prefix catch-all. TLS block conditionally adds a
  `cert-manager.io/cluster-issuer` annotation. The Helm-templated twin of
  `k8s/ingress/main-ingress.yaml`.
- `templates/limitrange.yaml` — Conditional per-container default
  request/limit so any pod that omits its own resources still lands inside
  the namespace ResourceQuota. Off in base; both env values files turn it
  on.
- `templates/networkpolicy.yaml` — Conditional (off in dev, on in prod)
  4-part bundle: default-deny-ingress; allow ingress controller (+ VPC CIDR
  in prod, + monitoring namespace) → app pods:5000; allow the 3 app services
  → Postgres:5432 (if `postgres.enabled`); allow auth+dashboard (not
  redirect) → Redis:6379 (if `redis.enabled`). Explicit warning: on EKS
  these are inert no-ops unless the VPC CNI's `enableNetworkPolicy` is also
  on (`terraform/modules/eks`).
- `templates/resourcequota.yaml` — Conditional namespace-wide CPU/memory
  ceiling. Off in base; each env's values file sets numbers computed as the
  worst case of every service at HPA maxReplicas plus in-cluster databases
  where enabled.
- `values.yaml` — The umbrella's base defaults: hardcodes
  `fullnameOverride: urle-auth/urle-dashboard/urle-redirect/postgres/redis`
  (so `DATABASE_URL`'s `postgres` host, the rate-limit URI's `redis` host,
  and the Ingress's hardcoded backend names all resolve regardless of Helm
  release name); `postgres.enabled: true`/`redis.enabled: true` (prod flips
  postgres off); `redis.auth.enabled: false` (prod flips on); the `ingress`
  block; the off-by-default switches each env values file layers on top of.
- `values-dev.yaml` — Dev overrides: 2 replicas per service (vs. base's 3);
  ECR image repos at the real account; `ingress.host:
  app.urle-dev.internal` (VPN-only, resolved via the private zone);
  `resourceQuota`/`limitRange` on. Everything not overridden here
  (networkPolicy, externalSecrets, grafana.dashboards, pdb, topologySpread,
  serviceAccount.create, metrics.serviceMonitor) stays at the base chart's
  off default — precisely the list of gaps the 2026-07-19 session found,
  since dev was never meant to have prod's full hardening.
- `values-prod.yaml` — Prod overrides: 3 replicas per service; real ECR
  repos; per-service hardening turned on for all three app charts (`pdb`,
  `topologySpread` zone-based, `serviceAccount.create`,
  `metrics.serviceMonitor` with the operator's selector label);
  `autoscaling` deliberately left off until Metrics Server is confirmed;
  `ingress.host: url-e.online` with TLS off (ACM terminates at
  CloudFront/ALB instead) and `config.trustProxy: "3"` (CloudFront → ALB →
  nginx → pod); `networkPolicy.enabled: true`; `postgres.enabled: false`
  (RDS instead); `redis.auth.enabled: true`; `externalSecrets.enabled: true`
  with the real IRSA role ARN; `grafana.dashboards.enabled: true`.

**`helm/git-ops/`** — the app-of-apps layer Argo CD's root Application
watches — everything from here down is Argo-owned, in contrast to Terraform
which only builds the platform and never deploys workloads.

- `README.md` — Documents the full sync chain: `terragrunt apply
  <env>/argocd` installs Argo CD **and** creates the `urle-root` Application
  (created by Terraform in `terraform/modules/argocd/main.tf`, since
  something outside Git has to bootstrap the first Application before Argo
  CD exists to watch anything). `urle-root` syncs this directory filtered to
  `{projects/*.yaml, <env>.yaml}`, which creates the `urle` AppProject + the
  environment's `Application`, which deploys `helm/urle-chart` with the
  matching `values-<env>.yaml`.
- `projects/urle-project.yaml` — The `urle` AppProject: `sourceRepos` locked
  to this one repo; `destinations` locked to `urle-*` namespaces;
  `clusterResourceWhitelist` restricted to `Namespace` only (an Application
  in this project cannot create any other cluster-scoped resource);
  `namespaceResourceWhitelist` wide open (inside its own `urle-*` namespace
  the umbrella chart legitimately needs many kinds).
- `dev.yaml` — The `urle-dev` Argo CD `Application`: sources
  `helm/urle-chart` from `main` with `values.yaml` + `values-dev.yaml`;
  deploys to namespace `urle-dev`; `syncPolicy.automated` sets `prune:
  true, selfHeal: true` (continuously converges to `main`, reverting any
  manual `kubectl edit`); `managedNamespaceMetadata` stamps
  `pod-security.kubernetes.io/enforce: restricted` — since every workload
  is already PSS-`restricted`-compliant, this makes any future regression
  get rejected at admission, not just caught in review.
- `prod.yaml` — The `urle-prod` Application: identical structure to
  `dev.yaml`, just `values-prod.yaml` and namespace `urle-prod`.

### `k8s/`

A hand-written, non-templated set of raw Kubernetes manifests kept as a
minikube-local reference/teaching path — deploys the same three-service app
as `helm/`, but real dev/prod environments never use it; they go through the
Helm umbrella chart deployed by Argo CD instead.

- `k8s/README.md` — Operating manual: building/pushing images (or building
  straight into minikube's Docker daemon for zero-push local testing); the
  two ways to create the shared Secret; the exact `kubectl apply` order
  (namespace → secret → configmap → postgres+service → redis+service → wait
  for Postgres ready → init-db Job → wait for completion → three app
  Deployments → their Services → Ingress); minikube-specific ingress-addon
  and `/etc/hosts` steps; notes on managed-Postgres swap, safe scaling
  (stateless, shared `SECRET_KEY` — no sticky sessions needed), and
  `RESERVED_SHORT_CODES` interaction.
- `k8s/namespaces/urle-namespace.yaml` — Defines the `urle` Namespace. Must
  be applied first — every other manifest sets `namespace: urle`.
- `k8s/secrets.example/urle-secret.yaml` — Example (not-for-real-use) Secret
  `urlshortener-secrets` holding `SECRET_KEY`, `DATABASE_URL`,
  `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` as placeholders.
  Copied to a gitignored `secrets/urle-secret.yaml` and filled in, or
  created via the `kubectl create secret` one-liner in `k8s/README.md`.
  Everything downstream — Postgres, all three app Deployments, the init-db
  Job — `envFrom.secretRef` this exact Secret name; `SECRET_KEY` must be
  byte-identical across `urle-auth` and `urle-dashboard` (signs the shared
  session cookie), and `DATABASE_URL`'s password must match
  `POSTGRES_PASSWORD`.
- `k8s/configmaps/urle-configmap.yaml` — `urlshortener-config`:
  `RATELIMIT_STORAGE_URI` (points Flask-Limiter at in-cluster
  `redis:6379/0` so limits are shared across replicas) and `TRUST_PROXY:
  "1"`. Consumed via `envFrom.configMapRef` by all three app Deployments.
- `k8s/statefulsets/postgres.yaml` — `StatefulSet` `postgres`, 1 replica,
  image `postgres:16`, `envFrom` the Secret, `volumeClaimTemplate` (1Gi,
  RWO) at `/var/lib/postgresql/data`, readiness via `pg_isready`. Requests
  `100m`/`128Mi`, limits `500m`/`256Mi`. Single source of truth for both
  `User` and `Url` rows.
- `k8s/deployments/auth-deployment.yaml` — `Deployment` `urle-auth`, 3
  replicas, image `urle-auth:dev` (`imagePullPolicy: IfNotPresent` — built
  straight into minikube's Docker daemon, no registry push needed),
  container port 5000, non-root. Memory limit `512Mi` specifically because
  scrypt password hashing is memory-hard (~64MB transient per call) —
  `256Mi` OOM-kills on register/login, a concrete debugged constraint
  captured as a comment. Owns `/login`, `/register`, `/logout`.
- `k8s/deployments/dashboard-deployment.yaml` — `Deployment` `urle-dashboard`,
  3 replicas, image `urle-dashboard:dev`, same pattern as auth. Owns `/`,
  `/shorten`, `/urls`, `/url/*`, `/static/*` — the only service serving
  static assets. Its image is reused by `k8s/jobs/init-db-job.yaml`.
- `k8s/deployments/redirect-deployment.yaml` — `Deployment` `urle-redirect`,
  3 replicas, image `urle-redirect:dev`, lighter resources (`128Mi`/`256Mi`
  — no password hashing). The hottest public path — separately scaled so it
  can absorb short-code traffic independent of auth/dashboard. Owns the
  catch-all `/` prefix route.
- `k8s/deployments/redis-deployment.yaml` — `Deployment` `redis`, 1 replica,
  image `redis:7-alpine`, no persistence (disposable rate-limit counters
  only), readiness via `redis-cli ping`. Backs
  `RATELIMIT_STORAGE_URI`; without it, Flask-Limiter falls back to
  per-process in-memory storage and limits silently stop being shared
  across replicas.
- `k8s/services/auth-service.yaml` — `ClusterIP` `urle-auth`, port 80 →
  5000, selects `app: urle-auth`. DNS name the Ingress backend for
  `/login`/`/register`/`/logout` points at.
- `k8s/services/dashboard-service.yaml` — `ClusterIP` `urle-dashboard`, port
  80 → 5000. Ingress backend for `/`, `/shorten`, `/urls`, `/url/*`,
  `/static/*`.
- `k8s/services/redirect-service.yaml` — `ClusterIP` `urle-redirect`, port
  80 → 5000. Ingress backend for the catch-all short-code route.
- `k8s/services/redis-service.yaml` — `ClusterIP` `redis`, port 6379.
  Provides the `redis:6379` hostname `RATELIMIT_STORAGE_URI` references.
- `k8s/services/postgres-service.yaml` — **Headless** (`clusterIP: None`)
  `postgres`, port 5432 — required specifically because it fronts a
  StatefulSet, giving stable per-pod DNS instead of a load-balanced VIP.
  Deletable if switching to managed Postgres.
- `k8s/jobs/init-db-job.yaml` — `Job` `urle-dashboard-init-db`,
  `backoffLimit: 5`, runs the `urle-dashboard:dev` image with `flask --app
  run init-db`. Exists because running `db.create_all()` per-replica (3x
  auth + 3x dashboard + 3x redirect racing against a fresh DB) causes a
  concurrent-DDL race; running it once as a Job avoids that. Idempotent —
  only creates missing tables. App pods may crash-loop briefly if they
  start before this Job finishes, self-healing once the tables exist.
- `k8s/ingress/main-ingress.yaml` — `Ingress` `urle`, `ingressClassName:
  nginx`, single host `urle.local` (placeholder — swapped for the real
  domain, or added to `/etc/hosts` for local testing). Routes: exact
  `/login`, `/register`, `/logout` → `urle-auth`; exact `/`, `/shorten`,
  `/urls` + prefix `/url`, `/static` → `urle-dashboard`; prefix `/`
  (catch-all) → `urle-redirect`. The single point where all three Services
  actually get exposed to traffic. Cross-references
  `RESERVED_SHORT_CODES` in `services/dashboard/app/utils/validators.py`.

### `terraform/modules/`

Reusable Terraform modules, each instantiated per-environment by
`terraform/terragrunt/{global,dev,prod}/` units below.

**`acm/`** — Requests and DNS-validates a public ACM TLS certificate for the
app's public hostname, so the ALB controller can auto-discover it without a
hardcoded cert ARN anywhere.
- `main.tf` — `aws_acm_certificate` (DNS validation, `create_before_destroy`)
  for `domain_name` + SANs, one `aws_route53_record` per validation option,
  `aws_acm_certificate_validation` blocking until propagation, optional SSM
  publish of the ARN. If missing/failed, CloudFront and the ALB have no
  valid HTTPS cert and prod TLS breaks entirely.
- `outputs.tf` — `certificate_arn` — consumed by the `cloudfront` module.
- `variables.tf` — `domain_name`, `subject_alternative_names` (covers the
  CloudFront origin hostname too — one ALB serves both), `zone_id`
  (validation records land here), `ssm_parameter_prefix`, `tags`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`alb-controller/`** — Installs the AWS Load Balancer Controller (via
IRSA) so Ingress objects of class `alb` provision real ALBs, and optionally
builds a CloudFront-only security group cloaking the ALB's origin from
direct internet access.
- `main.tf` — IRSA role trusted by `kube-system:aws-load-balancer-controller`;
  installs the chart with `enableServiceMutatorWebhook = false` (the webhook
  races Service creation during a cold multi-resource bootstrap). Optionally
  creates a security group admitting only CloudFront's managed origin-facing
  prefix list. Terraform installs only the controller — the ALB itself is
  created later by the controller reacting to the edge Ingress the prod
  `ingress-nginx` unit deploys.
- `data.tf` — Looks up AWS's managed CloudFront origin-facing prefix list by
  name (`com.amazonaws.global.cloudfront.origin-facing`), feeding the
  optional origin-cloaking security group above.
- `outputs.tf` — `iam_role_arn`, `cloudfront_only_sg_id` (empty string if
  cloaking disabled — a misconfigured empty string here silently disables
  origin cloaking with no error).
- `providers.tf` — `helm` provider authenticated against EKS via `aws eks
  get-token`, using `cluster_endpoint`/`cluster_ca_data` from the `eks`
  module.
- `variables.tf` — `cluster_name`, `cluster_endpoint`, `cluster_ca_data`,
  `aws_region`, `vpc_id`, `oidc_provider_arn` (from eks), `chart_version`
  (`3.4.2`), `cloudfront_only_sg_name`.
- `versions.tf` — Pins `aws ~> 5.80`, `helm ~> 2.16`.

**`argocd/`** — Installs Argo CD via Helm and bootstraps the app-of-apps
root Application that then owns everything under `helm/git-ops/` — after
this applies, further Kubernetes state changes flow through Argo CD
reconciling from Git, not further `terraform apply`s.
- `main.tf` — Installs `argo-cd` with conditional value blocks: an Ingress +
  `server.insecure = true` if `ingress_host` is set (without this the pod
  redirects to its own self-signed HTTPS in a loop, since TLS already
  terminates at ingress-nginx); a `repositories` config block if a PAT path
  is given. Then installs `urle-root` via `argocd-apps`, pointing at
  `helm/git-ops` with a `directory.include` glob of
  `{projects/*.yaml,<environment>.yaml}` and automated `prune`+`selfHeal`
  sync — this is the literal seam between Terraform and GitOps.
- `data.tf` — Reads an optional SSM SecureString (a fine-grained GitHub PAT
  for the private GitOps repo), consumed by `main.tf`'s conditional
  `repositories` block.
- `outputs.tf` — `namespace`, `root_application`.
- `providers.tf` — Same per-module `helm` provider pattern.
- `variables.tf` — `environment` (selects which `helm/git-ops/<env>.yaml`
  the root app watches — one module serves both dev and prod),
  `chart_version` (`10.1.3`), `apps_chart_version` (`2.0.5`),
  `gitops_repo_url`, `gitops_revision` (`main`), `gitops_token_ssm_path`,
  `ingress_host` (empty = no ingress, port-forward only — this is exactly
  the `argocd.urle-<env>.internal` hostname used in the dev session).
- `versions.tf` — Pins `helm ~> 2.16`.

**`cert-manager/`** — Installs the cert-manager controller + CRDs;
deliberately does **not** create the ClusterIssuer itself.
- `main.tf` — One `helm_release` for `cert-manager` with `crds.enabled=true`
  into a dedicated namespace. The `ClusterIssuer` is managed separately via
  `helm/urle-chart/templates/clusterissuer.yaml` so the ACME email/host stay
  env-valued and GitOps-managed.
- `outputs.tf` — `namespace`.
- `providers.tf` — Same per-module helm-provider-against-eks pattern.
- `variables.tf` — Cluster connection vars + `chart_version` (`v1.21.0`).
- `versions.tf` — Pins `helm ~> 2.16`.

**`cloudfront/`** — Builds the prod edge: a CloudFront distribution in
front of the ALB, with an anti-bypass secret header, a security-headers
policy, and (via `waf.tf`) an attached WAF. A pass-through edge for a
server-rendered Flask app, not a static-site setup.
- `main.tf` — Generates `random_password.origin_verify` sent as a custom
  header `X-Origin-Verify` on every origin request — "origin cloaking, half
  2" (half 1 is the CloudFront-only SG in `alb-controller`): the
  prefix-list SG alone admits every CloudFront customer's origin-facing
  ranges, so this secret header is what actually distinguishes this
  distribution's traffic. Default behavior forwards everything uncached; an
  `/static/*` behavior uses `caching_optimized`. `origin.domain_name` does
  NOT need to resolve at apply time — CloudFront resolves origins
  per-request, and ExternalDNS populates it once the app's Ingress exists.
  Creates A + AAAA alias Route53 records.
- `data.tf` — Looks up four AWS-managed policies by name:
  `Managed-CachingDisabled`, `Managed-CachingOptimized`,
  `Managed-AllViewer` (forwards the Host header — load-bearing, since the
  app builds short links from `request.host_url`), `Managed-
  SecurityHeadersPolicy` — consumed by the distribution's cache/origin
  behaviors in `main.tf`.
- `outputs.tf` — `distribution_id`, `distribution_domain_name`,
  `origin_verify_value` (sensitive) — the secret header value the ALB edge
  rule must require.
- `variables.tf` — `domain_name`, `origin_hostname`, `certificate_arn`
  (from `acm`), `zone_id`, `price_class` (default `PriceClass_100`),
  `ssm_parameter_prefix`, `tags`, `waf_enabled` (default true — a fixed
  ~$8/month cost that accrues even between sessions since this unit is
  destroy-excluded), `waf_rate_limit` (default 2000 req/5min per IP — a
  coarse pre-filter; Flask-Limiter still enforces per-route limits
  application-side).
- `versions.tf` — Pins `aws ~> 5.80`, `random ~> 3.6`.
- `waf.tf` — `aws_wafv2_web_acl` (count-gated), scoped `CLOUDFRONT`. Four
  rules in priority order: rate-limit-per-ip; AWS-managed IP reputation
  list; AWS-managed common rule set, with `GenericRFI_BODY`/
  `GenericRFI_QUERYARGUMENTS` switched to count-only (a URL shortener's core
  input is a URL in the body/query args — exactly what the RFI rules would
  otherwise flag, breaking every `POST /shorten`); AWS-managed known-bad-
  inputs set, fully enforced.

**`ecr/`** — Creates one immutable, scan-on-push ECR repository with a
lifecycle policy — instantiated three times (once per service image) via
the global Terragrunt tier.
- `main.tf` — `aws_ecr_repository` with `image_tag_mutability = "IMMUTABLE"`
  (enforces SemVer discipline — a published X.Y.Z tag can never be
  overwritten) and `scan_on_push = true`. Lifecycle policy expiring
  anything beyond the newest `keep_last_images`.
- `outputs.tf` — `repository_url` (used in `docker push` and Helm
  `image.repository` values — the literal value in
  `helm/urle-chart/values-dev.yaml`), `repository_arn` (scopes CI IAM
  policies via `github-oidc`'s `ecr_repository_prefix`).
- `variables.tf` — `name`, `keep_last_images` (default 20), `tags`,
  `ssm_parameter_prefix`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`eks/`** — Wraps the community `terraform-aws-modules/eks/aws` module to
stand up the EKS control plane, one managed node group, and three baseline
addons — the foundational unit nearly every other Kubernetes-targeting
module depends on for cluster connection info.
- `main.tf` — `enable_cluster_creator_admin_permissions = false` —
  deliberate: every admin principal is an explicit `access_entries` grant,
  because IAM permissions alone only cover the AWS control-plane API while
  the helm/kubectl providers used throughout this repo authenticate against
  the cluster's Kubernetes API, which access entries specifically grant.
  Two conditional access entries (`personal` via `admin_principal_arn`,
  `cicd` via `cicd_principal_arn`), both `AmazonEKSClusterAdminPolicy`.
  Three `cluster_addons`: `metrics-server` (HPA's metrics source),
  `vpc-cni` with `enableNetworkPolicy=true` explicitly set (without this the
  CNI does not enforce NetworkPolicy objects at all — silently accepted but
  ignored, meaning the umbrella chart's default-deny policy would be a
  no-op), `eks-pod-identity-agent` (required because Karpenter's controller
  role trusts `pods.eks.amazonaws.com` via Pod Identity — without this
  addon, `AssumeRole` fails and the Karpenter controller crash-loops). One
  managed node group: `ami_type = "AL2023_x86_64_STANDARD"` explicitly set
  (AL2 AMIs don't exist for k8s ≥1.33).
- `data.tf` — `aws_partition` lookup, avoiding a hardcoded partition in the
  access-policy ARN below.
- `locals.tf` — `eks_admin_policy_arn` — the `AmazonEKSClusterAdminPolicy`
  ARN built from the partition lookup, referenced by both access entries.
- `outputs.tf` — `cluster_name`, `cluster_endpoint`,
  `cluster_certificate_authority_data`, `node_security_group_id` (source
  for RDS ingress), `oidc_provider_arn` (the IRSA federation root every
  other module's IRSA block consumes). The most fanned-out module in the
  repo — essentially every Helm-installing unit takes cluster connection
  info from here.
- `variables.tf` — `cluster_name`, `cluster_version` (default `1.36`),
  `vpc_id`, `subnet_ids`, `node_instance_types` (default `["t3.medium"]`),
  `node_min_size`/`max_size`/`desired_size` (1/3/2), `admin_principal_arn`
  (passed via `ADMIN_PRINCIPAL_ARN` env var — without it, kubectl/helm
  against the cluster fails with a credentials error),
  `cicd_principal_arn`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`external-dns/`** — Installs ExternalDNS via Helm+IRSA so it watches
Ingress objects and writes matching Route53 records automatically — what
makes the ALB's DNS name appear without a second `terraform apply` after
the app's Ingress is created by Argo CD.
- `main.tf` — IRSA role scoped to `zone_arn` only. ExternalDNS reads
  `spec.rules[].host` directly for Ingress resources (the
  hostname-annotation mechanism is Service-only). Closes the ALB
  sequencing gap: the ALB controller creates the real ALB reactively from
  the chart's Ingress once Argo CD syncs it, ExternalDNS notices that same
  Ingress and points the public hostname at it, no manual second apply
  needed. `policy = "upsert-only"` (never delete-on-reconcile, since the
  zone also holds records it doesn't own — VPN hostname, ACM validation
  records); TXT-based ownership tracking.
- `providers.tf` — Same per-module helm-provider-against-eks pattern.
- `variables.tf` — Cluster connection vars, `oidc_provider_arn`,
  `zone_arn`, `domain_filter`, `txt_owner_id`, `chart_version` (`1.21.1`),
  `ingress_class_filter` (prod sets this to `"alb"` specifically so the
  nginx-class app Ingress — whose status carries the internal NLB address —
  never competes for the public hostnames the alb-class edge Ingress owns).
- `versions.tf` — Pins `aws ~> 5.80`, `helm ~> 2.16`.

**`external-secrets/`** — Installs the External Secrets Operator + a
narrowly-scoped IRSA role so Kubernetes can pull `urlshortener-secrets`
from AWS Secrets Manager instead of secrets living in Git or CI.
- `main.tf` — Helm-installs `external-secrets` with `installCRDs=true`.
  IAM policy granting only `secretsmanager:GetSecretValue`/
  `DescribeSecret`, resource-scoped to `<secrets_path_prefix>/*` (e.g.
  `urle/prod/*` — cannot read any other environment's secrets). The IRSA
  role's trust is scoped to a specific in-namespace ServiceAccount subject,
  not the operator's own namespace — trust boundary and IAM permission
  boundary are two independent, both-must-hold checks.
- `data.tf` — `aws_caller_identity` + `aws_partition` lookups, used to build
  the account/partition-scoped Secrets Manager ARN in the IAM policy above.
- `outputs.tf` — `namespace`, `role_arn` (set as `externalSecrets.roleArn`
  in `helm/urle-chart/values-prod.yaml` — a manual, not automatic,
  hand-off).
- `providers.tf` — Same per-module helm-provider-against-eks pattern.
- `variables.tf` — Cluster connection vars, `oidc_provider_arn`,
  `app_namespace` (default `urle-prod`), `service_account_name` (default
  `urle-external-secrets`), `secrets_path_prefix` (default `urle/prod`),
  `chart_version` (`2.7.0`), `ssm_parameter_prefix`.
- `versions.tf` — Pins `helm ~> 2.16`, `aws ~> 5.0`.

**`github-oidc/`** — Sets up passwordless GitHub Actions CI: one OIDC
identity provider + three narrowly-trusted IAM roles (dev-cicd, prod-cicd,
release), so no long-lived AWS access keys exist anywhere in the repo or
CI secrets.
- `main.tf` — `aws_iam_openid_connect_provider` for
  `token.actions.githubusercontent.com` (AWS validates tokens against
  trusted root CAs, ignoring the required-but-cosmetic `thumbprint_list`;
  one provider per URL per account — a pre-existing one must be imported,
  not duplicated). For each of `["dev", "prod"]`: an IAM role
  (`<prefix>-<env>-cicd`) trusted via the `ci_trust` policy document
  (`data.tf`), attached to the `ci_permissions` document. Separately, a
  `release` role trusted via `release_trust`, attached to
  `release_permissions` — permissioned narrowly to ECR push actions
  resource-scoped to `ecr_repository_prefix*`.
- `data.tf` — Four `aws_iam_policy_document`s: `ci_trust`/`release_trust`
  (federated OIDC trust, gated by `aud=sts.amazonaws.com` AND, respectively,
  `sub=repo:<repo>:environment:<env>` — trust scoped per **GitHub
  Environment**, not per branch — or `sub` matching
  `repo:<repo>:ref:refs/tags/v*`, so only SemVer tag pushes can assume the
  release role), `ci_permissions`/`release_permissions` (the actions each
  role is actually granted). Plus `aws_caller_identity`/`aws_region`/
  `aws_partition` lookups used to scope the release role's ECR resource ARN.
- `locals.tf` — `ci_service_actions` — broad but service-scoped, not
  `AdministratorAccess`; granted via inline policies (not managed
  attachments) since attached-policy count is capped at 10 and this list
  only grows; specifically includes `kms`/`logs`/`autoscaling` permissions
  required just to *describe* an EKS cluster. Also `environments`
  (`["dev", "prod"]`) and the OIDC provider URL string, both reused across
  `data.tf` and `main.tf`.
- `outputs.tf` — `oidc_provider_arn`, `dev_ci_role_arn`,
  `prod_ci_role_arn`, `release_role_arn` — exactly what the GitHub Actions
  workflows reference via `role-to-assume` (as repo variables
  `AWS_DEV_CI_ROLE_ARN`/`AWS_PROD_CI_ROLE_ARN`), the entire mechanism CI
  authenticates to AWS with zero stored credentials.
- `variables.tf` — `github_repository` (e.g. `yoavm300/URLe` — the exact
  `sub` claim match string), `role_name_prefix` (default `urle`),
  `ecr_repository_prefix` (default `urle-`), `lock_table_arn` (empty =
  skip — a stopgap for a state-locking mechanism being phased out), `tags`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`ingress-nginx/`** — Installs the ingress-nginx controller (fronted by an
AWS NLB, internal or internet-facing per env) and, in prod, an ALB-class
edge Ingress that puts an internet-facing ALB in front of the controller
with CloudFront origin-cloaking enforcement.
- `main.tf` — Installs the controller via `helm_release` with an NLB
  (internal for dev/VPN-only, internet-facing otherwise); when
  `edge.enabled` (prod), also declares a `kubernetes_ingress_v1` (`alb`
  class) that the AWS LB Controller turns into a public ALB whose only
  backend is the nginx controller pods, gated by the `X-Origin-Verify`
  header check and the CloudFront-only security group.
- `data.tf` — Reads back the NLB's assigned hostname from the controller's
  Kubernetes Service once it exists (`depends_on` the helm release) — feeds
  the `lb_hostname` output below.
- `outputs.tf` — `namespace`, `lb_hostname` (the controller's NLB DNS name
  — consumed directly by `route53-private` to point `argocd.*`/`grafana.*`
  CNAMEs at the internal NLB).
- `providers.tf` — Same per-module helm-provider-against-eks pattern.
- `variables.tf` — Cluster connection vars, `chart_version` (pinned
  `4.15.1`), `internal` (default false), `edge` object
  (enabled/hosts/group_name/security_group_id), separate sensitive
  `edge_origin_verify_value` (sourced from the `cloudfront` module's output
  in prod, closing the loop between CloudFront and the ALB's header check).
- `versions.tf` — Pins `helm ~> 2.16`, `kubernetes ~> 2.33`.

**`karpenter/`** — Installs the Karpenter node autoscaler (controller + a
default NodePool/EC2NodeClass) so HPA-requested pods can get new EC2
capacity instead of sitting Pending once the fixed node group fills.
- `main.tf` — Wraps `terraform-aws-modules/eks/aws//modules/karpenter`
  (creates IAM roles/instance profile/interruption SQS queue, bound via
  **Pod Identity**, not IRSA, since the submodule's controller role trusts
  `pods.eks.amazonaws.com` in v20.24+); installs the Karpenter chart; tags
  the node security group with `karpenter.sh/discovery`; declares a default
  `EC2NodeClass` (AL2023, on-demand) and `NodePool` (100 vCPU cap,
  consolidates after 1 minute underutilized) as raw `kubectl_manifest`
  resources rather than `kubernetes_manifest` (so the CRD doesn't need to
  exist at plan time). Explicitly flagged "⚠️ UNVERIFIED + version-sensitive"
  — the submodule's API shape and the NodePool/EC2NodeClass v1 schema shift
  across versions; `chart_version` and the submodule version must be a
  matched, plan-tested pair. This is the module that makes the cluster
  elastic — and the module whose destroy ordering caused the 2026-07-19
  incident: Terraform tears down the NodePool CR without waiting for node
  drain before killing the controller that would terminate them, orphaning
  EC2 instances (fixed 2026-07-20 by the drain step added to
  `infra-destroy.yaml`).
- `outputs.tf` — `node_iam_role_name` (feeds `EC2NodeClass.spec.role`),
  `controller_role_arn`, `interruption_queue_name`.
- `providers.tf` — `helm` and `kubectl` (the `gavinbunney/kubectl`
  provider, chosen because it doesn't require the CRD to exist at plan
  time) providers.
- `variables.tf` — Cluster connection vars, `node_security_group_id` (from
  `eks`, used for the discovery tag), `chart_version` (pinned `1.14.0`),
  `nodepool_cpu_limit` (default `"100"`), `tags`.
- `versions.tf` — Pins `helm ~> 2.16`, `aws ~> 5.0`, `kubectl ~> 1.14`.

**`kube-prometheus-stack/`** — Installs Prometheus + Operator CRDs
(including ServiceMonitor) + Alertmanager + node-exporter + kube-state-
metrics + Grafana (with dashboard auto-loading via labeled ConfigMaps) for
cluster and app observability.
- `main.tf` — Installs the chart into `monitoring` with
  `serviceMonitorSelectorNilUsesHelmValues=false` set explicitly so
  Prometheus discovers ServiceMonitors in *any* namespace. Deliberately a
  self-contained Terraform module, not routed through the Argo CD
  app-of-apps. The dashboard sidecar auto-loading ConfigMaps labeled
  `grafana_dashboard: "1"` is exactly the mechanism used in-session on
  2026-07-19 to add an ad-hoc "URLe Services" dashboard by hand.
- `outputs.tf` — `namespace` (`"monitoring"`).
- `providers.tf` — Same per-module helm-provider-against-eks pattern.
- `variables.tf` — Cluster connection vars, `chart_version` (pinned
  `87.16.1`) — no separate ingress toggle exists here, exactly the gap that
  had to be patched by hand (no Grafana Ingress ships from this module).
- `versions.tf` — Pins `helm ~> 2.16`.

**`rds-postgres/`** — Provisions the prod managed Postgres instance and is
the sole owner/composer of the Secrets Manager secret External Secrets
syncs into the cluster.
- `main.tf` — Creates a DB subnet group, a dedicated security group allowing
  5432 only from EKS-node security groups, and the `aws_db_instance`
  (encrypted storage, `publicly_accessible=false`, 7-day backups, and a
  **randomized** final-snapshot-identifier suffix — fixing a real incident
  where a fixed name collided with a previous teardown's leftover snapshot
  and blocked destroy with `DBSnapshotAlreadyExists`). Is the sole
  owner/composer of the app's Secrets Manager secret: combines `SECRET_KEY`
  and the Redis password (`data.tf`) with the `DATABASE_URL` it alone can
  derive, writes one JSON secret with `recovery_window_in_days=0` (also
  deliberate — the default 30-day window would hold the secret name
  hostage across a teardown/rebootstrap cycle). The module the maintainer's
  own `MANIFEST.md` had flagged as a "[P0]" gap (no documented way to get
  `urlshortener-secrets` into prod) — what the `ExternalSecret` template
  actually reads from.
- `data.tf` — Reads three manually-bootstrapped SSM values: the master
  password (used directly by `main.tf`'s `aws_db_instance`), and
  `SECRET_KEY`/the Redis password (used by the app-secret composition
  above).
- `outputs.tf` — `address`, `port`, `db_name`, `security_group_id`.
- `variables.tf` — `identifier`, `engine_version` (default `16.14`),
  `instance_class` (default `db.t4g.micro`), `allocated_storage` (default
  20 GiB), `db_name`, `username`, `multi_az`, `vpc_id`, `subnet_ids`,
  `allowed_security_group_ids`, `tags`, `deletion_protection` (default
  true — turned off only for environments riding automated teardown
  cycles; the final snapshot is the real data guard), the SSM-path
  variables, `app_secret_name` (empty = skip secret composition),
  `redis_host` (default `"redis"`), `ssm_parameter_prefix`.
- `versions.tf` — Pins `aws ~> 5.80`, `random ~> 3.6`.

**`route53-private/`** — Creates a VPC-associated private hosted zone
(`urle-<env>.internal`) with CNAME records for admin surfaces (argocd,
grafana), resolvable only inside the VPC/over the VPN.
- `main.tf` — Creates the private hosted zone and a `for_each`-driven set
  of CNAME records pointing at one `target_dns_name` (the internal
  ingress-nginx NLB hostname). Responsible for `argocd.urle-<env>.internal`
  and `grafana.urle-<env>.internal` resolving at all — the exact hostnames
  debugged during the 2026-07-19 session (Grafana's DNS record existed
  here but nothing in-cluster routed the hostname until an Ingress was
  added by hand).
- `outputs.tf` — `zone_id`, `zone_name`.
- `variables.tf` — `zone_name`, `vpc_id`, `records` (default
  `["argocd", "grafana"]` — the dev unit's real invocation passes
  `["argocd", "grafana", "app"]`), `target_dns_name`, `tags`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`route53-public-zone/`** — Creates the public hosted zone for the app's
real domain — lives in `global/` because recreating it changes the NS set
and breaks registrar delegation.
- `main.tf` — Creates the public Route 53 zone (`url-e.online`) and
  optionally publishes its zone id to SSM. Creates *only* the zone — the
  actual records inside (app A/CNAME, ACM validation records, `vpn-<env>`
  records) are all written by other modules/controllers. Lives in
  `global/` so an environment teardown never destroys it — a destroyed
  zone would require re-delegating at the registrar every cycle.
- `outputs.tf` — `zone_id`, `zone_name`, `zone_arn` (needed for
  ExternalDNS's IRSA scoping), `name_servers` (the one-time NS set for
  the registrar).
- `variables.tf` — `domain_name`, `ssm_parameter_prefix`, `tags`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`vpc/`** — Provisions the VPC (public/private subnets, NAT, DNS) with
the discovery tags EKS, the AWS LB Controller, and Karpenter all rely on to
find subnets/security groups.
- `main.tf` — Thin wrapper around `terraform-aws-modules/vpc/aws`: public +
  private subnets across the given AZs, single NAT gateway, DNS
  support/hostnames on. Tags public subnets `kubernetes.io/role/elb` (for
  the AWS LB Controller's public load balancers), private subnets
  `kubernetes.io/role/internal-elb` **and** `karpenter.sh/discovery` (the
  latter one half of the Karpenter subnet-discovery mechanism, completed
  by the `karpenter` module's matching security-group tag). The
  foundational network module every other module implicitly depends on.
- `outputs.tf` — `vpc_id`, `private_subnet_ids`, `public_subnet_ids`,
  `vpc_cidr` (used for VPN split-tunnel routes and NetworkPolicy egress
  rules — flows straight into the `vpn` module's allowed-IPs and DNS-server
  calculation).
- `variables.tf` — `name`, `cidr`, `azs`, `private_subnets`/`public_subnets`
  (CIDR lists, one per AZ), `cluster_name` (used only for subnet discovery
  tags), `tags`.
- `versions.tf` — Pins `aws ~> 5.80`.

**`vpn/`** — Stands up a single EC2 instance running WireGuard (wg-easy)
behind Caddy for TLS — the sole front door to every admin surface and to
the entire dev environment, which has no other public ingress.
- `main.tf` — Provisions one EC2 instance (Amazon Linux 2023, AMI looked up
  in `data.tf`), in the public subnet, SSM-only management (no SSH, no port
  22 — admin sessions logged to CloudTrail via SSM Session Manager).
  Security group opens UDP 51820 (WireGuard) and TCP 443 (the wg-easy admin
  UI, reverse-proxied through Caddy) to the world. An Elastic IP is
  allocated *before* the instance so `user_data` can bake the stable
  address into `WG_HOST` at boot. `user_data` (rendered from
  `user_data.sh.tpl`) also carries `password_hash` (read in `data.tf` from
  a manually-bootstrapped SSM SecureString — same bootstrap-credential
  pattern as RDS's master password), `allowed_ips` (the VPC CIDR —
  split-tunnel, only VPC traffic routes through the tunnel), and
  `dns_server` (the VPC's reserved `.2` resolver, pushed to WireGuard peers
  so `*.internal` private-zone names resolve over the tunnel — exactly the
  mechanism that resolves `argocd.urle-dev.internal` once connected).
  IMDSv2 enforced; root volume encrypted gp3. Optional public
  `vpn-<env>.<domain>` A record. Sole front door to every admin surface and
  to dev itself — but a still-open gap: the EKS control-plane security
  group doesn't admit traffic from this VPN's security group, so `kubectl`
  breaks whenever the tunnel is active.
- `data.tf` — Latest Amazon Linux 2023 AMI lookup
  (`al2023-ami-2023.*-x86_64`, amazon-owned), the manually-bootstrapped
  `password_hash` SSM SecureString, and an `aws_partition` lookup (keeps
  the instance role's SSM-managed-policy ARN partition-agnostic).
- `outputs.tf` — `public_ip` (the stable EIP, i.e. `WG_HOST`),
  `security_group_id` (exactly what's still missing from the EKS cluster's
  allowed ingress list — the fix for the "kubectl times out over VPN" gap).
- `variables.tf` — `name`, `vpc_id`, `public_subnet_id`, `vpc_cidr`
  (the only range routed through the split tunnel), `instance_type`
  (default `t3.micro`), `password_hash_ssm_path`, `public_zone_id`
  (optional), `hostname` (optional — empty means the admin UI falls back
  to a self-signed cert), `tags`.
- `versions.tf` — Pins `aws ~> 5.80`.
- `user_data.sh.tpl` — Bash cloud-init: installs/enables Docker; runs
  `ghcr.io/wg-easy/wg-easy` detached with `WG_HOST`, `PASSWORD_HASH`,
  `WG_DEFAULT_DNS`, `WG_ALLOWED_IPS` (single-quoted in the heredoc
  specifically because bcrypt hashes contain `$`), publishing UDP 51820 to
  the world and the wg-easy web UI (TCP 51821) bound to `127.0.0.1` only;
  then runs `caddy:2.8-alpine` on host networking as a reverse proxy from
  the real hostname (or a self-signed `--internal-certs` fallback) to
  `127.0.0.1:51821` — Caddy is the only thing actually exposed on 443. The
  literal boot script for the machine reached at
  `https://vpn-dev.url-e.online` to create WireGuard client profiles —
  explains why old client `.conf` files stop working after a rebootstrap:
  wg-easy's state lives on the old, now-destroyed instance, so a new
  instance means entirely new WireGuard server keys.

### `terraform/terragrunt/`

The live tree — Terragrunt units that instantiate the modules above per
environment.

- `terraform/terragrunt/root.hcl` — Included by every unit. Defines the S3
  remote-state backend (bucket `urle-tfstate-<account_id>`, key = the
  unit's relative path + `/terraform.tfstate`, S3-native locking, no
  DynamoDB table), and generates a `provider.tf` in each unit stamping
  `default_tags` (`Project=urle`, `Environment=<env>`,
  `ManagedBy=terraform`). Reads `env.hcl` from whichever `dev/`, `prod/`,
  or `global/` directory contains the calling unit — the same root file
  drives all three environments.

**`terraform/terragrunt/global/`** — account-wide, environment-independent
resources that must survive every dev/prod teardown: released container
images, the CI identity that bootstraps everything else, and the one
public DNS zone the whole domain hangs off. Applied rarely, cheap to keep
running permanently.

- `global/env.hcl` — `env = "global"`, `aws_region = "us-east-1"`. Living
  outside `dev/`/`prod/` means a `terragrunt run --all destroy` scoped to
  either environment can never reach this directory — structurally
  excluded from environment teardown, not just policy-excluded.
- `global/ecr-auth/terragrunt.hcl` — Instantiates `ecr` with `name =
  "urle-auth"`. One repo per service so one SemVer-tagged image release is
  consumed by both dev and prod; living in `global/` means a dev/prod
  destroy never deletes released images.
- `global/ecr-dashboard/terragrunt.hcl` — Same module/pattern, `name =
  "urle-dashboard"`.
- `global/ecr-redirect/terragrunt.hcl` — Same module/pattern, `name =
  "urle-redirect"`.
- `global/github-oidc/terragrunt.hcl` — Instantiates `github-oidc` with
  `github_repository = "yoavm300/URLe"`. The chicken-and-egg unit: creates
  the OIDC provider and CI/release IAM roles every GitHub Actions workflow
  assumes — since CI has no identity until this exists, it must be applied
  once, manually, with personal AWS credentials. Every `eks`,
  `alb-controller`, `external-dns`, `external-secrets` unit in dev and
  prod depends on its role-ARN outputs.
- `global/route53-public-zone/terragrunt.hcl` — Instantiates
  `route53-public-zone` with `domain_name = "url-e.online"`. Single source
  of truth for the public domain — every other unit that needs it (VPN
  hostnames, ACM SANs, CloudFront, ExternalDNS's `domain_filter`) reads it
  as a dependency output rather than hardcoding the string.

**`terraform/terragrunt/dev/`** — the cheap, VPN-only, single-AZ-light
environment used for iteration and (2026-07-19) capturing the book's Argo
CD/Grafana screenshots — smaller EKS nodes, no RDS/CloudFront/ACM/
alb-controller/external-dns (Postgres runs in-cluster via `helm/urle-chart/charts/postgres`
instead), everything gated behind WireGuard rather than a public ALB, torn
down between sessions for cost.

- `dev/env.hcl` — `env="dev"`, region `us-east-1`, VPC CIDR `10.10.0.0/16`
  across 2 AZs, `cluster_name = "urle-dev"`. Every unit in `dev/` reads
  this for shared values.
- `dev/vpc/terragrunt.hcl` — Instantiates `vpc` with dev's CIDR/AZ/subnet
  lists. Root of dev's dependency graph.
- `dev/eks/terragrunt.hcl` — Instantiates `eks`. Depends on `vpc` and
  `global/github-oidc` (`dev_ci_role_arn`). Sizes the node group small:
  `t3.medium`, min 1 / max 2 / desired 1 — Karpenter adds capacity beyond
  this floor.
- `dev/karpenter/terragrunt.hcl` — Instantiates `karpenter`, depending on
  `eks`.
- `dev/ingress-nginx/terragrunt.hcl` — Instantiates `ingress-nginx`,
  depending on `eks`. Sets `internal = true` — dev has no public-facing
  edge at all; the controller only gets an internal NLB, reachable
  exclusively over the VPN. Its `lb_hostname` feeds `route53-private`.
- `dev/cert-manager/terragrunt.hcl` — Instantiates `cert-manager`,
  depending on `eks` only.
- `dev/argocd/terragrunt.hcl` — Instantiates `argocd`, depending on `eks`
  plus an ordering-only dependency on `ingress-nginx` and
  `external-secrets`. Points at the GitHub repo, reads the private-repo PAT
  from `/urle/global/github/gitops-token`, sets `ingress_host =
  argocd.urle-dev.internal`. The unit that ultimately deploys
  `helm/urle-chart` (via `helm/git-ops/dev.yaml`) into the cluster.
- `dev/external-secrets/terragrunt.hcl` — Instantiates `external-secrets`,
  depending on `eks`. Scopes to `app_namespace = urle-dev`,
  `secrets_path_prefix = urle/dev`. Despite this infra existing, the
  chart's `externalSecrets.enabled` flag is only turned on in
  `values-prod.yaml` — today this is provisioned but unused in dev; the
  dev secret is currently created by hand.
- `dev/monitoring/terragrunt.hcl` — Instantiates `kube-prometheus-stack`,
  depending on `eks` only, stock chart values — no dev-specific Grafana
  ingress or dashboard, the exact gap patched by hand during the
  2026-07-19 session.
- `dev/route53-private/terragrunt.hcl` — Instantiates `route53-private`,
  depending on `vpc` and `ingress-nginx`. Creates `urle-dev.internal` with
  three records: `argocd`, `grafana`, and — unlike prod — `app`, since
  dev's application itself is VPN-only too.
- `dev/vpn/terragrunt.hcl` — Instantiates `vpn`, depending on `vpc` and
  `global/route53-public-zone`. `name = urle-dev-vpn`, password hash at
  `/urle/dev/vpn/wg-easy-password-hash`, public hostname
  `vpn-dev.url-e.online`. The sole entry point into dev — every
  `.internal` hostname is unreachable without first connecting through
  this tunnel.

**`terraform/terragrunt/prod/`** — the full public-facing production
shape: 3-AZ VPC, larger/more nodes, RDS instead of in-cluster Postgres, and
a public edge (CloudFront → ACM-certified ALB → ingress-nginx) in front of
the app, with admin surfaces still VPN-gated exactly like dev. `acm` and
`cloudfront` are excluded from `infra-destroy` (slow/pointless to recreate
every cost-saving cycle); RDS is deliberately **not** excluded, guarded
instead by the workflow's typed confirmation, a required reviewer, and a
final snapshot.

- `prod/env.hcl` — `env="prod"`, region `us-east-1`, VPC CIDR
  `10.20.0.0/16` across 3 AZs, `cluster_name = "urle-prod"`. One more AZ
  than dev — extends to RDS `multi_az = true` and pod spread via
  TopologySpreadConstraints.
- `prod/vpc/terragrunt.hcl` — Instantiates `vpc` with prod's 3-AZ
  CIDR/subnet lists. Root of prod's dependency graph.
- `prod/eks/terragrunt.hcl` — Instantiates `eks`, depending on `vpc` and
  `global/github-oidc` (`prod_ci_role_arn`). Sizes the node group larger
  than dev: `t3.large`, min 2 / max 5 / desired 3.
- `prod/karpenter/terragrunt.hcl` — Same module/shape as dev's.
- `prod/cert-manager/terragrunt.hcl` — Same module/shape as dev's.
- `prod/acm/terragrunt.hcl` — Instantiates `acm`, depending on
  `global/route53-public-zone`. Requests a cert for the bare domain plus
  SAN `urle-origin.<domain>` (the CloudFront-to-ALB origin hostname).
  Carries the destroy-`exclude` block — certs are free to keep, and
  changing the ARN every teardown cycle would force downstream rewiring.
- `prod/alb-controller/terragrunt.hcl` — Instantiates `alb-controller`,
  depending on `vpc` and `eks`. Creates security group
  `urle-prod-alb-cloudfront-only`, consumed by `ingress-nginx`'s edge
  Ingress.
- `prod/cloudfront/terragrunt.hcl` — Instantiates `cloudfront`, depending
  on `global/route53-public-zone` and `acm` (`certificate_arn`). Sets
  `origin_hostname = urle-origin.<domain>`, same destroy-`exclude` as ACM
  (15–30 min edge-propagation time, near-zero idle cost) — the direct
  explanation for the 502 seen on 2026-07-19: the distribution survives a
  prod teardown but its ALB origin doesn't, so `url-e.online` 502s until
  the next prod bootstrap recreates the ALB and ExternalDNS repoints
  `urle-origin`.
- `prod/ingress-nginx/terragrunt.hcl` — Instantiates `ingress-nginx`,
  depending on `eks`, `alb-controller` (`cloudfront_only_sg_id`),
  `cloudfront` (`origin_verify_value`), and
  `global/route53-public-zone`. Sets `internal = true` (nginx still serves
  the VPN-gated admin surfaces via an internal NLB, same as dev) **plus**
  an `edge` block that builds the public ALB. Full public path: CloudFront
  → ALB → this ingress-nginx controller → the app's Ingress → Services →
  pods. The biggest structural dev/prod difference — dev only ever sets
  `internal = true` with no edge block at all.
- `prod/external-dns/terragrunt.hcl` — Instantiates `external-dns` (**no
  dev equivalent** — dev has no public DNS to automate). Depends on `eks`
  and `global/route53-public-zone`. Sets `ingress_class_filter = "alb"` so
  ExternalDNS only reacts to the edge (ALB-class) Ingress and ignores the
  internal nginx-class app Ingress.
- `prod/external-secrets/terragrunt.hcl` — Same module/shape as dev's,
  scoped to `app_namespace = urle-prod`. Unlike dev, actually exercised
  end-to-end: `values-prod.yaml` sets `externalSecrets.enabled = true`, so
  in prod this SecretStore really is how `urlshortener-secrets` reaches
  the cluster (sourced from `rds-postgres`).
- `prod/rds-postgres/terragrunt.hcl` — Instantiates `rds-postgres` (**no
  dev equivalent**). Depends on `vpc` and `eks`. `db.t4g.small`, 20 GiB,
  `multi_az = true`, `deletion_protection = false` (the real guard rails
  are the destroy workflow's typed confirmation, the required reviewer,
  and the final snapshot — not Terraform-level protection, which would
  just block the intended workflow). Composes the app's Secrets Manager
  secret from three manually-created SSM SecureStrings. Not
  destroy-excluded like ACM/CloudFront, since its security group
  references the EKS node SG — excluding it would leave a dangling
  dependency that fails the VPC/EKS destroy and leaves a half-torn-down,
  still-billing environment.
- `prod/route53-private/terragrunt.hcl` — Same module as dev's, depending
  on `vpc` and `ingress-nginx` (the internal NLB — the edge Ingress uses a
  separate ALB). Creates `urle-prod.internal` with only `["argocd",
  "grafana"]` — no `app` record, since prod's app is reached publicly
  through CloudFront.
- `prod/vpn/terragrunt.hcl` — Same module/shape as dev's, `name =
  urle-prod-vpn`, public hostname `vpn-prod.url-e.online`. The admin-access
  model (WireGuard-gated Argo CD/Grafana) is deliberately identical in
  both environments even though the app itself isn't.
- `prod/argocd/terragrunt.hcl` — Instantiates `argocd`, depending on `eks`,
  with a much longer ordering-only dependency list than dev's:
  `ingress-nginx`, `external-secrets`, `rds-postgres`, `alb-controller`,
  `external-dns`, `monitoring`, `cloudfront` — prod's app chart needs far
  more infrastructure to exist before its first auto-sync succeeds. One
  subtle ordering reason: `cloudfront` must own the public
  `urle.<domain>` record *before* ExternalDNS (triggered by the chart's
  own Ingress) gets a chance to — since ExternalDNS is upsert-only, if the
  record already exists and is unowned by it, it skips claiming it and
  only manages the `urle-origin` hostname instead. `ingress_host =
  argocd.urle-prod.internal`.
- `prod/monitoring/terragrunt.hcl` — Same module/shape as dev's, installs
  the same Prometheus Operator + Grafana stack. Since this is one of the
  seven units `prod/argocd` orders against (unlike dev, where monitoring
  isn't in argocd's ordering list), prod's app ServiceMonitors have their
  CRDs ready before Argo's first sync — the exact gap found unaddressed
  for dev.

---
---

## Project history / session reference

This codebase was hardened from a working-but-not-production app through
three passes — runtime correctness, security, and infrastructure — plus a
live Kubernetes validation that surfaced and fixed container/runtime issues.
It was later split from a single Flask app into the 3-service architecture
described above (`shared/` + `services/{auth,dashboard,redirect}/`), with a
matching follow-up pass across the Helm charts, CI/CD, and Terraform to
describe 3 images instead of 1.

A final AWS-automation pass (2026-07, modeled on the maintainer's
`chess-infrastructure` reference) made the whole lifecycle run from GitHub
Actions: provisioned OIDC CI identity, the `terraform/terragrunt/global/` tier that
survives teardown cycles, plan-on-PR / dispatch-apply / no-plan-bootstrap
workflows, the WireGuard + private-zone access layer, and the prod
ALB + ACM + ExternalDNS public edge. Goals and rationale live in
`MANIFEST.md` §8a; the one-time setup in `docs/BOOTSTRAP.md`.

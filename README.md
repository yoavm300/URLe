# URLe — URL Shortener

A production-structured URL shortener built with Flask. Users register, log in,
shorten URLs, share the short links, and track how many times each link is
clicked. Built with the application-factory pattern, modular blueprints, and a
full container + Kubernetes deployment.

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

The app uses the **application-factory pattern** (`create_app()` in `app/__init__.py`).
Extensions are created once in `app/extensions.py` and initialized against the app
inside the factory, which keeps imports clean and avoids circular dependencies.

```
app/
├── __init__.py        # create_app(): wires extensions, blueprints, CLI, ProxyFix, SECRET_KEY guard
├── config.py          # config from env (SECRET_KEY, DATABASE_URL with postgres:// normalization)
├── extensions.py      # db, login_manager, csrf, limiter (singletons)
├── models/
│   ├── user.py        # User (UserMixin): id, username, email, password_hash + scrypt helpers
│   └── url.py         # Url: id, original_url, short_code, clicks, created_at, user_id (FK)
├── routes/
│   ├── auth.py        # /register, /login, /logout
│   ├── urls.py        # /shorten, /urls, /url/<id> (DELETE + POST delete)
│   └── main.py        # /, /<short_code> redirect, /healthz
├── utils/
│   ├── shortener.py   # generate_short_code(): collision-safe random code
│   └── validators.py  # normalize_url(): scheme/host/length validation
├── templates/         # Jinja2: base, index, login, register, dashboard
└── static/            # css/style.css, js/app.js (copy-to-clipboard + AJAX delete)
run.py                 # local dev entry point + `flask init-db` host
requirements.txt
Dockerfile
k8s/                   # Kubernetes manifests (see Infrastructure)
```

### Request flows

- **Register** → validates fields + password length (≥ 8), checks username/email
  uniqueness, hashes the password (Werkzeug **scrypt**), stores the user.
- **Login** → verifies the password hash, starts a Flask-Login session (signed cookie).
- **Shorten** → validates/normalizes the URL (`normalize_url`), generates a unique
  short code (retrying on the unique-constraint race), stores it against the user.
  Returns a redirect (form) or `201` JSON (API).
- **Redirect** (`GET /<code>`) → looks up the code; on hit, performs an **atomic**
  `clicks = clicks + 1` SQL update and 302-redirects to the original URL; unknown
  codes return `404`.
- **Delete** → form `POST /url/<id>/delete` (redirect) or `DELETE /url/<id>` (JSON);
  both are scoped to the owner.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Landing page (anon) / dashboard (logged in) |
| GET·POST | `/register` | Registration form + submit |
| GET·POST | `/login` | Login form + submit |
| GET | `/logout` | End session |
| POST | `/shorten` | Create a short link (form → redirect, JSON → 201) |
| GET | `/urls` | List the current user's links (JSON) |
| DELETE | `/url/<id>` | Delete a link (JSON, used by the dashboard AJAX) |
| POST | `/url/<id>/delete` | Delete a link (no-JS form fallback) |
| GET | `/<short_code>` | Redirect to the original URL + count the click |
| GET | `/healthz` | Liveness/readiness probe (no DB) |

---

## Tech stack

| Concern | Choice |
|---|---|
| Web framework | Flask (application factory + blueprints) |
| ORM / DB | SQLAlchemy; SQLite (local) / PostgreSQL (prod, via psycopg 3) |
| Auth | Flask-Login (session cookies), Werkzeug scrypt password hashing |
| CSRF | Flask-WTF (`CSRFProtect`) — tokens on all forms + AJAX header |
| Rate limiting | Flask-Limiter (in-memory local / Redis in prod) |
| WSGI server | gunicorn (production) |
| Frontend | Jinja2 templates, vanilla JS, hand-written CSS |

---

## Running locally

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python run.py
```

Open http://localhost:5000. `run.py` is **dev-only**: it injects a development
`SECRET_KEY`, creates the SQLite schema on startup, and serves the Flask dev
server (debug off unless `FLASK_DEBUG=1`). The SQLite file (`app.db`) is created
automatically.

### Configuration (environment variables)

| Variable | Default | Notes |
|---|---|---|
| `SECRET_KEY` | — | **Required in production** (the app refuses to boot without it). `run.py` injects a dev value locally. Must be identical across all replicas (signs session cookies). |
| `DATABASE_URL` | `sqlite:///app.db` | `postgres://` / `postgresql://` are normalized to the psycopg driver automatically. |
| `RATELIMIT_STORAGE_URI` | `memory://` | Set to `redis://host:6379/0` so limits are shared across replicas. |
| `TRUST_PROXY` | unset | Set to `1` behind a proxy/ingress to trust `X-Forwarded-*` (real client IP). |
| `FLASK_DEBUG` | `0` | `1` enables the dev-server debugger (never in prod). |
| `PORT` | `5000` | Dev-server port. |

### Production server

Production serves the **factory** directly (so the `SECRET_KEY` guard is enforced):

```bash
gunicorn -w 4 -b 0.0.0.0:5000 "app:create_app()"
```

### Database schema

Schema creation is a one-shot command, kept out of the request/worker path so it
doesn't race across workers or replicas:

```bash
flask --app run init-db
```

> Note: `init-db` only creates missing tables. Ongoing schema changes need a
> migration tool (e.g. Flask-Migrate).

---

## Security

- **Passwords**: hashed with Werkzeug scrypt; minimum length 8 enforced at registration.
- **Sessions**: signed cookies (no server-side session store needed; scales horizontally).
- **CSRF**: every state-changing form carries a token; the AJAX delete sends `X-CSRFToken`.
- **Rate limiting**: `5/min` on login & register, `20/min` on shorten.
- **URL validation**: only `http`/`https` with a host accepted; `javascript:`/`data:`
  and malformed input rejected; length capped to the DB column (2048).
- **SECRET_KEY**: no insecure default — production fails closed if it isn't set.
- **Container**: runs as a non-root numeric UID.

---

## Infrastructure

### Container

`Dockerfile` builds a `python:3.12-slim` image, installs `requirements.txt`, runs
as a non-root user (UID 1000), and serves gunicorn against the factory on port 5000.

```bash
docker build -t your-registry/urlshortener:latest .
docker push your-registry/urlshortener:latest
```

### Kubernetes (`k8s/`)

The app is **stateless** — all state lives in Postgres (data) and Redis
(rate-limit counters) — so it scales horizontally by replica count.

```
                    ┌─────────────┐
   Internet ─────▶  │   Ingress   │  (urlshortener.example.com)
                    └──────┬──────┘
                           ▼
                    ┌─────────────┐
                    │  Service    │  ClusterIP :80 → :5000
                    └──────┬──────┘
                           ▼
              ┌────────────┴────────────┐
              ▼            ▼             ▼
        ┌─────────┐  ┌─────────┐  ┌─────────┐    Deployment
        │  pod 1  │  │  pod 2  │  │  pod 3  │    (3 replicas, gunicorn)
        └────┬────┘  └────┬────┘  └────┬────┘
             └─────┬──────┴──────┬─────┘
                   ▼             ▼
            ┌────────────┐  ┌─────────┐
            │  Postgres  │  │  Redis  │
            │ StatefulSet│  │ (limits)│
            │   + PVC    │  └─────────┘
            └────────────┘
   (one-shot init-db Job creates the schema before rollout)
```

| Manifest | Resource | Purpose |
|---|---|---|
| `secret.example.yaml` | Secret | `SECRET_KEY`, `DATABASE_URL`, Postgres creds (template — do not commit real values) |
| `configmap.yaml` | ConfigMap | `RATELIMIT_STORAGE_URI`, `TRUST_PROXY` |
| `postgres.yaml` | StatefulSet + headless Service + PVC | In-cluster database (swap for managed Postgres in prod) |
| `redis.yaml` | Deployment + Service | Shared rate-limit store |
| `init-db-job.yaml` | Job | Runs `flask init-db` once |
| `deployment.yaml` | Deployment (3 replicas) | The app; `/healthz` probes, non-root, resource limits |
| `service.yaml` | Service (ClusterIP) | Stable in-cluster address (80 → 5000) |
| `ingress.yaml` | Ingress | External HTTP entry point |

See **`k8s/README.md`** for the build → secrets → apply order and operational notes.

### Local cluster (minikube)

This project has been validated end-to-end on a local minikube cluster
(Docker driver): image built and loaded, manifests applied, the init-db Job
creating the schema, 3 app replicas reaching `Ready`, and the full user flow
working through the Service against real Postgres + Redis.

```bash
minikube start --driver=docker
docker build -t urlshortener:local .
minikube image load urlshortener:local
# create a real Secret, then apply k8s/ in the documented order
kubectl port-forward svc/urlshortener 8080:80   # then open http://localhost:8080
```

---

## Project history / session reference

This codebase was hardened from a working-but-not-production app through three
passes — runtime correctness, security, and infrastructure — plus a live
Kubernetes validation that surfaced and fixed container/runtime issues.

**Claude Code session ID:** `6898f956-8270-4140-8daf-b7980a18fb28`

_To resume that session: `claude --resume 6898f956-8270-4140-8daf-b7980a18fb28`_

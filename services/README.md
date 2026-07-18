# services — the three deployable microservices

The application is split into three independently deployable Flask services,
each with the same anatomy: an `app/` package built by an application factory
(`create_app()`), a dev-only `run.py` entrypoint, its own `Dockerfile` and
`requirements.txt`, and a `project.json` wiring it into the Nx graph.

## The split and why

| Service     | Routes                                  | Role |
|-------------|-----------------------------------------|------|
| `auth`      | `/register` `/login` `/logout`          | Owns the users table and session auth. |
| `dashboard` | `/` `/shorten` `/urls` `/url/*` + static| URL management UI — the only service with templates/static assets. |
| `redirect`  | `GET /<short_code>`                     | The hot path: resolves a short code and 302s. Kept minimal so it scales independently of everything else. |

They share one database (models in `shared/`) but no code calls between
services — the split is by route ownership, so each can be scaled, released,
and rolled back on its own. `redirect` is the reason the split exists: it
takes nearly all production traffic and must not be coupled to the dashboard's
weight.

## How a change here reaches production

1. PR touching `services/**` or `shared/**` → `app-ci` runs `nx affected`
   (lint via Ruff, tests) for only the impacted services.
2. Pushing a `vX.Y.Z` tag → `app-release` builds all three Dockerfiles,
   pushes SemVer + SHA tags to ECR, and opens a chart-bump PR.
3. Merging that PR → Argo CD rolls the new version out (see
   `helm/git-ops/README.md` for the deployment chain).

Locally: `python services/<name>/run.py`, one terminal per service — see the
root `README.md` ("Running locally") for ports and env vars.

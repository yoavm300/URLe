# helm — charts and GitOps definitions

Everything Kubernetes-deployment-shaped lives here, in the umbrella-chart
pattern: leaf charts hold the actual workloads, one umbrella composes them,
and Argo CD deploys only the umbrella.

```
helm/
  auth/ dashboard/ redirect/   # one chart per service (the real templates)
  postgres/ redis/             # in-cluster data stores (dev only in practice)
  urle-chart/                  # umbrella: composes all of the above as
                               #   file:// dependencies; values-dev/prod.yaml
                               #   select the environment
  git-ops/                     # Argo CD AppProject + per-env Applications
                               #   (see its README for the app-of-apps chain)
```

## How the umbrella works

`urle-chart/Chart.yaml` pins each subchart version; `postgres` and `redis`
are conditional (`postgres.enabled` / `redis.enabled`) so dev runs them
in-cluster while prod uses RDS and disables them. Nothing deploys the leaf
charts directly — Argo CD's `urle-dev`/`urle-prod` Applications point at
`urle-chart` with the matching values file.

Versioning is automated: the `app-release` workflow bumps each service
chart's `appVersion` (the image tag) and `version`, updates the umbrella's
dependency pins, and opens a PR. Merging it is the deploy action.

## Rules that apply here

Charts follow `.claude/standards.md` §6: no `default` namespace, no `latest`
image tags, resource requests/limits on every workload, and all pods are
Pod-Security-Standards `restricted`-compliant (enforced by the namespace
labels Argo CD stamps — see `git-ops/dev.yaml`). `charts-ci` lints and
templates every chart on any `helm/**` change.

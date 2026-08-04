# helm — charts and GitOps definitions

Everything Kubernetes-deployment-shaped lives here, in the umbrella-chart
pattern: leaf charts hold the actual workloads, one umbrella composes them,
and Argo CD deploys only the umbrella.

```
helm/
  urle-chart/                  # umbrella: values-dev/prod.yaml select the
                               #   environment
    charts/
      urle-auth/ urle-dashboard/ urle-redirect/   # one chart per service
      postgres/ redis/                             # in-cluster data stores
                                                    #   (dev only in practice)
  git-ops/                     # Argo CD AppProject + per-env Applications
                               #   (see its README for the app-of-apps chain)
```

## How the umbrella works

The 5 service/datastore charts are vendored directly under
`urle-chart/charts/` — real source directories, not packaged `.tgz`
dependencies, and not linked via `file://` paths. `urle-chart/Chart.yaml`
still lists each by `name`+`version` to pin versions (Helm matches a
dependency with no `repository:` field against the chart already present
under `charts/`); `postgres` and `redis` are conditional
(`postgres.enabled` / `redis.enabled`) so dev runs them in-cluster while
prod uses RDS and disables them. Nothing deploys the leaf charts directly —
Argo CD's `urle-dev`/`urle-prod` Applications point at `urle-chart` with the
matching values file.

Versioning is automated: the `app-release` workflow bumps each service
chart's `appVersion` (the image tag) and `version` under
`urle-chart/charts/`, updates the umbrella's dependency pins, and opens a
PR. Merging it is the deploy action.

## Rules that apply here

Charts follow `.claude/standards.md` §6: no `default` namespace, no `latest`
image tags, resource requests/limits on every workload, and all pods are
Pod-Security-Standards `restricted`-compliant (enforced by the namespace
labels Argo CD stamps — see `git-ops/dev.yaml`). `charts-ci` lints and
templates every chart on any `helm/**` change.

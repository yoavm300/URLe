# git-ops — Argo CD app-of-apps

This directory is what the app-of-apps root Application syncs. The root app
itself (`urle-root`) is **not** a file here — it is created by Terraform
(`terraform/modules/argocd/main.tf`, applied per environment from
`terraform/terragrunt/<env>/argocd/`), because something outside git has to
create the first Application before Argo CD is watching the repo.

## The chain

```
terragrunt apply (<env>/argocd)
  └─ installs Argo CD + the urle-root Application (app of apps)
       └─ syncs this directory from main, filtered to
          {projects/*.yaml, <env>.yaml}
            └─ creates AppProject "urle" + Application "urle-<env>"
                 └─ deploys helm/urle-chart with values-<env>.yaml
                      └─ auth / dashboard / redirect (+ postgres/redis in dev)
```

## Files

- `projects/urle-project.yaml` — the `urle` AppProject: restricts source repo,
  destination namespaces (`urle-*`), and cluster-scoped resources to Namespace
  creation only.
- `dev.yaml` / `prod.yaml` — one Application per environment, both tracking
  `main` and `helm/urle-chart`, differing only in values file and target
  namespace. The root app's include filter means a dev cluster never receives
  `prod.yaml` and vice versa.

## Division of labor

Terraform builds the platform (VPC, EKS, ingress, Argo CD, the root app) and
never deploys workloads. Argo CD owns everything from this directory down,
with automated sync, prune, and self-heal — the cluster converges to `main`.
CI only pushes images and opens the chart-bump PR (`app-release.yaml`);
merging that PR is what triggers a rollout.

Renaming or moving this directory requires updating the hardcoded
`path = "helm/git-ops"` in `terraform/modules/argocd/main.tf` and re-applying
the argocd unit in every environment — see `variables.tf` there too.

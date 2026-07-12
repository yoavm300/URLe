# Kubernetes deployment

Manifests to run the URL shortener on Kubernetes. The app is split into 3
services — `urle-auth`, `urle-dashboard`, `urle-redirect` — routed by one
Ingress under a single host. All are stateless; state lives in Postgres
(data) and Redis (rate-limit counters).

## Build & push the images

Each service has its own Dockerfile; **build context must be the repo root**
(they each `COPY shared/` from there):

```bash
docker build -f services/auth/Dockerfile      -t your-registry/urle-auth:latest      .
docker build -f services/dashboard/Dockerfile -t your-registry/urle-dashboard:latest .
docker build -f services/redirect/Dockerfile  -t your-registry/urle-redirect:latest  .
docker push your-registry/urle-auth:latest
docker push your-registry/urle-dashboard:latest
docker push your-registry/urle-redirect:latest
```

Replace the `image:` in `deployment-auth.yaml`, `deployment-dashboard.yaml`,
`deployment-redirect.yaml`, and `init-db-job.yaml` (dashboard's image) with
your actual image references.

For local minikube testing, skip the registry entirely:

```bash
eval $(minikube docker-env)
docker build -f services/auth/Dockerfile      -t urle-auth:dev      .
docker build -f services/dashboard/Dockerfile -t urle-dashboard:dev .
docker build -f services/redirect/Dockerfile  -t urle-redirect:dev  .
```

This builds directly into minikube's Docker daemon — the manifests already
reference `urle-auth:dev` / `urle-dashboard:dev` / `urle-redirect:dev` with
`imagePullPolicy: IfNotPresent`, so no push is needed.

## Secrets

Do **not** commit real secrets. Either create the Secret out of band:

```bash
kubectl create secret generic urlshortener-secrets -n urle \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_URL="postgresql://urlshortener:CHANGEME@postgres:5432/urlshortener" \
  --from-literal=POSTGRES_USER=urlshortener \
  --from-literal=POSTGRES_PASSWORD=CHANGEME \
  --from-literal=POSTGRES_DB=urlshortener
```

or copy `secret.example.yaml` to `secret.yaml`, fill it in, and apply it
(keep `secret.yaml` out of git). The `DATABASE_URL` password must match
`POSTGRES_PASSWORD`. All 3 services and Postgres read from this **same**
Secret — `SECRET_KEY` in particular must be identical across `urle-auth` and
`urle-dashboard`, since it signs the session cookie that has to validate
across both.

## Apply order

```bash
kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml            # or create via kubectl (above)
kubectl apply -f configmap.yaml
kubectl apply -f postgres.yaml          # skip if using managed Postgres
kubectl apply -f redis.yaml

# wait for the database to be ready, then create the schema once:
kubectl rollout status statefulset/postgres -n urle
kubectl apply -f init-db-job.yaml
kubectl wait --for=condition=complete job/urle-dashboard-init-db -n urle --timeout=120s

kubectl apply -f deployment-auth.yaml -f deployment-dashboard.yaml -f deployment-redirect.yaml
kubectl apply -f service-auth.yaml -f service-dashboard.yaml -f service-redirect.yaml
kubectl apply -f ingress.yaml
```

For minikube, also enable the ingress addon and add the host to
`/etc/hosts` before hitting it:

```bash
minikube addons enable ingress
echo "$(minikube ip) urle.local" | sudo tee -a /etc/hosts
```

## Notes

- **Managed Postgres:** delete `postgres.yaml`, point `DATABASE_URL` at your
  managed instance. The app rewrites `postgres://` / `postgresql://` to the
  psycopg driver automatically.
- **Schema init** runs as a one-shot Job against the `urle-dashboard` image
  (the only service importing both the `User` and `Url` models), not per
  pod, to avoid the concurrent `create_all()` race. App pods may briefly
  restart if they start before the Job finishes; they recover once the
  tables exist.
- **Scaling:** all 3 services are stateless — bump `replicas` freely and
  independently. Sessions are signed cookies (shared `SECRET_KEY`), so no
  sticky sessions are needed. This is the main point of the split: e.g.
  `urle-redirect` (the hottest, public path) can scale independently of
  `urle-auth`/`urle-dashboard`.
- **Ingress routing:** `urle-auth` and `urle-dashboard` own exact/prefix
  routes for their known paths; `urle-redirect` is the catch-all for
  everything else (short codes). `RESERVED_SHORT_CODES` in
  `services/dashboard/app/utils/validators.py` blocks users from picking a
  custom short code that would collide with a reserved path segment.
- **Schema changes** still need a real migration tool (e.g. Flask-Migrate);
  `init-db` only creates missing tables.

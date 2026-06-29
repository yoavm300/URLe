# Kubernetes deployment

Manifests to run the URL shortener on Kubernetes. The app is stateless; all
state lives in Postgres (data) and Redis (rate-limit counters).

## Build & push the image

```bash
docker build -t your-registry/urlshortener:latest .
docker push your-registry/urlshortener:latest
```

Replace `your-registry/urlshortener:latest` in `deployment.yaml` and
`init-db-job.yaml` with your actual image reference.

## Secrets

Do **not** commit real secrets. Either create the Secret out of band:

```bash
kubectl create secret generic urlshortener-secrets \
  --from-literal=SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=DATABASE_URL="postgresql://urlshortener:CHANGEME@postgres:5432/urlshortener" \
  --from-literal=POSTGRES_USER=urlshortener \
  --from-literal=POSTGRES_PASSWORD=CHANGEME \
  --from-literal=POSTGRES_DB=urlshortener
```

or copy `secret.example.yaml` to `secret.yaml`, fill it in, and apply it
(keep `secret.yaml` out of git). The `DATABASE_URL` password must match
`POSTGRES_PASSWORD`.

## Apply order

```bash
kubectl apply -f secret.yaml            # or create via kubectl (above)
kubectl apply -f configmap.yaml
kubectl apply -f postgres.yaml          # skip if using managed Postgres
kubectl apply -f redis.yaml

# wait for the database to be ready, then create the schema once:
kubectl rollout status statefulset/postgres
kubectl apply -f init-db-job.yaml
kubectl wait --for=condition=complete job/urlshortener-init-db --timeout=120s

kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
```

## Notes

- **Managed Postgres:** delete `postgres.yaml`, point `DATABASE_URL` at your
  managed instance. The app rewrites `postgres://` / `postgresql://` to the
  psycopg driver automatically.
- **Schema init** runs as a one-shot Job (not per pod) to avoid the concurrent
  `create_all()` race. App pods may briefly restart if they start before the
  Job finishes; they recover once the tables exist.
- **Scaling:** app pods are stateless — bump `replicas` freely. Sessions are
  signed cookies (shared `SECRET_KEY`), so no sticky sessions are needed.
- **Schema changes** still need a real migration tool (e.g. Flask-Migrate);
  `init-db` only creates missing tables.

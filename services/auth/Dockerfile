# Build context must be the repo root (needed to reach shared/):
#   docker build -f services/auth/Dockerfile -t urle-auth:dev .
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies first for better layer caching.
COPY services/auth/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Shared models/extensions/config, then this service's own code.
COPY shared/ ./shared/
COPY services/auth/app ./app
COPY services/auth/run.py .

# Run as an unprivileged user. Use a numeric UID so Kubernetes can verify the
# container is non-root (runAsNonRoot rejects non-numeric image users).
RUN useradd --create-home --uid 1000 appuser && chown -R appuser /app
USER 1000

EXPOSE 5000

# Production entrypoint: serve the factory so the SECRET_KEY guard is enforced
# (run.py is dev-only and injects a dev key). Bind 0.0.0.0 so K8s can reach it.
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:5000", "app:create_app()"]

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Install dependencies first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application code.
COPY . .

# Run as an unprivileged user. Use a numeric UID so Kubernetes can verify the
# container is non-root (runAsNonRoot rejects non-numeric image users).
RUN useradd --create-home --uid 1000 appuser && chown -R appuser /app
USER 1000

EXPOSE 5000

# Production entrypoint: serve the factory so the SECRET_KEY guard is enforced
# (run.py is dev-only and injects a dev key). Bind 0.0.0.0 so K8s can reach it.
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:5000", "app:create_app()"]

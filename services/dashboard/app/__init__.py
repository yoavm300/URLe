import os

from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

from shared.config import Config
from shared.extensions import csrf, db, limiter, login_manager, metrics


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Behind a proxy/ingress, trust X-Forwarded-* so the real client IP is used
    # for rate limiting and logging (and the correct scheme for redirects).
    # TRUST_PROXY is the NUMBER of proxy hops in front of the app (unset/0 =
    # direct, headers ignored so they can't be spoofed): 1 = ALB/ingress only,
    # 2 = CloudFront in front of the ALB. x_for must equal the hop count or
    # rate limiting keys on the wrong entry of the X-Forwarded-For chain
    # (with CloudFront that would be the edge's IP, throttling all clients
    # collectively).
    trusted_hops = int(os.environ.get("TRUST_PROXY", "0") or "0")
    if trusted_hops > 0:
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=trusted_hops, x_proto=1, x_host=1)

    # Fail closed if no SECRET_KEY is configured. Tests get a throwaway key so
    # they don't each have to set one; production must provide a real secret.
    if not app.config.get("SECRET_KEY"):
        if app.config.get("TESTING"):
            app.config["SECRET_KEY"] = "testing-only-key"
        else:
            raise RuntimeError(
                "SECRET_KEY is not set. Export SECRET_KEY in production "
                "(e.g. a Kubernetes Secret), or run via run.py for local dev."
            )

    # Initialize extensions
    db.init_app(app)
    login_manager.init_app(app)
    # Absolute path, not a blueprint-relative endpoint: this service has no
    # "auth" blueprint registered, so "auth.login" would fail url_for(). The
    # auth service owns /login. flask_login treats any login_view starting
    # with "/" as a literal URL and skips url_for entirely.
    login_manager.login_view = "/login"
    csrf.init_app(app)

    # Rate limiting. In-memory by default (per-process — fine for a single
    # instance); in K8s set RATELIMIT_STORAGE_URI to a shared store (e.g. Redis)
    # so limits apply across replicas.
    app.config.setdefault(
        "RATELIMIT_STORAGE_URI",
        os.environ.get("RATELIMIT_STORAGE_URI", "memory://"),
    )
    limiter.init_app(app)

    # Exposes GET /metrics (Prometheus format) and instruments requests.
    metrics.init_app(app)

    # Register blueprints
    register_blueprints(app)

    # CLI: `flask --app run init-db` creates the schema. Kept out of the request/
    # worker path so DDL runs once (a Job/initContainer), not per replica. This
    # service imports both shared.models.user and shared.models.url, so this is
    # the one image used by k8s/init-db-job.yaml to create the full schema.
    @app.cli.command("init-db")
    def init_db():
        db.create_all()
        print("Initialized the database.")

    return app


def register_blueprints(app):
    from app.routes.health import health_bp
    from app.routes.main import main_bp
    from app.routes.urls import urls_bp

    app.register_blueprint(urls_bp)
    app.register_blueprint(main_bp)
    app.register_blueprint(health_bp)

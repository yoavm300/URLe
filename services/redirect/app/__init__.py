import os

from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

from shared.config import Config
from shared.extensions import db, metrics


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Behind a proxy/ingress, trust X-Forwarded-* so the real client IP is used
    # for logging (and the correct scheme for redirects).
    # TRUST_PROXY is the NUMBER of proxy hops in front of the app (unset/0 =
    # direct, headers ignored so they can't be spoofed): 1 = ALB/ingress only,
    # 2 = CloudFront in front of the ALB.
    trusted_hops = int(os.environ.get("TRUST_PROXY", "0") or "0")
    if trusted_hops > 0:
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=trusted_hops, x_proto=1, x_host=1)

    # Fail closed if no SECRET_KEY is configured. Tests get a throwaway key so
    # they don't each have to set one; production must provide a real secret.
    # This service has no session/auth, but SECRET_KEY is still required
    # because Flask.__init__ needs it configured before serving any request
    # that could touch flashing/signing machinery.
    if not app.config.get("SECRET_KEY"):
        if app.config.get("TESTING"):
            app.config["SECRET_KEY"] = "testing-only-key"
        else:
            raise RuntimeError(
                "SECRET_KEY is not set. Export SECRET_KEY in production "
                "(e.g. a Kubernetes Secret), or run via run.py for local dev."
            )

    # This service is public, unauthenticated, and GET-only: no login_manager,
    # no CSRF protection, no rate limiter are needed (confirmed no
    # @limiter.limit anywhere in this service's routes).
    db.init_app(app)

    # Exposes GET /metrics (Prometheus format) and instruments requests.
    # NOTE: this service is the public catch-all, so /metrics is reachable
    # through the ingress here (Flask matches the registered /metrics route
    # before the <short_code> converter). The NetworkPolicy scrape-allow is for
    # in-cluster Prometheus; see §10 item 15 follow-up about denying public
    # /metrics at the ingress or moving it to a dedicated metrics port.
    metrics.init_app(app)

    register_blueprints(app)

    return app


def register_blueprints(app):
    from app.routes.health import health_bp
    from app.routes.redirect import redirect_bp

    app.register_blueprint(redirect_bp)
    app.register_blueprint(health_bp)

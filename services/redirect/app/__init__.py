import os

from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

from shared.config import Config
from shared.extensions import db


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Behind a proxy/ingress, trust X-Forwarded-* so the real client IP is used
    # for logging (and the correct scheme for redirects).
    # Enabled only when TRUST_PROXY=1 so it can't be spoofed in direct setups.
    if os.environ.get("TRUST_PROXY") == "1":
        app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

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

    register_blueprints(app)

    return app


def register_blueprints(app):
    from app.routes.health import health_bp
    from app.routes.redirect import redirect_bp

    app.register_blueprint(redirect_bp)
    app.register_blueprint(health_bp)

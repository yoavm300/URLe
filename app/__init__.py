from flask import Flask

from app.config import Config
from app.extensions import db, login_manager


def create_app(config_class=Config):
    app = Flask(__name__)
    app.config.from_object(config_class)

    # Initialize extensions
    db.init_app(app)
    login_manager.init_app(app)
    login_manager.login_view = "auth.login"

    # Register blueprints
    register_blueprints(app)

    return app


def register_blueprints(app):
    from app.routes.auth import auth_bp
    from app.routes.urls import urls_bp
    from app.routes.main import main_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(urls_bp)
    app.register_blueprint(main_bp)

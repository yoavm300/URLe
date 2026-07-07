import os

basedir = os.path.abspath(os.path.dirname(os.path.dirname(__file__)))


def _database_uri():
    uri = os.environ.get("DATABASE_URL", "sqlite:///" + os.path.join(basedir, "app.db"))
    # Normalize Postgres URLs to the psycopg (v3) driver, which is what we ship.
    # Some hosts (Heroku, Render, Railway) hand out the legacy "postgres://"
    # form, which SQLAlchemy 1.4+ also rejects.
    if uri.startswith("postgres://"):
        uri = uri.replace("postgres://", "postgresql+psycopg://", 1)
    elif uri.startswith("postgresql://"):
        uri = uri.replace("postgresql://", "postgresql+psycopg://", 1)
    return uri


class Config:
    # No hardcoded fallback: a missing SECRET_KEY must fail the boot in
    # production rather than silently signing sessions with a guessable key.
    # Local dev/CLI get a dev key injected by run.py; tests get one in create_app.
    SECRET_KEY = os.environ.get("SECRET_KEY")
    SQLALCHEMY_DATABASE_URI = _database_uri()
    SQLALCHEMY_TRACK_MODIFICATIONS = False

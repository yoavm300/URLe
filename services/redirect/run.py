import os

# Local-dev / CLI convenience only: ensure a SECRET_KEY exists before the app is
# imported, so `python run.py` works out of the box.
# Production does NOT go through here — it serves the factory directly and must
# supply a real SECRET_KEY (see below), so this dev key never reaches prod.
os.environ.setdefault("SECRET_KEY", "dev-secret-key-change-me")

from app import create_app

# This module is the local entry point. In production, serve the factory so the
# SECRET_KEY guard is enforced (no dev-key injection):
#   gunicorn -w 4 -b 0.0.0.0:5000 "app:create_app()"
app = create_app()


if __name__ == "__main__":
    # Local development only. Production should be served by gunicorn (above),
    # never the Flask dev server. Debug is OFF unless explicitly enabled, so the
    # Werkzeug debugger (a remote-code-execution risk) can't be left on by accident.
    #
    # Schema creation isn't done here against a real Postgres: this service only
    # imports the Url model (whose user_id column references "users"), so
    # db.create_all() alone would fail against Postgres unless the dashboard
    # service already created the users table first. Run the dashboard
    # service's `flask --app run init-db` (or the k8s init-db Job) once before
    # standalone local testing of this service against Postgres. Against a
    # fresh local SQLite file this isn't an issue since SQLite doesn't enforce
    # FK-referenced tables at CREATE TABLE time.

    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    port = int(os.environ.get("PORT", "5000"))
    app.run(host="0.0.0.0", port=port, debug=debug)

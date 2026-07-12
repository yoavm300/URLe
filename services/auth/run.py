import os

# Local-dev / CLI convenience only: ensure a SECRET_KEY exists before the app is
# imported, so `python run.py` and `flask --app run ...` work out of the box.
# Production does NOT go through here — it serves the factory directly and must
# supply a real SECRET_KEY (see below), so this dev key never reaches prod.
os.environ.setdefault("SECRET_KEY", "dev-secret-key-change-me")

from app import create_app

from shared.extensions import db

# This module is the local entry point. In production, serve the factory so the
# SECRET_KEY guard is enforced (no dev-key injection):
#   gunicorn -w 4 -b 0.0.0.0:5000 "app:create_app()"
app = create_app()


if __name__ == "__main__":
    # Local development only. Production should be served by gunicorn (above),
    # never the Flask dev server. Debug is OFF unless explicitly enabled, so the
    # Werkzeug debugger (a remote-code-execution risk) can't be left on by accident.
    #
    # Schema creation is NOT done at import time — that would race across gunicorn
    # workers / K8s replicas. It runs here for local convenience; in production use
    # the `flask --app run init-db` command (e.g. a one-shot Job/initContainer).
    with app.app_context():
        db.create_all()

    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    port = int(os.environ.get("PORT", "5000"))
    app.run(host="0.0.0.0", port=port, debug=debug)

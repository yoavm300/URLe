#!/usr/bin/env bash
# Run the app locally (dev only — run.py injects a dev SECRET_KEY and uses SQLite).
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --quiet -r requirements.txt

exec .venv/bin/python run.py

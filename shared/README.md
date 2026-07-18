# shared — common code for all three services

The single Python package every service imports: SQLAlchemy models (`models/`),
Flask extensions (`extensions.py`), and configuration (`config.py`). It is not
a service and never runs on its own — it exists so the services agree on one
schema and one config contract instead of drifting apart.

## Role in the system

- `models/user.py` and `models/url.py` define the two tables. All services
  read the same database (SQLite locally, Postgres in-cluster in dev, RDS in
  prod — selected by `DATABASE_URL` via `config.py`), so the models must live
  in exactly one place.
- `extensions.py` holds the shared extension instances (SQLAlchemy,
  Flask-Login) that each service's `create_app()` initialises.
- Each service's Docker build copies `shared/` into its image; there is no
  published package. That is why `app-ci` triggers on `shared/**` — a change
  here affects every service, and the Nx graph (`project.json`) records that
  dependency so `nx affected` rebuilds all three.

## Ownership boundary

Table *definitions* live here, but table *ownership* stays with services:
auth owns the users table, dashboard owns URL management, redirect only reads
URLs. Business logic belongs in `services/<name>/app/`, never here — this
package stays limited to models, extensions, and config.

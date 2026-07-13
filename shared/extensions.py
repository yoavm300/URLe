from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from flask_login import LoginManager
from flask_sqlalchemy import SQLAlchemy
from flask_wtf import CSRFProtect
from prometheus_flask_exporter import PrometheusMetrics

db = SQLAlchemy()
login_manager = LoginManager()
csrf = CSRFProtect()
limiter = Limiter(key_func=get_remote_address)
# Prometheus /metrics endpoint + default request instrumentation (§10 item 15).
# for_app_factory() defers registration to metrics.init_app(app) so it fits the
# create_app() pattern the same way db/limiter do.
metrics = PrometheusMetrics.for_app_factory()

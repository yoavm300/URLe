from flask import Blueprint, render_template
from flask_login import current_user

from shared.models.url import Url

main_bp = Blueprint("main", __name__)


@main_bp.route("/")
def index():
    if current_user.is_authenticated:
        urls = Url.query.filter_by(user_id=current_user.id).order_by(Url.created_at.desc()).all()
        return render_template("dashboard.html", urls=urls)
    return render_template("index.html")

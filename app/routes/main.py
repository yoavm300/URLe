from flask import Blueprint, abort, redirect, render_template
from flask_login import current_user

from app.extensions import db
from app.models.url import Url

main_bp = Blueprint("main", __name__)


@main_bp.route("/healthz")
def healthz():
    return {"status": "ok"}, 200


@main_bp.route("/")
def index():
    if current_user.is_authenticated:
        urls = Url.query.filter_by(user_id=current_user.id).order_by(Url.created_at.desc()).all()
        return render_template("dashboard.html", urls=urls)
    return render_template("index.html")


@main_bp.route("/<short_code>")
def redirect_short(short_code):
    url = Url.query.filter_by(short_code=short_code).first()
    if url is None:
        abort(404)

    # Atomic increment at the DB level so concurrent hits don't lose updates.
    Url.query.filter_by(short_code=short_code).update(
        {Url.clicks: Url.clicks + 1}, synchronize_session=False
    )
    db.session.commit()

    return redirect(url.original_url)

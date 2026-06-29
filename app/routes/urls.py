from flask import Blueprint, request, jsonify, url_for, redirect, flash
from flask_login import login_required, current_user

from app.extensions import db
from app.models.url import Url
from app.utils.shortener import generate_short_code

urls_bp = Blueprint("urls", __name__)


@urls_bp.route("/shorten", methods=["POST"])
@login_required
def shorten():
    data = request.get_json(silent=True) or request.form
    original_url = (data.get("original_url") or "").strip()

    if not original_url:
        if request.is_json:
            return jsonify({"error": "original_url is required."}), 400
        flash("Please enter a URL to shorten.", "danger")
        return redirect(url_for("main.index"))

    short_code = generate_short_code()
    url = Url(
        original_url=original_url,
        short_code=short_code,
        user_id=current_user.id,
    )
    db.session.add(url)
    db.session.commit()

    if not request.is_json:
        flash("Short link created.", "success")
        return redirect(url_for("main.index"))

    short_url = request.host_url.rstrip("/") + url_for(
        "main.redirect_short", short_code=short_code
    )

    return (
        jsonify(
            {
                "id": url.id,
                "original_url": url.original_url,
                "short_code": url.short_code,
                "short_url": short_url,
            }
        ),
        201,
    )


@urls_bp.route("/urls", methods=["GET"])
@login_required
def list_urls():
    urls = (
        Url.query.filter_by(user_id=current_user.id)
        .order_by(Url.created_at.desc())
        .all()
    )

    return jsonify(
        [
            {
                "id": url.id,
                "original_url": url.original_url,
                "short_code": url.short_code,
                "clicks": url.clicks,
                "created_at": url.created_at.isoformat(),
            }
            for url in urls
        ]
    )


@urls_bp.route("/url/<int:url_id>", methods=["DELETE"])
@login_required
def delete_url(url_id):
    url = Url.query.filter_by(id=url_id, user_id=current_user.id).first()
    if url is None:
        return jsonify({"error": "URL not found."}), 404

    db.session.delete(url)
    db.session.commit()

    return jsonify({"message": "URL deleted."})


@urls_bp.route("/url/<int:url_id>/delete", methods=["POST"])
@login_required
def delete_url_form(url_id):
    url = Url.query.filter_by(id=url_id, user_id=current_user.id).first()
    if url is not None:
        db.session.delete(url)
        db.session.commit()
        flash("URL deleted.", "info")

    return redirect(url_for("main.index"))

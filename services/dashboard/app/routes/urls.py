from flask import Blueprint, flash, jsonify, redirect, request, url_for
from flask_login import current_user, login_required
from sqlalchemy.exc import IntegrityError

from app.utils.shortener import generate_short_code
from app.utils.validators import normalize_custom_code, normalize_url
from shared.extensions import db, limiter
from shared.models.url import Url

urls_bp = Blueprint("urls", __name__)


@urls_bp.route("/shorten", methods=["POST"])
@login_required
@limiter.limit("20 per minute")
def shorten():
    data = request.get_json(silent=True) or request.form
    original_url = (data.get("original_url") or "").strip()
    custom_code_raw = (data.get("custom_code") or "").strip()

    if not original_url:
        if request.is_json:
            return jsonify({"error": "original_url is required."}), 400
        flash("Please enter a URL to shorten.", "danger")
        return redirect(url_for("main.index"))

    normalized = normalize_url(original_url)
    if normalized is None:
        if request.is_json:
            return jsonify({"error": "Enter a valid http or https URL (max 2048 characters)."}), 400
        flash("Enter a valid http or https URL (max 2048 characters).", "danger")
        return redirect(url_for("main.index"))
    original_url = normalized

    custom_code = None
    if custom_code_raw:
        custom_code = normalize_custom_code(custom_code_raw)
        if custom_code is None:
            message = (
                "Custom code must be 3-16 characters (letters, numbers, "
                "hyphens, underscores) and not a reserved word."
            )
            if request.is_json:
                return jsonify({"error": message}), 400
            flash(message, "danger")
            return redirect(url_for("main.index"))

        if Url.query.filter_by(short_code=custom_code).first() is not None:
            message = "That custom code is already taken. Please choose another."
            if request.is_json:
                return jsonify({"error": message}), 409
            flash(message, "danger")
            return redirect(url_for("main.index"))

    # Generate + persist with retry: under concurrency two requests can pass
    # generate_short_code()'s pre-check with the same code, so the unique
    # constraint is the real guard — on conflict, regenerate and try again.
    # A custom code is never retried with a different value on conflict —
    # that would silently override the user's explicit choice.
    url = None
    if custom_code is not None:
        candidate = Url(
            original_url=original_url,
            short_code=custom_code,
            user_id=current_user.id,
        )
        db.session.add(candidate)
        try:
            db.session.commit()
            url = candidate
        except IntegrityError:
            db.session.rollback()
    else:
        for _ in range(5):
            candidate = Url(
                original_url=original_url,
                short_code=generate_short_code(),
                user_id=current_user.id,
            )
            db.session.add(candidate)
            try:
                db.session.commit()
                url = candidate
                break
            except IntegrityError:
                db.session.rollback()

    if url is None:
        if custom_code is not None:
            message = "That custom code is already taken. Please choose another."
            status = 409
        else:
            message = "Could not generate a unique short code."
            status = 500
        if request.is_json:
            return jsonify({"error": message}), status
        if custom_code is not None:
            flash(message, "danger")
        else:
            flash("Could not create a short link. Please try again.", "danger")
        return redirect(url_for("main.index"))

    if not request.is_json:
        flash("Short link created.", "success")
        return redirect(url_for("main.index"))

    # The redirect route now lives in a separate service (no shared URL map),
    # so this can't be built with url_for("main.redirect_short", ...) anymore —
    # it's a hardcoded path, routed to the redirect service by the Ingress.
    short_url = request.host_url.rstrip("/") + "/" + url.short_code

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
    urls = Url.query.filter_by(user_id=current_user.id).order_by(Url.created_at.desc()).all()

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

from flask import Blueprint, abort, redirect

from shared.extensions import db
from shared.models.url import Url

redirect_bp = Blueprint("redirect", __name__)


@redirect_bp.route("/<short_code>")
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

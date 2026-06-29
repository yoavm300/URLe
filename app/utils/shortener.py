import secrets
import string

from app.models.url import Url

ALPHABET = string.ascii_letters + string.digits


def generate_short_code(length=6):
    """Generate a random short code that is not already in use.

    Retries until an unused code is found, so the result is guaranteed
    unique against the current state of the database.
    """
    while True:
        code = "".join(secrets.choice(ALPHABET) for _ in range(length))
        if Url.query.filter_by(short_code=code).first() is None:
            return code

import re
from urllib.parse import urlparse

# Must match the original_url column length in shared/models/url.py.
MAX_URL_LENGTH = 2048

CUSTOM_CODE_PATTERN = re.compile(r"^[A-Za-z0-9_-]{3,16}$")

# Real top-level route segments this app defines (across all 3 services) plus
# the Flask-managed "static" endpoint. A custom short_code equal to one of
# these would never actually be reachable through the redirect service's
# /<short_code> route -- the Ingress always routes these exact segments to
# auth/dashboard, never to the redirect service -- so the short link would
# silently be a dead link.
RESERVED_SHORT_CODES = {
    "register",
    "login",
    "logout",
    "shorten",
    "urls",
    "url",
    "healthz",
    "static",
}


def normalize_url(raw):
    """Validate and normalize a user-supplied URL.

    - Strips whitespace.
    - Adds an "https://" scheme when none is given (so the redirect isn't
      treated as a relative path).
    - Accepts only http/https with a host; returns None otherwise (blocks
      javascript:, data:, mailto:, scheme-less hosts with no netloc, etc.).

    Returns the normalized URL string, or None if invalid.
    """
    raw = (raw or "").strip()
    if not raw or any(ch.isspace() for ch in raw):
        return None

    parsed = urlparse(raw)
    if not parsed.scheme:
        raw = "https://" + raw
        parsed = urlparse(raw)

    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        return None

    # Reject anything longer than the DB column to avoid a write-time error.
    if len(raw) > MAX_URL_LENGTH:
        return None

    return raw


def normalize_custom_code(raw):
    """Validate a user-supplied custom short code.

    Returns the code with its original case preserved (matching the
    case-sensitive codes produced by generate_short_code) if valid,
    or None if invalid or reserved.
    """
    code = (raw or "").strip()
    if not code or not CUSTOM_CODE_PATTERN.match(code):
        return None
    if code.lower() in RESERVED_SHORT_CODES:
        return None
    return code

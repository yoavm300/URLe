from urllib.parse import urlparse

# Must match the original_url column length in app/models/url.py.
MAX_URL_LENGTH = 2048


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

# User.urls declares db.relationship("Url", backref="user", ...) using a
# string class name, resolved lazily against SQLAlchemy's class registry the
# first time any mapper configures (e.g. the first query). Any service that
# imports User without ever importing Url (the auth service: it never touches
# the urls table) hits InvalidRequestError: "'Url' failed to locate a name" as
# soon as a request touches the User model. Importing both here, so that
# importing either submodule always registers both classes, regardless of
# which service does the importing.
from shared.models.url import Url  # noqa: F401
from shared.models.user import User  # noqa: F401

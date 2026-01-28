"""Shared Firestore utilities for Google Cloud Functions.

Provides a lazy-loaded, cached Firestore client shared across all functions.
"""
from google.cloud import firestore

_db = None


def get_db():
    """Lazy-load and cache Firestore client."""
    global _db
    if _db is None:
        _db = firestore.Client()
    return _db


def reset_db():
    """Clear the cached Firestore client (for testing)."""
    global _db
    _db = None

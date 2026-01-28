"""Tests for APNs notifier main handlers."""
import json
import sys
import os
from unittest.mock import MagicMock, patch
from datetime import datetime, timezone

# Mock functions_framework before importing main (not available in Py3.13)
_mock_ff = MagicMock()
_mock_ff.http = lambda f: f  # Decorator should pass through
_mock_ff.cloud_event = lambda f: f
sys.modules.setdefault("functions_framework", _mock_ff)

import flask
import pytest

# Add shared module to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), '..'))


class TestRegisterApnsToken:
    """Tests for register_apns_token handler."""

    def _import_handler(self):
        from main import register_apns_token
        return register_apns_token

    def test_cors_preflight(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(method="OPTIONS"):
            body, status, headers = handler(flask.request)
            assert status == 204
            assert "Access-Control-Allow-Origin" in headers

    def test_post_only(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(method="GET"):
            response, status, _ = handler(flask.request)
            assert status == 405

    def test_invalid_json(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data="not json",
        ):
            response, status, _ = handler(flask.request)
            assert status == 400

    def test_invalid_token_format(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({"token": "invalid"}),
        ):
            response, status, _ = handler(flask.request)
            assert status == 400

    @patch("main.get_db")
    def test_valid_registration(self, mock_get_db):
        handler = self._import_handler()
        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        valid_token = "a" * 64
        app = flask.Flask(__name__)
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({
                "token": valid_token,
                "sandbox": True,
            }),
        ):
            response, status, headers = handler(flask.request)
            data = json.loads(response.get_data(as_text=True))
            assert status == 200
            assert data["success"] is True
            mock_db.collection.assert_called_once()

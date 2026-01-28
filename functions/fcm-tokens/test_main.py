"""Tests for FCM tokens main handlers."""
import json
import sys
import os
from unittest.mock import MagicMock, patch

# Mock functions_framework before importing main (not available in Py3.13)
_mock_ff = MagicMock()
_mock_ff.http = lambda f: f  # Decorator should pass through
sys.modules.setdefault("functions_framework", _mock_ff)

import flask
import pytest

# Add shared module to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), '..'))


class TestRegisterToken:
    """Tests for register_token handler."""

    def _import_handler(self):
        from main import register_token
        return register_token

    def test_cors_preflight(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(method="OPTIONS"):
            body, status, headers = handler(flask.request)
            assert status == 204

    def test_post_only(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(method="GET"):
            _, status, _ = handler(flask.request)
            assert status == 405

    def test_invalid_json(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data="not json",
        ):
            _, status, _ = handler(flask.request)
            assert status == 400

    def test_invalid_token_format(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({
                "token": "short",
                "platform": "ios"
            }),
        ):
            _, status, _ = handler(flask.request)
            assert status == 400

    def test_invalid_platform(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        valid_token = "a" * 150
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({
                "token": valid_token,
                "platform": "blackberry"
            }),
        ):
            _, status, _ = handler(flask.request)
            assert status == 400

    @patch("main.get_db")
    def test_valid_registration(self, mock_get_db):
        handler = self._import_handler()
        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        app = flask.Flask(__name__)
        valid_token = "a" * 150
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({
                "token": valid_token,
                "platform": "ios",
                "app_version": "1.0.0"
            }),
        ):
            response, status, _ = handler(flask.request)
            data = json.loads(response.get_data(as_text=True))
            assert status == 200
            assert data["success"] is True
            mock_db.collection.assert_called_once()


class TestUnregisterToken:
    """Tests for unregister_token handler."""

    def _import_handler(self):
        from main import unregister_token
        return unregister_token

    def test_cors_preflight(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(method="OPTIONS"):
            _, status, _ = handler(flask.request)
            assert status == 204

    def test_post_only(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(method="GET"):
            _, status, _ = handler(flask.request)
            assert status == 405

    def test_invalid_token(self):
        handler = self._import_handler()
        app = flask.Flask(__name__)
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({"token": "short"}),
        ):
            _, status, _ = handler(flask.request)
            assert status == 400

    @patch("main.get_db")
    def test_valid_unregistration(self, mock_get_db):
        handler = self._import_handler()
        mock_db = MagicMock()
        mock_get_db.return_value = mock_db

        app = flask.Flask(__name__)
        valid_token = "a" * 150
        with app.test_request_context(
            method="POST",
            content_type="application/json",
            data=json.dumps({"token": valid_token}),
        ):
            response, status, _ = handler(flask.request)
            data = json.loads(response.get_data(as_text=True))
            assert status == 200
            assert data["success"] is True

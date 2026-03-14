"""Tests for shared HTTP utilities."""
import json
import flask
from shared.http_utils import (
    cors_headers,
    handle_cors_preflight,
    json_response,
    error_response,
    CORS_HEADERS,
)


def _get_app():
    """Create a Flask app context for testing."""
    app = flask.Flask(__name__)
    return app


class TestCorsHeaders:
    """Tests for cors_headers()."""

    def test_returns_allow_origin(self):
        headers = cors_headers()
        assert headers["Access-Control-Allow-Origin"] == "*"


class TestHandleCorsPreflight:
    """Tests for handle_cors_preflight()."""

    def test_returns_204_status(self):
        body, status, headers = handle_cors_preflight()
        assert status == 204
        assert body == ""

    def test_includes_full_cors_headers(self):
        _, _, headers = handle_cors_preflight()
        assert headers["Access-Control-Allow-Origin"] == "*"
        assert "POST" in headers["Access-Control-Allow-Methods"]
        assert "Content-Type" in headers["Access-Control-Allow-Headers"]
        assert headers["Access-Control-Max-Age"] == "3600"


class TestJsonResponse:
    """Tests for json_response()."""

    def test_default_200_status(self):
        app = _get_app()
        with app.test_request_context():
            response, status, headers = json_response(
                {"success": True})
            assert status == 200

    def test_custom_status(self):
        app = _get_app()
        with app.test_request_context():
            _, status, _ = json_response({"data": "test"}, 201)
            assert status == 201

    def test_includes_cors_headers(self):
        app = _get_app()
        with app.test_request_context():
            _, _, headers = json_response({"ok": True})
            assert headers["Access-Control-Allow-Origin"] == "*"

    def test_json_body(self):
        app = _get_app()
        with app.test_request_context():
            response, _, _ = json_response(
                {"message": "hello"})
            data = json.loads(response.get_data(as_text=True))
            assert data["message"] == "hello"


class TestErrorResponse:
    """Tests for error_response()."""

    def test_default_400_status(self):
        app = _get_app()
        with app.test_request_context():
            _, status, _ = error_response("Bad request")
            assert status == 400

    def test_custom_status(self):
        app = _get_app()
        with app.test_request_context():
            _, status, _ = error_response("Not found", 404)
            assert status == 404

    def test_error_body(self):
        app = _get_app()
        with app.test_request_context():
            response, _, _ = error_response("Invalid input")
            data = json.loads(response.get_data(as_text=True))
            assert data["error"] == "Invalid input"

    def test_includes_cors_headers(self):
        app = _get_app()
        with app.test_request_context():
            _, _, headers = error_response("error")
            assert headers["Access-Control-Allow-Origin"] == "*"

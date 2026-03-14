import json
import pytest
from unittest.mock import patch, MagicMock
from flask import Flask


@pytest.fixture(autouse=True)
def mock_firebase_init():
    with patch("main.firebase_admin") as mock_admin:
        mock_admin._apps = {"[DEFAULT]": True}
        yield mock_admin


@pytest.fixture
def mock_firebase():
    with patch("main.auth") as mock_auth:
        mock_auth.verify_id_token.return_value = {"uid": "test-uid-123"}
        yield mock_auth


@pytest.fixture
def mock_gcs():
    with patch("main.storage") as mock_storage:
        mock_bucket = MagicMock()
        mock_blob = MagicMock()
        mock_blob.download_as_text.side_effect = Exception("Not found")
        mock_bucket.blob.return_value = mock_blob
        mock_storage.Client.return_value.bucket.return_value = mock_bucket
        yield mock_storage, mock_bucket, mock_blob


@pytest.fixture
def flask_app():
    app = Flask(__name__)
    return app


@pytest.fixture
def app(flask_app):
    from main import receive_feedback

    def _call(request):
        with flask_app.app_context():
            return receive_feedback(request)

    return _call


def make_request(method="POST", json_body=None, auth_token="valid-token"):
    request = MagicMock()
    request.method = method
    request.headers = {"Authorization": f"Bearer {auth_token}"} if auth_token else {}
    request.get_json.return_value = json_body
    return request


def test_rejects_get(app):
    request = make_request(method="GET")
    response = app(request)
    assert response[1] == 405


def test_rejects_missing_auth(app):
    request = make_request(auth_token=None)
    request.headers = {}
    response = app(request)
    assert response[1] == 401


def test_rejects_invalid_feedback(app, mock_firebase, mock_gcs):
    request = make_request(json_body={"summary_url": "gs://test", "feedback": "maybe"})
    response = app(request)
    assert response[1] == 400


def test_stores_feedback(app, mock_firebase, mock_gcs):
    _, mock_bucket, mock_blob = mock_gcs
    request = make_request(json_body={
        "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
        "feedback": "up",
        "prompt_version": None,
    })
    response = app(request)
    body = json.loads(response[0].get_data(as_text=True))
    assert body["status"] == "ok"
    mock_blob.upload_from_string.assert_called_once()
    uploaded = json.loads(mock_blob.upload_from_string.call_args[0][0])
    assert len(uploaded) == 1
    assert uploaded[0]["feedback"] == "up"
    assert uploaded[0]["uid"] == "test-uid-123"


def test_cors_preflight(app):
    request = make_request(method="OPTIONS")
    response = app(request)
    assert response[1] == 204
    headers = response[2]
    assert headers["Access-Control-Allow-Origin"] == "*"
    assert "Authorization" in headers["Access-Control-Allow-Headers"]
    assert "POST" in headers["Access-Control-Allow-Methods"]


def test_rejects_malformed_body(app, mock_firebase):
    request = make_request(json_body=None)
    request.get_json.return_value = None
    response = app(request)
    assert response[1] == 400


def test_rejects_expired_token(app):
    with patch("main.auth") as mock_auth:
        mock_auth.ExpiredIdTokenError = type("ExpiredIdTokenError", (Exception,), {})
        mock_auth.InvalidIdTokenError = type("InvalidIdTokenError", (Exception,), {})
        mock_auth.RevokedIdTokenError = type("RevokedIdTokenError", (Exception,), {})
        mock_auth.verify_id_token.side_effect = mock_auth.ExpiredIdTokenError("Token expired")
        request = make_request(json_body={"summary_url": "gs://test", "feedback": "up"})
        response = app(request)
        assert response[1] == 401


def test_upserts_existing_feedback(app, mock_firebase, mock_gcs):
    _, mock_bucket, mock_blob = mock_gcs
    existing = json.dumps([{
        "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
        "feedback": "up",
        "prompt_version": None,
        "uid": "test-uid-123",
        "timestamp": "2026-03-14T08:00:00+00:00",
    }])
    mock_blob.download_as_text.side_effect = None
    mock_blob.download_as_text.return_value = existing

    request = make_request(json_body={
        "summary_url": "gs://tsvet01-agent-brain/summaries/gemini/2026-03-14.md",
        "feedback": "down",
        "prompt_version": None,
    })
    response = app(request)
    uploaded = json.loads(mock_blob.upload_from_string.call_args[0][0])
    assert len(uploaded) == 1
    assert uploaded[0]["feedback"] == "down"

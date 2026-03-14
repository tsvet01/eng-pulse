"""Shared pytest fixtures for Cloud Functions tests."""
import pytest
from unittest.mock import MagicMock, patch


@pytest.fixture
def mock_firestore():
    """Mock Firestore client."""
    return MagicMock()


@pytest.fixture
def mock_secret_manager():
    """Mock Secret Manager client with APNs credentials."""
    with patch(
        "google.cloud.secretmanager.SecretManagerServiceClient"
    ) as mock_cls:
        mock_client = MagicMock()
        mock_cls.return_value = mock_client

        def make_secret_response(value):
            resp = MagicMock()
            resp.payload.data.decode.return_value = value
            return resp

        mock_client.access_secret_version.side_effect = (
            lambda request: {
                "projects/tsvet01/secrets/apns-auth-key/versions/latest":
                    make_secret_response("fake-key-content"),
                "projects/tsvet01/secrets/apns-key-id/versions/latest":
                    make_secret_response("KEYID123"),
                "projects/tsvet01/secrets/apns-team-id/versions/latest":
                    make_secret_response("TEAMID456"),
            }.get(request["name"], make_secret_response(""))
        )

        yield mock_client


@pytest.fixture
def mock_httpx():
    """Mock httpx Client for APNs HTTP/2 calls."""
    with patch("httpx.Client") as mock_cls:
        mock_client = MagicMock()
        mock_cls.return_value.__enter__ = MagicMock(
            return_value=mock_client)
        mock_cls.return_value.__exit__ = MagicMock(return_value=False)
        yield mock_client

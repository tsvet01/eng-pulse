"""Tests for shared APNs utilities."""
from unittest.mock import patch, MagicMock
from shared import apns_utils


def _make_ec_key_pem():
    """Generate a real EC key PEM for JWT tests."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization

    private_key = ec.generate_private_key(ec.SECP256R1())
    return private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()
    ).decode()


def _setup_real_key(mock_secret_manager):
    """Configure mock_secret_manager with a real EC key."""
    pem = _make_ec_key_pem()

    def make_response(value):
        resp = MagicMock()
        resp.payload.data.decode.return_value = value
        return resp

    mock_secret_manager.access_secret_version.side_effect = (
        lambda request: {
            "projects/tsvet01/secrets/apns-auth-key/versions/latest":
                make_response(pem),
            "projects/tsvet01/secrets/apns-key-id/versions/latest":
                make_response("KEYID123"),
            "projects/tsvet01/secrets/apns-team-id/versions/latest":
                make_response("TEAMID456"),
        }[request["name"]]
    )


class TestGetApnsCredentials:
    """Tests for get_apns_credentials()."""

    def setup_method(self):
        apns_utils.reset_apns_credentials()

    def teardown_method(self):
        apns_utils.reset_apns_credentials()

    def test_loads_credentials(self, mock_secret_manager):
        key, key_id, team_id = apns_utils.get_apns_credentials()
        assert key == "fake-key-content"
        assert key_id == "KEYID123"
        assert team_id == "TEAMID456"

    def test_caches_credentials(self, mock_secret_manager):
        apns_utils.get_apns_credentials()
        apns_utils.get_apns_credentials()
        assert mock_secret_manager.access_secret_version.call_count == 3

    def test_handles_errors(self):
        with patch(
            "google.cloud.secretmanager.SecretManagerServiceClient"
        ) as mock_cls:
            mock_cls.return_value.access_secret_version.side_effect = (
                Exception("Connection failed"))
            key, key_id, team_id = apns_utils.get_apns_credentials()
            assert key is None
            assert key_id is None
            assert team_id is None

    def test_returns_tuple(self, mock_secret_manager):
        result = apns_utils.get_apns_credentials()
        assert isinstance(result, tuple)
        assert len(result) == 3


class TestCreateApnsJwt:
    """Tests for create_apns_jwt()."""

    def setup_method(self):
        apns_utils.reset_apns_credentials()

    def teardown_method(self):
        apns_utils.reset_apns_credentials()

    def test_creates_valid_es256_jwt(self, mock_secret_manager):
        import jwt as pyjwt

        _setup_real_key(mock_secret_manager)

        token = apns_utils.create_apns_jwt()
        assert token is not None

        decoded = pyjwt.decode(
            token, options={"verify_signature": False})
        assert decoded["iss"] == "TEAMID456"
        assert "iat" in decoded

        header = pyjwt.get_unverified_header(token)
        assert header["alg"] == "ES256"
        assert header["kid"] == "KEYID123"

    def test_returns_none_when_no_credentials(self):
        with patch(
            "google.cloud.secretmanager.SecretManagerServiceClient"
        ) as mock_cls:
            mock_cls.return_value.access_secret_version.side_effect = (
                Exception("fail"))
            token = apns_utils.create_apns_jwt()
            assert token is None


class TestSendApnsNotification:
    """Tests for send_apns_notification()."""

    def setup_method(self):
        apns_utils.reset_apns_credentials()

    def teardown_method(self):
        apns_utils.reset_apns_credentials()

    def test_uses_production_endpoint(
        self, mock_secret_manager, mock_httpx
    ):
        _setup_real_key(mock_secret_manager)
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_httpx.post.return_value = mock_response

        success, _ = apns_utils.send_apns_notification(
            "a" * 64, "Title", "Body", "https://example.com",
            sandbox=False
        )
        assert success is True
        call_url = mock_httpx.post.call_args[0][0]
        assert "api.push.apple.com" in call_url

    def test_uses_sandbox_endpoint(
        self, mock_secret_manager, mock_httpx
    ):
        _setup_real_key(mock_secret_manager)
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_httpx.post.return_value = mock_response

        success, _ = apns_utils.send_apns_notification(
            "a" * 64, "Title", "Body", "https://example.com",
            sandbox=True
        )
        assert success is True
        call_url = mock_httpx.post.call_args[0][0]
        assert "api.sandbox.push.apple.com" in call_url

    def test_success_response(self, mock_secret_manager, mock_httpx):
        _setup_real_key(mock_secret_manager)
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_httpx.post.return_value = mock_response

        success, reason = apns_utils.send_apns_notification(
            "a" * 64, "Title", "Body", "https://example.com"
        )
        assert success is True
        assert reason == ""

    def test_failure_response(self, mock_secret_manager, mock_httpx):
        _setup_real_key(mock_secret_manager)
        mock_response = MagicMock()
        mock_response.status_code = 400
        mock_response.content = b'{"reason": "BadDeviceToken"}'
        mock_response.json.return_value = {"reason": "BadDeviceToken"}
        mock_httpx.post.return_value = mock_response

        success, reason = apns_utils.send_apns_notification(
            "a" * 64, "Title", "Body", "https://example.com"
        )
        assert success is False
        assert reason == "BadDeviceToken"

    def test_correct_headers_and_payload(
        self, mock_secret_manager, mock_httpx
    ):
        _setup_real_key(mock_secret_manager)
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_httpx.post.return_value = mock_response

        apns_utils.send_apns_notification(
            "a" * 64, "Test Title", "Test Body",
            "https://example.com/article"
        )

        call_args = mock_httpx.post.call_args
        headers = call_args[1]["headers"]
        payload = call_args[1]["json"]

        assert "authorization" in headers
        assert headers["authorization"].startswith("bearer ")
        assert headers["apns-topic"] == "org.tsvetkov.EngPulseSwift"
        assert headers["apns-push-type"] == "alert"
        assert payload["aps"]["alert"]["title"] == "Test Title"
        assert payload["aps"]["alert"]["body"] == "Test Body"
        assert payload["article_url"] == "https://example.com/article"


class TestSendApnsNotifications:
    """Tests for send_apns_notifications()."""

    def setup_method(self):
        apns_utils.reset_apns_credentials()

    def teardown_method(self):
        apns_utils.reset_apns_credentials()

    def test_iterates_active_tokens(self, mock_firestore):
        doc1 = MagicMock()
        doc1.to_dict.return_value = {
            "token": "a" * 64, "sandbox": False}
        doc2 = MagicMock()
        doc2.to_dict.return_value = {
            "token": "b" * 64, "sandbox": True}

        mock_query = MagicMock()
        mock_query.stream.return_value = [doc1, doc2]
        mock_firestore.collection.return_value.where.return_value = (
            mock_query)

        with patch.object(
            apns_utils, "send_apns_notification"
        ) as mock_send:
            mock_send.return_value = (True, "")
            count = apns_utils.send_apns_notifications(
                "Title", "Body", "https://example.com",
                db=mock_firestore
            )

        assert count == 2
        assert mock_send.call_count == 2

    def test_marks_bad_tokens_inactive(self, mock_firestore):
        doc1 = MagicMock()
        doc1.to_dict.return_value = {
            "token": "a" * 64, "sandbox": False}

        mock_query = MagicMock()
        mock_query.stream.return_value = [doc1]
        mock_firestore.collection.return_value.where.return_value = (
            mock_query)

        with patch.object(
            apns_utils, "send_apns_notification"
        ) as mock_send:
            mock_send.return_value = (False, "BadDeviceToken")
            count = apns_utils.send_apns_notifications(
                "Title", "Body", "https://example.com",
                db=mock_firestore
            )

        assert count == 0
        doc1.reference.update.assert_called_once_with({"active": False})

    def test_returns_success_count(self, mock_firestore):
        doc1 = MagicMock()
        doc1.to_dict.return_value = {
            "token": "a" * 64, "sandbox": False}
        doc2 = MagicMock()
        doc2.to_dict.return_value = {
            "token": "b" * 64, "sandbox": False}

        mock_query = MagicMock()
        mock_query.stream.return_value = [doc1, doc2]
        mock_firestore.collection.return_value.where.return_value = (
            mock_query)

        with patch.object(
            apns_utils, "send_apns_notification"
        ) as mock_send:
            mock_send.side_effect = [
                (True, ""), (False, "InternalError")]
            count = apns_utils.send_apns_notifications(
                "Title", "Body", "https://example.com",
                db=mock_firestore
            )

        assert count == 1

    def test_no_active_tokens(self, mock_firestore):
        mock_query = MagicMock()
        mock_query.stream.return_value = []
        mock_firestore.collection.return_value.where.return_value = (
            mock_query)

        count = apns_utils.send_apns_notifications(
            "Title", "Body", "https://example.com",
            db=mock_firestore
        )
        assert count == 0

"""Tests for shared Firestore utilities."""
from unittest.mock import patch, MagicMock


class TestGetDb:
    """Tests for get_db() function."""

    def test_get_db_returns_firestore_client(self):
        """get_db() returns a Firestore Client instance."""
        from shared import firestore_utils
        firestore_utils.reset_db()

        with patch("google.cloud.firestore.Client") as mock_cls:
            mock_client = MagicMock()
            mock_cls.return_value = mock_client

            result = firestore_utils.get_db()
            assert result is mock_client
            mock_cls.assert_called_once()

        firestore_utils.reset_db()

    def test_get_db_caches_client(self):
        """get_db() only creates the client once (caching)."""
        from shared import firestore_utils
        firestore_utils.reset_db()

        with patch("google.cloud.firestore.Client") as mock_cls:
            mock_client = MagicMock()
            mock_cls.return_value = mock_client

            result1 = firestore_utils.get_db()
            result2 = firestore_utils.get_db()

            assert result1 is result2
            mock_cls.assert_called_once()

        firestore_utils.reset_db()

    def test_reset_db_clears_cache(self):
        """reset_db() clears the cached client."""
        from shared import firestore_utils
        firestore_utils.reset_db()

        with patch("google.cloud.firestore.Client") as mock_cls:
            mock_client1 = MagicMock()
            mock_client2 = MagicMock()
            mock_cls.side_effect = [mock_client1, mock_client2]

            first = firestore_utils.get_db()
            firestore_utils.reset_db()
            second = firestore_utils.get_db()

            assert first is mock_client1
            assert second is mock_client2
            assert mock_cls.call_count == 2

        firestore_utils.reset_db()

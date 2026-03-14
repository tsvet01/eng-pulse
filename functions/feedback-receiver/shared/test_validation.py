"""Tests for shared validation utilities."""
from shared.validation import TokenValidator


class TestApnsTokenValidation:
    """Tests for is_valid_apns_token()."""

    def test_valid_hex_token(self):
        token = "a" * 64
        assert TokenValidator.is_valid_apns_token(token) is True

    def test_valid_mixed_hex(self):
        token = "abcdef0123456789" * 4
        assert TokenValidator.is_valid_apns_token(token) is True

    def test_uppercase_hex(self):
        token = "ABCDEF0123456789" * 4
        assert TokenValidator.is_valid_apns_token(token) is True

    def test_wrong_length_short(self):
        assert TokenValidator.is_valid_apns_token("abc123") is False

    def test_wrong_length_long(self):
        token = "a" * 65
        assert TokenValidator.is_valid_apns_token(token) is False

    def test_non_hex_characters(self):
        token = "g" * 64
        assert TokenValidator.is_valid_apns_token(token) is False

    def test_empty_string(self):
        assert TokenValidator.is_valid_apns_token("") is False

    def test_none(self):
        assert TokenValidator.is_valid_apns_token(None) is False

    def test_non_string(self):
        assert TokenValidator.is_valid_apns_token(12345) is False


class TestFcmTokenValidation:
    """Tests for is_valid_fcm_token()."""

    def test_valid_token(self):
        token = "a" * 150
        assert TokenValidator.is_valid_fcm_token(token) is True

    def test_valid_with_special_chars(self):
        token = "abc_def:ghi-jkl" * 10
        assert TokenValidator.is_valid_fcm_token(token) is True

    def test_too_short(self):
        token = "a" * 99
        assert TokenValidator.is_valid_fcm_token(token) is False

    def test_too_long(self):
        token = "a" * 301
        assert TokenValidator.is_valid_fcm_token(token) is False

    def test_min_length_boundary(self):
        token = "a" * 100
        assert TokenValidator.is_valid_fcm_token(token) is True

    def test_max_length_boundary(self):
        token = "a" * 300
        assert TokenValidator.is_valid_fcm_token(token) is True

    def test_invalid_characters(self):
        token = "a" * 149 + "!"
        assert TokenValidator.is_valid_fcm_token(token) is False

    def test_empty_string(self):
        assert TokenValidator.is_valid_fcm_token("") is False

    def test_none(self):
        assert TokenValidator.is_valid_fcm_token(None) is False


class TestPlatformValidation:
    """Tests for is_valid_platform()."""

    def test_ios(self):
        assert TokenValidator.is_valid_platform("ios") is True

    def test_android(self):
        assert TokenValidator.is_valid_platform("android") is True

    def test_web(self):
        assert TokenValidator.is_valid_platform("web") is True

    def test_invalid_platform(self):
        assert TokenValidator.is_valid_platform("windows") is False

    def test_empty_string(self):
        assert TokenValidator.is_valid_platform("") is False

    def test_uppercase(self):
        assert TokenValidator.is_valid_platform("iOS") is False

"""Shared validation utilities for Google Cloud Functions.

Provides reusable validation logic for tokens and other common inputs
across all Cloud Functions.
"""
import re
from typing import Optional


class TokenValidator:
    """Validator for push notification tokens.

    Supports validation of both APNs (Apple Push Notification service)
    and FCM (Firebase Cloud Messaging) tokens.
    """

    # APNs token validation constants
    APNS_TOKEN_LENGTH = 64  # APNs tokens are always 64 hex characters
    APNS_TOKEN_PATTERN = re.compile(r'^[a-fA-F0-9]+$')

    # FCM token validation constants
    FCM_TOKEN_MIN_LENGTH = 100  # Minimum FCM token length
    FCM_TOKEN_MAX_LENGTH = 300  # Maximum FCM token length with safety margin
    FCM_TOKEN_PATTERN = re.compile(r'^[A-Za-z0-9_:\-]+$')

    @classmethod
    def is_valid_apns_token(cls, token: Optional[str]) -> bool:
        """Validate APNs device token format.

        APNs tokens are always 64 hexadecimal characters representing
        a 32-byte device token from Apple's push notification service.

        Args:
            token: The token string to validate

        Returns:
            True if the token is valid, False otherwise
        """
        if not token or not isinstance(token, str):
            return False
        if len(token) != cls.APNS_TOKEN_LENGTH:
            return False
        if not cls.APNS_TOKEN_PATTERN.match(token):
            return False
        return True

    @classmethod
    def is_valid_fcm_token(cls, token: Optional[str]) -> bool:
        """Validate FCM token format per Firebase specifications.

        FCM tokens are typically 152-163 characters containing alphanumeric
        characters, underscores, colons, and hyphens.

        Args:
            token: The token string to validate

        Returns:
            True if the token is valid, False otherwise
        """
        if not token or not isinstance(token, str):
            return False
        if len(token) < cls.FCM_TOKEN_MIN_LENGTH or len(token) > cls.FCM_TOKEN_MAX_LENGTH:
            return False
        if not cls.FCM_TOKEN_PATTERN.match(token):
            return False
        return True

    @classmethod
    def is_valid_platform(cls, platform: str) -> bool:
        """Validate platform string.

        Args:
            platform: Platform identifier to validate

        Returns:
            True if platform is valid (ios, android, or web)
        """
        return platform in ("ios", "android", "web")

"""Prepare an Eng Pulse TestFlight archive without printing secrets."""

import argparse
import base64
import binascii
import os
from pathlib import Path
import plistlib
import re
import sys


TEAM_ID = "9XQ7BW6Q4T"
BUNDLE_ID = "org.tsvetkov.eng-pulse"
REQUIRED_SECRETS = (
    "APP_STORE_CONNECT_API_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_API_KEY",
    "SUPABASE_PUBLISHABLE_KEY",
)
OPTIONAL_SECRETS = ("GOOGLE_CLOUD_TTS_API_KEY",)
PLACEHOLDERS = {
    "YOUR_PUBLISHABLE_KEY",
    "YOUR_API_KEY",
    "public-ci-placeholder",
    "public-test-placeholder",
}
KEY_ID_RE = re.compile(r"[A-Z0-9]{10}\Z")
ISSUER_RE = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)
BUILD_RE = re.compile(r"[1-9][0-9]{0,9}\Z")
APP_VALUE_RE = re.compile(r"[A-Za-z0-9._\-]+\Z")
RESULT_VALUE_RE = re.compile(r"[A-Za-z0-9_./\-]+\Z")


class ConfigError(Exception):
    pass


def decode_api_key(material):
    if not isinstance(material, str) or not material.strip():
        raise ConfigError("APP_STORE_CONNECT_API_KEY is empty")
    text = material.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        text = text[1:-1].strip()
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    if "\\n" in text and "\n" not in text:
        text = text.replace("\\n", "\n")
    if "PRIVATE KEY" in text:
        pem = text if text.endswith("\n") else text + "\n"
    else:
        try:
            decoded = base64.b64decode("".join(text.split()), validate=True)
            pem_text = decoded.decode("utf-8")
        except (binascii.Error, UnicodeDecodeError):
            raise ConfigError(
                "APP_STORE_CONNECT_API_KEY must be the .p8 PEM or its base64 encoding"
            ) from None
        pem_text = pem_text.replace("\r\n", "\n").replace("\r", "\n")
        pem = pem_text if pem_text.endswith("\n") else pem_text + "\n"
    if "-----BEGIN PRIVATE KEY-----" not in pem or "-----END PRIVATE KEY-----" not in pem:
        raise ConfigError(
            "APP_STORE_CONNECT_API_KEY must be an App Store Connect API .p8 (BEGIN PRIVATE KEY)"
        )
    return pem.encode("utf-8")


def resolve_build_number(requested, run_number):
    chosen = (requested or "").strip() or str(run_number).strip()
    if not BUILD_RE.fullmatch(chosen):
        raise ConfigError("Build number must be a positive integer with no leading zero")
    return chosen


def include_carplay_enabled(value):
    if value in (True, "true"):
        return True
    if value in (False, "false", "", None):
        return False
    raise ConfigError("INCLUDE_CARPLAY must be true or false")


def _app_setting(name, value, required):
    if value is None or value == "":
        if required:
            raise ConfigError(f"Missing {name}")
        return ""
    if not isinstance(value, str) or value in PLACEHOLDERS or not APP_VALUE_RE.fullmatch(value):
        raise ConfigError(f"{name} is missing or has unsupported characters")
    return value


def assert_project_identity(pbxproj_text):
    teams = set(re.findall(r"DEVELOPMENT_TEAM = ([A-Z0-9]+);", pbxproj_text))
    if teams != {TEAM_ID}:
        raise ConfigError("Xcode DEVELOPMENT_TEAM does not match the TestFlight team")
    if f'PRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}"' not in pbxproj_text:
        raise ConfigError(f"Xcode bundle ID does not match {BUNDLE_ID}")


def write_private(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, payload if isinstance(payload, bytes) else payload.encode("utf-8"))
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def patch_entitlements(path, include_carplay):
    with path.open("rb") as handle:
        data = plistlib.load(handle)
    if "com.apple.developer.applesignin" not in data or "aps-environment" not in data:
        raise ConfigError("EngPulse.entitlements is missing Sign in with Apple or Push")
    data["aps-environment"] = "production"
    if include_carplay:
        if data.get("com.apple.developer.carplay-audio") is not True:
            raise ConfigError("CarPlay was requested but EngPulse.entitlements does not grant it")
    else:
        data.pop("com.apple.developer.carplay-audio", None)
    with path.open("wb") as handle:
        plistlib.dump(data, handle, fmt=plistlib.FMT_XML)


def write_export_options(path):
    options = {
        "method": "app-store-connect",
        "destination": "upload",
        "signingStyle": "automatic",
        "teamID": TEAM_ID,
        "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
    }
    with path.open("wb") as handle:
        plistlib.dump(options, handle, fmt=plistlib.FMT_XML)


def _assignment(name, value):
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name) or not RESULT_VALUE_RE.fullmatch(value):
        raise ConfigError("refusing to record an unsafe TestFlight result")
    return f"{name}={value}\n"


def prepare(app_dir, key_dir, export_options, result, *, key_id, issuer_id, api_key,
            supabase_key, tts_key, build_number, run_number, include_carplay):
    app_dir = Path(app_dir)
    key_dir = Path(key_dir)
    key_id = (key_id or "").strip().upper()
    issuer_id = (issuer_id or "").strip()
    if not KEY_ID_RE.fullmatch(key_id):
        raise ConfigError("APP_STORE_CONNECT_API_KEY_ID must be the 10-character Key ID")
    if not ISSUER_RE.fullmatch(issuer_id):
        raise ConfigError("APP_STORE_CONNECT_ISSUER_ID must be the Issuer ID UUID")
    pem = decode_api_key(api_key)
    number = resolve_build_number(build_number, run_number)
    carplay = include_carplay_enabled(include_carplay)
    supabase = _app_setting("SUPABASE_PUBLISHABLE_KEY", supabase_key, required=True)
    tts = _app_setting("GOOGLE_CLOUD_TTS_API_KEY", tts_key, required=False)
    project = app_dir / "EngPulse.xcodeproj" / "project.pbxproj"
    entitlements = app_dir / "EngPulse" / "EngPulse.entitlements"
    firebase_ci = app_dir / "GoogleService-Info.plist.ci"
    assert_project_identity(project.read_text())
    if not entitlements.is_file() or not firebase_ci.is_file():
        raise ConfigError("App directory is missing entitlements or the CI Firebase plist")

    key_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(key_dir, 0o700)
    key_path = key_dir / f"AuthKey_{key_id}.p8"
    write_private(key_path, pem)
    secrets = (
        "// Written for this TestFlight run. Gitignored.\n"
        f"SUPABASE_PUBLISHABLE_KEY = {supabase}\n"
        f"GOOGLE_CLOUD_TTS_API_KEY = {tts}\n"
    )
    write_private(app_dir / "Secrets.xcconfig", secrets)
    firebase_dest = app_dir / "EngPulse" / "GoogleService-Info.plist"
    firebase_dest.write_bytes(firebase_ci.read_bytes())
    patch_entitlements(entitlements, carplay)
    write_export_options(Path(export_options))
    body = "".join((
        _assignment("BUILD_NUMBER", number),
        _assignment("ASC_KEY_ID", key_id),
        _assignment("ASC_ISSUER_ID", issuer_id),
        _assignment("ASC_KEY_PATH", str(key_path)),
        _assignment("INCLUDE_CARPLAY", "true" if carplay else "false"),
    ))
    write_private(Path(result), body)
    state = "on" if carplay else "off"
    return f"Prepared TestFlight archive inputs (build {number}, CarPlay {state})"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-dir", type=Path, required=True)
    parser.add_argument("--key-dir", type=Path, required=True)
    parser.add_argument("--export-options", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        summary = prepare(
            args.app_dir,
            args.key_dir,
            args.export_options,
            args.result,
            key_id=os.environ.get("APP_STORE_CONNECT_API_KEY_ID", ""),
            issuer_id=os.environ.get("APP_STORE_CONNECT_ISSUER_ID", ""),
            api_key=os.environ.get("APP_STORE_CONNECT_API_KEY", ""),
            supabase_key=os.environ.get("SUPABASE_PUBLISHABLE_KEY", ""),
            tts_key=os.environ.get("GOOGLE_CLOUD_TTS_API_KEY", ""),
            build_number=os.environ.get("BUILD_NUMBER_INPUT", ""),
            run_number=os.environ.get("RUN_NUMBER", ""),
            include_carplay=os.environ.get("INCLUDE_CARPLAY", "false"),
        )
    except ConfigError as error:
        print(error, file=sys.stderr)
        return 1
    print(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

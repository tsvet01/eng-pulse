import base64
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare_api_env.py"
SPEC = importlib.util.spec_from_file_location("prepare_api_env", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
PUBLIC = {
    "SUPABASE_JWKS_URL": "https://testproject.supabase.co/auth/v1/.well-known/jwks.json",
    "SUPABASE_ISSUER": "https://testproject.supabase.co/auth/v1",
    "SUPABASE_AUDIENCE": "authenticated",
    "ADMIN_EMAIL": "admin@example.com",
    "RECONCILE_HISTORY_ENABLED": "true",
    "NOTIFY_PUSH_ENABLED": "false",
}
PASSWORD = "test-existing-database-password"
TOKEN = "test-existing-service-token"
BASE = f"POSTGRES_PASSWORD={PASSWORD}\nPIPELINE_SERVICE_TOKEN={TOKEN}\nRUST_LOG=info\n"
KEY = "LS0tLS1CRUdJTiBQUklWQVRFIEtFWS0tLS0tCnRlc3QKLS0tLS1FTkQgUFJJVkFURSBLRVktLS0tLQo="
APNS = f"APNS_KEY_BASE64={KEY}\nAPNS_KEY_ID=TESTKEYID1\nAPNS_TEAM_ID=TESTTEAMID\n"


class PrepareApiEnvTest(unittest.TestCase):
    def test_preserves_existing_private_values_and_applies_public_settings(self):
        base = BASE + "SUPABASE_ISSUER=https://old.invalid\nADMIN_EMAIL=old@example.com\n"
        result = MODULE.prepare_runtime(base, PUBLIC)
        self.assertEqual(dict(line.split("=", 1) for line in result.splitlines()),
                         {"POSTGRES_PASSWORD": PASSWORD, "PIPELINE_SERVICE_TOKEN": TOKEN,
                          "RUST_LOG": "info", **PUBLIC})

    def test_reconciliation_flag_is_reviewed_strict_and_overrides_secret_copy(self):
        result = MODULE.prepare_runtime(BASE + "RECONCILE_HISTORY_ENABLED=false\n", PUBLIC)
        self.assertIn("RECONCILE_HISTORY_ENABLED=true\n", result)
        self.assertIn("RECONCILE_HISTORY_ENABLED=false\n", MODULE.prepare_runtime(
            BASE, {**PUBLIC, "RECONCILE_HISTORY_ENABLED": "false"}))
        for value in ("yes", "TRUE", "", True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.prepare_runtime(BASE, {**PUBLIC, "RECONCILE_HISTORY_ENABLED": value})

    def test_push_flag_is_required_and_strict(self):
        public = {k: v for k, v in PUBLIC.items() if k != "NOTIFY_PUSH_ENABLED"}
        with self.assertRaises(ValueError):
            MODULE.prepare_runtime(BASE, public)
        for value in ("yes", "TRUE", "", True):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MODULE.prepare_runtime(BASE, {**PUBLIC, "NOTIFY_PUSH_ENABLED": value})

    def test_push_flag_overrides_secret_copy(self):
        result = MODULE.prepare_runtime(BASE + "NOTIFY_PUSH_ENABLED=true\n", PUBLIC)
        self.assertIn("NOTIFY_PUSH_ENABLED=false\n", result)

    def test_apns_key_must_be_a_base64_pem_whatever_the_flag(self):
        valid = f"APNS_KEY_BASE64={KEY}\n"
        for flag in ("false", "true"):
            with self.subTest(flag=flag):
                public = {**PUBLIC, "NOTIFY_PUSH_ENABLED": flag}
                body = BASE + (APNS if flag == "true" else valid)
                self.assertIn(valid, MODULE.prepare_runtime(body, public))
        bad = {
            "garbage": "not*base64!",
            "non-utf8": base64.b64encode(b"\xff\xfe\xfd").decode(),
            "non-pem": base64.b64encode(b"just some text").decode(),
        }
        for name, value in bad.items():
            for flag in ("false", "true"):
                with self.subTest(case=name, flag=flag), self.assertRaises(ValueError) as error:
                    MODULE.prepare_runtime(BASE + APNS.replace(KEY, value),
                                           {**PUBLIC, "NOTIFY_PUSH_ENABLED": flag})
                self.assertIn("APNS_KEY_BASE64", str(error.exception))
                self.assertNotIn(value, str(error.exception))

    def test_push_on_requires_apns_secrets_without_echoing_them(self):
        public = {**PUBLIC, "NOTIFY_PUSH_ENABLED": "true"}
        for name in ("APNS_KEY_BASE64", "APNS_KEY_ID", "APNS_TEAM_ID"):
            lines = [line for line in APNS.splitlines(True) if not line.startswith(name)]
            for base in (BASE + "".join(lines), BASE + "".join(lines) + f"{name}=\n",
                         BASE + "".join(lines) + f"{name}=<placeholder>\n"):
                with self.subTest(name=name, base_length=len(base)):
                    with self.assertRaises(ValueError) as error:
                        MODULE.prepare_runtime(base, public)
                    self.assertIn(name, str(error.exception))
                    self.assertNotIn(KEY, str(error.exception))

    def test_push_on_passes_apns_secrets_through(self):
        result = MODULE.prepare_runtime(BASE + APNS, {**PUBLIC, "NOTIFY_PUSH_ENABLED": "true"})
        values = dict(line.split("=", 1) for line in result.splitlines())
        self.assertEqual(values["NOTIFY_PUSH_ENABLED"], "true")
        self.assertEqual(values["APNS_KEY_BASE64"], KEY)
        self.assertEqual(values["APNS_KEY_ID"], "TESTKEYID1")
        self.assertEqual(values["APNS_TEAM_ID"], "TESTTEAMID")

    def test_push_off_does_not_need_apns_secrets(self):
        self.assertIn("NOTIFY_PUSH_ENABLED=false\n", MODULE.prepare_runtime(BASE, PUBLIC))

    def test_rejects_missing_empty_and_placeholder_private_fields(self):
        for base in ("", BASE.replace(f"POSTGRES_PASSWORD={PASSWORD}\n", ""),
                     BASE.replace(TOKEN, ""), BASE.replace(TOKEN, "<generate>")):
            with self.subTest(base_length=len(base)):
                with self.assertRaises(ValueError) as error:
                    MODULE.prepare_runtime(base, PUBLIC)
                self.assertNotIn(PASSWORD, str(error.exception))
                self.assertNotIn(TOKEN, str(error.exception))

    def test_rejects_ambiguous_or_malformed_input_without_echoing_values(self):
        for extra in (f"POSTGRES_PASSWORD={TOKEN}\n", f"bad line {TOKEN}\n",
                      f"EXTRA={TOKEN} unsafe whitespace\n"):
            with self.subTest(length=len(extra)):
                with self.assertRaises(ValueError) as error:
                    MODULE.prepare_runtime(BASE + extra, PUBLIC)
                self.assertNotIn(PASSWORD, str(error.exception))
                self.assertNotIn(TOKEN, str(error.exception))

    def test_public_config_cannot_replace_private_credentials(self):
        with self.assertRaises(ValueError):
            MODULE.prepare_runtime(BASE, {**PUBLIC, "POSTGRES_PASSWORD": "replacement"})

    def test_rejects_incomplete_or_unsafe_public_configuration(self):
        for public in ({}, {**PUBLIC, "ADMIN_EMAIL": "admin@example.com\nEVIL=yes"},
                       {**PUBLIC, "SUPABASE_JWKS_URL": "https://other.supabase.co/auth/v1/.well-known/jwks.json"}):
            with self.subTest(keys=list(public)):
                with self.assertRaises(ValueError):
                    MODULE.prepare_runtime(BASE, public)

    def run_cli(self, base, output, config):
        result = subprocess.run([sys.executable, str(SCRIPT), "--config", str(config),
                                 "--output", str(output)], text=True, capture_output=True,
                                env={**os.environ, "PULSE_ENV": base})
        self.assertNotIn(PASSWORD, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result

    def test_cli_writes_private_file_without_logging_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, output = root / "public.json", root / "runtime.env"
            config.write_text(json.dumps(PUBLIC))
            result = self.run_cli(BASE, output, config)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(output.exists())
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertIn(f"POSTGRES_PASSWORD={PASSWORD}\n", output.read_text())
            self.assertIn("SUPABASE_ISSUER=https://testproject.supabase.co/auth/v1\n", output.read_text())

    def test_failed_validation_creates_no_runtime_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, output = root / "public.json", root / "runtime.env"
            config.write_text(json.dumps(PUBLIC))
            result = self.run_cli(BASE.replace(TOKEN, ""), output, config)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_cli_does_not_overwrite_an_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config, output = root / "public.json", root / "runtime.env"
            config.write_text(json.dumps(PUBLIC))
            output.write_text("existing")
            result = self.run_cli(BASE, output, config)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), "existing")

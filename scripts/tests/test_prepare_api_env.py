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
}
PASSWORD = "test-existing-database-password"
TOKEN = "test-existing-service-token"
BASE = f"POSTGRES_PASSWORD={PASSWORD}\nPIPELINE_SERVICE_TOKEN={TOKEN}\nRUST_LOG=info\n"


class PrepareApiEnvTest(unittest.TestCase):
    def test_preserves_existing_private_values_and_applies_public_settings(self):
        base = BASE + "SUPABASE_ISSUER=https://old.invalid\nADMIN_EMAIL=old@example.com\n"
        result = MODULE.prepare_runtime(base, PUBLIC)
        self.assertEqual(dict(line.split("=", 1) for line in result.splitlines()),
                         {"POSTGRES_PASSWORD": PASSWORD, "PIPELINE_SERVICE_TOKEN": TOKEN,
                          "RUST_LOG": "info", **PUBLIC})

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

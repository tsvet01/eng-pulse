import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "prepare_testflight.py"
SPEC = importlib.util.spec_from_file_location("prepare_testflight", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

PEM = "-----BEGIN PRIVATE KEY-----\nSUPERSECRETKEYMATERIAL\n-----END PRIVATE KEY-----\n"
KEY_ID = "ABCD123456"
ISSUER = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
SUPABASE = "sb_publishable_SUPERSECRETTOKEN"
TTS = "AIzaSUPERSECRETTTS"


class PrepareTestFlightTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.app = Path(self.tmp.name) / "mobile"
        shutil.copytree(ROOT / "apps" / "mobile-swift" / "EngPulse.xcodeproj",
                        self.app / "EngPulse.xcodeproj")
        shutil.copy(ROOT / "apps" / "mobile-swift" / "EngPulse" / "EngPulse.entitlements",
                    self._entitlements())
        shutil.copy(ROOT / "apps" / "mobile-swift" / "GoogleService-Info.plist.ci",
                    self.app / "GoogleService-Info.plist.ci")

    def _entitlements(self):
        path = self.app / "EngPulse" / "EngPulse.entitlements"
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def prepare(self, **overrides):
        values = {
            "key_id": KEY_ID,
            "issuer_id": ISSUER,
            "api_key": PEM,
            "supabase_key": SUPABASE,
            "tts_key": TTS,
            "build_number": "",
            "run_number": "17",
            "include_carplay": "false",
        }
        values.update(overrides)
        return MODULE.prepare(
            self.app,
            Path(self.tmp.name) / "private_keys",
            Path(self.tmp.name) / "ExportOptions.plist",
            Path(self.tmp.name) / "testflight.env",
            **values,
        )

    def test_run_number_is_the_build_and_files_stay_private(self):
        summary = self.prepare()
        self.assertEqual(summary, "Prepared TestFlight archive inputs (build 17, CarPlay off)")
        env = (Path(self.tmp.name) / "testflight.env").read_text()
        self.assertEqual(env, (
            "BUILD_NUMBER=17\n"
            f"ASC_KEY_ID={KEY_ID}\n"
            f"ASC_ISSUER_ID={ISSUER}\n"
            f"ASC_KEY_PATH={Path(self.tmp.name) / 'private_keys' / f'AuthKey_{KEY_ID}.p8'}\n"
            "INCLUDE_CARPLAY=false\n"
        ))
        key = Path(self.tmp.name) / "private_keys" / f"AuthKey_{KEY_ID}.p8"
        self.assertEqual(key.read_text(), PEM)
        self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(key.parent.stat().st_mode), 0o700)
        secrets = (self.app / "Secrets.xcconfig").read_text()
        self.assertIn(f"SUPABASE_PUBLISHABLE_KEY = {SUPABASE}\n", secrets)
        self.assertIn(f"GOOGLE_CLOUD_TTS_API_KEY = {TTS}\n", secrets)
        self.assertEqual(stat.S_IMODE((self.app / "Secrets.xcconfig").stat().st_mode), 0o600)
        self.assertEqual((self.app / "EngPulse" / "GoogleService-Info.plist").read_bytes(),
                         (ROOT / "apps" / "mobile-swift" / "GoogleService-Info.plist.ci").read_bytes())

    def test_distribution_entitlements_and_export_options(self):
        self.prepare(include_carplay="true", build_number="204")
        self.assertIn("BUILD_NUMBER=204\n", (Path(self.tmp.name) / "testflight.env").read_text())
        data = plistlib.loads(self._entitlements().read_bytes())
        self.assertEqual(data["aps-environment"], "production")
        self.assertIs(data["com.apple.developer.carplay-audio"], True)
        self.assertIn("Default", data["com.apple.developer.applesignin"])
        self.prepare(include_carplay="false")
        stripped = plistlib.loads(self._entitlements().read_bytes())
        self.assertNotIn("com.apple.developer.carplay-audio", stripped)
        self.assertEqual(stripped["aps-environment"], "production")
        options = plistlib.loads((Path(self.tmp.name) / "ExportOptions.plist").read_bytes())
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "upload")
        self.assertEqual(options["signingStyle"], "automatic")
        self.assertEqual(options["teamID"], "9XQ7BW6Q4T")
        self.assertIs(options["uploadSymbols"], True)
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)

    def test_api_key_accepts_base64_and_rejects_garbage_without_echoing_it(self):
        encoded = base64.b64encode(PEM.encode()).decode()
        self.prepare(api_key=encoded)
        oneline = PEM.replace("\n", "\\n")
        self.prepare(api_key=oneline, key_id=" abcd123456 ")
        key = Path(self.tmp.name) / "private_keys" / f"AuthKey_{KEY_ID}.p8"
        self.assertEqual(key.read_text(), PEM)
        for label, value in {
            "garbage": "not-a-key UNIQUEBADKEY",
            "non-pem": base64.b64encode(b"just some text UNIQUEBADKEY").decode(),
        }.items():
            with self.subTest(label=label):
                with self.assertRaises(MODULE.ConfigError) as error:
                    self.prepare(api_key=value)
                self.assertIn("APP_STORE_CONNECT_API_KEY", str(error.exception))
                self.assertNotIn("UNIQUEBADKEY", str(error.exception))

    def test_build_number_and_app_settings_reject_unsafe_values(self):
        for requested, run in (("", "0"), ("", "01"), ("-3", "4"), ("1 2", "4"), ("", "")):
            with self.subTest(requested=requested, run=run), self.assertRaises(MODULE.ConfigError):
                self.prepare(build_number=requested, run_number=run)
        with self.assertRaises(MODULE.ConfigError) as error:
            self.prepare(supabase_key="has space SECRETVALUE")
        self.assertNotIn("SECRETVALUE", str(error.exception))
        with self.assertRaises(MODULE.ConfigError):
            self.prepare(supabase_key="YOUR_PUBLISHABLE_KEY")
        self.prepare(tts_key="")
        self.assertIn("GOOGLE_CLOUD_TTS_API_KEY = \n", (self.app / "Secrets.xcconfig").read_text())
        with self.assertRaises(MODULE.ConfigError) as error:
            self.prepare(include_carplay="yes")
        self.assertIn("INCLUDE_CARPLAY", str(error.exception))

    def test_cli_output_omits_secret_material(self):
        env = os.environ.copy()
        env.update({
            "APP_STORE_CONNECT_API_KEY_ID": KEY_ID,
            "APP_STORE_CONNECT_ISSUER_ID": ISSUER,
            "APP_STORE_CONNECT_API_KEY": PEM,
            "SUPABASE_PUBLISHABLE_KEY": SUPABASE,
            "GOOGLE_CLOUD_TTS_API_KEY": TTS,
            "BUILD_NUMBER_INPUT": "",
            "RUN_NUMBER": "3",
            "INCLUDE_CARPLAY": "false",
        })
        result = subprocess.run(
            [sys.executable, str(SCRIPT),
             "--app-dir", str(self.app),
             "--key-dir", str(Path(self.tmp.name) / "private_keys"),
             "--export-options", str(Path(self.tmp.name) / "ExportOptions.plist"),
             "--result", str(Path(self.tmp.name) / "testflight.env")],
            env=env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        blob = result.stdout + result.stderr
        self.assertNotIn("SUPERSECRETKEYMATERIAL", blob)
        self.assertNotIn(SUPABASE, blob)
        self.assertNotIn(TTS, blob)
        self.assertIn("build 3", result.stdout)

    def test_workflow_is_manual_and_names_the_same_secrets_as_the_doc(self):
        workflow = (ROOT / ".github" / "workflows" / "testflight.yml").read_text()
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        doc = (ROOT / "docs" / "testflight.md").read_text()
        pin = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1"
        self.assertIn(pin, ci)
        self.assertIn(pin, workflow)
        self.assertRegex(workflow, r"(?m)^on:\n  workflow_dispatch:\n")
        self.assertNotRegex(workflow, r"(?m)^  (push|pull_request|schedule):")
        uses = re.findall(r"(?m)^\s*- uses: .+$", workflow)
        self.assertEqual(uses, [f"      - uses: {pin}"])
        for name in MODULE.REQUIRED_SECRETS + MODULE.OPTIONAL_SECRETS:
            self.assertIn(f"secrets.{name}", workflow)
            self.assertIn(f"### {name}", doc)
        self.assertIn("Beta App Review", doc)
        self.assertIn("public link", doc.lower())

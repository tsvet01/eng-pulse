"""Run the workflow wrapper against a local recording Docker stand-in."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "pilot-push-test.sh"
SHA = "c" * 40
CONTAINER = "d" * 64
TEST_ID = "c3611711-95ab-4d30-8ea2-afa4369ff7fd"


class PushProbeTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.calls = self.root / "calls"
        docker = self.root / "docker"
        docker.write_text("""#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ["RECORDER"], 'a') as f: print(json.dumps(a), file=f)
if a[:2] == ['compose', 'ps']: print('d' * 64)
elif a[:2] == ['inspect','--format']: print('ghcr.io/tsvet01/pulse-api:' + os.environ['IMAGE'])
elif a[:3] == ['exec','d' * 64,'sh']: print(os.environ['SOURCE'])
elif 'pilot-push-test' in a: pass
else: sys.exit(99)
""")
        docker.chmod(0o755)
        self.env = {
            "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
            "EXPECTED_API_REVISION": SHA, "IMAGE": SHA, "SOURCE": "container",
            "TEST_MODE": "check", "TEST_ID": TEST_ID, "RECORDER": str(self.calls),
            "PILOT_PUSH_TEST_USER_ID": "d44c4209-e534-4eec-bd72-69bd72039549",
            "PILOT_PUSH_TEST_TOKEN_SHA256": "a" * 64,
            "APNS_KEY_BASE64": "fixture-private-key", "APNS_KEY_ID": "fixture-key-id",
            "APNS_TEAM_ID": "fixture-team",
        }

    def invoke(self, *args, **changes):
        self.calls.write_text("")
        env = {**self.env, **changes}
        result = subprocess.run(["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True)
        captured = result.stdout + result.stderr + self.calls.read_text()
        for key in ("PILOT_PUSH_TEST_USER_ID", "PILOT_PUSH_TEST_TOKEN_SHA256", "APNS_KEY_BASE64", "APNS_KEY_ID", "APNS_TEAM_ID"):
            self.assertNotIn(self.env[key], captured)
        return result.returncode, [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_inputs_never_interpreted_or_logged(self):
        self.assertEqual(self.invoke("--check-inputs"), (0, []))
        for key in ("TEST_ID", "TEST_MODE", "EXPECTED_API_REVISION", "PILOT_PUSH_TEST_USER_ID", "PILOT_PUSH_TEST_TOKEN_SHA256"):
            result, calls = self.invoke(**{key: "untrusted; echo should-not-execute"})
            self.assertNotEqual(result, 0)
            self.assertEqual(calls, [])

    def test_refuses_wrong_revision_or_incomplete_credentials(self):
        for change in ({"IMAGE": "old"}, {"SOURCE": "partial"}, {"SOURCE": "environment", "APNS_KEY_ID": ""}):
            result, calls = self.invoke(**change)
            self.assertNotEqual(result, 0)
            self.assertFalse(any("pilot-push-test" in c for c in calls))

    def test_uses_container_credentials_or_complete_environment_set_only(self):
        for source in ("environment", "container"):
            for mode in ("send", "check"):
                result, calls = self.invoke(SOURCE=source, TEST_MODE=mode)
                self.assertEqual(result, 0)
                sends = [c for c in calls if "pilot-push-test" in c]
                self.assertEqual(len(sends), 1)
                self.assertEqual(sends[0][-5:], [CONTAINER, "pulse-api", "pilot-push-test", mode, TEST_ID])
                for key in ("APNS_KEY_BASE64", "APNS_KEY_ID", "APNS_TEAM_ID"):
                    self.assertEqual(key in sends[0], source == "environment")

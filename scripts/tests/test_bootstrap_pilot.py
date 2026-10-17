"""Exercise pilot setup guards with recording Docker and HTTP boundaries."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap-pilot.sh"
REVISION = "a" * 40
INVITE = "private-test-bootstrap-invite-0123456789"
TOKEN = "private-test-service-token"
FEED = {"slug": "engineering", "name": "Engineering", "description": None,
        "is_active": True, "topics": [],
        "sources": [{"url": "https://example.com/rss", "kind": "rss"}]}


class BootstrapPilotTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.events = self.root / "events.jsonl"
        self.scenario = {
            "container": "b" * 64,
            "image": f"ghcr.io/tsvet01/pulse-api:{REVISION}",
            "health": {"status": "ok", "db": "ok"},
            "pre_feeds": [], "post_feeds": [FEED],
            "pre_status": 200, "post_status": 200,
            "token": TOKEN, "inactive": "0", "invite_valid": "t",
            "seed_failure": False,
        }
        boundary = """#!/usr/bin/env python3
import json, os, pathlib, stat, sys
root = pathlib.Path(os.environ['TEST_ROOT'])
cfg = json.loads((root / 'scenario.json').read_text())
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
with (root / 'events.jsonl').open('a') as f:
    f.write(json.dumps([name, *args]) + '\\n')
if name == 'docker':
    if args == ['compose', 'ps', '--status', 'running', '-q', 'pulse-api']:
        print(cfg['container'])
    elif args[:2] == ['inspect', '--format']:
        print(cfg['image'])
    elif args == ['compose', 'exec', '-T', 'pulse-api', 'printenv', 'PIPELINE_SERVICE_TOKEN']:
        print(cfg['token'])
    elif args[:6] == ['compose', 'exec', '-T', 'pulse-api', 'pulse-api', 'seed']:
        (root / 'seeded').touch()
        # Real seed currently prints the code. The wrapper must suppress it.
        print(os.environ['PILOT_INVITE_CODE'])
        print(os.environ['PILOT_INVITE_CODE'], file=sys.stderr)
        sys.exit(1 if cfg['seed_failure'] else 0)
    elif args[:6] == ['compose', 'exec', '-T', 'postgres', 'psql', '-U']:
        sql = sys.stdin.read()
        if 'is_active = false' in sql:
            print(cfg['inactive'])
        elif 'max_uses = 1' in sql and ":'invite_code'" in sql:
            if '--set=invite_code=' + os.environ['PILOT_INVITE_CODE'] not in args:
                sys.exit(98)
            print(cfg['invite_valid'])
        else:
            sys.exit(99)
    else:
        sys.exit(99)
elif name == 'curl':
    url = args[-1]
    if url == 'http://127.0.0.1:8080/healthz':
        status, body = 200, cfg['health']
    elif url == 'http://127.0.0.1:8080/internal/feeds':
        header = args[args.index('--header') + 1]
        p = pathlib.Path(header[1:])
        assert stat.S_IMODE(p.stat().st_mode) == 0o600
        assert p.read_text() == 'Authorization: Bearer ' + cfg['token'] + '\\n'
        assert cfg['token'] not in args
        phase = 'post' if (root / 'seeded').exists() else 'pre'
        status, body = cfg[phase + '_status'], cfg[phase + '_feeds']
    else:
        sys.exit(99)
    output = pathlib.Path(args[args.index('--output') + 1])
    output.write_text(body if isinstance(body, str) else json.dumps(body))
    print(status, end='')
    if status >= 400:
        sys.exit(22)
"""
        for name in ("docker", "curl"):
            path = self.root / name
            path.write_text(boundary)
            path.chmod(0o755)

    def run_setup(self, *, invite=INVITE, revision=REVISION, check_only=False):
        self.events.write_text("")
        (self.root / "seeded").unlink(missing_ok=True)
        (self.root / "scenario.json").write_text(json.dumps(self.scenario))
        env = {**os.environ, "PATH": f"{self.root}:{os.environ['PATH']}",
               "TEST_ROOT": str(self.root), "TMPDIR": str(self.root),
               "PILOT_INVITE_CODE": invite, "EXPECTED_API_REVISION": revision}
        result = subprocess.run(["bash", str(SCRIPT), *(["--check-inputs"] if check_only else [])],
                                cwd=self.root, env=env, capture_output=True, text=True, timeout=15)
        events = [json.loads(line) for line in self.events.read_text().splitlines()]
        self.assertNotIn(INVITE, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        for event in events:
            if event[0] == "curl" and "--header" in event:
                header = event[event.index("--header") + 1]
                self.assertFalse(Path(header[1:]).exists(), "Private header must be cleaned up")
        return result, events

    def seed_calls(self, events):
        return [e for e in events if e[:7] ==
                ["docker", "compose", "exec", "-T", "pulse-api", "pulse-api", "seed"]]

    def test_seeds_verified_running_revision_with_one_private_invite_use(self):
        result, events = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.seed_calls(events)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][7:], ["--sources", "https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json",
                                       "--invite", INVITE, "--invite-uses", "1"])
        self.assertEqual(len([e for e in events if e[0] == "curl"]), 3)
        self.assertFalse([e for e in events if e[:3] in
                          (["docker", "compose", "up"], ["docker", "compose", "pull"])])

    def test_invalid_inputs_fail_before_external_commands(self):
        for invite, revision in (("", REVISION), ("too-short", REVISION),
                                 (INVITE + "'", REVISION), (INVITE + "\n", REVISION),
                                 (INVITE, "main"), (INVITE, REVISION + ";bad")):
            with self.subTest(invite_length=len(invite), revision_length=len(revision)):
                result, events = self.run_setup(invite=invite, revision=revision)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events, [])

    def test_check_inputs_never_contacts_docker_or_api(self):
        result, events = self.run_setup(check_only=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(events, [])

    def test_missing_or_wrong_running_revision_cannot_seed(self):
        for field, value in (("container", ""), ("image", "ghcr.io/tsvet01/pulse-api:latest"),
                             ("image", "ghcr.io/tsvet01/pulse-api:" + "c" * 40)):
            with self.subTest(field=field):
                old = self.scenario[field]
                self.scenario[field] = value
                result, events = self.run_setup()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.seed_calls(events), [])
                self.scenario[field] = old

    def test_unhealthy_or_unauthenticated_api_cannot_seed(self):
        for field, value in (("health", {"status": "ok", "db": "error"}),
                             ("health", "not json"), ("token", ""), ("pre_status", 401),
                             ("pre_status", 302), ("pre_feeds", {}), ("inactive", "1")):
            with self.subTest(field=field, value=value):
                old = self.scenario[field]
                self.scenario[field] = value
                result, events = self.run_setup()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.seed_calls(events), [])
                self.scenario[field] = old

    def test_seed_failure_is_reported_without_exposing_the_invite(self):
        self.scenario["seed_failure"] = True
        result, events = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.seed_calls(events)), 1)

    def test_failed_post_seed_verification_is_not_success(self):
        for field, value in (("post_feeds", []), ("post_feeds", [{**FEED, "sources": []}]),
                             ("post_feeds", [{**FEED, "is_active": False}]),
                             ("post_status", 403), ("invite_valid", "f")):
            with self.subTest(field=field):
                old = self.scenario[field]
                self.scenario[field] = value
                result, events = self.run_setup()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.seed_calls(events)), 1)
                self.scenario[field] = old

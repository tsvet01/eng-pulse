"""Exercise the CI import wrapper against a recording container boundary."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'import-pilot-history.sh'
SHA = 'a' * 40

class HistoryReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = {'image': 'ghcr.io/tsvet01/pulse-api:' + SHA, 'db': 'ok', 'exit': 0,
                       'report': {'expected_dates': ['2026-10-17'], 'missing_dates': ['gap'] * 29,
                                  'inserted': 1, 'unchanged': 0, 'verified': 1}}
        boundary = '''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['TEST_ROOT'])
cfg=json.loads((root/'config.json').read_text());args=sys.argv[1:]
with (root/'calls').open('a') as f:f.write(json.dumps([pathlib.Path(sys.argv[0]).name,*args])+'\\n')
if pathlib.Path(sys.argv[0]).name=='curl':
 print(json.dumps({'status':'ok','db':cfg['db']}))
elif args==['compose','ps','--status','running','-q','pulse-api']:print('b'*64)
elif args[:2]==['inspect','--format']:print(cfg['image'])
elif args==['compose','exec','-T','pulse-api','pulse-api','import-history']:
 print(json.dumps(cfg['report']));sys.exit(cfg['exit'])
else:sys.exit(99)
'''
        for command in ('docker', 'curl'):
            file = self.root / command
            file.write_text(boundary)
            file.chmod(0o755)

    def run_import(self, revision=SHA, check=False):
        (self.root / 'config.json').write_text(json.dumps(self.config))
        (self.root / 'calls').write_text('')
        env = {**os.environ, 'TEST_ROOT': str(self.root), 'PATH': str(self.root) + ':' + os.environ['PATH'],
               'EXPECTED_API_REVISION': revision, 'TMPDIR': str(self.root)}
        result = subprocess.run(['bash', str(SCRIPT), *(['--check-inputs'] if check else [])],
                                env=env, text=True, capture_output=True, timeout=10)
        calls = [json.loads(s) for s in (self.root / 'calls').read_text().splitlines()]
        return result, calls

    def test_correct_revision_runs_only_history_import_and_reports_parity(self):
        result, calls = self.run_import()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.strip().startswith('{'), 'Expected a JSON parity report')
        self.assertEqual(json.loads(result.stdout)['verified'], 1)
        self.assertIn(['docker', 'compose', 'exec', '-T', 'pulse-api', 'pulse-api', 'import-history'], calls)
        self.assertFalse(any('seed' in c or 'up' in c or 'pull' in c for c in calls))

    def test_invalid_or_check_only_inputs_never_contact_production(self):
        for revision in ('', 'main', SHA + ';x'):
            result, calls = self.run_import(revision)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, [])
        result, calls = self.run_import(check=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_wrong_image_or_unhealthy_db_prevents_import(self):
        for key, value in (('image', 'ghcr.io/tsvet01/pulse-api:latest'), ('db', 'error')):
            old = self.config[key]
            self.config[key] = value
            result, calls = self.run_import()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any('import-history' in c for c in calls))
            self.config[key] = old

    def test_failed_or_incomplete_import_is_not_success(self):
        self.config['exit'] = 1
        result, _ = self.run_import()
        self.assertNotEqual(result.returncode, 0)
        self.config['exit'] = 0
        for report in ({}, {'verified': 0}, {**self.config['report'], 'verified': 2}):
            self.config['report'] = report
            result, _ = self.run_import()
            self.assertNotEqual(result.returncode, 0)

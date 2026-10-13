import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class JsonCLI(unittest.TestCase):
    def test_entrypoints(self):
        with tempfile.TemporaryDirectory() as d:
            repo = pathlib.Path(d)
            subprocess.run(['git', 'init', '-q', d], check=True)
            (repo / 'hello.py').write_text('print("café\\nquote")\n', encoding='utf-8')
            subprocess.run(['git', '-C', d, 'add', '.'], check=True)
            subprocess.run(['git', '-C', d, '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'Initial'], check=True)
            for entry in ([str(ROOT / 'git-context')], ['-m', 'git_context']):
                with self.subTest(entry=entry):
                    cmd = [sys.executable, *entry, '--dir', d]
                    r = subprocess.run(cmd + ['--json', '--files'], cwd=ROOT, capture_output=True, text=True, check=True)
                    data = json.loads(r.stdout)
                    self.assertEqual(data['path'], d)
                    self.assertEqual(len(data['commits']), 1)
                    self.assertIn('café', data['files'])
                    self.assertIn('hello.py', data['tree'])
                    out = repo / 'context.json'
                    r = subprocess.run(cmd + ['--json', '--log', '0', '-o', str(out)], cwd=ROOT, capture_output=True, text=True, check=True)
                    self.assertEqual(r.stdout, '')
                    self.assertEqual(json.loads(out.read_text())['commits'], [])
                    self.assertNotIn('files', json.loads(out.read_text()))
                    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=True)
                    self.assertTrue(r.stdout.startswith('# git-context:'))

    def test_invalid_repo(self):
        with tempfile.TemporaryDirectory() as d:
            r = subprocess.run([sys.executable, '-m', 'git_context', '--json', '--dir', d], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertEqual(r.stdout, '')
            self.assertIn('Not a git repo', r.stderr)

if __name__ == '__main__':
    unittest.main()

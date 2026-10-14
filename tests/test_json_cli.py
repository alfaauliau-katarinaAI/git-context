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

    def test_file_export_excludes_hidden_ignored_and_symlink_targets(self):
        with tempfile.TemporaryDirectory() as d, tempfile.TemporaryDirectory() as outside:
            repo = pathlib.Path(d)
            subprocess.run(['git', 'init', '-q', d], check=True)
            (repo / 'safe.py').write_text('SAFE_SOURCE', encoding='utf-8')
            (repo / '.private.json').write_text('HIDDEN_SENTINEL', encoding='utf-8')
            ignored = repo / 'generated.egg-info'
            ignored.mkdir()
            (ignored / 'info.py').write_text('IGNORED_SENTINEL', encoding='utf-8')
            external = pathlib.Path(outside) / 'external.py'
            external.write_text('EXTERNAL_SENTINEL', encoding='utf-8')
            (repo / 'linked.py').symlink_to(external)
            (repo / 'broken.py').symlink_to(pathlib.Path(outside) / 'absent.py')
            (repo / 'linked_dir').symlink_to(outside, target_is_directory=True)
            for entry in ([str(ROOT / 'git-context')], ['-m', 'git_context']):
                for mode in ([], ['--json']):
                    with self.subTest(entry=entry, mode=mode):
                        result = subprocess.run([sys.executable, *entry, '--dir', d, '--files', '--log', '0', *mode], cwd=ROOT, capture_output=True, text=True, check=True)
                        self.assertIn('SAFE_SOURCE', result.stdout)
                        for sentinel in ('HIDDEN_SENTINEL', 'IGNORED_SENTINEL', 'EXTERNAL_SENTINEL'):
                            self.assertNotIn(sentinel, result.stdout)
                        self.assertNotIn('linked.py', result.stdout)
                        self.assertNotIn('broken.py', result.stdout)

    def test_remote_credentials_are_not_exported(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(['git', 'init', '-q', d], check=True)
            subprocess.run(['git', '-C', d, 'remote', 'add', 'origin',
                            'https://synthetic-user:AUTH_SENTINEL@example.test/repo.git?token=QUERY_SENTINEL#FRAGMENT_SENTINEL'], check=True)
            for entry in ([str(ROOT / 'git-context')], ['-m', 'git_context']):
                for mode in ([], ['--json']):
                    with self.subTest(entry=entry, mode=mode):
                        result = subprocess.run([sys.executable, *entry, '--dir', d, '--log', '0', *mode], cwd=ROOT, capture_output=True, text=True, check=True)
                        self.assertIn('https://example.test/repo.git', result.stdout)
                        for secret in ('synthetic-user', 'AUTH_SENTINEL', 'QUERY_SENTINEL', 'FRAGMENT_SENTINEL'):
                            self.assertNotIn(secret, result.stdout)

    def test_invalid_repo(self):
        with tempfile.TemporaryDirectory() as d:
            r = subprocess.run([sys.executable, '-m', 'git_context', '--json', '--dir', d], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertEqual(r.stdout, '')
            self.assertIn('Not a git repo', r.stderr)

if __name__ == '__main__':
    unittest.main()

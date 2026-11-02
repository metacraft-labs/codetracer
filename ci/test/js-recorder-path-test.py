#!/usr/bin/env python3
"""Exercise recorder discovery using real filesystem entries and shell scripts.

The temporary CLI is an inert file, not a recorder mock: these cases exercise
prerequisite validation only and assert that unrelated missing prerequisites
stop the scripts before any recording. Full recording is covered separately.
"""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
DEMO = REPO / 'src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm'


class RecorderPathTests(unittest.TestCase):
    def test_shell_resolver_preserves_cli_and_derives_repository(self):
        with tempfile.TemporaryDirectory(prefix='ct js resolver ') as directory:
            cli = Path(directory) / 'packages/cli/dist/index.js'
            cli.parent.mkdir(parents=True)
            cli.touch()
            result = subprocess.run(['bash', '-c',
                'source "$1"; js_recorder_cli "$2"; js_recorder_root "$2"',
                'resolver-test', str(REPO / 'scripts/js-recorder-path.sh'), directory],
                env=dict(os.environ, CODETRACER_JS_RECORDER_PATH=str(cli)),
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [str(cli), directory])
            rejected = subprocess.run(['bash', '-c',
                'source "$1"; js_recorder_root "$2"', 'resolver-test',
                str(REPO / 'scripts/js-recorder-path.sh'), directory],
                env=dict(os.environ, CODETRACER_JS_RECORDER_PATH=directory),
                capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('must name the CLI file', rejected.stderr)

    def test_cli_file_is_accepted_by_every_recording_entrypoint(self):
        with tempfile.TemporaryDirectory(prefix='ct js recorder ') as directory:
            cli = Path(directory) / 'packages/cli/dist/index.js'
            cli.parent.mkdir(parents=True)
            cli.write_text('// prerequisite validation only\n')
            # Deliberately omit language toolchains so validation cannot start
            # the recording pipeline, even on a fully provisioned workstation.
            tools = Path(directory) / 'tools'
            tools.mkdir()
            for name in ['dirname', 'mkdir', 'grep', 'stat', 'sort', 'head', 'cut']:
                executable = shutil.which(name)
                self.assertIsNotNone(executable, name)
                (tools / name).symlink_to(executable)
            for script, args in [
                (REPO / 'scripts/materialize-recording.sh', ['cross-process-three-trace']),
                (DEMO / 'regenerate.sh', []),
                (DEMO / 'stream-snapshots-demo.sh', []),
            ]:
                with self.subTest(script=script.name):
                    env = dict(os.environ, CODETRACER_JS_RECORDER_PATH=str(cli),
                               CT_INSTRUMENT_BIN='/nonexistent/ct-instrument',
                               CODETRACER_WASM_INSTRUMENTER_PATH='/nonexistent/instrumenter',
                               CT_RECORDING_OUT_DIR=directory, PATH=str(tools))
                    result = subprocess.run([shutil.which('bash'), str(script), *args], env=env,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('missing prerequisite', (result.stdout + result.stderr).lower())
                    self.assertIn('cargo not on PATH', result.stdout + result.stderr)
                    self.assertNotIn('codetracer-js-recorder is not built', (result.stdout + result.stderr))
                    self.assertNotIn('index.js/packages/', (result.stdout + result.stderr))


if __name__ == '__main__':
    unittest.main()

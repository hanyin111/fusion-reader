import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ios_runner', ROOT / 'scripts/run_ios_integration.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class IOSIntegrationRunnerTests(unittest.TestCase):
    def attempt(self, source):
        with tempfile.TemporaryDirectory() as root, contextlib.redirect_stdout(io.StringIO()):
            return runner.run_attempt(
                [sys.executable, '-u', '-c', source], Path(root) / 'test.log',
                launch_timeout=0.15, total_timeout=3,
            )

    def test_successful_test_keeps_success(self):
        self.assertEqual(self.attempt('print("00:01 +1: All tests passed!")'), (0, False))

    def test_failed_tests_are_never_retried(self):
        with patch.object(runner, 'run_attempt', return_value=(1, False)) as attempt:
            with patch.object(runner.subprocess, 'run') as reset:
                self.assertEqual(runner.run_test('sim', 'test.dart', 'test.log'), 1)
                self.assertEqual(attempt.call_count, 1)
                reset.assert_not_called()

    def test_build_failure_is_not_a_simulator_hang(self):
        self.assertEqual(self.attempt('raise SystemExit(65)'), (65, False))

    def test_startup_hang_is_bounded_even_after_loading_message(self):
        self.assertEqual(self.attempt(
            'import time; print("00:00 +0: loading test.dart"); '
            'print("Xcode build done. 10s"); time.sleep(10)'
        ), (124, True))

    def test_running_tests_are_allowed_past_the_attachment_deadline(self):
        self.assertEqual(self.attempt(
            'import time; print("Xcode build done. 10s"); '
            'print("00:00 +0: actual application test"); time.sleep(0.25)'
        ), (0, False))

    def test_only_one_retry_and_failed_retry_stays_failed(self):
        with tempfile.TemporaryDirectory() as root:
            with patch.object(runner, 'run_attempt', side_effect=[(124, True), (124, True)]) as attempt:
                with patch.object(runner.subprocess, 'run') as reset:
                    self.assertEqual(runner.run_test('sim', 'test.dart', str(Path(root) / 'test.log')), 124)
                    self.assertEqual(attempt.call_count, 2)
                    self.assertEqual(reset.call_count, 5)

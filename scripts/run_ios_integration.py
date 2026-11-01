"""Bound simulator attachment time without retrying failed application tests."""
import argparse
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import threading
import time


def run_attempt(command, log_path, launch_timeout=150, total_timeout=840):
    lines = queue.Queue()
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, start_new_session=os.name != 'nt',
    )

    def read_output():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    threading.Thread(target=read_output, daemon=True).start()
    deadline = time.monotonic() + total_timeout
    launch_deadline = None
    tests_started = False
    reason = None
    try:
        with Path(log_path).open('w', encoding='utf-8') as log:
            while True:
                try:
                    line = lines.get(timeout=0.1)
                except queue.Empty:
                    line = ''
                if line is None:
                    return process.wait(), False
                if line:
                    print(line, end='', flush=True)
                    log.write(line)
                    log.flush()
                    if 'Xcode build done.' in line:
                        launch_deadline = time.monotonic() + launch_timeout
                    # "loading /.../test.dart" is emitted before building.
                    if (re.search(r'\d+:\d+ \+\d+.*: ', line)
                            and ': loading ' not in line):
                        tests_started = True
                now = time.monotonic()
                if now >= deadline:
                    reason = 'Native test process exceeded its total time limit.'
                    break
                if (not tests_started and launch_deadline is not None
                        and now >= launch_deadline):
                    reason = 'Simulator never entered tests after Xcode finished.'
                    break
            print(reason, flush=True)
            log.write(reason + '\n')
    finally:
        if process.poll() is None:
            if os.name == 'nt':
                process.terminate()
            else:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if os.name == 'nt':
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        process.stdout.close()
    # Only an attachment timeout before test execution is safe to retry.
    return 124, reason.startswith('Simulator never entered')


def run_test(device, target, log_path):
    command = [
        'flutter', 'test', target, '-d', device, '--no-pub', '--timeout',
        '3m', '--reporter', 'expanded', '--verbose',
    ]
    code, launch_hung = run_attempt(command, log_path)
    if not launch_hung:
        return code
    print('Restarting the CI simulator once after an attachment timeout.', flush=True)
    diagnostic = Path(log_path).with_suffix('.launch.log')
    with diagnostic.open('w', encoding='utf-8') as output:
        subprocess.run(
            ['xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '3m',
             '--style', 'compact', '--predicate', 'process == "Runner"'],
            stdout=output, stderr=subprocess.STDOUT, timeout=45, check=False,
        )
    # This is the disposable simulator created by this job, not a user device.
    for arguments in [('shutdown', device), ('erase', device), ('boot', device),
                      ('bootstatus', device, '-b')]:
        subprocess.run(['xcrun', 'simctl', *arguments], check=True, timeout=150)
    retry_log = Path(log_path).with_suffix('.retry.log')
    code, _ = run_attempt(command, retry_log)
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--log', required=True)
    args = parser.parse_args()
    raise SystemExit(run_test(args.device, args.target, args.log))

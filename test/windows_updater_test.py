"""Exercise the shipped updater on isolated fake bundles, never the running app."""
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == 'nt', 'Windows helper requires PowerShell')
class WindowsUpdaterTest(unittest.TestCase):
    def setUp(self):
        self.workspace = Path(__file__).resolve().parents[1]
        self.test_root = self.workspace / 'build/private'
        self.test_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='updater-test-', dir=self.test_root)
        self.root = Path(self.temp.name).resolve()
        self.root.relative_to(self.test_root.resolve())
        self.install = self.root / '安装位置 with spaces'
        self.job = self.root / 'job-test'
        self.payload = self.job / 'payload'
        self.files = ['fusion_reader.exe', 'flutter_windows.dll', 'data/app.so']
        for relative in self.files:
            for parent, value in [(self.install, 'old'), (self.payload, 'new')]:
                path = parent / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(value, encoding='utf-8')
        (self.install / 'user-book.txt').write_text('keep', encoding='utf-8')
        (self.job / 'config.json').write_text(json.dumps({'processId': 0,
            'installDirectory': str(self.install)}, ensure_ascii=False), encoding='utf-8')
        # Match the UTF-8 BOM used by the app under Windows PowerShell 5.1.
        self.script = self.job / 'update.ps1'
        self.script.write_text((self.workspace / 'assets/update_windows.ps1').read_text(encoding='utf-8'), encoding='utf-8-sig')

    def tearDown(self):
        self.root.relative_to(self.test_root.resolve())
        self.temp.cleanup()

    def run_helper(self):
        return subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive',
            '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', str(self.script),
            '-ConfigPath', str(self.job / 'config.json'), '-SkipLaunch'],
            capture_output=True, timeout=30)

    def status(self):
        return json.loads((self.job / 'result.json').read_text(encoding='utf-8-sig'))['status']

    def test_update_replaces_bundle_and_preserves_unrelated_user_files(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        self.assertEqual(self.status(), 'complete')
        for relative in self.files:
            self.assertEqual((self.install / relative).read_text(), 'new')
            self.assertEqual((self.job / 'rollback' / relative).read_text(), 'old')
        self.assertEqual((self.install / 'user-book.txt').read_text(), 'keep')

    def test_locked_dll_rolls_back_files_already_replaced(self):
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel.CreateFileW.restype = ctypes.c_void_p
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        # Allow the backup read, but deny the subsequent replacement write.
        handle = kernel.CreateFileW(str(self.install / 'flutter_windows.dll'),
            0x80000000, 1, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            result = self.run_helper()
        finally:
            kernel.CloseHandle(handle)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.status(), 'failed')
        for relative in self.files:
            self.assertEqual((self.install / relative).read_text(), 'old',
                relative + ': ' + (self.job / 'result.json').read_text(encoding='utf-8-sig'))
        self.assertEqual((self.install / 'user-book.txt').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()

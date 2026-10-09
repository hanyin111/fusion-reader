import io
import json
from pathlib import Path
import tempfile
import tkinter as tk
import unittest
from unittest.mock import Mock

import paramiko
from manager import ManagerApp
from ssh_client import ConnectionSettings, ManagerError, RemoteManager, UnknownHost, VerifyHost, safe_error, REMOTE_COMMAND


class TransportTests(unittest.TestCase):
    def test_settings_and_secret_errors(self):
        for host in ['https://example.com', 'example.com;evil', '-oCommand=evil', 'host name']:
            with self.assertRaises(ManagerError):
                ConnectionSettings(host, 22, 'root', 'secret').validate()
        ConnectionSettings('2001:db8::1', 22, 'root', 'secret').validate()
        for error in [OSError('private IP sensitive-password'), paramiko.SSHException('secret-token'), ValueError('sensitive-password')]:
            self.assertNotIn('sensitive-password', safe_error(error))
            self.assertNotIn('secret-token', safe_error(error))

    def test_unknown_host_requires_exact_key_confirmation(self):
        key = paramiko.RSAKey.generate(1024)
        client = Mock()
        with self.assertRaises(UnknownHost) as raised:
            VerifyHost().missing_host_key(client, 'example.com', key)
        approved = raised.exception
        self.assertTrue(approved.fingerprint.startswith('SHA256:'))
        VerifyHost(approved).missing_host_key(client, 'example.com', key)
        client.get_host_keys().add.assert_called_once()
        with self.assertRaises(UnknownHost):
            VerifyHost(approved).missing_host_key(client, 'changed.example.com', key)

    def test_password_and_code_travel_on_stdin_only(self):
        remote = RemoteManager()
        remote.client = Mock()
        stdin, stdout, stderr = Mock(), Mock(), Mock()
        stdout.read.return_value = json.dumps({'ok': True, 'result': {'ok': True}}).encode()
        stdout.channel.recv_exit_status.return_value = 0
        remote.client.exec_command.return_value = (stdin, stdout, stderr)
        remote.request('users.reset_password', id='a' * 32, password='sensitive-password')
        self.assertEqual(remote.client.exec_command.call_args.args[0], REMOTE_COMMAND)
        self.assertNotIn('sensitive-password', REMOTE_COMMAND)
        self.assertIn(b'sensitive-password', stdin.write.call_args.args[0])
        stdout.channel.shutdown_write.assert_called_once()

    def test_transport_rejects_failure_or_invalid_response(self):
        for data in [b'{', b'[]', b'{"ok":true,"result":null}', b'{"ok":false,"error":"secret-password"}']:
            remote = RemoteManager()
            remote.client = Mock()
            stdin, stdout, stderr = Mock(), Mock(), Mock()
            stdout.read.return_value = data
            stdout.channel.recv_exit_status.return_value = 0
            remote.client.exec_command.return_value = stdin, stdout, stderr
            with self.assertRaises(ManagerError) as error:
                remote.request('info')
            self.assertNotIn('secret-password', str(error.exception))


class UiTests(unittest.TestCase):
    def test_empty_connection_and_list_presentation(self):
        root = tk.Tk()
        root.withdraw()
        try:
            app = ManagerApp(root, Mock())
            root.update_idletasks()
            self.assertEqual(app.host.get(), '')
            self.assertEqual(app.password.get(), '')
            self.assertEqual(app.proxy_mode.get(), '跟随系统代理')
            self.assertEqual(str(app.proxy_mode_box['state']), 'readonly')
            self.assertTrue(all(str(entry['state']) == 'disabled' for entry in app.proxy_entries))
            app.proxy_mode.set('手动代理')
            app.update_buttons()
            self.assertTrue(all(str(entry['state']) == 'normal' for entry in app.proxy_entries))
            self.assertFalse(app.connected)
            app.render_invites({'items': [{'id': 'a' * 16, 'status': 'used', 'username': 'reader',
                'createdAt': None, 'expiresAt': '2030-01-01T00:00:00Z', 'usedAt': '2026-01-01T00:00:00Z'}], 'next': None})
            self.assertEqual(app.invite_tree.item('a' * 16)['values'][1], '已使用')
            self.assertIn('旧版', app.invite_tree.item('a' * 16)['values'][3])
            app.render_users({'items': [{'id': 'b' * 32, 'username': 'reader', 'enabled': False,
                'createdAt': '2026-01-01T00:00:00Z', 'favorites': 3, 'history': 5, 'sessions': 0, 'revision': 8}], 'next': None})
            self.assertEqual(app.user_tree.item('b' * 32)['values'][1], '已禁用')
            app.disconnect()
            self.assertEqual(app.invite_tree.get_children(), ())
            self.assertEqual(app.user_tree.get_children(), ())
        finally:
            root.destroy()


if __name__ == '__main__':
    unittest.main()

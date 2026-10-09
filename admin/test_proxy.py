import socket
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from proxy_transport import ProxyEndpoint, ProxyError, ProxySettings, open_tunnel, parse_proxy, read_system_proxy
from ssh_client import ConnectionSettings, RemoteManager, UnknownHost


class SystemProxyTests(unittest.TestCase):
    def registry(self, values):
        registry = types.SimpleNamespace(HKEY_CURRENT_USER=1)
        registry.OpenKey = Mock()
        registry.OpenKey.return_value.__enter__ = Mock(return_value=registry)
        registry.OpenKey.return_value.__exit__ = Mock(return_value=False)
        def query(key, name):
            if name not in values:
                raise FileNotFoundError()
            return values[name], 1
        registry.QueryValueEx = query
        return registry

    def test_windows_reads_system_proxy_instead_of_environment(self):
        registry = self.registry({'ProxyEnable': 1, 'ProxyServer': '127.0.0.1:8123'})
        with patch('proxy_transport.sys.platform', 'win32'), patch.dict('sys.modules', winreg=registry), patch('proxy_transport.getproxies') as environment:
            self.assertEqual(ProxySettings().resolve(), ProxyEndpoint('127.0.0.1', 8123))
            environment.assert_not_called()

    def test_per_protocol_proxy_and_disabled_system_proxy(self):
        for values, expected in [
            ({'ProxyEnable': 1, 'ProxyServer': 'http=proxy.example:8080;https=127.0.0.1:8123'}, ProxyEndpoint('127.0.0.1', 8123)),
            ({'ProxyEnable': 0, 'ProxyServer': '127.0.0.1:8123'}, None),
        ]:
            with patch('proxy_transport.sys.platform', 'win32'), patch.dict('sys.modules', winreg=self.registry(values)):
                self.assertEqual(read_system_proxy(), expected)

    def test_pac_and_unsupported_system_proxy_require_manual_configuration(self):
        for values in [
            {'ProxyEnable': 0, 'AutoConfigURL': 'http://localhost/proxy.pac'},
            {'ProxyEnable': 1, 'ProxyServer': 'socks=127.0.0.1:8123'},
            {'ProxyEnable': 1},
        ]:
            with patch('proxy_transport.sys.platform', 'win32'), patch.dict('sys.modules', winreg=self.registry(values)):
                with self.assertRaises(ProxyError):
                    read_system_proxy()

    def test_manual_and_direct_do_not_read_system_settings(self):
        with patch('proxy_transport.read_system_proxy', side_effect=AssertionError()):
            self.assertEqual(ProxySettings('manual', 'localhost', 8123).resolve(), ProxyEndpoint('localhost', 8123))
            self.assertIsNone(ProxySettings('direct').resolve())
        for value in ['http://secret:password@localhost:7890', 'localhost:0', 'localhost:65536', 'https://localhost:7890', 'socks5://localhost:7890', 'localhost:7890/path']:
            with self.assertRaises(ProxyError) as raised:
                parse_proxy(value)
            self.assertNotIn('password', str(raised.exception))


class TunnelTests(unittest.TestCase):
    def test_connect_preserves_ssh_banner_and_only_sends_destination(self):
        # Real local sockets exercise framing when headers and SSH bytes arrive
        # in the same packet. No SSH credentials enter the proxy request.
        listener = socket.socket()
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.settimeout(3)
        endpoint = ProxyEndpoint('127.0.0.1', listener.getsockname()[1])
        requests, errors = [], []
        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(3)
                    request = bytearray()
                    while not request.endswith(b'\r\n\r\n'):
                        byte = connection.recv(1)
                        if not byte:
                            raise AssertionError('Unexpected disconnect')
                        request.extend(byte)
                    requests.append(bytes(request))
                    connection.sendall(b'HTTP/1.1 200 Connection established\r\n\r\nSSH-2.0-fixture\r\n')
            except Exception as error:
                errors.append(error)
        server = threading.Thread(target=serve)
        server.start()
        try:
            tunnel = open_tunnel(endpoint, '2001:db8::1', 2222, timeout=3)
            with tunnel:
                banner = bytearray()
                while not banner.endswith(b'\r\n'):
                    byte = tunnel.recv(1)
                    if not byte:
                        break
                    banner.extend(byte)
                self.assertEqual(banner, b'SSH-2.0-fixture\r\n')
        finally:
            listener.close()
            server.join(4)
        self.assertFalse(server.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(requests, [b'CONNECT [2001:db8::1]:2222 HTTP/1.1\r\nHost: [2001:db8::1]:2222\r\n\r\n'])

    def test_rejected_malformed_or_oversized_proxy_response_closes_socket(self):
        for response in [b'HTTP/1.1 403 secret-address\r\n\r\n', b'HTTP/1.1 407 secret-token\r\n\r\n', b'SSH-2.0-wrong-port\r\n\r\n', b'A' * 16385, b'']:
            connection = Mock()
            connection.recv.side_effect = [bytes([byte]) for byte in response] + [b'']
            with patch('proxy_transport.socket.create_connection', return_value=connection):
                with self.assertRaises(ProxyError) as raised:
                    open_tunnel(ProxyEndpoint('localhost', 8123), 'example.com', 22)
                self.assertNotIn('secret', str(raised.exception))
                connection.close.assert_called_once()

    def test_paramiko_uses_tunnel_and_keeps_original_host_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            remote = RemoteManager(Path(directory) / 'known_hosts')
            client, tunnel = Mock(), Mock()
            with patch('ssh_client.paramiko.SSHClient', return_value=client), patch('ssh_client.open_tunnel', return_value=tunnel), patch.object(remote, 'request', return_value={'protocolVersion': 1}):
                remote.connect(ConnectionSettings('example.com', 2222, 'root', 'secret', proxy=ProxySettings('manual', 'localhost', 8123)))
                self.assertEqual(client.connect.call_args.args[0], 'example.com')
                self.assertEqual(client.connect.call_args.kwargs['port'], 2222)
                self.assertIs(client.connect.call_args.kwargs['sock'], tunnel)
                self.assertIsNone(client.set_missing_host_key_policy.call_args.args[0].approved)
                remote.close()

    def test_proxy_failure_never_falls_back_to_direct_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            remote = RemoteManager(Path(directory) / 'known_hosts')
            client = Mock()
            with patch('ssh_client.paramiko.SSHClient', return_value=client), patch('ssh_client.open_tunnel', side_effect=ProxyError('代理连接失败')):
                with self.assertRaises(ProxyError):
                    remote.connect(ConnectionSettings('example.com', 22, 'root', 'secret', proxy=ProxySettings('manual', 'localhost', 8123)))
                client.connect.assert_not_called()
                client.close.assert_called_once()

    def test_rejected_ssh_host_key_closes_proxy_tunnel(self):
        with tempfile.TemporaryDirectory() as directory:
            remote = RemoteManager(Path(directory) / 'known_hosts')
            client, tunnel = Mock(), Mock()
            key = Mock()
            key.asbytes.return_value = b'fixture-key'
            client.connect.side_effect = UnknownHost('example.com', key)
            with patch('ssh_client.paramiko.SSHClient', return_value=client), patch('ssh_client.open_tunnel', return_value=tunnel):
                with self.assertRaises(UnknownHost):
                    remote.connect(ConnectionSettings('example.com', 22, 'root', 'secret', proxy=ProxySettings('manual', 'localhost', 8123)))
                tunnel.close.assert_called_once()

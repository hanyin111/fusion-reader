"""HTTP CONNECT tunnels using explicit settings or the user's system proxy."""
from __future__ import annotations

from dataclasses import dataclass
import re
import socket
import sys
import time
from urllib.parse import urlsplit
from urllib.request import getproxies


class ProxyError(Exception):
    pass


@dataclass(frozen=True)
class ProxyEndpoint:
    host: str
    port: int

    def validate(self):
        if not isinstance(self.host, str) or not re.fullmatch(r'[a-zA-Z0-9_.:\-]{1,253}', self.host) or self.host.startswith('-'):
            raise ProxyError('请输入代理的 IP 或域名，不包含协议和路径。')
        if type(self.port) is not int or not 1 <= self.port <= 65535:
            raise ProxyError('代理端口必须在 1 到 65535 之间。')


def parse_proxy(value):
    try:
        parsed = urlsplit(value if '://' in value else 'http://' + value)
        if parsed.scheme != 'http' or parsed.username is not None or parsed.password is not None or parsed.path not in ('', '/') or parsed.query or parsed.fragment:
            raise ValueError()
        endpoint = ProxyEndpoint(parsed.hostname or '', 80 if parsed.port is None else parsed.port)
        endpoint.validate()
        return endpoint
    except (ValueError, TypeError, ProxyError):
        raise ProxyError('系统代理格式不支持，请选择“手动代理”，填写 HTTP / 混合代理的地址和端口。') from None


def read_system_proxy():
    if sys.platform == 'win32':
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Internet Settings') as key:
                def value(name, default=None):
                    try:
                        return winreg.QueryValueEx(key, name)[0]
                    except FileNotFoundError:
                        return default
                enabled, server, pac = value('ProxyEnable', 0), value('ProxyServer', ''), value('AutoConfigURL', '')
        except FileNotFoundError:
            return None
        except OSError:
            raise ProxyError('无法读取系统代理，请选择“手动代理”填写地址和端口。') from None
        if not enabled:
            if pac:
                raise ProxyError('系统使用自动代理脚本，请选择“手动代理”，填写本机代理地址和端口。')
            return None
        if not isinstance(server, str) or not server.strip():
            raise ProxyError('系统代理已开启，但没有可用地址，请填写手动代理。')
        if '=' in server:
            entries = {name.strip().lower(): address.strip() for part in server.split(';') if '=' in part for name, address in [part.split('=', 1)]}
            server = entries.get('https') or entries.get('http')
            if not server:
                raise ProxyError('系统没有 HTTP 代理入口，请选择“手动代理”，填写 HTTP / 混合代理端口。')
        return parse_proxy(server.strip())
    proxies = getproxies()
    value = proxies.get('https') or proxies.get('http')
    return parse_proxy(value) if value else None


@dataclass(frozen=True)
class ProxySettings:
    mode: str = 'system'
    host: str = '127.0.0.1'
    port: int = 7890

    def validate(self):
        if self.mode not in ('system', 'manual', 'direct'):
            raise ProxyError('请选择有效的连接方式。')
        if self.mode == 'manual':
            ProxyEndpoint(self.host, self.port).validate()

    def resolve(self):
        self.validate()
        if self.mode == 'direct':
            return None
        if self.mode == 'manual':
            return ProxyEndpoint(self.host, self.port)
        return read_system_proxy()


def open_tunnel(proxy, host, port, timeout=12):
    """Leave the SSH banner unread; Paramiko must receive and verify it itself."""
    proxy.validate()
    connection = None
    try:
        connection = socket.create_connection((proxy.host, proxy.port), timeout=timeout)
        authority = f'[{host}]:{port}' if ':' in host else f'{host}:{port}'
        connection.sendall(f'CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n'.encode('ascii'))
        deadline = time.monotonic() + timeout
        headers = bytearray()
        # A buffered reader can consume the SSH banner together with the proxy
        # headers. Read exactly through the delimiter without losing SSH bytes.
        while not headers.endswith(b'\r\n\r\n'):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or len(headers) >= 16384:
                raise ProxyError('代理连接超时或响应异常，请检查代理地址和端口。')
            connection.settimeout(remaining)
            byte = connection.recv(1)
            if not byte:
                raise ProxyError('代理关闭了连接，请检查 HTTP / 混合代理端口。')
            headers.extend(byte)
        status = bytes(headers).split(b'\r\n', 1)[0]
        match = re.fullmatch(rb'HTTP/1\.[01] ([0-9]{3})(?: .*)?', status)
        if match is None:
            raise ProxyError('代理响应格式不正确，请使用 HTTP / 混合代理端口。')
        if match[1] != b'200':
            if match[1] == b'407':
                raise ProxyError('代理要求认证，请使用本机无需认证的代理入口。')
            raise ProxyError('代理未能连接服务器，请检查代理是否允许 SSH 端口连接。')
        connection.settimeout(timeout)
        return connection
    except Exception as error:
        if connection is not None:
            connection.close()
        if isinstance(error, ProxyError):
            raise
        raise ProxyError('代理连接失败，请确认代理已启动，并检查 HTTP / 混合代理地址和端口。') from None

"""SSH transport for the desktop manager. No credentials or host defaults."""
from __future__ import annotations

import base64
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re

import paramiko
from proxy_transport import ProxyError, ProxySettings, open_tunnel


SERVICE_COMMAND = ('/opt/fusion-reader-sync/.venv/bin/python '
                   '/opt/fusion-reader-sync/sync_server.py '
                   '--db /var/lib/fusion-reader-sync/library.sqlite3 admin')
# SQLite WAL files must be created by the service user, including when the
# maintainer logs in as root. Other SSH users need the documented permissions.
REMOTE_COMMAND = ('if [ "$(id -u)" -eq 0 ]; then exec runuser -u fusion-sync -- '
                  + SERVICE_COMMAND + '; else exec ' + SERVICE_COMMAND + '; fi')
MAX_RESPONSE = 2 * 1024 * 1024


class ManagerError(Exception):
    pass


class UnknownHost(ManagerError):
    def __init__(self, hostname, key):
        self.hostname, self.key = hostname, key
        self.fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')
        super().__init__('首次连接需要核对服务器指纹。')


@dataclass(frozen=True)
class ConnectionSettings:
    host: str
    port: int
    username: str
    password: str = ''
    key_filename: str = ''
    proxy: ProxySettings = field(default_factory=ProxySettings)

    def validate(self):
        if not isinstance(self.host, str) or not re.fullmatch(r'[a-zA-Z0-9_.:\-]{1,253}', self.host) or self.host.startswith('-'):
            raise ManagerError('请输入服务器的 IP 或域名，不包含协议和路径。')
        if type(self.port) is not int or not 1 <= self.port <= 65535:
            raise ManagerError('SSH 端口必须在 1 到 65535 之间。')
        if not re.fullmatch(r'[a-zA-Z0-9_\-]{1,32}', self.username):
            raise ManagerError('请输入 SSH 用户名。')
        if self.key_filename and not Path(self.key_filename).is_file():
            raise ManagerError('找不到选择的私钥文件。')
        if not self.key_filename and not self.password:
            raise ManagerError('请填写 SSH 密码或选择私钥。')
        self.proxy.validate()


class VerifyHost(paramiko.MissingHostKeyPolicy):
    def __init__(self, approved=None):
        self.approved = approved

    def missing_host_key(self, client, hostname, key):
        if self.approved is None or hostname != self.approved.hostname or key.asbytes() != self.approved.key.asbytes():
            raise UnknownHost(hostname, key)
        client.get_host_keys().add(hostname, key.get_name(), key)


ERRORS = {'invalid_input': '输入内容不正确。', 'not_found': '记录已不存在，请刷新列表。',
          'already_used': '激活码已被使用，无法撤销。',
          'unknown_action': '服务器管理功能版本较旧，请先更新服务端。',
          'service_unavailable': '服务器暂时无法完成操作，请检查服务或稍后重试。'}


class RemoteManager:
    def __init__(self, known_hosts=None):
        if known_hosts is None:
            base = Path(os.environ.get('LOCALAPPDATA', str(Path.home() / '.local' / 'share')))
            known_hosts = base / 'FusionReaderAdmin' / 'known_hosts'
        self.known_hosts = Path(known_hosts)
        self.client = None

    def connect(self, settings, approved=None):
        settings.validate()
        self.close()
        client = paramiko.SSHClient()
        system_hosts = Path.home() / '.ssh' / 'known_hosts'
        if system_hosts.is_file():
            client.load_system_host_keys(str(system_hosts))
        if self.known_hosts.is_file():
            client.load_host_keys(str(self.known_hosts))
        client.set_missing_host_key_policy(VerifyHost(approved))
        proxy_socket = None
        try:
            proxy = settings.proxy.resolve()
            if proxy is not None:
                proxy_socket = open_tunnel(proxy, settings.host, settings.port)
            client.connect(settings.host, port=settings.port, username=settings.username,
                           password=settings.password or None,
                           key_filename=settings.key_filename or None,
                           look_for_keys=False, allow_agent=False, timeout=12,
                           banner_timeout=15, auth_timeout=15,
                           passphrase=settings.password if settings.key_filename else None,
                           sock=proxy_socket)
            if approved is not None:
                self.known_hosts.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                client.save_host_keys(str(self.known_hosts))
                if os.name != 'nt':
                    self.known_hosts.chmod(0o600)
            client.get_transport().set_keepalive(30)
            self.client = client
            info = self.request('info')
            if info.get('protocolVersion') != 1:
                raise ManagerError('服务器管理功能版本不兼容，请先更新服务端。')
        except Exception:
            client.close()
            if proxy_socket is not None:
                proxy_socket.close()
            self.client = None
            raise

    def request(self, action, **fields):
        if self.client is None:
            raise ManagerError('请先连接服务器。')
        payload = json.dumps({'action': action, **fields}, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(payload) > 8192:
            raise ManagerError('输入内容过长。')
        stdin, stdout, stderr = self.client.exec_command(REMOTE_COMMAND, timeout=30)
        channel = stdout.channel
        try:
            stdin.write(payload)
            stdin.flush()
            channel.shutdown_write()
            data = stdout.read(MAX_RESPONSE + 1)
            # Never surface stderr: it may contain host paths or private data.
            if len(data) > MAX_RESPONSE or channel.recv_exit_status() != 0:
                raise ManagerError('无法执行服务器管理命令，请检查服务端安装和 SSH 权限。')
            result = json.loads(data.decode('utf-8'))
            if not isinstance(result, dict) or type(result.get('ok')) is not bool:
                raise ManagerError('服务器管理响应格式不正确。')
            if not result['ok']:
                raise ManagerError(ERRORS.get(result.get('error'), '服务器未能完成操作。'))
            value = result.get('result')
            if not isinstance(value, dict):
                raise ManagerError('服务器管理响应格式不正确。')
            return value
        except (UnicodeError, ValueError):
            raise ManagerError('服务器管理响应格式不正确。') from None
        finally:
            channel.close()

    def close(self):
        if self.client is not None:
            self.client.close()
            self.client = None


def safe_error(error):
    if isinstance(error, (ManagerError, ProxyError)):
        return str(error)
    if isinstance(error, paramiko.BadHostKeyException):
        return '服务器指纹与已信任记录不同，已停止连接。请先核对是否更换了服务器密钥。'
    if isinstance(error, paramiko.AuthenticationException):
        return 'SSH 登录失败，请核对用户名、密码或私钥。'
    if isinstance(error, (OSError, TimeoutError, paramiko.SSHException)):
        return '服务器连接中断或超时，请检查地址、端口和网络。'
    return '操作未能完成，请重试。'

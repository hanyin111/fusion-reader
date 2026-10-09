"""Small WSGI sync API. Production: Gunicorn behind HTTPS, bound to loopback.

SQLite, password hashing and random session/invite tokens use Python's standard
library. No source credentials or downloaded books are stored here.
"""
from __future__ import annotations

import argparse
from collections import OrderedDict, deque
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
from http import HTTPStatus

MAX_BYTES = 20 * 1024 * 1024
MAX_RECORDS = 50000
MAX_INTEGER = 9007199254740991
SESSION_SECONDS = 30 * 86400


class ApiError(Exception):
    def __init__(self, status: int, code: str):
        self.status, self.code = status, code


def utc_string(timestamp: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if timestamp is None else timestamp,
                                  timezone.utc).isoformat().replace('+00:00', 'Z')


def token_hash(value: str) -> str:
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def password_hash(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(password.encode('utf-8'), salt=salt, n=32768, r=8,
                          p=1, dklen=32, maxmem=64 * 1024 * 1024)


def json_bytes(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'),
                      allow_nan=False).encode('utf-8')


def reject_nonfinite(_):
    raise ValueError('Non-finite number')


def integer(value, maximum=MAX_INTEGER) -> int:
    if type(value) is not int or not 0 <= value <= maximum:
        raise ApiError(400, 'invalid_input')
    return value


def text(value, *, required=False, optional=False, maximum=131072) -> str:
    if optional and value is None:
        return ''
    if not isinstance(value, str) or len(value.encode('utf-16-le')) // 2 > maximum:
        raise ApiError(400, 'invalid_input')
    if required and not value.strip():
        raise ApiError(400, 'invalid_input')
    return value


def item(raw) -> dict:
    if not isinstance(raw, dict):
        raise ApiError(400, 'invalid_input')
    package = text(raw.get('package'), required=True)
    media_type = text(raw.get('type'), required=True)
    if package == 'local' or '|' in package or package != package.strip() or media_type not in ('manga', 'novel', 'anime'):
        raise ApiError(400, 'invalid_input')
    return {'package': package, 'type': media_type, 'title': text(raw.get('title')),
            'url': text(raw.get('url'), required=True),
            'cover': text(raw.get('cover'), optional=True),
            'update': text(raw.get('update'), optional=True)}


def validate_snapshot(raw) -> dict:
    if not isinstance(raw, dict) or raw.get('format') != 'FusionReader.library' or type(raw.get('schemaVersion')) is not int or raw['schemaVersion'] != 1:
        raise ApiError(400, 'invalid_input')
    exported = text(raw.get('exportedAt'), required=True)
    try:
        datetime.fromisoformat(exported.replace('Z', '+00:00'))
    except ValueError:
        raise ApiError(400, 'invalid_input') from None
    favorites, history = raw.get('favorites'), raw.get('history')
    if not isinstance(favorites, list) or not isinstance(history, list):
        raise ApiError(400, 'invalid_input')
    if len(favorites) + len(history) > MAX_RECORDS:
        raise ApiError(413, 'payload_too_large')
    favorites = [item(value) for value in favorites]
    clean_history = []
    for record in history:
        if not isinstance(record, dict):
            raise ApiError(400, 'invalid_input')
        key = text(record.get('key'), required=True)
        package, separator, url = key.partition('|')
        if not separator or not package or not url or package != package.strip() or package == 'local':
            raise ApiError(400, 'invalid_input')
        metadata = None if record.get('item') is None else item(record['item'])
        if metadata is not None and f"{metadata['package']}|{metadata['url']}" != key:
            raise ApiError(400, 'invalid_input')
        clean_history.append({
            'key': key, 'item': metadata,
            'episodeUrl': text(record.get('episodeUrl')),
            'episodeName': text(record.get('episodeName')),
            'groupIndex': integer(record.get('groupIndex')),
            'episodeIndex': integer(record.get('episodeIndex')),
            'timestamp': integer(record.get('timestamp'), 253402300799999),
            'position': integer(record.get('position', 0)),
            'textOffset': integer(record.get('textOffset', 0)),
        })
    cleaned = {'format': 'FusionReader.library', 'schemaVersion': 1,
               'exportedAt': exported, 'favorites': favorites, 'history': clean_history,
               'excludedLocalFavorites': integer(raw.get('excludedLocalFavorites', 0)),
               'excludedLocalHistory': integer(raw.get('excludedLocalHistory', 0))}
    if len(json_bytes(cleaned)) > MAX_BYTES:
        raise ApiError(413, 'payload_too_large')
    return cleaned


def empty_snapshot() -> dict:
    return {'format': 'FusionReader.library', 'schemaVersion': 1,
            'exportedAt': utc_string(), 'favorites': [], 'history': [],
            'excludedLocalFavorites': 0, 'excludedLocalHistory': 0}


class RateLimit:
    """Bounded, process-local rolling windows; deploy with exactly one worker."""
    def __init__(self):
        self.entries = OrderedDict()
        self.lock = threading.Lock()

    def check(self, key: str, count: int, seconds=60):
        now = time.monotonic()
        with self.lock:
            queue = self.entries.setdefault(key, deque())
            self.entries.move_to_end(key)
            while queue and queue[0] <= now - seconds:
                queue.popleft()
            if len(queue) >= count:
                raise ApiError(429, 'rate_limited')
            queue.append(now)
            while len(self.entries) > 4096:
                self.entries.popitem(last=False)


class SyncApp:
    def __init__(self, db_path: str | Path, *, trusted_proxy: str = ''):
        self.db_path = str(db_path)
        Path(db_path).parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.trusted_proxy = trusted_proxy
        self.limits = RateLimit()
        self.hash_slot = threading.BoundedSemaphore(1)
        with closing(self.connect()) as db:
            version = db.execute('PRAGMA user_version').fetchone()[0]
            if version not in (0, 1, 2):
                raise RuntimeError('Unsupported database version')
            if version == 0 and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").fetchone():
                raise RuntimeError('Refusing to use an unrelated database')
            db.execute('PRAGMA journal_mode=WAL')
            # All schema changes and old invite IDs commit together, including
            # simultaneous starts by Gunicorn and the SSH management command.
            with db:
                db.execute('BEGIN IMMEDIATE')
                version = db.execute('PRAGMA user_version').fetchone()[0]
                if version == 0:
                    for statement in '''
                CREATE TABLE IF NOT EXISTS users (
                    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE,
                    salt BLOB NOT NULL, password_hash BLOB NOT NULL, created_at INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS invites (
                    code_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL,
                    used_by TEXT REFERENCES users(id), used_at INTEGER);
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
                    expires_at INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS session_user ON sessions(user_id);
                CREATE TABLE IF NOT EXISTS libraries (
                    user_id TEXT PRIMARY KEY REFERENCES users(id), revision INTEGER NOT NULL DEFAULT 0,
                    snapshot TEXT NOT NULL, updated_at INTEGER NOT NULL);
                    '''.split(';'):
                        if statement.strip():
                            db.execute(statement)
                    version = 1
                if version == 1:
                    db.execute('ALTER TABLE users ADD COLUMN disabled INTEGER NOT NULL DEFAULT 0 CHECK(disabled IN (0,1))')
                    db.execute('ALTER TABLE invites ADD COLUMN invite_id TEXT')
                    db.execute('ALTER TABLE invites ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0')
                    db.execute('ALTER TABLE invites ADD COLUMN revoked_at INTEGER')
                    for row in db.execute('SELECT code_hash FROM invites').fetchall():
                        db.execute('UPDATE invites SET invite_id=? WHERE code_hash=?',
                                   (secrets.token_hex(8), row['code_hash']))
                    db.execute('CREATE UNIQUE INDEX invite_management_id ON invites(invite_id)')
                    db.execute('PRAGMA user_version=2')
        if os.name != 'nt':
            os.chmod(self.db_path, 0o600)

    def connect(self):
        db = sqlite3.connect(self.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        db.execute('PRAGMA trusted_schema=OFF')
        return db

    def invite(self, *, days=30) -> str:
        code = secrets.token_urlsafe(24)
        with closing(self.connect()) as db, db:
            db.execute('INSERT INTO invites(code_hash,expires_at,invite_id,created_at) VALUES(?,?,?,?)',
                       (token_hash(code), int(time.time()) + days * 86400, secrets.token_hex(8), int(time.time())))
        return code

    def _client_ip(self, environ):
        address = environ.get('REMOTE_ADDR', '')
        if self.trusted_proxy and address == self.trusted_proxy:
            candidate = environ.get('HTTP_X_REAL_IP', '')
            try:
                address = str(ipaddress.ip_address(candidate))
            except ValueError:
                pass
        return address

    def _body(self, environ, *, limit=MAX_BYTES + 262144):
        if environ.get('CONTENT_TYPE', '').split(';')[0].strip().lower() != 'application/json':
            raise ApiError(400, 'invalid_input')
        try:
            size = int(environ.get('CONTENT_LENGTH', ''))
        except ValueError:
            raise ApiError(400, 'invalid_input') from None
        if size > limit:
            raise ApiError(413, 'payload_too_large')
        if size <= 0:
            raise ApiError(400, 'invalid_input')
        data = environ['wsgi.input'].read(size)
        if len(data) != size:
            raise ApiError(400, 'invalid_input')
        try:
            value = json.loads(data.decode('utf-8'), parse_constant=reject_nonfinite)
        except (ValueError, RecursionError, UnicodeError):
            raise ApiError(400, 'invalid_input') from None
        if not isinstance(value, dict):
            raise ApiError(400, 'invalid_input')
        return value

    def _user(self, db, environ):
        bearer = environ.get('HTTP_AUTHORIZATION', '')
        if not re.fullmatch(r'Bearer [A-Za-z0-9_-]{32,1024}', bearer):
            raise ApiError(401, 'invalid_credentials')
        digest = token_hash(bearer[7:])
        row = db.execute('SELECT u.id,u.username FROM sessions s JOIN users u ON u.id=s.user_id '
                         'WHERE s.token_hash=? AND s.expires_at>? AND u.disabled=0', (digest, int(time.time()))).fetchone()
        if row is None:
            raise ApiError(401, 'invalid_credentials')
        return row, digest

    def _session(self, db, user_id, username):
        token = secrets.token_urlsafe(32)
        expiry = int(time.time()) + SESSION_SECONDS
        db.execute('DELETE FROM sessions WHERE expires_at<=?', (int(time.time()),))
        db.execute('INSERT INTO sessions VALUES(?,?,?)', (token_hash(token), user_id, expiry))
        # Keep the ten newest logins per user; no unbounded token growth.
        db.execute('DELETE FROM sessions WHERE user_id=? AND token_hash NOT IN '
                   '(SELECT token_hash FROM sessions WHERE user_id=? ORDER BY expires_at DESC,rowid DESC LIMIT 10)', (user_id, user_id))
        return {'user': {'id': user_id, 'username': username}, 'token': token,
                'expiresAt': utc_string(expiry)}

    def _auth(self, environ, register):
        self.limits.check('auth-ip:' + self._client_ip(environ), 10)
        body = self._body(environ, limit=4096)
        username = text(body.get('username'), required=True, maximum=32).strip().lower()
        password = text(body.get('password'), required=True, maximum=128)
        if not re.fullmatch(r'[a-z0-9_]{3,32}', username) or len(password.encode('utf-16-le')) // 2 < 8:
            raise ApiError(400, 'invalid_input')
        self.limits.check('auth-user:' + username, 10)
        if not self.hash_slot.acquire(blocking=False):
            raise ApiError(429, 'rate_limited')
        try:
            with closing(self.connect()) as db:
                if register:
                    code = text(body.get('activationCode'), required=True, maximum=128).strip()
                    digest = token_hash(code)
                    invite = db.execute('SELECT * FROM invites WHERE code_hash=?', (digest,)).fetchone()
                    if invite is None or invite['used_by'] is not None or invite['revoked_at'] is not None or invite['expires_at'] <= time.time():
                        raise ApiError(403, 'invalid_activation_code')
                    salt = secrets.token_bytes(16)
                    hashed = password_hash(password, salt)
                    user_id = secrets.token_hex(16)
                    with db:
                        db.execute('BEGIN IMMEDIATE')
                        # Recheck and consume in the same transaction as creating the user.
                        invite = db.execute('SELECT * FROM invites WHERE code_hash=?', (digest,)).fetchone()
                        if invite is None or invite['used_by'] is not None or invite['revoked_at'] is not None or invite['expires_at'] <= time.time():
                            raise ApiError(403, 'invalid_activation_code')
                        try:
                            db.execute('INSERT INTO users(id,username,salt,password_hash,created_at) VALUES(?,?,?,?,?)', (user_id, username, salt, hashed, int(time.time())))
                        except sqlite3.IntegrityError:
                            raise ApiError(409, 'username_taken') from None
                        db.execute('UPDATE invites SET used_by=?,used_at=? WHERE code_hash=?', (user_id, int(time.time()), digest))
                        db.execute('INSERT INTO libraries VALUES(?,0,?,?)', (user_id, json_bytes(empty_snapshot()).decode(), int(time.time())))
                        return 201, self._session(db, user_id, username)
                user = db.execute('SELECT * FROM users WHERE username=?', (username,)).fetchone()
                hashed = password_hash(password, user['salt'] if user else b'fusion-dummy-v1__')
                if user is None or user['disabled'] or not hmac.compare_digest(hashed, user['password_hash']):
                    raise ApiError(401, 'invalid_credentials')
                with db:
                    db.execute('BEGIN IMMEDIATE')
                    current = db.execute('SELECT disabled,password_hash FROM users WHERE id=?', (user['id'],)).fetchone()
                    if current is None or current['disabled'] or not hmac.compare_digest(hashed, current['password_hash']):
                        raise ApiError(401, 'invalid_credentials')
                    return 200, self._session(db, user['id'], user['username'])
        finally:
            self.hash_slot.release()

    def dispatch(self, environ):
        method, path = environ.get('REQUEST_METHOD'), environ.get('PATH_INFO')
        if environ.get('QUERY_STRING'):
            raise ApiError(400, 'invalid_input')
        if method == 'GET' and path == '/health':
            return 200, {'ok': True, 'schemaVersion': 1}
        if method == 'POST' and path in ('/v1/auth/register', '/v1/auth/login'):
            return self._auth(environ, path.endswith('/register'))
        if (method, path) not in (('GET', '/v1/library'), ('PUT', '/v1/library'), ('POST', '/v1/auth/logout')):
            raise ApiError(404, 'not_found')
        self.limits.check('api-ip:' + self._client_ip(environ), 120)
        with closing(self.connect()) as db:
            user, digest = self._user(db, environ)
            if path == '/v1/auth/logout':
                with db:
                    db.execute('DELETE FROM sessions WHERE token_hash=?', (digest,))
                return 200, {'ok': True}
            if method == 'GET':
                library = db.execute('SELECT revision,snapshot FROM libraries WHERE user_id=?', (user['id'],)).fetchone()
                return 200, {'revision': library['revision'], 'snapshot': json.loads(library['snapshot'])}
            body = self._body(environ)
            revision = integer(body.get('expectedRevision'), MAX_INTEGER - 1)
            snapshot = validate_snapshot(body.get('snapshot'))
            with db:
                db.execute('BEGIN IMMEDIATE')
                # A reset/disable may have invalidated this session while a
                # large upload was being parsed. Recheck under the write lock.
                self._user(db, environ)
                changed = db.execute('UPDATE libraries SET snapshot=?,revision=revision+1,updated_at=? '
                                     'WHERE user_id=? AND revision=?',
                                     (json_bytes(snapshot).decode(), int(time.time()), user['id'], revision))
                if changed.rowcount != 1:
                    raise ApiError(409, 'revision_conflict')
            return 200, {'revision': revision + 1}

    def __call__(self, environ, start_response):
        try:
            status, body = self.dispatch(environ)
        except ApiError as error:
            status, body = error.status, {'error': error.code}
        except (UnicodeError, RecursionError):
            status, body = 400, {'error': 'invalid_input'}
        except sqlite3.OperationalError:
            status, body = 503, {'error': 'service_unavailable'}
        except Exception:
            # Never include request bodies, passwords, tokens, or SQL in responses.
            status, body = 500, {'error': 'internal_error'}
        payload = json_bytes(body)
        headers = [('Content-Type', 'application/json; charset=utf-8'),
                   ('Content-Length', str(len(payload))), ('Cache-Control', 'no-store'),
                   ('X-Content-Type-Options', 'nosniff')]
        if status == 429:
            headers.append(('Retry-After', '60'))
        start_response(f'{status} {HTTPStatus(status).phrase}', headers)
        return [payload]


def create_app():
    return SyncApp(os.environ.get('FUSION_SYNC_DB', 'data/library.sqlite3'),
                   trusted_proxy=os.environ.get('FUSION_SYNC_TRUSTED_PROXY', ''))


def main():
    parser = argparse.ArgumentParser(description='FusionReader account sync administration')
    parser.add_argument('--db', default=os.environ.get('FUSION_SYNC_DB', 'data/library.sqlite3'))
    commands = parser.add_subparsers(dest='command', required=True)
    invite = commands.add_parser('invite', help='Print new one-time activation codes')
    invite.add_argument('--count', type=int, default=1)
    invite.add_argument('--days', type=int, default=30)
    commands.add_parser('users', help='List account names and creation times; no tokens')
    commands.add_parser('admin', help='SSH-only management JSON request on stdin; no public API')
    backup = commands.add_parser('backup', help='Create a consistent SQLite backup')
    backup.add_argument('destination')
    args = parser.parse_args()
    app = SyncApp(args.db)
    if args.command == 'invite':
        if not 1 <= args.count <= 100 or not 1 <= args.days <= 365:
            parser.error('count must be 1–100 and days 1–365')
        for _ in range(args.count):
            print(app.invite(days=args.days))
    elif args.command == 'users':
        with closing(app.connect()) as db:
            for row in db.execute('SELECT username,created_at FROM users ORDER BY created_at'):
                print(row['username'], utc_string(row['created_at']))
    elif args.command == 'backup':
        target = Path(args.destination)
        if target.exists() or target.resolve() == Path(args.db).resolve():
            parser.error('destination must be a new file')
        target.parent.mkdir(parents=True, exist_ok=True)
        with closing(app.connect()) as source, closing(sqlite3.connect(target)) as destination:
            source.backup(destination)
        if os.name != 'nt':
            target.chmod(0o600)
    elif args.command == 'admin':
        from admin_commands import handle_stdin
        handle_stdin(app)


if __name__ == '__main__':
    main()

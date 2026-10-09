"""Private management protocol: authenticated SSH process stdin, never HTTP.

No command arguments contain passwords or activation codes. Existing invite
plaintext cannot be recovered because the service stores only SHA-256 hashes.
"""
from __future__ import annotations

from contextlib import closing
import hmac
import json
import re
import secrets
import sys
import time

from sync_server import password_hash, token_hash, utc_string


class AdminError(ValueError):
    pass


def bounded_integer(value, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise AdminError('invalid_input')
    return value


def identifier(value, length):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{%d}' % length, value):
        raise AdminError('invalid_input')
    return value


def timestamp(value):
    return utc_string(value) if value else None


def invite_info(row):
    state = ('used' if row['used_by'] is not None else
             'revoked' if row['revoked_at'] is not None else
             'expired' if row['expires_at'] <= time.time() else 'unused')
    return {'id': row['invite_id'], 'status': state,
            'username': row['username'], 'createdAt': timestamp(row['created_at']),
            'expiresAt': timestamp(row['expires_at']),
            'usedAt': timestamp(row['used_at']), 'revokedAt': timestamp(row['revoked_at'])}


class AdminManager:
    def __init__(self, app):
        self.app = app

    def execute(self, body):
        if not isinstance(body, dict) or not isinstance(body.get('action'), str):
            raise AdminError('invalid_input')
        action = body['action']
        with closing(self.app.connect()) as db:
            if action == 'info':
                return {'protocolVersion': 1, 'databaseVersion': db.execute('PRAGMA user_version').fetchone()[0]}
            if action == 'invites.create':
                count = bounded_integer(body.get('count'), 1, 100)
                days = bounded_integer(body.get('days'), 1, 365)
                now = int(time.time())
                generated = []
                with db:
                    db.execute('BEGIN IMMEDIATE')
                    for _ in range(count):
                        code, invite_id = secrets.token_urlsafe(24), secrets.token_hex(8)
                        db.execute('INSERT INTO invites(code_hash,expires_at,invite_id,created_at) VALUES(?,?,?,?)',
                                   (token_hash(code), now + days * 86400, invite_id, now))
                        generated.append({'id': invite_id, 'code': code,
                                          'createdAt': utc_string(now),
                                          'expiresAt': utc_string(now + days * 86400)})
                return {'invites': generated}
            if action in ('invites.list', 'users.list'):
                after = bounded_integer(body.get('after', 0), 0, 2**63 - 1)
                limit = bounded_integer(body.get('limit', 100), 1, 500)
                if action == 'invites.list':
                    rows = db.execute('SELECT i.rowid AS cursor,i.*,u.username FROM invites i '
                                      'LEFT JOIN users u ON u.id=i.used_by WHERE i.rowid>? '
                                      'ORDER BY i.rowid LIMIT ?', (after, limit + 1)).fetchall()
                    values = [invite_info(row) for row in rows[:limit]]
                else:
                    rows = db.execute('SELECT u.rowid AS cursor,u.id,u.username,u.created_at,u.disabled,'
                                      'COALESCE(json_array_length(l.snapshot,\'$.favorites\'),0) AS favorites,'
                                      'COALESCE(json_array_length(l.snapshot,\'$.history\'),0) AS history,'
                                      'COALESCE(l.revision,0) AS revision,'
                                      '(SELECT count(*) FROM sessions s WHERE s.user_id=u.id AND s.expires_at>?) AS sessions '
                                      'FROM users u LEFT JOIN libraries l ON l.user_id=u.id '
                                      'WHERE u.rowid>? ORDER BY u.rowid LIMIT ?',
                                      (int(time.time()), after, limit + 1)).fetchall()
                    values = [{'id': row['id'], 'username': row['username'],
                               'createdAt': utc_string(row['created_at']),
                               'enabled': not bool(row['disabled']), 'favorites': row['favorites'],
                               'history': row['history'], 'sessions': row['sessions'],
                               'revision': row['revision']} for row in rows[:limit]]
                return {'items': values, 'next': rows[limit - 1]['cursor'] if len(rows) > limit else None}
            if action == 'invites.check':
                code = body.get('code')
                if not isinstance(code, str) or not 1 <= len(code.strip()) <= 128:
                    raise AdminError('invalid_input')
                row = db.execute('SELECT i.*,u.username FROM invites i LEFT JOIN users u ON u.id=i.used_by '
                                 'WHERE i.code_hash=?', (token_hash(code.strip()),)).fetchone()
                return {'invite': invite_info(row) if row else None}
            if action == 'invites.revoke':
                invite_id = identifier(body.get('id'), 16)
                with db:
                    db.execute('BEGIN IMMEDIATE')
                    row = db.execute('SELECT used_by FROM invites WHERE invite_id=?', (invite_id,)).fetchone()
                    if row is None:
                        raise AdminError('not_found')
                    if row['used_by'] is not None:
                        raise AdminError('already_used')
                    db.execute('UPDATE invites SET revoked_at=COALESCE(revoked_at,?) WHERE invite_id=?',
                               (int(time.time()), invite_id))
                return {'ok': True}
            if action in ('users.set_enabled', 'users.revoke_sessions', 'users.reset_password'):
                user_id = identifier(body.get('id'), 32)
                enabled = None
                salt = hashed = None
                if action == 'users.set_enabled':
                    enabled = body.get('enabled')
                    if type(enabled) is not bool:
                        raise AdminError('invalid_input')
                if action == 'users.reset_password':
                    password = body.get('password')
                    if not isinstance(password, str) or not 8 <= len(password.encode('utf-16-le')) // 2 <= 128 or not password.strip():
                        raise AdminError('invalid_input')
                    salt = secrets.token_bytes(16)
                    hashed = password_hash(password, salt)
                with db:
                    db.execute('BEGIN IMMEDIATE')
                    if db.execute('SELECT 1 FROM users WHERE id=?', (user_id,)).fetchone() is None:
                        raise AdminError('not_found')
                    if enabled is not None:
                        db.execute('UPDATE users SET disabled=? WHERE id=?', (int(not enabled), user_id))
                    if hashed is not None:
                        db.execute('UPDATE users SET salt=?,password_hash=? WHERE id=?', (salt, hashed, user_id))
                    if action != 'users.set_enabled' or not enabled:
                        db.execute('DELETE FROM sessions WHERE user_id=?', (user_id,))
                return {'ok': True}
        raise AdminError('unknown_action')


def handle_stdin(app, source=None, output=None):
    source = source or sys.stdin.buffer
    output = output or sys.stdout
    try:
        data = source.read(8193)
        if len(data) > 8192:
            raise AdminError('invalid_input')
        body = json.loads(data.decode('utf-8'))
        result = {'ok': True, 'result': AdminManager(app).execute(body)}
    except (ValueError, UnicodeError) as error:
        code = str(error) if isinstance(error, AdminError) else 'invalid_input'
        result = {'ok': False, 'error': code}
    except Exception:
        # Never serialize exceptions: they could contain request data or paths.
        result = {'ok': False, 'error': 'service_unavailable'}
    output.write(json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n')
    output.flush()

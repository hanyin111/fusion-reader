from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

from admin_commands import AdminError, AdminManager, handle_stdin
from sync_server import SyncApp, empty_snapshot, json_bytes, password_hash, token_hash
from test_server import request


class AdminTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='fusion_admin_test_')
        self.path = Path(self.directory.name) / 'library.sqlite3'
        self.app = SyncApp(self.path)
        self.manager = AdminManager(self.app)

    def tearDown(self):
        self.directory.cleanup()

    def command(self, action, **fields):
        return self.manager.execute({'action': action, **fields})

    def register(self):
        code = self.app.invite()
        status, result, _ = request(self.app, 'POST', '/v1/auth/register', {
            'username': 'reader', 'password': 'fixture-password', 'activationCode': code})
        self.assertEqual(status, 201)
        return code, result

    def test_invite_batch_only_hashes_persist_and_original_check_works(self):
        result = self.command('invites.create', count=3, days=7)['invites']
        self.assertEqual(len({row['code'] for row in result}), 3)
        listed = self.command('invites.list')['items']
        self.assertEqual([row['status'] for row in listed], ['unused'] * 3)
        self.assertNotIn('code', listed[0])
        checked = self.command('invites.check', code=result[0]['code'])['invite']
        self.assertEqual(checked['id'], result[0]['id'])
        with closing(self.app.connect()) as db:
            rows = str([dict(row) for row in db.execute('SELECT * FROM invites')])
            for value in result:
                self.assertNotIn(value['code'], rows)
        self.assertIsNone(self.command('invites.check', code='missing')['invite'])

    def test_batch_failure_rolls_back_all_codes(self):
        with patch('admin_commands.secrets.token_hex', return_value='a' * 16):
            with self.assertRaises(sqlite3.IntegrityError):
                self.command('invites.create', count=2, days=30)
        self.assertEqual(self.command('invites.list')['items'], [])

    def test_invite_used_expired_revoked_and_revoke_blocks_registration(self):
        code, session = self.register()
        used = self.command('invites.check', code=code)['invite']
        self.assertEqual((used['status'], used['username']), ('used', 'reader'))
        with self.assertRaisesRegex(AdminError, 'already_used'):
            self.command('invites.revoke', id=used['id'])
        fresh = self.command('invites.create', count=2, days=30)['invites']
        self.command('invites.revoke', id=fresh[0]['id'])
        self.assertEqual(self.command('invites.check', code=fresh[0]['code'])['invite']['status'], 'revoked')
        self.assertEqual(request(self.app, 'POST', '/v1/auth/register', {'username': 'other', 'password': 'fixture-password', 'activationCode': fresh[0]['code']})[0], 403)
        with closing(self.app.connect()) as db, db:
            db.execute('UPDATE invites SET expires_at=1 WHERE invite_id=?', (fresh[1]['id'],))
        self.assertEqual(self.command('invites.check', code=fresh[1]['code'])['invite']['status'], 'expired')

    def test_disable_invalidates_sessions_and_enable_preserves_library(self):
        _, session = self.register()
        user_id, token = session['user']['id'], session['token']
        snapshot = empty_snapshot()
        snapshot['favorites'] = [{'package': 'fixture', 'type': 'novel', 'title': 'book', 'url': '/book'}]
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': snapshot}, token)[0], 200)
        before = self.command('users.list')['items'][0]
        self.assertEqual((before['favorites'], before['history'], before['sessions']), (1, 0, 1))
        self.command('users.set_enabled', id=user_id, enabled=False)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=token)[0], 401)
        self.assertEqual(request(self.app, 'POST', '/v1/auth/login', {'username': 'reader', 'password': 'fixture-password'})[0], 401)
        self.assertFalse(self.command('users.list')['items'][0]['enabled'])
        self.command('users.set_enabled', id=user_id, enabled=True)
        logged = request(self.app, 'POST', '/v1/auth/login', {'username': 'reader', 'password': 'fixture-password'})
        self.assertEqual(logged[0], 200)
        self.assertEqual(len(request(self.app, 'GET', '/v1/library', token=logged[1]['token'])[1]['snapshot']['favorites']), 1)

    def test_reset_password_and_expire_sessions_no_plaintext_response(self):
        _, session = self.register()
        user_id = session['user']['id']
        self.command('users.revoke_sessions', id=user_id)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=session['token'])[0], 401)
        logged = request(self.app, 'POST', '/v1/auth/login', {'username': 'reader', 'password': 'fixture-password'})[1]
        result = self.command('users.reset_password', id=user_id, password='new-fixture-password')
        self.assertEqual(result, {'ok': True})
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=logged['token'])[0], 401)
        self.assertEqual(request(self.app, 'POST', '/v1/auth/login', {'username': 'reader', 'password': 'fixture-password'})[0], 401)
        self.assertEqual(request(self.app, 'POST', '/v1/auth/login', {'username': 'reader', 'password': 'new-fixture-password'})[0], 200)
        with closing(self.app.connect()) as db:
            self.assertNotIn('new-fixture-password', str(dict(db.execute('SELECT * FROM users').fetchone())))

    def test_pagination_no_hashes_tokens_or_shelf_contents(self):
        self.command('invites.create', count=3, days=30)
        page = self.command('invites.list', limit=2)
        self.assertIsNotNone(page['next'])
        remaining = self.command('invites.list', after=page['next'], limit=2)
        self.assertEqual(len(remaining['items']), 1)
        self.assertIsNone(remaining['next'])
        _, session = self.register()
        encoded = json.dumps(self.command('users.list'))
        for field in ['password_hash', 'salt', 'token_hash', session['token'], 'snapshot']:
            self.assertNotIn(field, encoded)

    def test_private_protocol_validates_and_never_exposes_traceback(self):
        for payload in [b'{', b'x' * 8193, b'{"action":"invites.create","count":true,"days":1}', b'{"action":"users.reset_password","id":"invalid","password":"sensitive-password"}']:
            output = io.StringIO()
            handle_stdin(self.app, io.BytesIO(payload), output)
            value = json.loads(output.getvalue())
            self.assertFalse(value['ok'])
            self.assertNotIn('sensitive-password', output.getvalue())
            self.assertNotIn('Traceback', output.getvalue())
        self.assertEqual(request(self.app, 'POST', '/v1/admin', {})[0], 404)

    def test_v1_migration_preserves_accounts_invites_sessions_and_snapshot(self):
        old = Path(self.directory.name) / 'v1.sqlite3'
        user_id, code, token = '1' * 32, 'old-fixture-code', 'a' * 40
        salt, now = b'fixture-salt-1234', int(time.time())
        with closing(sqlite3.connect(old)) as db, db:
            db.executescript('''
                CREATE TABLE users(id TEXT PRIMARY KEY,username TEXT NOT NULL UNIQUE,salt BLOB NOT NULL,password_hash BLOB NOT NULL,created_at INTEGER NOT NULL);
                CREATE TABLE invites(code_hash TEXT PRIMARY KEY,expires_at INTEGER NOT NULL,used_by TEXT REFERENCES users(id),used_at INTEGER);
                CREATE TABLE sessions(token_hash TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),expires_at INTEGER NOT NULL);
                CREATE INDEX session_user ON sessions(user_id);
                CREATE TABLE libraries(user_id TEXT PRIMARY KEY REFERENCES users(id),revision INTEGER NOT NULL DEFAULT 0,snapshot TEXT NOT NULL,updated_at INTEGER NOT NULL);
                PRAGMA user_version=1;
            ''')
            db.execute('INSERT INTO users VALUES(?,?,?,?,?)', (user_id, 'reader', salt, password_hash('fixture-password', salt), now))
            db.execute('INSERT INTO invites VALUES(?,?,?,?)', (token_hash(code), now + 86400, user_id, now))
            db.execute('INSERT INTO sessions VALUES(?,?,?)', (token_hash(token), user_id, now + 86400))
            db.execute('INSERT INTO libraries VALUES(?,?,?,?)', (user_id, 7, json_bytes(empty_snapshot()).decode(), now))
        app = SyncApp(old)
        manager = AdminManager(app)
        checked = manager.execute({'action': 'invites.check', 'code': code})['invite']
        self.assertEqual((checked['status'], checked['username'], checked['createdAt']), ('used', 'reader', None))
        self.assertEqual(len(checked['id']), 16)
        self.assertEqual(request(app, 'GET', '/v1/library', token=token)[1]['revision'], 7)
        self.assertEqual(request(app, 'POST', '/v1/auth/login', {'username': 'reader', 'password': 'fixture-password'})[0], 200)
        restarted = AdminManager(SyncApp(old)).execute({'action': 'invites.check', 'code': code})['invite']
        self.assertEqual(checked['id'], restarted['id'])
        with closing(app.connect()) as db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 2)

    def test_concurrent_initialization_and_preservation(self):
        _, session = self.register()
        with ThreadPoolExecutor(max_workers=2) as pool:
            apps = list(pool.map(lambda _: SyncApp(self.path), range(2)))
        for app in apps:
            self.assertEqual(request(app, 'GET', '/v1/library', token=session['token'])[0], 200)


if __name__ == '__main__':
    unittest.main()

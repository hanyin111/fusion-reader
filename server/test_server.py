from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from sync_server import SyncApp, RateLimit, MAX_BYTES, MAX_RECORDS, empty_snapshot, json_bytes, token_hash


def request(app, method, path, body=None, token=None, **extra):
    payload = b'' if body is None else json_bytes(body)
    environ = {'REQUEST_METHOD': method, 'PATH_INFO': path, 'QUERY_STRING': '',
               'REMOTE_ADDR': '192.0.2.1', 'CONTENT_TYPE': 'application/json',
               'CONTENT_LENGTH': str(len(payload)), 'wsgi.input': io.BytesIO(payload)}
    if token:
        environ['HTTP_AUTHORIZATION'] = 'Bearer ' + token
    environ.update(extra)
    response = {}
    def start(status, headers):
        response['status'] = int(status.split()[0])
        response['headers'] = dict(headers)
    result = b''.join(app(environ, start))
    return response['status'], json.loads(result), response['headers']


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='fusion_sync_test_')
        self.path = Path(self.directory.name) / 'library.sqlite3'
        self.app = SyncApp(self.path)
    def tearDown(self):
        self.directory.cleanup()
    def register(self, name='reader', code=None):
        status, body, _ = request(self.app, 'POST', '/v1/auth/register', {
            'username': name, 'password': 'fixture-password',
            'activationCode': self.app.invite() if code is None else code})
        self.assertEqual(status, 201, body)
        return body

    def test_registration_requires_invite_and_consumes_once(self):
        data = {'username': 'reader', 'password': 'fixture-password', 'activationCode': 'unissued'}
        self.assertEqual(request(self.app, 'POST', '/v1/auth/register', data)[:2], (403, {'error': 'invalid_activation_code'}))
        code = self.app.invite()
        self.register(code=code)
        data['username'] = 'other'; data['activationCode'] = code
        self.assertEqual(request(self.app, 'POST', '/v1/auth/register', data)[0], 403)
        with closing(self.app.connect()) as db, db:
            self.assertEqual(db.execute('SELECT count(*) FROM users').fetchone()[0], 1)
            self.assertNotIn('fixture-password', str(db.execute('SELECT * FROM users').fetchall()))
            self.assertIsNone(db.execute('SELECT code_hash FROM invites WHERE code_hash=?', (code,)).fetchone())

    def test_taken_username_rolls_back_invite_use(self):
        self.register()
        code = self.app.invite()
        body = {'username': 'reader', 'password': 'fixture-password', 'activationCode': code}
        self.assertEqual(request(self.app, 'POST', '/v1/auth/register', body)[0], 409)
        self.register('other', code)

    def test_expired_invite_and_input_validation(self):
        code = self.app.invite()
        with closing(self.app.connect()) as db, db:
            db.execute('UPDATE invites SET expires_at=0')
        body = {'username': 'reader', 'password': 'fixture-password', 'activationCode': code}
        self.assertEqual(request(self.app, 'POST', '/v1/auth/register', body)[0], 403)
        for username, password in [('x', 'fixture-password'), ('../../x', 'fixture-password'), ('reader', 'short')]:
            body.update(username=username, password=password)
            self.assertEqual(request(self.app, 'POST', '/v1/auth/register', body)[0], 400)

    def test_login_logout_and_hashed_sessions(self):
        registered = self.register()
        for name, password in [('reader', 'wrong-password'), ('unknown', 'fixture-password')]:
            self.assertEqual(request(self.app, 'POST', '/v1/auth/login', {'username': name, 'password': password})[:2], (401, {'error': 'invalid_credentials'}))
        status, logged, _ = request(self.app, 'POST', '/v1/auth/login', {'username': ' READER ', 'password': 'fixture-password'})
        self.assertEqual(status, 200); self.assertEqual(logged['user'], registered['user'])
        with closing(self.app.connect()) as db, db:
            self.assertIsNotNone(db.execute('SELECT * FROM sessions WHERE token_hash=?', (token_hash(logged['token']),)).fetchone())
            self.assertIsNone(db.execute('SELECT * FROM sessions WHERE token_hash=?', (logged['token'],)).fetchone())
        self.assertEqual(request(self.app, 'POST', '/v1/auth/logout', token=logged['token'])[0], 200)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=logged['token'])[0], 401)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=registered['token'])[0], 200)

    def test_expired_token_and_bearer_required(self):
        session = self.register()
        self.assertEqual(request(self.app, 'GET', '/v1/library')[0], 401)
        with closing(self.app.connect()) as db, db:
            db.execute('UPDATE sessions SET expires_at=0')
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=session['token'])[0], 401)

    def test_account_isolation_and_revision_conflict(self):
        one, two = self.register(), self.register('other')
        snapshot = empty_snapshot()
        novel = {'package': 'fixture', 'type': 'novel', 'title': '书名', 'url': '/book', 'cover': '', 'update': ''}
        snapshot['favorites'] = [novel]
        snapshot['history'] = [{'key': 'fixture|/book', 'item': novel, 'episodeUrl': '/chapter', 'episodeName': '第一章', 'groupIndex': 0, 'episodeIndex': 1, 'timestamp': 100, 'position': 2, 'textOffset': 731}]
        status, body, _ = request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': snapshot}, one['token'])
        self.assertEqual((status, body), (200, {'revision': 1}))
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': empty_snapshot()}, one['token'])[0], 409)
        result = request(self.app, 'GET', '/v1/library', token=one['token'])[1]
        self.assertEqual(result['snapshot']['history'][0]['textOffset'], 731)
        self.assertEqual(result['revision'], 1)
        other = request(self.app, 'GET', '/v1/library', token=two['token'])[1]
        self.assertEqual(other['revision'], 0); self.assertEqual(other['snapshot']['favorites'], [])

    def test_concurrent_writes_compare_revision_atomically(self):
        token = self.register()['token']
        payload = {'expectedRevision': 0, 'snapshot': empty_snapshot()}
        with ThreadPoolExecutor(max_workers=2) as pool:
            statuses = list(pool.map(lambda _: request(self.app, 'PUT', '/v1/library', payload, token)[0], range(2)))
        self.assertEqual(sorted(statuses), [200, 409])
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=token)[1]['revision'], 1)

    def test_reader_profiles_preserve_other_platforms_and_legacy_uploads(self):
        token = self.register()['token']
        first = empty_snapshot()
        first['readerSettings'] = {'ios': {'novel_fontName': '衬线', 'novel_fontSize': 26, 'novel_paged': True}}
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': first}, token)[0], 200)
        second = empty_snapshot()
        second['readerSettings'] = {'android': {'mangaWebtoon': True}}
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 1, 'snapshot': second}, token)[0], 200)
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 2, 'snapshot': empty_snapshot()}, token)[0], 200)
        saved = request(self.app, 'GET', '/v1/library', token=token)[1]['snapshot']
        self.assertEqual(saved['readerSettings']['ios'], first['readerSettings']['ios'])
        self.assertEqual(saved['readerSettings']['android'], second['readerSettings']['android'])
        self.assertEqual(saved['favorites'], [])

    def test_invalid_reader_profiles_do_not_mutate_data(self):
        token = self.register()['token']
        for profiles in [{'invalid': {}}, {'ios': {'novel_fontSize': 1000}},
                         {'ios': {'novel_paged': 'true'}}, {'ios': {'account_token': 'secret'}},
                         {'ios': {'novel_fontName': ['衬线']}}, {'ios': {'novel_fontWeightIndex': True}}]:
            snapshot = empty_snapshot()
            snapshot['readerSettings'] = profiles
            self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': snapshot}, token)[0], 400)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=token)[1]['revision'], 0)

    def test_invalid_payload_does_not_mutate_accepted_data(self):
        token = self.register()['token']
        bad = empty_snapshot(); bad['schemaVersion'] = True
        local = empty_snapshot(); local['favorites'] = [{'package': 'local', 'type': 'novel', 'title': 'secret path', 'url': '/device/file'}]
        malformed = empty_snapshot(); malformed['history'] = [{'key': 'missing-separator'}]
        too_many = empty_snapshot(); too_many['favorites'] = [{}] * (MAX_RECORDS + 1)
        for snapshot, expected in [(bad, 400), (local, 400), (malformed, 400), (too_many, 413)]:
            self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': snapshot}, token)[0], expected)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=token)[1]['revision'], 0)
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {}, token, CONTENT_LENGTH=str(MAX_BYTES + 262145))[0], 413)

    def test_rate_limit_and_untrusted_forwarded_addresses(self):
        for _ in range(10):
            request(self.app, 'POST', '/v1/auth/login', {'username': 'x', 'password': 'short'})
        status, _, headers = request(self.app, 'POST', '/v1/auth/login', {'username': 'x', 'password': 'short'}, HTTP_X_REAL_IP='203.0.113.1')
        self.assertEqual(status, 429); self.assertEqual(headers['Retry-After'], '60')
        limiter = RateLimit()
        for i in range(4100):
            limiter.check(str(i), 1)
        self.assertEqual(len(limiter.entries), 4096)

    def test_corrupt_json_oversize_and_unknown_fields_are_not_stored(self):
        token = self.register()['token']
        body = {'expectedRevision': 0, 'snapshot': empty_snapshot()}
        body['snapshot']['password'] = 'not-metadata'
        self.assertEqual(request(self.app, 'PUT', '/v1/library', body, token)[0], 200)
        saved = request(self.app, 'GET', '/v1/library', token=token)[1]
        self.assertNotIn('password', saved['snapshot'])
        self.assertEqual(request(self.app, 'PUT', '/v1/library', token=token, CONTENT_LENGTH='1', **{'wsgi.input': io.BytesIO(b'{')})[0], 400)
        self.assertEqual(request(self.app, 'GET', '/v1/library', token=token, QUERY_STRING='token=secret')[0], 400)
        self.assertEqual(request(self.app, 'GET', '/health')[2]['Cache-Control'], 'no-store')

    def test_restart_retains_library_and_session(self):
        session = self.register()
        self.assertEqual(request(self.app, 'PUT', '/v1/library', {'expectedRevision': 0, 'snapshot': empty_snapshot()}, session['token'])[0], 200)
        restarted = SyncApp(self.path)
        self.assertEqual(request(restarted, 'GET', '/v1/library', token=session['token'])[1]['revision'], 1)

    def test_unrelated_database_is_preserved(self):
        path = Path(self.directory.name) / 'existing-service.sqlite3'
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('CREATE TABLE original(value TEXT)')
            db.execute("INSERT INTO original VALUES('keep')")
        with self.assertRaises(RuntimeError):
            SyncApp(path)
        with closing(sqlite3.connect(path)) as db:
            self.assertEqual(db.execute('SELECT value FROM original').fetchone()[0], 'keep')
            self.assertEqual(db.execute("SELECT count(*) FROM sqlite_master WHERE name='users'").fetchone()[0], 0)


if __name__ == '__main__':
    unittest.main()

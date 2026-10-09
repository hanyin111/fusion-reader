"""Loopback-only disposable fixture for the Flutter protocol integration test.

Never use wsgiref to serve the production account API.
"""
import json
import sys
from wsgiref.simple_server import make_server, WSGIRequestHandler

from sync_server import SyncApp


class QuietHandler(WSGIRequestHandler):
    def log_message(self, *args):
        pass


if __name__ == '__main__':
    app = SyncApp(sys.argv[1])
    with make_server('127.0.0.1', 0, app, handler_class=QuietHandler) as server:
        print(json.dumps({'port': server.server_port, 'activationCode': app.invite()}), flush=True)
        server.serve_forever()

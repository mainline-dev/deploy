"""A stand-in for Mainline's deploy endpoint. It records every request as one
JSON line (path, authorisation, body) and answers with the status and body it
is told to, so the tests can see what the Action sent.

    python3 stub_mainline.py PORT RECORD_FILE STATUS BODY
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, RECORD, STATUS, BODY = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode()
        with open(RECORD, 'a') as record:
            record.write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization'), 'body': body}) + '\n')
        self.send_response(STATUS)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(BODY.encode())

    def log_message(self, *args):
        pass


HTTPServer(('127.0.0.1', PORT), Stub).serve_forever()

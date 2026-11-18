"""A stand-in for Mainline's deploy endpoint. It records every request as one
JSON line (path, authorisation, content type, body) and answers with the status and body it
is told to, so the tests can see what the Action sent.

    python3 stub_mainline.py PORT RECORD_FILE STATUS BODY
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import TCPServer

PORT, RECORD, STATUS, BODY = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode()
        with open(RECORD, 'a') as record:
            record.write(json.dumps({
                # As it was asked for: self.path has a doubled first slash put right.
                'path': self.requestline.split()[1],
                'auth': self.headers.get('Authorization'),
                'type': self.headers.get('Content-Type'),
                'body': body,
            }) + '\n')
        self.send_response(STATUS)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(BODY.encode())

    def log_message(self, *args):
        pass


class Server(HTTPServer):
    # HTTPServer looks up the machine's name as it starts, which takes half a
    # minute on GitHub's macOS runners. Nothing here needs the name.
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]


Server(('127.0.0.1', PORT), Stub).serve_forever()

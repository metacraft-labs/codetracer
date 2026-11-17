#!/usr/bin/env python3
"""git-basic-auth-server.py ROOT TOKEN PORTFILE -- a smart-HTTP git server that
answers like GitHub does for a private repository: 401 unless the request
carries `Authorization: Basic x-access-token:TOKEN`.

Serves the repositories under ROOT through `git http-backend` on 127.0.0.1, on
a free port it writes to PORTFILE. For ci/test/git-credential-header-test.sh
only. Logs each request's path and whether it was let in to stderr.
"""

import base64
import http.server
import os
import subprocess
import sys
import urllib.parse

ROOT, TOKEN, PORTFILE = sys.argv[1], sys.argv[2], sys.argv[3]
GOOD = "Basic " + base64.b64encode(f"x-access-token:{TOKEN}".encode()).decode()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _serve(self):
        auths = self.headers.get_all("Authorization") or []
        # A refused header is refused even when a good one rides along, which is
        # what GitHub does with git's extraHeader beside the helper's credential.
        allowed = bool(auths) and all(a.strip().lower() == GOOD.lower() for a in auths)
        sys.stderr.write(f"{self.command} {self.path} auth={len(auths)} allowed={allowed}\n")
        if not allowed:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="test"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        url = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(
            os.environ,
            GIT_PROJECT_ROOT=ROOT,
            GIT_HTTP_EXPORT_ALL="1",
            PATH_INFO=url.path,
            QUERY_STRING=url.query,
            REQUEST_METHOD=self.command,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(len(body)),
            REMOTE_USER="x-access-token",
            GIT_PROTOCOL=self.headers.get("Git-Protocol", ""),
        )
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, payload = out.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in head.split(b"\r\n"):
            name, _, value = line.decode().partition(":")
            if name.lower() == "status":
                status = int(value.strip().split()[0])
            elif name:
                headers.append((name, value.strip()))
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _serve
    do_POST = _serve


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORTFILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()

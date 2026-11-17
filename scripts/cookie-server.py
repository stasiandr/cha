#!/usr/bin/env python3
"""A tiny site for the sign-in checks: /set?p=NAME answers with a session
cookie and a persistent one, as a sign-in does; /check?p=NAME logs the
cookies the browser sends back. Usage: cookie-server.py PORT LOGFILE"""
import http.server
import sys

port, log = int(sys.argv[1]), sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path, _, query = self.path.partition("?")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        if path == "/set":
            self.send_header("Set-Cookie", "session=s1; Path=/")
            self.send_header("Set-Cookie", "kept=k1; Max-Age=86400; Path=/")
        self.end_headers()
        self.wfile.write(b"<title>" + path.encode() + b"</title>ok")
        cookies = sorted((self.headers.get("Cookie") or "").split("; "))
        with open(log, "a") as f:
            f.write(f"{path} {query} cookies={','.join(c for c in cookies if c)}\n")

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

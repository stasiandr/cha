#!/usr/bin/env python3
"""A fake Google for the calendar check: OAuth consent, tokens, events.

    google-fake.py <port> <log>

/auth       redirects to redirect_uri with a code (what Google's consent page
            does once the user agrees), keeping the state.
/token      checks the PKCE verifier against the challenge and the client,
            answers with tokens; an access token lasts 2 seconds, so the next
            fetch has to refresh it.
/calendar/v3/calendars/primary/events
            events around now: one going on with a Meet link, one in 20 min
            with a Zoom link in its place, one later without a link, and ones
            that are no meetings (declined, all-day, cancelled, over).
Every request is a line in <log>.
"""
import base64
import datetime
import hashlib
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, log_path = int(sys.argv[1]), sys.argv[2]
challenges = {}  # code -> challenge
access = {"token": None, "until": 0}


def log(line):
    with open(log_path, "a") as f:
        f.write(line + "\n")


def at(minutes):
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=minutes)
    return {"dateTime": t.isoformat(timespec="seconds").replace("+00:00", "Z")}


def events():
    base = f"http://127.0.0.1:{port}"
    return [
        {"id": "over", "summary": "Earlier", "start": at(-90), "end": at(-60)},
        {"id": "now", "summary": "Standup", "start": at(-5), "end": at(10),
         "hangoutLink": f"{base}/meet/abc-defg-hij", "htmlLink": f"{base}/event/now"},
        {"id": "declined", "summary": "Declined", "start": at(1), "end": at(30),
         "hangoutLink": f"{base}/meet/no",
         "attendees": [{"email": "me@example.com", "self": True, "responseStatus": "declined"}]},
        {"id": "allday", "summary": "Holiday", "start": {"date": "2030-01-01"}, "end": {"date": "2030-01-02"}},
        {"id": "cancelled", "status": "cancelled", "summary": "Gone", "start": at(2), "end": at(20)},
        {"id": "zoom", "summary": "Review", "start": at(20), "end": at(50),
         "location": "Zoom https://example.zoom.us/j/123?pwd=x"},
        {"id": "later", "summary": "Lunch", "start": at(120), "end": at(180)},
    ]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body, kind="application/json", headers=()):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(url.query))
        if url.path == "/auth":
            ok = (q.get("client_id") == "test-client" and q.get("code_challenge_method") == "S256"
                  and "calendar.events.readonly" in q.get("scope", "") and q.get("redirect_uri", "").startswith("http://127.0.0.1:"))
            log(f"auth ok={ok}")
            if not ok:
                return self.send(400, "bad auth request", "text/plain")
            challenges["code-1"] = q["code_challenge"]
            target = q["redirect_uri"] + "/?" + urllib.parse.urlencode({"code": "code-1", "state": q["state"]})
            return self.send(302, "", "text/plain", [("Location", target)])
        if url.path == "/calendar/v3/calendars/primary/events":
            auth = self.headers.get("Authorization", "")
            import time
            valid = access["token"] and auth == f"Bearer {access['token']}" and time.time() < access["until"]
            log(f"events valid={bool(valid)} singleEvents={q.get('singleEvents')}")
            if not valid:
                return self.send(401, json.dumps({"error": {"code": 401}}))
            return self.send(200, json.dumps({"items": events()}))
        if url.path.startswith("/meet/") or url.path.startswith("/event/"):
            return self.send(200, f"<title>{url.path}</title>", "text/html")
        self.send(404, "", "text/plain")

    def do_POST(self):
        import time
        length = int(self.headers.get("Content-Length", "0"))
        form = dict(urllib.parse.parse_qsl(self.rfile.read(length).decode()))
        if self.path != "/token" or form.get("client_id") != "test-client" or form.get("client_secret") != "test-secret":
            log("token bad-client")
            return self.send(400, json.dumps({"error": "invalid_client"}))
        grant = form.get("grant_type")
        if grant == "authorization_code":
            verifier = form.get("code_verifier", "")
            digest = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            ok = challenges.get(form.get("code")) == digest
            log(f"token code pkce={ok}")
            if not ok:
                return self.send(400, json.dumps({"error": "invalid_grant"}))
        elif grant == "refresh_token":
            ok = form.get("refresh_token") == "refresh-1"
            log(f"token refresh ok={ok}")
            if not ok:
                return self.send(400, json.dumps({"error": "invalid_grant"}))
        else:
            return self.send(400, json.dumps({"error": "unsupported_grant_type"}))
        access["token"] = f"access-{int(time.time() * 1000)}"
        access["until"] = time.time() + 62  # cha takes a minute off: 2 s for it
        body = {"access_token": access["token"], "expires_in": 62, "token_type": "Bearer"}
        if grant == "authorization_code":
            body["refresh_token"] = "refresh-1"
        self.send(200, json.dumps(body))


# Threads: Chromium opens spare connections that send nothing for a while.
ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

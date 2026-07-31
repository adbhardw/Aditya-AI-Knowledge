#!/usr/bin/env python3
"""
Minimal webhook receiver for testing orinix's WEBHOOK delivery channel.
No dependencies beyond the Python 3 standard library — nothing to pip install.

Usage:
  1. Register a callback with orinix (RegisterCallback / the registration
     endpoint) using the public URL this ends up running behind (see step 3).
     That call returns a signing_secret — paste it into SIGNING_SECRET below.
  2. Run:  python3 verify_webhook.py
     Listens on port 8080, prints every request it receives, and tells you
     whether the signature actually matches — not just that something arrived.
  3. Make it reachable from the internet (orinix needs to be able to POST to
     it). Easiest: install ngrok (https://ngrok.com, free tier is enough),
     then run:  ngrok http 8080
     ngrok prints an https://....ngrok-free.app URL — that's your callback_url.
     Share that URL back to register it.

Nothing here is production code — it's a disposable test receiver. Don't
point real customer traffic at it.
"""
import hashlib
import hmac
import http.server

SIGNING_SECRET = "REPLACE_ME"  # paste the signing_secret from registration here
PORT = 8080


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        signature_header = self.headers.get("X-Habu-Signature", "")
        event_id = self.headers.get("X-Habu-Event-Id", "")

        expected = hmac.new(
            SIGNING_SECRET.encode("utf-8"), body, hashlib.sha256
        ).hexdigest()

        # constant-time comparison — same practice the real verification
        # should use, so this test receiver models correct behavior too
        valid = hmac.compare_digest(expected, signature_header)

        print("=" * 70)
        print(f"Event-Id:        {event_id}")
        print(f"Signature valid: {valid}")
        print(f"Body:            {body.decode('utf-8', errors='replace')}")
        print("=" * 70, flush=True)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        pass  # quiet the default per-request access log; we print our own


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Listening on :{PORT} — waiting for orinix to POST here")
    server.serve_forever()

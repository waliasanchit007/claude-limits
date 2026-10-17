#!/usr/bin/env python3
"""Pass-through proxy that harvests Claude rate-limit headers for free.

Forwards everything to api.anthropic.com untouched and streams responses back.
The anthropic-ratelimit-unified-* headers riding on traffic your sessions were
making anyway are written to the shared usage file, where ClaudeLimits.app reads
them. Costs zero extra tokens: it never originates a request.

Entries are keyed by a SHA-256 prefix of the bearer token, NOT by organization -
several accounts can share one org, and org-keying would make them collide.
The token itself is forwarded but never stored or logged.
"""
import hashlib, http.server, http.client, json, os, ssl, sys, threading, time

UPSTREAM = "api.anthropic.com"
OUT = os.path.expanduser("~/.local/share/claude-usage/usage.json")
LOG = os.path.expanduser("~/.local/share/claude-usage/proxy.log")
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length"}
PRE = "anthropic-ratelimit-unified-"
lock = threading.Lock()


def ssl_context():
    """macOS system Python ships no CA bundle; fall back to the system one."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        pass
    for p in ("/etc/ssl/cert.pem", "/private/etc/ssl/cert.pem"):
        if os.path.exists(p):
            return ssl.create_default_context(cafile=p)
    return ssl.create_default_context()


CTX = ssl_context()


def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
        if os.path.getsize(LOG) > 512_000:          # keep the log small
            os.replace(LOG, LOG + ".1")
    except Exception:
        pass


def token_key(auth_header):
    """Stable per-account id. The token is hashed, never retained."""
    if not auth_header:
        return None
    tok = auth_header.split(None, 1)[-1].strip()
    if not tok:
        return None
    return hashlib.sha256(tok.encode()).hexdigest()[:16]


def record(key, headers):
    vals = {k.lower(): v for k, v in headers.items()
            if k.lower().startswith(PRE) or k.lower() == "anthropic-organization-id"}
    if not vals or not key:
        return
    entry = {"observed_at": time.time()}
    for k, v in vals.items():
        entry[k.replace(PRE, "").replace("anthropic-", "")] = v
    with lock:
        try:
            db = json.load(open(OUT))
        except Exception:
            db = {}
        db[key] = entry
        tmp = OUT + ".tmp"
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(tmp, "w") as f:
            json.dump(db, f, indent=2)
        os.replace(tmp, OUT)
    log("captured key=%s 5h=%s 7d=%s" % (key, entry.get("5h-utilization"),
                                         entry.get("7d-utilization")))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def forward(self):
        body = None
        n = self.headers.get("Content-Length")
        if n:
            body = self.rfile.read(int(n))
        key = token_key(self.headers.get("Authorization"))
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        conn = http.client.HTTPSConnection(UPSTREAM, timeout=900, context=CTX)
        try:
            conn.request(self.command, self.path, body=body, headers=hdrs)
            resp = conn.getresponse()
            record(key, resp.headers)
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:                       # stream so SSE is not buffered
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except Exception as e:
            log("error %s: %s" % (type(e).__name__, e))
            try:
                self.send_response(502)
                self.end_headers()
            except Exception:
                pass
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = forward


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log("listening on 127.0.0.1:%d" % port)
    print("proxy listening on 127.0.0.1:%d" % port, flush=True)
    srv.serve_forever()

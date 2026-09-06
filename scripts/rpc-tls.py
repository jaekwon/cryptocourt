#!/usr/bin/env python3
"""HTTPS in front of a local gnodev RPC, so a browser wallet can reach it.

WHY THIS EXISTS. Adena's popup runs under a Content-Security-Policy that blocks
plaintext http:// requests, so against a local gnodev it cannot reach the node at
all -- not even /health. Measured in the extension's own Network tab: the health
check comes back `(blocked:csp)`, 0.0 kB, 0 ms, never leaving the browser. The
node is fine; the request is never sent. The visible symptom is the wallet's fee
and storage-deposit estimates spinning forever with no error banner, because
nothing failed -- it just never asked.

The node cannot serve TLS itself, so this terminates it and forwards.

TRUST IS THE WHOLE POINT, and it is why mkcert is a dependency rather than a
self-signed openssl cert. An extension XHR has no "proceed anyway" -- an
untrusted certificate is simply a failed request, which is the state we are
trying to leave. `mkcert -install` puts a local CA in the system keychain and
that is what makes the certificate acceptable.

    brew install mkcert && mkcert -install          # once, asks for your password
    python3 scripts/rpc-tls.py                      # then this, per session

Point BOTH at it afterwards, or the overlay will refuse to sign:
  * Adena  -> Settings -> Networks -> the `dev` entry's RPC
  * the page's own RPC field in the left rail
index.html compares the wallet's RPC host against its own and stops before
prompting when they differ, on purpose -- two nodes can both be called "dev".
"""
import http.client
import http.server
import os
import ssl
import subprocess
import sys
import threading

LISTEN = int(os.environ.get("TLS_PORT", "26751"))
TARGET = os.environ.get("RPC_TARGET", "127.0.0.1:26750")
CERTDIR = os.environ.get("CERTDIR", os.path.expanduser("~/.cryptocourt-tls"))
HOSTS = ["localhost", "127.0.0.1"]


def ensure_cert():
    """A cert for localhost, made once and reused."""
    os.makedirs(CERTDIR, exist_ok=True)
    crt = os.path.join(CERTDIR, "rpc.crt")
    key = os.path.join(CERTDIR, "rpc.key")
    if os.path.exists(crt) and os.path.exists(key):
        return crt, key
    if not shutil_which("mkcert"):
        sys.exit("rpc-tls: mkcert not found — brew install mkcert && mkcert -install")
    subprocess.run(["mkcert", "-cert-file", crt, "-key-file", key] + HOSTS,
                   check=True, capture_output=True)
    print("rpc-tls: made a certificate for " + ", ".join(HOSTS))
    return crt, key


def shutil_which(x):
    from shutil import which
    return which(x)


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        pass                                   # one line per RPC call is noise

    # CORS IS ANSWERED HERE, NOT FORWARDED. The preflight is a browser
    # negotiation about THIS origin and this port; gnodev's answer would name the
    # wrong one. It already allows *, so nothing is being widened.
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._forward("GET", None)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self._forward("POST", self.rfile.read(n) if n else b"")

    def _forward(self, method, body):
        try:
            c = http.client.HTTPConnection(TARGET, timeout=30)
            c.request(method, self.path, body=body,
                      headers={"Content-Type": self.headers.get("Content-Type",
                                                                "application/json")})
            r = c.getresponse()
            data = r.read()
        except Exception as e:
            # A DEAD NODE MUST READ AS A DEAD NODE. Returning nothing here would
            # reproduce the exact failure this script exists to remove: a wallet
            # waiting on a request that never resolves.
            msg = ("rpc-tls: upstream %s unreachable: %s" % (TARGET, e)).encode()
            self.send_response(502)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)
            return
        self.send_response(r.status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", r.getheader("Content-Type", "application/json"))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    crt, key = ensure_cert()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    srv = Server(("127.0.0.1", LISTEN), Proxy)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    print("rpc-tls: https://localhost:%d  ->  http://%s" % (LISTEN, TARGET))
    print("rpc-tls: point Adena AND the page's RPC field at https://localhost:%d" % LISTEN)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

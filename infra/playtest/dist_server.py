#!/usr/bin/env python3
"""Playtest download server — browser-friendly HTTP hosting for the dist/ zips.

Serves (all behind the ?token= gate, no traversal, no listing without the token):
  * *.zip from the dist directory        — first install + full-download fallback
  * /manifest.json                       — T-690 auto-updater manifest (latest stamp, hashes, edges)
  * /patches/<name>.zst                  — T-690 zstd binary-delta patches the launcher applies

HTTP Range support so 800MB+ downloads survive flaky home connections (browsers/launcher resume
instead of restarting). Threaded so several testers can download at once.

Usage: AVALON_DIST_TOKEN=<token> dist_server.py [--port 8090] [--dir dist]
"""
import html
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = os.environ.get("AVALON_DIST_TOKEN", "")
CHUNK = 1024 * 256


class DistHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    dist_dir = "dist"  # overridden in main

    def log_message(self, fmt, *args):  # quiet-ish log with client ip
        sys.stderr.write("[dist] %s %s\n" % (self.address_string(), fmt % args))

    def _deny(self, code=403, msg="denied"):
        body = msg.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 (stdlib naming)
        url = urlparse(self.path)
        qs = parse_qs(url.query)
        if not TOKEN or qs.get("token", [""])[0] != TOKEN:
            return self._deny(403, "missing or bad token")
        # T-690 auto-updater manifest — small JSON, no Range needed.
        if url.path == "/manifest.json":
            path = os.path.join(self.dist_dir, "manifest.json")
            if not os.path.isfile(path):
                return self._deny(404, "no manifest")
            return self._send_file(path, "application/json")
        # T-690 delta patches live in dist/patches/. Match the LAST path segment against a strict
        # allowlist and re-anchor under patches/ ourselves — never trust the client's directory.
        if url.path.startswith("/patches/"):
            name = os.path.basename(url.path)
            if not re.fullmatch(r"[A-Za-z0-9._-]+\.zst", name):
                return self._deny(404, "not found")
            path = os.path.join(self.dist_dir, "patches", name)
            if not os.path.isfile(path):
                return self._deny(404, "not found")
            return self._send_file(path, "application/zstd")
        # T-690 raw engine binaries (re-fetched only on an engine bump). Strict name allowlist.
        if url.path.startswith("/engine/"):
            name = os.path.basename(url.path)
            if not re.fullmatch(r"Avalon\.(x86_64|exe)", name):
                return self._deny(404, "not found")
            path = os.path.join(self.dist_dir, "engine", name)
            if not os.path.isfile(path):
                return self._deny(404, "not found")
            return self._send_file(path, "application/octet-stream")
        name = os.path.basename(url.path)  # basename kills any traversal attempt
        if url.path in ("", "/") or name == "":
            return self._index()
        if not re.fullmatch(r"[A-Za-z0-9._-]+\.zip", name):
            return self._deny(404, "not found")
        path = os.path.join(self.dist_dir, name)
        if not os.path.isfile(path):
            return self._deny(404, "not found")
        return self._send_file(path, "application/zip")

    def _index(self):
        rows = []
        for f in sorted(os.listdir(self.dist_dir)):
            if f.endswith(".zip"):
                size_mb = os.path.getsize(os.path.join(self.dist_dir, f)) // (1024 * 1024)
                link = "/%s?token=%s" % (f, TOKEN)
                rows.append(
                    '<li><a href="%s">%s</a> (%d MB)</li>'
                    % (html.escape(link, quote=True), html.escape(f), size_mb)
                )
        body = (
            "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>Avalon Playtest Downloads</title>"
            "<h2>Avalon Playtest Downloads</h2><ul>%s</ul>"
            "<p>Pick the build for your computer (windows / linux). See the guide inside the zip.</p>"
            % "".join(rows)
        )
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_file(self, path, content_type="application/octet-stream"):
        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200
        rng = self.headers.get("Range")
        if rng:
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
            if m and (m.group(1) or m.group(2)):
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                else:  # suffix range: last N bytes
                    start = max(0, size - int(m.group(2)))
                if start > end or start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", "bytes */%d" % size)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                end = min(end, size - 1)
                status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(CHUNK, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client paused/cancelled — Range lets them resume


def main():
    port = 8090
    dist = "dist"
    args = sys.argv[1:]
    while args:
        a = args.pop(0)
        if a == "--port":
            port = int(args.pop(0))
        elif a == "--dir":
            dist = args.pop(0)
    if not TOKEN:
        sys.exit("set AVALON_DIST_TOKEN")
    if not os.path.isdir(dist):
        sys.exit("no such dir: %s" % dist)
    DistHandler.dist_dir = os.path.abspath(dist)
    srv = ThreadingHTTPServer(("0.0.0.0", port), DistHandler)
    print("[dist] serving %s on 0.0.0.0:%d" % (DistHandler.dist_dir, port), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Local HTTP fixtures; no third-party station availability required."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import threading
import sys


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/redirect.m3u":
            self.send_response(302)
            self.send_header("Location", "/lists/station.m3u")
            self.end_headers()
            return
        responses = {
            "/lists/station.m3u": ("audio/x-mpegurl", b"#EXTM3U\n../missing\n../station.pls"),
            "/station.pls": ("audio/x-scpls", b"[playlist]\nFile1=/live"),
            "/playlist": ("audio/x-mpegurl", b"#EXTM3U\n/live"),
            "/live": ("audio/mpeg", b"audio fixture"),
            "/hls.m3u8": ("application/vnd.apple.mpegurl", b"#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts"),
            "/webpage": ("text/html", b"<html>Station</html>"),
            "/oversized.m3u": ("audio/x-mpegurl", b"x" * (256 * 1024 + 1)),
            "/oversized-chunked.m3u": ("audio/x-mpegurl", b"x" * (256 * 1024 + 1)),
        }
        if self.path not in responses:
            self.send_error(404)
            return
        mime, body = responses[self.path]
        self.send_response(200)
        self.send_header("Content-Type", mime)
        if self.path != "/oversized-chunked.m3u":
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for binary in sys.argv[1:]:
            subprocess.run([binary, f"http://127.0.0.1:{server.server_port}"], check=True, timeout=60)
    finally:
        server.shutdown()

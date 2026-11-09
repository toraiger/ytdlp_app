"""Loopback-only HTTP range fixture for AVFoundation tests; no user media."""
import http.server
import re
import sys
from pathlib import Path

fixture_root = Path(sys.argv[1]).resolve()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/dash-tone.m4a", "/normalized.m4a"):
            self.send_error(404)
            return
        data = (fixture_root / self.path[1:]).read_bytes()
        start, end = 0, len(data)
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
            if not match:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(end, int(match[2]) + 1) if match[2] else end
            if start >= end:
                self.send_error(416)
                return
        self.send_response(206 if requested else 200)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start))
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end - 1}/{len(data)}")
        self.end_headers()
        try:
            self.wfile.write(data[start:end])
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()

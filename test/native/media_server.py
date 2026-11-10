'''Loopback-only range fixture; all server state is local to main.'''
import http.server
from http import HTTPStatus
from pathlib import Path
import re
import sys


def make_handler(fixture_root):
    allowed_names = {entry.name for entry in fixture_root.glob('*.m4a')}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            filename = self.path.removeprefix('/')
            if filename not in allowed_names:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            data = (fixture_root / filename).read_bytes()
            start, end = 0, len(data)
            requested = self.headers.get('Range')
            if requested:
                match = re.fullmatch(r'bytes=(\d+)-(\d*)', requested)
                if not match:
                    self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    return
                start = int(match[1])
                end = min(end, int(match[2]) + 1) if match[2] else end
                if start >= end:
                    self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                    return
            status = HTTPStatus.PARTIAL_CONTENT if requested else HTTPStatus.OK
            self.send_response(status)
            self.send_header('Content-Type', 'audio/mp4')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start))
            if requested:
                self.send_header('Content-Range', f'bytes {start}-{end - 1}/{len(data)}')
            self.end_headers()
            try:
                self.wfile.write(data[start:end])
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *ignored_arguments):
            pass

    return Handler


def main():
    fixture_root = Path(sys.argv[1]).resolve()
    port_path = Path(sys.argv[2])
    # Port zero requests an ephemeral loopback port from the OS.
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), make_handler(fixture_root))
    port_path.write_text(str(server.server_port))
    server.serve_forever()


if __name__ == '__main__':
    main()

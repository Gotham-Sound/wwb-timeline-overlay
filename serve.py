#!/usr/bin/env python3
"""
serve.py: tiny static server with HTTP Range support, so the browser can seek inside large
video files. Serves the folder this script lives in (player.html, data/...).

  python3 serve.py            # http://127.0.0.1:8765/
  python3 serve.py 9000       # another port

Then open e.g. http://127.0.0.1:8765/player.html?video=data/bb.mp4&tline=data/bb.tline&shw=data/bb.shw
"""
import os
import re
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))


class RangeHandler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def send_head(self):
        path = self.translate_path(self.path)
        rng = self.headers.get("Range")
        if os.path.isdir(path) or not rng:
            return super().send_head()
        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        if not m or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start = int(m.group(1)) if m.group(1) else max(0, size - int(m.group(2) or 0))
        end = int(m.group(2)) if m.group(1) and m.group(2) else size - 1
        end = min(end, size - 1)
        if start > end or start >= size:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self._range_left = end - start + 1
        return f

    def copyfile(self, source, outputfile):
        left = getattr(self, "_range_left", None)
        if left is None:
            return super().copyfile(source, outputfile)
        while left > 0:
            chunk = source.read(min(1 << 16, left))
            if not chunk:
                break
            outputfile.write(chunk)
            left -= len(chunk)

    def end_headers(self):
        if "Accept-Ranges" not in self._headers_buffer_text():
            self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def _headers_buffer_text(self):
        return b"".join(getattr(self, "_headers_buffer", [])).decode("latin1")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"serving {ROOT} at http://127.0.0.1:{port}/  (Ctrl-C to stop)")
    ThreadingHTTPServer(("127.0.0.1", port), RangeHandler).serve_forever()

#!/usr/bin/env python3
"""decide — interactive picker UI for AI agents.

Behavior mirrors `crit`: run in the background, a browser opens, the process
blocks until the user presses Submit. On submit, the result JSON path is
printed to stdout and the process exits.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import tempfile
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

TEMPLATE = Path(__file__).parent / "template.html"


def load_input(arg: str | None) -> dict:
    if arg is None or arg == "-":
        return json.load(sys.stdin)
    return json.loads(Path(arg).read_text())


def pick_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def serve(data: dict, port: int) -> dict:
    html = TEMPLATE.read_text().replace("__DECIDE_DATA__", json.dumps(data))
    result: dict = {}
    done = threading.Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a, **k):
            pass

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                body = html.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path != "/submit":
                self.send_error(404)
                return
            n = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(n).decode("utf-8")
            try:
                result["data"] = json.loads(body)
            except json.JSONDecodeError:
                self.send_error(400, "invalid json")
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            threading.Thread(target=done.set, daemon=True).start()

    server = HTTPServer(("127.0.0.1", port), Handler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    try:
        done.wait()
        time.sleep(0.25)
    finally:
        server.shutdown()
    return result.get("data", {})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", nargs="?", help="JSON file with questions; '-' or omitted = stdin")
    ap.add_argument("--port", type=int, default=0, help="port to bind (default: random free)")
    ap.add_argument("--output", help="where to write result JSON (default: temp file)")
    ap.add_argument("--no-open", action="store_true", help="do not auto-open the browser")
    args = ap.parse_args()

    data = load_input(args.input)
    port = args.port or pick_port()
    url = f"http://127.0.0.1:{port}/"

    print(f"decide: listening on {url}", file=sys.stderr)
    if not args.no_open:
        webbrowser.open(url)
    else:
        print(f"decide: open {url} in your browser", file=sys.stderr)

    result = serve(data, port)

    if args.output:
        out = Path(args.output)
    else:
        out = Path(tempfile.mkstemp(prefix="decide-result-", suffix=".json")[1])
    out.write_text(json.dumps(result, indent=2, ensure_ascii=False))
    print(f"Decision result saved to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Run opt-in Sprout HTTP transport tests against a loopback-only HTTP/1.1 server.

Example (build the tests separately first):
  python3 Scripts/test_http_transport.py --repeat 3 -- \
    swift test --skip-build --filter BoundedHTTPNetworkTests

For a Linux Docker test process using --network host, start --server-only with
--ready-file, then pass the JSON base_url as SPROUT_HTTP_TEST_BASE_URL. The server
has a bounded lifetime (--timeout), and SIGTERM shuts it down. No TLS, external
hosts, credentials, or personal state are used. Large redirect bodies are not
used: this fixture does not establish a bound on Foundation's internal 3xx buffer.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self):
        super().__init__(("127.0.0.1", 0), FixtureHandler)
        self.stopping = threading.Event()
        self.stats_lock = threading.Lock()
        self.stats = {}

    def update(self, token, **changes):
        with self.stats_lock:
            value = self.stats.setdefault(token, dict(chunks=0, disconnected=False,
                                                     completed=False, captures=0))
            value.update(changes)

    def snapshot(self, token):
        with self.stats_lock:
            return dict(self.stats.get(token, dict(chunks=0, disconnected=False,
                                                   completed=False, captures=0)))


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, format, *args):
        pass

    def reply(self, status, payload=b"", headers=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "application/json")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def do_GET(self):
        parsed = urlsplit(self.path)
        token = parse_qs(parsed.query).get("token", [""])[0]
        try:
            if parsed.path == "/echo":
                body = json.dumps(dict(id=token, cookie=self.headers.get("Cookie", ""))).encode()
                self.reply(200, body, {"Set-Cookie": "sprout_fixture=must-not-be-replayed; Path=/"})
            elif parsed.path == "/stats":
                self.reply(200, json.dumps(self.server.snapshot(token)).encode())
            elif parsed.path == "/redirect":
                # Tokens are UUIDs supplied by the XCTest fixture, not user URLs.
                self.reply(307, headers={"Location": "/capture?token=" + token})
            elif parsed.path == "/capture":
                previous = self.server.snapshot(token)
                self.server.update(token, captures=previous["captures"] + 1)
                self.reply(200, b"{}")
            elif parsed.path in ("/declared", "/chunked", "/slow"):
                self.stream(token, chunked=parsed.path != "/declared")
            else:
                self.reply(404)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True

    def stream(self, token, chunked):
        self.server.update(token, chunks=0, disconnected=False, completed=False)
        chunk = b"0123456789abcdef"
        count = 4096
        try:
            self.send_response(200)
            if chunked:
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Content-Length", str(count * len(chunk)))
            self.end_headers()
            for index in range(count):
                if self.server.stopping.is_set():
                    self.close_connection = True
                    return
                wire = b"10\r\n" + chunk + b"\r\n" if chunked else chunk
                self.wfile.write(wire)
                self.wfile.flush()
                self.server.update(token, chunks=index + 1)
                # Keep the body in flight long enough to observe real cancellation.
                if self.server.stopping.wait(0.002):
                    return
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            self.server.update(token, completed=True)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.server.update(token, disconnected=True)
            self.close_connection = True


def positive_float(raw):
    value = float(raw)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return value


def stop_process(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repeat", type=int, default=3, help="fresh test processes (default: 3)")
    parser.add_argument("--timeout", type=positive_float, default=120, help="seconds per command/server-only lifetime")
    parser.add_argument("--server-only", action="store_true")
    parser.add_argument("--ready-file", type=Path, help="create new JSON readiness file; never overwrite an existing file")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.repeat < 1:
        parser.error("--repeat must be positive")
    if args.server_only and command:
        parser.error("--server-only cannot be combined with a command")
    if not args.server_only and not command:
        parser.error("supply a test command after --, or use --server-only")
    if args.server_only and args.ready_file is None:
        parser.error("--server-only requires --ready-file")

    server = FixtureServer()
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    worker.start()
    base_url = "http://127.0.0.1:" + str(server.server_port)
    child = None
    ready_created = False

    def signal_stop(signum, frame):
        server.stopping.set()

    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    try:
        if args.ready_file:
            # Exclusive creation prevents a new server from silently replacing another fixture.
            with args.ready_file.open("x") as ready:
                ready_created = True
                json.dump(dict(base_url=base_url, pid=os.getpid()), ready)
                ready.write("\n")
        print("HTTP fixture:", base_url, flush=True)
        if args.server_only:
            server.stopping.wait(args.timeout)
            return 0
        environment = dict(os.environ, SPROUT_HTTP_TEST_BASE_URL=base_url)
        for index in range(args.repeat):
            print("HTTP transport process", str(index + 1) + "/" + str(args.repeat), flush=True)
            child = subprocess.Popen(command, env=environment, start_new_session=True)
            deadline = time.monotonic() + args.timeout
            while child.poll() is None:
                if server.stopping.wait(0.05):
                    stop_process(child)
                    return 130
                if time.monotonic() >= deadline:
                    stop_process(child)
                    print("FAIL: HTTP transport test process timed out", file=sys.stderr)
                    return 124
            if child.returncode:
                print("FAIL: HTTP transport test process exited", child.returncode, file=sys.stderr)
                return child.returncode if child.returncode > 0 else 128 - child.returncode
        print("PASS:", args.repeat, "HTTP transport test processes", flush=True)
        return 0
    except OSError as error:
        print("FAIL:", error, file=sys.stderr)
        return 1
    finally:
        server.stopping.set()
        if child is not None:
            stop_process(child)
        server.shutdown()
        server.server_close()
        worker.join(timeout=2)
        if ready_created:
            args.ready_file.unlink(missing_ok=True)


if __name__ == "__main__":
    sys.exit(main())

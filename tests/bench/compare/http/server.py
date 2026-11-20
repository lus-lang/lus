# HTTP server benchmark: answers GET / with a small JSON document, using
# http.server with one thread per connection and HTTP/1.1 keep-alive.
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
counter = 0
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        global counter
        if self.path == "/":
            with lock:
                counter += 1
                n = counter
            body = json.dumps({"message": "hello", "n": n}, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
        else:
            body = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 1024

    def handle_error(self, request, client_address):
        pass


Server(("127.0.0.1", port), Handler).serve_forever()

"""Test double for alert endpoints: records every POST as one JSON line.

Usage: python3 http_sink.py DIR  (writes DIR/port, appends to DIR/requests;
answers 500 while DIR/fail exists)."""
import http.server, json, os, sys

d = sys.argv[1]

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        fail = os.path.exists(os.path.join(d, "fail"))
        if not fail:
            with open(os.path.join(d, "requests"), "a") as f:
                f.write(json.dumps({"path": self.path, "title": self.headers.get("Title"),
                                    "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        self.send_response(500 if fail else 200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass

s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.tmp"), "w") as f: f.write(str(s.server_port))
os.replace(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()

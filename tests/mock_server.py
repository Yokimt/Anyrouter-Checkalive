#!/usr/bin/env python3
"""Tiny Codex-compatible mock endpoint used by the bats suite.

Routes:
  POST .../responses         -> SSE (or plain JSON when stream=false)
  POST .../chat/completions  -> SSE (or plain JSON when stream=false)
  any path containing /reject -> HTTP 401 error body
  anything else              -> HTTP 404
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the test output clean
        pass

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}

        if "/reject" in self.path:
            self._json(401, {"error": {"message": "invalid api key"}})
            return
        if self.path.endswith("/responses"):
            self._responses(body)
        elif self.path.endswith("/chat/completions"):
            self._chat(body)
        else:
            self._json(404, {"error": {"message": "not found"}})

    def _json(self, code, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for event in events:
            self.wfile.write(b"data: " + json.dumps(event).encode("utf-8") + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def _responses(self, body):
        answer = "17"
        completed = {
            "type": "response.completed",
            "response": {
                "id": "resp_mock",
                "status": "completed",
                "model": body.get("model", "gpt-6-astra"),
                "output": [{
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": answer}],
                }],
            },
        }
        if body.get("stream") is False:
            self._json(200, completed["response"])
            return
        self._sse([
            {"type": "response.output_text.delta", "delta": answer},
            completed,
        ])

    def _chat(self, body):
        answer = "42"
        if body.get("stream") is False:
            self._json(200, {
                "choices": [{
                    "message": {"role": "assistant", "content": answer},
                    "finish_reason": "stop",
                }],
            })
            return
        self._sse([
            {"choices": [{"delta": {"content": answer}, "finish_reason": None}]},
            {"choices": [{"delta": {}, "finish_reason": "stop"}]},
        ])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", default="")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if args.ready_file:
        with open(args.ready_file, "w", encoding="utf-8") as handle:
            handle.write(str(server.server_port))
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

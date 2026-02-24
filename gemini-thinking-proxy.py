#!/usr/bin/env python3
"""Gemini Thinking Token Proxy.

Lightweight reverse proxy between OpenClaw and Google's Gemini API that captures
thinking tokens (billed but not included in completion_tokens) and logs them.

Architecture:
  OpenClaw (18789) -> this proxy (18790) -> generativelanguage.googleapis.com
                            |
               ~/.openclaw/logs/gemini-thinking-tokens.jsonl
"""

import http.server
import http.client
import ssl
import json
import os
import sys
import threading
from datetime import datetime, timezone
from urllib.parse import urlparse

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 18790
TARGET_HOST = "generativelanguage.googleapis.com"
TARGET_PORT = 443
THINKING_LOG = os.path.expanduser("~/.openclaw/logs/gemini-thinking-tokens.jsonl")
CONNECT_TIMEOUT = 30
READ_TIMEOUT = 300  # thinking models can be slow

# Ensure log directory exists
os.makedirs(os.path.dirname(THINKING_LOG), exist_ok=True)

# Reusable SSL context
_ssl_ctx = ssl.create_default_context()

_log_lock = threading.Lock()


def log_thinking(model, thinking, prompt, completion, cached, total):
    """Append a thinking token record to JSONL log."""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "model": model,
        "thinking": thinking,
        "prompt": prompt,
        "completion": completion,
        "cached": cached,
        "total": total,
    }
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with _log_lock:
        with open(THINKING_LOG, "a") as f:
            f.write(line)


def extract_usage_from_json(body_bytes):
    """Extract usage from a non-streaming JSON response."""
    try:
        data = json.loads(body_bytes)
        usage = data.get("usage", {})
        return data.get("model", ""), usage
    except (json.JSONDecodeError, AttributeError):
        return "", {}


def extract_usage_from_sse(body_bytes):
    """Extract usage from the last SSE data chunk containing usage info."""
    model = ""
    usage = {}
    try:
        text = body_bytes.decode("utf-8", errors="replace")
        # Scan lines in reverse for the last data: chunk with usage
        lines = text.split("\n")
        for line in reversed(lines):
            line = line.strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                continue
            try:
                chunk = json.loads(payload)
                if "usage" in chunk:
                    usage = chunk["usage"]
                    model = chunk.get("model", model)
                    break
                if not model and chunk.get("model"):
                    model = chunk["model"]
            except json.JSONDecodeError:
                continue
    except Exception:
        pass
    return model, usage


def process_response(body_bytes, is_streaming):
    """Extract thinking tokens from response and log if present."""
    if is_streaming:
        model, usage = extract_usage_from_sse(body_bytes)
    else:
        model, usage = extract_usage_from_json(body_bytes)

    if not usage:
        return

    total = usage.get("total_tokens", 0) or 0
    prompt = usage.get("prompt_tokens", 0) or 0
    completion = usage.get("completion_tokens", 0) or 0

    # prompt_tokens_details may contain cached_tokens
    prompt_details = usage.get("prompt_tokens_details", {}) or {}
    cached = prompt_details.get("cached_tokens", 0) or 0

    # thinking = total - prompt - completion
    thinking = total - prompt - completion
    if thinking > 0:
        log_thinking(model, thinking, prompt, completion, cached, total)


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    """HTTP handler that proxies requests to Google and captures thinking tokens."""

    # Suppress default request logging
    def log_message(self, format, *args):
        pass

    def _proxy(self, method):
        # Health check endpoint
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok","proxy":"gemini-thinking-proxy"}')
            return

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        # Detect streaming request
        is_streaming = False
        if body:
            try:
                req_data = json.loads(body)
                is_streaming = req_data.get("stream", False)
            except (json.JSONDecodeError, AttributeError):
                pass

        # Build headers for upstream, skip hop-by-hop
        skip_headers = {"host", "transfer-encoding", "connection"}
        upstream_headers = {}
        for key, val in self.headers.items():
            if key.lower() not in skip_headers:
                upstream_headers[key] = val
        upstream_headers["Host"] = TARGET_HOST

        # Connect to upstream
        try:
            conn = http.client.HTTPSConnection(
                TARGET_HOST, TARGET_PORT,
                context=_ssl_ctx,
                timeout=READ_TIMEOUT,
            )
            conn.request(method, self.path, body=body, headers=upstream_headers)
            resp = conn.getresponse()
        except Exception as e:
            self.send_error(502, f"Upstream connection failed: {e}")
            return

        # Buffer full response
        resp_body = resp.read()

        # Forward response to client
        self.send_response(resp.status)
        for key, val in resp.getheaders():
            # Skip hop-by-hop headers
            if key.lower() in ("transfer-encoding", "connection", "keep-alive"):
                continue
            self.send_header(key, val)
        # Set correct content-length for buffered response
        self.send_header("Content-Length", str(len(resp_body)))
        self.end_headers()
        self.wfile.write(resp_body)

        conn.close()

        # Process in background to not delay response delivery
        if resp.status == 200 and self.path.endswith("/chat/completions"):
            threading.Thread(
                target=process_response,
                args=(resp_body, is_streaming),
                daemon=True,
            ).start()

    def do_POST(self):
        self._proxy("POST")

    def do_GET(self):
        self._proxy("GET")


class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    server = ThreadedHTTPServer((LISTEN_HOST, LISTEN_PORT), ProxyHandler)
    print(f"Gemini thinking proxy listening on {LISTEN_HOST}:{LISTEN_PORT}")
    print(f"Forwarding to {TARGET_HOST}:{TARGET_PORT}")
    print(f"Logging to {THINKING_LOG}")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()

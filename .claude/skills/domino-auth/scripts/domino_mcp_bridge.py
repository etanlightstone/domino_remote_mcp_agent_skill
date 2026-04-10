#!/usr/bin/env python3
"""
STDIO-to-HTTP MCP Bridge for Domino.

Runs as a local STDIO MCP server that Claude Code spawns automatically.
Reads JSON-RPC from stdin, gets a fresh Bearer token for every request,
forwards to the remote Domino MCP endpoint over HTTP, and writes the
response to stdout.

This sidesteps the headersHelper caching issue entirely — every upstream
request carries a freshly-refreshed token.

Usage in .mcp.json:
    {
      "mcpServers": {
        "domino-mcp": {
          "type": "stdio",
          "command": "python3",
          "args": [".claude/skills/domino-auth/scripts/domino_mcp_bridge.py",
                   "https://apps.your-domino.example.com/apps/<app-id>/mcp"]
        }
      }
    }
"""
import json
import os
import sys
import urllib.request
import urllib.error

# Import token and SSL helpers from the existing headersHelper module
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPTS_DIR)
import domino_headers


def get_auth_header():
    """Get a fresh Authorization header, refreshing the access token if needed."""
    stored = domino_headers.load_tokens()
    if not stored or not stored.get("access_token"):
        return {}

    import time
    access_token = stored["access_token"]
    expires_at = stored.get("expires_at", 0)
    domino_url = stored.get("domino_url", "")

    # Refresh if expired or within 30s of expiry
    if time.time() >= (expires_at - 30):
        refresh_tok = stored.get("refresh_token")
        if refresh_tok and domino_url:
            try:
                new_tokens = domino_headers.refresh_access_token(domino_url, refresh_tok)
                access_token = new_tokens["access_token"]
                domino_headers.save_tokens(stored, new_tokens)
            except Exception:
                pass  # use stale token; user may need to re-login

    return {"Authorization": f"Bearer {access_token}"}


_session_id = None


def forward_to_domino(target_url, request_body):
    """Forward a JSON-RPC request to the remote Domino MCP server."""
    global _session_id
    auth = get_auth_header()

    req = urllib.request.Request(
        target_url,
        data=request_body,
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if _session_id:
        req.add_header("Mcp-Session-Id", _session_id)
    for k, v in auth.items():
        req.add_header(k, v)

    resp = domino_headers._urlopen(req, timeout=120)

    # Capture session ID from the server (returned on initialize)
    sid = resp.headers.get("Mcp-Session-Id")
    if sid:
        _session_id = sid

    content_type = resp.headers.get("Content-Type", "")
    raw = resp.read()

    if "event-stream" in content_type:
        for line in raw.decode("utf-8", errors="replace").split("\n"):
            line = line.strip()
            if line.startswith("data: "):
                return line[6:]
        return raw.decode("utf-8", errors="replace")
    else:
        return raw.decode("utf-8", errors="replace")


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("Usage: domino_mcp_bridge.py <domino-mcp-url>\n")
        sys.exit(1)

    target_url = sys.argv[1]
    sys.stderr.write(f"[bridge] STDIO bridge started, target: {target_url}\n")

    # Read JSON-RPC messages from stdin, one per line
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            # Validate it's JSON
            msg = json.loads(line)
        except json.JSONDecodeError:
            sys.stderr.write(f"[bridge] Invalid JSON: {line[:100]}\n")
            continue

        method = msg.get("method", "")
        msg_id = msg.get("id")

        # Notifications (no id) that are client-only — acknowledge locally
        if msg_id is None and method == "notifications/initialized":
            # This is a client notification; don't forward, just consume
            continue

        try:
            response_json = forward_to_domino(target_url, line.encode("utf-8"))
            sys.stdout.write(response_json + "\n")
            sys.stdout.flush()
        except urllib.error.HTTPError as e:
            error_body = e.read().decode("utf-8", errors="replace")
            sys.stderr.write(f"[bridge] HTTP {e.code} for {method}: {error_body[:200]}\n")
            if msg_id is not None:
                err_resp = json.dumps({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {
                        "code": -32000,
                        "message": f"Upstream HTTP {e.code}: {error_body[:200]}",
                    },
                })
                sys.stdout.write(err_resp + "\n")
                sys.stdout.flush()
        except Exception as e:
            sys.stderr.write(f"[bridge] Error for {method}: {e}\n")
            if msg_id is not None:
                err_resp = json.dumps({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {
                        "code": -32000,
                        "message": f"Bridge error: {str(e)}",
                    },
                })
                sys.stdout.write(err_resp + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    main()

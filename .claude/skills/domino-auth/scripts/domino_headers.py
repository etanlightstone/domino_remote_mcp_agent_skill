#!/usr/bin/env python3
"""
headersHelper for Domino MCP server authentication.

Called by Claude Code before each MCP HTTP request. Outputs a JSON object
of HTTP headers to attach to the request.

Automatically refreshes expired access tokens using the stored refresh token.
If no tokens exist, outputs empty headers (MCP connection will fail gracefully).
"""

import json
import os
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error

TOKEN_FILE = os.path.expanduser("~/.domino-mcp/tokens.json")
REALM = "DominoRealm"
CLIENT_ID = "domino-connect-client"

# --- SSL (same logic as domino_oauth.py) ---

_ssl_ctx_cache = None


def _get_ssl_context():
    global _ssl_ctx_cache
    if _ssl_ctx_cache is not None:
        return _ssl_ctx_cache
    ctx = ssl.create_default_context()
    for var in ("DOMINO_CA_BUNDLE", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
        path = os.environ.get(var)
        if path and os.path.exists(path):
            ctx.load_verify_locations(path)
            _ssl_ctx_cache = ctx
            return ctx
    if sys.platform == "darwin":
        try:
            certs = ""
            for kc in (
                "/System/Library/Keychains/SystemRootCertificates.keychain",
                "/Library/Keychains/System.keychain",
            ):
                if os.path.exists(kc):
                    r = subprocess.run(
                        ["security", "find-certificate", "-a", "-p", kc],
                        capture_output=True, text=True, timeout=10,
                    )
                    if r.returncode == 0 and r.stdout:
                        certs += r.stdout + "\n"
            r = subprocess.run(
                ["security", "find-certificate", "-a", "-p"],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode == 0 and r.stdout:
                certs += r.stdout + "\n"
            if certs.strip():
                tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".pem", delete=False)
                tmp.write(certs)
                tmp.close()
                new_ctx = ssl.create_default_context()
                new_ctx.load_verify_locations(tmp.name)
                os.unlink(tmp.name)
                _ssl_ctx_cache = new_ctx
                return new_ctx
        except Exception:
            pass
    if os.environ.get("DOMINO_INSECURE", "").lower() in ("1", "true", "yes"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        _ssl_ctx_cache = ctx
        return ctx
    _ssl_ctx_cache = ctx
    return ctx


def _urlopen(req, timeout=10):
    return urllib.request.urlopen(req, timeout=timeout, context=_get_ssl_context())


# --- Token helpers ---

def load_tokens():
    if not os.path.exists(TOKEN_FILE):
        return None
    try:
        with open(TOKEN_FILE) as fh:
            return json.load(fh)
    except (json.JSONDecodeError, IOError):
        return None


def save_tokens(stored, new_tokens):
    """Merge refreshed tokens back into the stored file."""
    stored["access_token"] = new_tokens["access_token"]
    stored["expires_at"] = time.time() + new_tokens.get("expires_in", 300)
    if "refresh_token" in new_tokens:
        stored["refresh_token"] = new_tokens["refresh_token"]
        stored["refresh_expires_at"] = time.time() + new_tokens.get("refresh_expires_in", 1800)
    if "id_token" in new_tokens:
        stored["id_token"] = new_tokens["id_token"]
    try:
        with open(TOKEN_FILE, "w") as fh:
            json.dump(stored, fh, indent=2)
        os.chmod(TOKEN_FILE, 0o600)
    except IOError:
        pass  # best-effort save


def refresh_access_token(domino_url, refresh_token):
    """Exchange a refresh token for a fresh access token."""
    url = f"{domino_url}/auth/realms/{REALM}/protocol/openid-connect/token"
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": refresh_token,
    }).encode()

    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
    })
    with _urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def main():
    stored = load_tokens()

    if not stored or not stored.get("access_token"):
        # No tokens — output empty headers; MCP will get a 401/302
        print("{}")
        return

    access_token = stored["access_token"]
    expires_at = stored.get("expires_at", 0)
    domino_url = stored.get("domino_url", "")

    # Refresh if access token is expired or within 30s of expiry
    if time.time() >= (expires_at - 30):
        refresh_tok = stored.get("refresh_token")
        if refresh_tok and domino_url:
            try:
                new_tokens = refresh_access_token(domino_url, refresh_tok)
                access_token = new_tokens["access_token"]
                save_tokens(stored, new_tokens)
            except Exception:
                # Refresh failed — use the (possibly stale) token anyway.
                # If the refresh token is also expired, the user needs to re-login.
                pass

    headers = {
        "Authorization": f"Bearer {access_token}",
    }
    print(json.dumps(headers))


if __name__ == "__main__":
    main()

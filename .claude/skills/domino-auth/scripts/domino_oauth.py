#!/usr/bin/env python3
"""
Domino Data Lab OAuth2 Authentication

Authenticates against Domino's Keycloak using the Device Code flow (RFC 8628).
This is the most reliable method for CLI tools — no redirect URIs needed.

Usage:
  python3 domino_oauth.py login <domino-url>         # Device code login
  python3 domino_oauth.py login <domino-url> --localhost  # Localhost callback (if allowed)
  python3 domino_oauth.py refresh [<domino-url>]     # Refresh tokens
  python3 domino_oauth.py check                      # Check token status
  python3 domino_oauth.py logout                     # Remove stored tokens
"""

import http.server
import urllib.parse
import json
import hashlib
import base64
import secrets
import os
import sys
import ssl
import subprocess
import tempfile
import time
import urllib.request
import urllib.error

# --- Configuration ---
TOKEN_DIR = os.path.expanduser("~/.domino-mcp")
TOKEN_FILE = os.path.join(TOKEN_DIR, "tokens.json")
REALM = "DominoRealm"
CLIENT_ID = "domino-connect-client"
SCOPES = "openid profile email domino-jwt-claims offline_access"
AUTH_TIMEOUT = 300  # 5 minutes


# --- SSL Handling ---
# Python on macOS (python.org install) doesn't use the system keychain by
# default.  Internal / dogfood Domino instances often have certs signed by a
# private CA that IS trusted by the OS but NOT by Python's bundled certifi.
# We work around this by exporting the macOS system root certificates and
# feeding them to an ssl.SSLContext.

_ssl_ctx_cache = None


def _get_ssl_context():
    """Return an SSLContext that trusts the system certificate store."""
    global _ssl_ctx_cache
    if _ssl_ctx_cache is not None:
        return _ssl_ctx_cache

    ctx = ssl.create_default_context()

    # 1. Honour explicit CA bundle env vars
    for var in ("DOMINO_CA_BUNDLE", "SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
        path = os.environ.get(var)
        if path and os.path.exists(path):
            ctx.load_verify_locations(path)
            _ssl_ctx_cache = ctx
            return ctx

    # 2. On macOS, export system + user keychain certs
    if sys.platform == "darwin":
        try:
            certs = ""
            for keychain in (
                "/System/Library/Keychains/SystemRootCertificates.keychain",
                "/Library/Keychains/System.keychain",
            ):
                if os.path.exists(keychain):
                    r = subprocess.run(
                        ["security", "find-certificate", "-a", "-p", keychain],
                        capture_output=True, text=True, timeout=10,
                    )
                    if r.returncode == 0 and r.stdout:
                        certs += r.stdout + "\n"
            # Also the default (login) keychain
            r = subprocess.run(
                ["security", "find-certificate", "-a", "-p"],
                capture_output=True, text=True, timeout=10,
            )
            if r.returncode == 0 and r.stdout:
                certs += r.stdout + "\n"

            if certs.strip():
                tmp = tempfile.NamedTemporaryFile(
                    mode="w", suffix=".pem", delete=False, prefix="domino_ca_"
                )
                tmp.write(certs)
                tmp.close()
                new_ctx = ssl.create_default_context()
                new_ctx.load_verify_locations(tmp.name)
                os.unlink(tmp.name)
                _ssl_ctx_cache = new_ctx
                return new_ctx
        except Exception:
            pass  # fall through to default

    # 3. Allow opt-in insecure mode for truly unusual setups
    if os.environ.get("DOMINO_INSECURE", "").lower() in ("1", "true", "yes"):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        _ssl_ctx_cache = ctx
        return ctx

    _ssl_ctx_cache = ctx
    return ctx


def _urlopen(req, timeout=30):
    """urllib.request.urlopen with robust SSL handling."""
    ctx = _get_ssl_context()
    return urllib.request.urlopen(req, timeout=timeout, context=ctx)


# --- PKCE Helpers ---

def generate_pkce():
    """Generate PKCE code_verifier and code_challenge (S256)."""
    verifier = secrets.token_urlsafe(64)[:128]
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


# --- URL Builders ---

def keycloak_base(domino_url):
    return f"{domino_url}/auth/realms/{REALM}/protocol/openid-connect"


def build_auth_url(domino_url, code_challenge, state, redirect_uri):
    params = {
        "client_id": CLIENT_ID,
        "response_type": "code",
        "scope": SCOPES,
        "redirect_uri": redirect_uri,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    return f"{keycloak_base(domino_url)}/auth?{urllib.parse.urlencode(params)}"


# --- Token Exchange ---

def exchange_code_for_tokens(domino_url, code, code_verifier, redirect_uri):
    """Exchange an authorization code for access + refresh tokens."""
    url = f"{keycloak_base(domino_url)}/token"
    body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "client_id": CLIENT_ID,
        "code": code,
        "redirect_uri": redirect_uri,
        "code_verifier": code_verifier,
    }).encode()

    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
    })
    try:
        with _urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        print(f"ERROR: Token exchange failed (HTTP {exc.code}): {err}", file=sys.stderr)
        sys.exit(1)


def refresh_tokens(domino_url, refresh_token):
    """Use a refresh token to obtain new tokens."""
    url = f"{keycloak_base(domino_url)}/token"
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": refresh_token,
    }).encode()

    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
    })
    with _urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


# --- Token Storage ---

def save_tokens(domino_url, tokens):
    """Persist tokens to ~/.domino-mcp/tokens.json (mode 0600)."""
    os.makedirs(TOKEN_DIR, mode=0o700, exist_ok=True)
    data = {
        "domino_url": domino_url,
        "access_token": tokens["access_token"],
        "refresh_token": tokens.get("refresh_token"),
        "expires_at": time.time() + tokens.get("expires_in", 300),
        # refresh_expires_in=0 means offline token (never expires by time)
        "refresh_expires_at": (
            0 if tokens.get("refresh_expires_in", 0) == 0
            else time.time() + tokens["refresh_expires_in"]
        ),
        "token_type": tokens.get("token_type", "Bearer"),
        "id_token": tokens.get("id_token"),
        "saved_at": time.time(),
    }
    with open(TOKEN_FILE, "w") as fh:
        json.dump(data, fh, indent=2)
    os.chmod(TOKEN_FILE, 0o600)
    return data


def load_tokens():
    """Load stored tokens or return None."""
    if not os.path.exists(TOKEN_FILE):
        return None
    with open(TOKEN_FILE) as fh:
        return json.load(fh)


# --- OAuth Callback Server ---

class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Tiny HTTP handler that captures the OAuth redirect."""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return

        params = urllib.parse.parse_qs(parsed.query)

        if "error" in params:
            self.server.oauth_error = params["error"][0]
            self.server.oauth_error_desc = params.get("error_description", [""])[0]
            self._respond("Authentication Failed", "An error occurred. You can close this window and check the terminal.")
            return

        code = params.get("code", [None])[0]
        state = params.get("state", [None])[0]
        if not code:
            self.send_response(400)
            self.end_headers()
            return

        self.server.oauth_code = code
        self.server.oauth_state = state
        self._respond("Authentication Successful", "You can close this window and return to Claude Code.")

    def _respond(self, title, message):
        body = (
            f"<html><head><title>{title}</title>"
            "<style>body{font-family:system-ui;display:flex;justify-content:center;"
            "align-items:center;height:100vh;margin:0;background:#f5f5f5}"
            "div{text-align:center;padding:2rem;background:#fff;border-radius:12px;"
            "box-shadow:0 2px 8px rgba(0,0,0,.1)}</style></head>"
            f"<body><div><h1>{title}</h1><p>{message}</p></div></body></html>"
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, fmt, *args):
        pass  # suppress request logging


def _open_browser(url):
    """Best-effort browser open; never raises."""
    try:
        if sys.platform == "darwin":
            subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif sys.platform.startswith("linux"):
            subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            import webbrowser
            webbrowser.open(url)
    except Exception:
        pass


# --- Device Code Flow (primary) ---

def login_device_code(domino_url):
    """OAuth login using the Device Authorization Grant (RFC 8628).

    This is the best flow for CLI tools:
    - No redirect URI needed (avoids Keycloak client restrictions)
    - User visits a URL and enters a short code
    - Script polls until auth completes
    """
    device_url = f"{keycloak_base(domino_url)}/auth/device"

    # Step 1: Request a device code
    body = urllib.parse.urlencode({
        "client_id": CLIENT_ID,
        "scope": SCOPES,
    }).encode()

    req = urllib.request.Request(device_url, data=body, headers={
        "Content-Type": "application/x-www-form-urlencoded",
    })
    try:
        with _urlopen(req, timeout=30) as resp:
            device_resp = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        print(f"ERROR: Device code request failed (HTTP {exc.code}): {err}", file=sys.stderr)
        if exc.code == 400 and "client" in err.lower():
            print("The 'domino-play' client may not support device code flow.", file=sys.stderr)
            print("Try --localhost mode or ask your Domino admin to enable it.", file=sys.stderr)
        sys.exit(1)

    device_code = device_resp["device_code"]
    user_code = device_resp["user_code"]
    verification_uri = device_resp.get("verification_uri", "")
    verification_uri_complete = device_resp.get("verification_uri_complete", "")
    poll_interval = device_resp.get("interval", 5)
    expires_in = device_resp.get("expires_in", AUTH_TIMEOUT)

    # Step 2: Show the user what to do
    print()
    print("=" * 60)
    print("  Domino Data Lab Authentication")
    print("=" * 60)
    print()
    if verification_uri_complete:
        print(f"  1. Open this URL in your browser:\n")
        print(f"     {verification_uri_complete}")
        print()
        print(f"     (The code {user_code} is pre-filled)")
    else:
        print(f"  1. Open: {verification_uri}")
        print(f"  2. Enter code: {user_code}")
    print()
    print(f"  Waiting up to {expires_in // 60} minutes for you to log in...")
    print()

    # Try to open browser
    open_url = verification_uri_complete or verification_uri
    if open_url:
        _open_browser(open_url)

    # Step 3: Poll for token
    token_url = f"{keycloak_base(domino_url)}/token"
    deadline = time.time() + expires_in

    while time.time() < deadline:
        time.sleep(poll_interval)

        poll_body = urllib.parse.urlencode({
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": CLIENT_ID,
            "device_code": device_code,
        }).encode()

        poll_req = urllib.request.Request(token_url, data=poll_body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
        })

        try:
            with _urlopen(poll_req, timeout=30) as resp:
                tokens = json.loads(resp.read())
                # Success!
                saved = save_tokens(domino_url, tokens)
                print()
                print("Authentication successful!")
                print(f"  Tokens saved to: {TOKEN_FILE}")
                print(f"  Access token expires in: {tokens.get('expires_in', '?')}s")
                rt_exp = tokens.get("refresh_expires_in")
                if rt_exp:
                    if rt_exp > 86400:
                        print(f"  Refresh token expires in: {rt_exp // 86400} days")
                    elif rt_exp > 3600:
                        print(f"  Refresh token expires in: {rt_exp // 3600} hours")
                    else:
                        print(f"  Refresh token expires in: {rt_exp}s")
                return saved
        except urllib.error.HTTPError as exc:
            err_body = exc.read().decode("utf-8", errors="replace")
            try:
                err_json = json.loads(err_body)
                error = err_json.get("error", "")
            except json.JSONDecodeError:
                error = err_body

            if error == "authorization_pending":
                # User hasn't completed auth yet — keep polling
                continue
            elif error == "slow_down":
                poll_interval += 1
                continue
            elif error == "expired_token":
                print("ERROR: Device code expired. Please try again.", file=sys.stderr)
                sys.exit(1)
            elif error == "access_denied":
                print("ERROR: Access denied by user.", file=sys.stderr)
                sys.exit(1)
            else:
                print(f"ERROR: Token poll failed: {error}", file=sys.stderr)
                print(f"  Full response: {err_body}", file=sys.stderr)
                sys.exit(1)

    print("ERROR: Timed out waiting for authentication.", file=sys.stderr)
    sys.exit(1)


# --- Localhost Callback Flow (primary) ---

def _find_free_port():
    """Bind to port 0 and let the OS pick a free port, like the VS Code extension."""
    import socket
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def login_with_localhost(domino_url):
    """OAuth login using a localhost callback server with a dynamic port.

    Uses client_id=domino-connect-client which allows localhost redirects.
    """
    port = _find_free_port()
    code_verifier, code_challenge = generate_pkce()
    state = secrets.token_urlsafe(32)
    redirect_uri = f"http://localhost:{port}/callback"
    auth_url = build_auth_url(domino_url, code_challenge, state, redirect_uri)

    try:
        server = http.server.HTTPServer(("127.0.0.1", port), _CallbackHandler)
    except OSError as exc:
        print(f"ERROR: Could not bind port {port}: {exc}", file=sys.stderr)
        sys.exit(1)

    server.oauth_code = None
    server.oauth_state = None
    server.oauth_error = None
    server.oauth_error_desc = None
    server.timeout = AUTH_TIMEOUT

    print()
    print("=" * 60)
    print("  Domino Data Lab Authentication (Localhost Callback)")
    print("=" * 60)
    print()
    print("Opening browser for login...")
    print()
    print("If the browser does not open, visit this URL manually:")
    print()
    print(f"  {auth_url}")
    print()
    print(f"Waiting up to {AUTH_TIMEOUT // 60} minutes...")
    print()

    _open_browser(auth_url)

    deadline = time.time() + AUTH_TIMEOUT
    while server.oauth_code is None and server.oauth_error is None:
        remaining = deadline - time.time()
        if remaining <= 0:
            server.server_close()
            print("ERROR: Timed out.", file=sys.stderr)
            sys.exit(1)
        server.timeout = remaining
        server.handle_request()

    server.server_close()

    if server.oauth_error:
        print(f"ERROR: {server.oauth_error}: {server.oauth_error_desc}", file=sys.stderr)
        sys.exit(1)

    if server.oauth_state != state:
        print("ERROR: State mismatch.", file=sys.stderr)
        sys.exit(1)

    print("Exchanging authorization code for tokens...")
    tokens = exchange_code_for_tokens(domino_url, server.oauth_code, code_verifier, redirect_uri)
    saved = save_tokens(domino_url, tokens)

    print()
    print("Authentication successful!")
    print(f"  Tokens saved to: {TOKEN_FILE}")
    print(f"  Access token expires in: {tokens.get('expires_in', '?')}s")
    return saved


# --- Sub-commands ---

def cmd_login(domino_url, use_device_code=False):
    if use_device_code:
        return login_device_code(domino_url)
    else:
        return login_with_localhost(domino_url)


def cmd_refresh(domino_url):
    stored = load_tokens()
    if not stored or not stored.get("refresh_token"):
        print("ERROR: No stored refresh token. Run 'login' first.", file=sys.stderr)
        sys.exit(1)

    url = domino_url or stored.get("domino_url")
    if not url:
        print("ERROR: No Domino URL available.", file=sys.stderr)
        sys.exit(1)

    try:
        tokens = refresh_tokens(url, stored["refresh_token"])
    except urllib.error.HTTPError as exc:
        err = exc.read().decode("utf-8", errors="replace")
        print(f"ERROR: Refresh failed (HTTP {exc.code}): {err}", file=sys.stderr)
        print("Your session may have expired. Run 'login' again.", file=sys.stderr)
        sys.exit(1)

    save_tokens(url, tokens)
    print(json.dumps({"status": "refreshed", "expires_in": tokens.get("expires_in")}))


def cmd_check():
    stored = load_tokens()
    if not stored:
        result = {"authenticated": False, "reason": "no_tokens"}
    else:
        access_expired = time.time() >= stored.get("expires_at", 0)
        refresh_exp_at = stored.get("refresh_expires_at", 0)
        # 0 means offline token — never expires by time
        is_offline = refresh_exp_at == 0
        refresh_expired = False if is_offline else time.time() >= refresh_exp_at
        result = {
            "authenticated": True,
            "access_expired": access_expired,
            "refresh_expired": refresh_expired,
            "offline_token": is_offline,
            "domino_url": stored.get("domino_url", ""),
            "expires_at": stored.get("expires_at", 0),
            "refresh_expires_at": refresh_exp_at,
            "has_refresh_token": bool(stored.get("refresh_token")),
            "seconds_until_access_expiry": max(0, stored.get("expires_at", 0) - time.time()),
            "seconds_until_refresh_expiry": (
                "never" if is_offline else max(0, refresh_exp_at - time.time())
            ),
        }
    print(json.dumps(result, indent=2))


def cmd_logout():
    if os.path.exists(TOKEN_FILE):
        os.remove(TOKEN_FILE)
        print("Tokens removed.")
    else:
        print("No tokens to remove.")


# --- Main ---

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    action = sys.argv[1]

    if action == "check":
        cmd_check()
    elif action == "logout":
        cmd_logout()
    elif action == "login":
        if len(sys.argv) < 3:
            print("Usage: domino_oauth.py login <domino-url> [--device-code]", file=sys.stderr)
            sys.exit(1)
        domino_url = sys.argv[2].rstrip("/")
        use_device_code = "--device-code" in sys.argv[3:]
        cmd_login(domino_url, use_device_code=use_device_code)
    elif action == "refresh":
        domino_url = sys.argv[2].rstrip("/") if len(sys.argv) > 2 else None
        cmd_refresh(domino_url)
    else:
        print(f"Unknown action: {action}", file=sys.stderr)
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()

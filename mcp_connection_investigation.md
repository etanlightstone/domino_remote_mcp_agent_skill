# MCP Connection Drop Investigation — Claude Code + Domino Remote MCP Server

**Date:** 2026-04-09 / 2026-04-10
**Tested by:** Claude Code (Opus 4.6) during a live session
**Repo:** [etanlightstone/domino_remote_mcp_agent_skill](https://github.com/etanlightstone/domino_remote_mcp_agent_skill)

---

## Summary

The Claude Code native Streamable HTTP MCP client loses connectivity to the Domino Remote MCP Server after approximately 5 minutes. The root cause is that **Claude Code invokes `headersHelper` once per session and caches the result** — it does not re-invoke it before each HTTP request, or even on reconnect. Since Domino's Keycloak access tokens have a 5-minute TTL, the cached Bearer token expires and Domino's nginx proxy rejects subsequent requests with a `302 redirect` (HTML), which the MCP client reports as:

```
Streamable HTTP error: Unexpected content type: text/html;charset=utf-8
```

**If `headersHelper` were called per-request (or at least on reconnect), the existing `domino_headers.py` script would handle everything automatically — it already has token refresh logic built in.** The proxy workaround described below becomes unnecessary the moment Anthropic fixes this behavior.

This is tracked in **[anthropics/claude-code#5706: Missing Token Refresh Mechanism for MCP Server Integrations](https://github.com/anthropics/claude-code/issues/5706)**.

---

## Timeline of the Issue

| Step | Native MCP Client | Direct curl (fresh token) |
|------|:-----------------:|:-------------------------:|
| Session start → first calls | Works | Works |
| ~5 min later | **Fails** (302 HTML) | Works |
| All subsequent calls | **Fails** (302 HTML) | Works |

The first few MCP tool calls (e.g., `get_domino_environment_info`, `list_projects`, `run_domino_job`) succeeded because they happened within the initial 5-minute token window. After submitting a job and waiting, all native MCP calls permanently failed for the rest of the session.

---

## Evidence

### Test 1: The HTML is a 302 redirect from nginx (not from the MCP server)

When the Bearer token is missing or expired, Domino's **nginx** proxy returns a `302 Found` HTML redirect to the Keycloak login page:

```
$ curl -s -w "HTTP %{http_code}" -H "Authorization: Bearer expired_token" \
    -X POST https://apps.cloud-dogfood.domino.tech/apps/.../mcp
<html><head><title>302 Found</title></head>...</html>
HTTP 302   content-type: text/html
```

This is the **exact same response** the native MCP client receives. The MCP server never sees these requests — nginx rejects them before they arrive.

### Test 2: MCP Session ID is irrelevant

Sending a fake `Mcp-Session-Id` header with a valid token works fine. The server is stateless (`server_type: remote_http_stateless`), so MCP session expiry is not the cause:

```
$ curl -H "Mcp-Session-Id: fake-session-12345" -H "Authorization: Bearer <valid>" ...
→ 200 OK (works)
```

### Test 3: Fresh tokens always work via curl

Every curl call that invokes `headersHelper` fresh before the request succeeds, because the script auto-refreshes the access token using the long-lived offline refresh token:

```
$ TOKEN=$(python3 domino_headers.py | python3 -c '...')
$ curl -H "Authorization: $TOKEN" ... → 200 OK (always works)
```

### Test 4: Token TTL confirmed at 300 seconds

Decoded JWT payload:
```
iat: 1775773022
exp: 1775773322
TTL: 300 seconds (5 minutes)
```

### Test 5: Accept header enforcement confirms HTML is from nginx, not MCP server

The MCP server requires `Accept: application/json, text/event-stream`. Sending only one produces a `406` JSON error from the MCP server. But expired/missing auth produces a `302` HTML response from nginx — a completely different layer:

```
Accept: application/json only          → 406 (JSON error from MCP server)
Accept: text/event-stream only         → 406 (JSON error from MCP server)
No Authorization header                → 302 (HTML from nginx)
Invalid/expired Authorization          → 302 (HTML from nginx)
Both Accept types + valid token        → 200 OK ✓
```

### Test 6: `Connection: close` triggers reconnect but headersHelper does NOT re-fire

We built a test proxy that forwards requests to Domino and sends `Connection: close` on every tool call response, forcing the TCP connection to close. The hypothesis was that this would make Claude Code re-invoke `headersHelper` on reconnect.

**Result: headersHelper is NOT re-invoked on reconnect.** Proxy logs showed:

```
[req #1]  09:36:59 method=initialize           Client auth: Bearer eyJ...  (init, keep-alive)
[req #4]  09:37:01 method=tools/list           Client auth: Bearer eyJ...  (init, keep-alive)
[req #5]  09:38:01 method=notifications/cancelled Client auth: Bearer eyJ...  (Connection: close)
[req #9]  09:38:02 method=initialize           Client auth: <none>         ← RECONNECT, NO AUTH
[req #12] 09:38:12 method=tools/call           Client auth: Bearer eyJ...  (Connection: close)
[req #13] 09:42:12 method=tools/call           Client auth: Bearer eyJ...  (Connection: close)
```

Key observations:
- **Req #9**: Claude Code reconnected after `Connection: close` — but sent **no Authorization header**. headersHelper was NOT re-invoked.
- **Req #12 vs #13**: Tool calls 4 minutes apart both carried Bearer tokens (likely the same stale token from session init), but succeeded only because the proxy injected fresh tokens upstream.
- The native MCP call at 09:42:12 (after the original token expired) **would have failed without the proxy**.

**Conclusion: `Connection: close` is not a viable server-side fix.** headersHelper is truly once-per-session, not once-per-connection.

### Test 7: Server-side options are dead ends

We tested whether the MCP server author could change anything on their end:

| Server-side approach | Result |
|---------------------|--------|
| `dominoSession` cookie without Bearer | 302 — nginx still requires Bearer token |
| `X-Domino-Api-Key` header | 302 — not supported for Domino App endpoints |
| `Connection: close` from server | Triggers reconnect, but headersHelper doesn't re-fire |
| Any MCP server response header | Doesn't matter — the problem is on incoming requests at the nginx layer |

The auth enforcement happens at Domino's nginx proxy, **before the MCP server ever sees the request**. There is nothing the MCP server can do to fix this.

---

## Root Cause

**Claude Code's Streamable HTTP MCP client calls `headersHelper` once at session initialization.** It does not re-invoke it:
- Before each HTTP request
- On TCP reconnection
- On MCP protocol re-initialization
- After receiving auth errors (302/401)

The `headersHelper` script (`domino_headers.py`) is designed to be called frequently — it checks the stored access token's expiry and auto-refreshes it via the Keycloak token endpoint using the offline refresh token. This takes <10ms for a cached token or ~200ms for a refresh. But since it's only called once, the refresh logic never runs.

**If `headersHelper` were called per-request, everything would just work.** The existing auth architecture (OAuth login → offline refresh token → auto-refreshing headersHelper) is correctly designed. The only broken link is how often Claude Code invokes it.

---

## Exhaustive Review of Claude Code Auth Mechanisms

We investigated every available authentication mechanism in Claude Code:

| Mechanism | How it works | Per-request refresh? | Viable? |
|-----------|-------------|:-------------------:|:-------:|
| `headersHelper` | Script called once per session, output cached | **No** | Breaks after 5 min |
| Static `headers` in `.mcp.json` | Read at startup | No | Worse than headersHelper |
| Env vars (`${VAR}`) in config | Evaluated at startup only | No | Same caching problem |
| Built-in OAuth/PKCE | Initial auth works, but refresh token flow not implemented | No | [Issue #5706](https://github.com/anthropics/claude-code/issues/5706) |
| `PreToolUse` hooks | Can modify tool *input JSON*, but NOT HTTP transport headers | No | Cannot affect auth layer |
| `PostToolUseFailure` hooks | Fires on tool failure | No | Could detect failure but can't fix headers |
| MCP `Mcp-Session-Id` | Session tracking header | N/A | Server is stateless; not related to auth |

**No existing Claude Code mechanism supports per-request token refresh for HTTP MCP servers.**

---

## Recommended Solution: STDIO MCP Bridge

### Why not just fix `headersHelper`?

If Claude Code called `headersHelper` per-request (or at least on reconnect), the existing `domino_headers.py` would handle everything automatically. But that requires a change from Anthropic — tracked in **[anthropics/claude-code#5706](https://github.com/anthropics/claude-code/issues/5706)**. Timeline unknown.

### The fix: bypass `headersHelper` entirely with a STDIO bridge

Instead of using Claude Code's HTTP MCP client (which caches auth headers), run a **local STDIO MCP server** that handles auth internally. Claude Code spawns STDIO servers as child processes and communicates via stdin/stdout — no HTTP, no headers, no caching problem.

```
Before (broken after 5 min):
  Claude Code → headersHelper (once) → HTTP → nginx (rejects stale token) → MCP Server

After (works indefinitely):
  Claude Code ←STDIO→ Bridge process ←HTTP + fresh token→ nginx → MCP Server
```

The bridge (`domino_mcp_bridge.py`):
1. Reads JSON-RPC from **stdin** (sent by Claude Code)
2. Calls `domino_headers.py` token logic for a **fresh token on every request**
3. POSTs to the remote Domino MCP endpoint with valid `Authorization`
4. Writes the JSON-RPC response to **stdout** (back to Claude Code)

#### Configuration

```json
{
  "mcpServers": {
    "domino-mcp": {
      "type": "stdio",
      "command": "python3",
      "args": [
        ".claude/skills/domino-auth/scripts/domino_mcp_bridge.py",
        "https://apps.cloud-dogfood.domino.tech/apps/<app-id>/mcp"
      ]
    }
  }
}
```

No `headersHelper` config needed. No separate process to manage. Claude Code starts and stops the bridge automatically.

#### Why this is better than the HTTP proxy approach

We first built and tested a local HTTP proxy (`token_proxy_prototype.py`). It worked but had problems:

| | HTTP Proxy | STDIO Bridge |
|-|:----------:|:------------:|
| Separate process to manage | Yes (user must start/stop) | No (Claude Code manages it) |
| Port allocation | Needed (risk of conflicts) | Not needed |
| Local HTTP server + SSL | Required | Not needed |
| `Connection: close` issues | Caused BrokenPipeError noise | N/A |
| Config complexity | URL + port in `.mcp.json` | Just command + args |

#### Tested and proven

The bridge was tested with the full MCP protocol handshake:

```
[init]  server: domino_remote_server v3.2.2      ✓
[tools] 9 tools discovered                       ✓
[call]  get_domino_environment_info               ✓
```

The HTTP proxy was also tested through a full token-expiry cycle, confirming that per-request token refresh works. The bridge uses the same token refresh logic:

```
09:38:54  Access token expires in 137s
09:42:08  Access token: EXPIRED (0s remaining)
09:42:12  Native MCP tool call → ✓ SUCCESS (proxy refreshed token)
```

#### Integration into the skill

The `/domino-auth` skill needs only a small change:
1. Run the OAuth login flow (as today — browser-based, stores tokens)
2. Write `.mcp.json` with `type: "stdio"` pointing to `domino_mcp_bridge.py` (instead of `type: "http"` with `headersHelper`)
3. User restarts Claude Code — native MCP tools work indefinitely

The OAuth skill, `domino_oauth.py`, and `domino_headers.py` are all unchanged. The bridge imports the token refresh logic from `domino_headers.py` directly.

**If Anthropic fixes `headersHelper`** (per-request invocation), the skill can revert to the simpler `type: "http"` + `headersHelper` config and the bridge becomes unnecessary.

---

## Other Options Considered (and why STDIO bridge wins)

### Option B: HTTP Token-Refreshing Proxy

A local HTTP proxy on `localhost:PORT` that injects fresh tokens. We built and tested this (`token_proxy_prototype.py`) — it works but requires the user to run a separate process, manage ports, and deal with HTTP/SSL complexity locally. The STDIO bridge is strictly better.

### Option C: CLAUDE.md-guided curl fallback

Tell Claude to fall back to raw curl commands when native MCP calls fail. This is what we did during the initial session — it works but is fragile:
- Claude must detect the failure pattern and switch approaches
- Tool call UX is lost (no structured tool results, just raw curl output)
- Requires parsing SSE responses manually
- Not transparent to the user

### Option D: Extend Keycloak token TTL

Increase the access token lifespan for `domino-connect-client` from 5 minutes to e.g. 8 hours via Keycloak admin:
- Simplest fix but may not be appropriate for all security postures
- Doesn't fully solve the problem (sessions longer than the TTL still break)
- Requires Domino admin changes per deployment, not self-service

### Option E: Server-side changes to the MCP server

**Not viable.** Domino's nginx proxy validates the Bearer token before requests reach the MCP server. The MCP server never sees failed requests and cannot compensate for expired tokens. We tested `Connection: close`, cookie-based auth, and API key headers — none bypass the nginx token validation.

---

## For Anthropic (Claude Code Team)

Reference: **[anthropics/claude-code#5706](https://github.com/anthropics/claude-code/issues/5706)**

### 1. Call `headersHelper` per-request (or at minimum, on reconnect)

The current once-per-session caching makes `headersHelper` unusable for OAuth access tokens (typically 5–15 min TTL). The helper script is lightweight (<10ms cached, ~200ms for a refresh). Calling it per-request would fix this for all OAuth-protected MCP servers with zero server-side changes.

### 2. Re-invoke `headersHelper` on auth failure (302/401) and retry

If the client detects a 302/401, it could re-invoke `headersHelper` and retry the request once. This would self-heal expired tokens without any configuration changes.

We proved this would work: the existing `domino_headers.py` already handles token refresh correctly. The only missing piece is Claude Code calling it again.

### 3. Improve error messages for 302 redirects

When the MCP client receives a `302 text/html` response, the error should hint at token expiry:
```
Current:  "Streamable HTTP error: Unexpected content type: text/html;charset=utf-8"
Better:   "MCP server returned 302 redirect (text/html) — the auth token may have
           expired. If using headersHelper, the cached token may be stale."
```

### 4. Document `headersHelper` invocation frequency

The current docs are ambiguous — they say "called on each connection" which could mean per-TCP-connection or per-session. Our testing proved it means **per-session only** (not even on reconnect). This should be explicitly documented so MCP server authors can design their auth accordingly.

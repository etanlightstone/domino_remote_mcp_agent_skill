---
name: domino-auth
description: Authenticate to Domino Data Lab via OAuth and connect to a remote Domino MCP server. Use when user mentions Domino login, Domino auth, or Domino MCP connection issues.
user-invocable: true
allowed-tools: Bash Read Write Edit
argument-hint: [domino-instance-url]
---

# Domino Data Lab Authentication & MCP Connection

Authenticate the user to a Domino Data Lab instance via Keycloak OAuth2 (Authorization Code + PKCE) and configure a remote MCP server connection.

## Overview

Domino uses Keycloak (realm `DominoRealm`, client `domino-connect-client`). The OAuth flow opens a browser for login, captures the callback on a dynamic localhost port, and stores tokens at `~/.domino-mcp/tokens.json`. A headersHelper script injects the Bearer token into MCP requests and auto-refreshes it. With `offline_access` scope, the refresh token never expires — user authenticates once.

## Step 1 — Determine the Domino URL

If the user provided a URL argument (`$ARGUMENTS`), use it.
Otherwise, ask for their Domino instance URL (e.g. `https://cloud-dogfood.domino.tech`).

## Step 2 — Check existing auth status

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/domino_oauth.py" check
```

Parse the JSON output:
- `authenticated: true` + `access_expired: false` → already logged in, skip to Step 4.
- `authenticated: true` + `access_expired: true` + `offline_token: true` → the headersHelper will auto-refresh. Tell the user they're fine.
- `authenticated: true` + `refresh_expired: true` + `offline_token: false` → re-login needed (Step 3).
- `authenticated: false` → proceed to Step 3.

## Step 3 — Run the OAuth login

**Use a 5-minute timeout (300000ms)** since it waits for browser authentication:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/domino_oauth.py" login <domino-url>
```

This will:
1. Start a local HTTP server on a dynamically-allocated port
2. Open the browser to Keycloak login (client: `domino-connect-client`, scopes: `openid profile email domino-jwt-claims offline_access`)
3. Capture the OAuth callback with PKCE verification
4. Save tokens to `~/.domino-mcp/tokens.json`

The `offline_access` scope gives a long-lived refresh token — the user only needs to log in once.

## Step 4 — Configure the MCP server

Ask the user for the MCP server URL if not already known. For the test server:
`https://apps.cloud-dogfood.domino.tech/apps/403c7f11-77da-41a5-bb16-a638488c9eef/mcp`

The project `.mcp.json` may already have this configured. If not, add it:

```bash
claude mcp add-json domino-mcp '{"type":"http","url":"<MCP_SERVER_URL>","headersHelper":"python3 '"${CLAUDE_SKILL_DIR}"'/scripts/domino_headers.py"}'
```

The MCP server uses **Streamable HTTP** transport (not SSE), so `type` must be `"http"`.

After adding, tell the user: **Restart your Claude Code session** for the MCP server to connect.

## Step 4b — First-time pass-through authentication warning

Before the user restarts, check whether they may need to authorize the Domino app proxy. Extract the MCP server URL from the project `.mcp.json` (look under `mcpServers.*.url` for any entry whose URL contains `/mcp`). Strip the trailing `/mcp` to get the base app URL.

For example, if `.mcp.json` contains:
```
"url": "https://apps.cloud-dogfood.domino.tech/apps/adfa68c5-f233-4b15-97cd-665701e0c2cb/mcp"
```
then the base app URL is:
```
https://apps.cloud-dogfood.domino.tech/apps/adfa68c5-f233-4b15-97cd-665701e0c2cb
```

**Tell the user:**

> ⚠️ **First-time setup required:** If this is your first time connecting to this MCP server, you must visit the app URL below in your browser **before** restarting the session:
>
> `<base app URL>`
>
> Domino will show a "pass-through authentication" prompt — click to accept it. This authorizes the app to act on your behalf. You only need to do this once per app.

If the user confirms they've already done this (or it's not their first time), they can skip straight to restarting.

## Step 5 — Verify (after restart)

After restart, the Domino MCP tools should appear. If issues occur:
1. Check: `python3 "${CLAUDE_SKILL_DIR}/scripts/domino_oauth.py" check`
2. Test headers: `python3 "${CLAUDE_SKILL_DIR}/scripts/domino_headers.py"`
3. Re-login if needed: repeat Step 3

## Logout

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/domino_oauth.py" logout
```

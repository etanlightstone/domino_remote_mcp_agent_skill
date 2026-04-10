# Domino Remote MCP Agent Skill

Connect your AI coding agent to a [Domino Data Lab](https://www.dominodatalab.com/) MCP server — so you can write code locally and run jobs, manage data, and train models on Domino, all from your IDE.

Works with: **Claude Code**, **Cursor**, **Codex**, **Kiro**, **GitHub Copilot**, and any MCP-capable IDE.

## How It Works

```
Your Laptop                              Domino Data Lab
┌──────────────────────┐                 ┌──────────────────────────┐
│  IDE (Claude Code,   │                 │  MCP Server (App)        │
│   Cursor, Codex,     │                 │  ├── Run jobs             │
│   Kiro, Copilot)     │                 │  ├── Manage files         │
│                      │   STDIO         │  ├── Check status         │
│  ├── AGENTS.md       │ ◄──────►        │  └── MLflow experiments   │
│  ├── MCP config      │   JSON-RPC      └──────────────────────────┘
│  └── Bridge process  │       │
│      (auto-managed)  │       │
│                      │   HTTP + fresh
│  Bridge injects      │   Bearer token
│  fresh Bearer token  │ ──────────────►  nginx (validates token)
│  on every request    │                  ──────► MCP Server
└──────────────────────┘
```

Your IDE spawns a lightweight STDIO bridge process that handles authentication internally. The bridge gets a fresh OAuth token for every HTTP request to Domino, so connections never expire. You authenticate once — the offline refresh token keeps you logged in indefinitely.

## Prerequisites — Deploy the Domino MCP Server

Before using this skill, a Domino admin (or any user with project-publish permissions) must deploy the **[Domino Remote MCP Server](https://github.com/etanlightstone/domino-remote-mcp-proj)** as a Domino App. This is the server that your IDE connects to.

### Deployment steps

1. **Create a Domino project** (or use an existing one) and add the files from [etanlightstone/domino-remote-mcp-proj](https://github.com/etanlightstone/domino-remote-mcp-proj).
2. **Publish the project as a Domino App** with the app script set to `app.sh`.
3. **Enable "Identity Propagation"** (also called "pass-through authentication") on the app. This allows the app to act on behalf of each connecting user rather than the app owner — so Domino jobs, file operations, and project access all respect individual user permissions and audit trails.
4. **Grant access** to all Domino users who will be using this agent skill. In the app settings, add each user (or group) so they are authorized to access the app.
5. **Note the app URL** — it will look like:
   ```
   https://apps.<your-domino>/apps/<app-id>/mcp
   ```

> **Important:** Each user connecting for the first time must visit the app's base URL (without `/mcp`) in their browser and accept the identity propagation consent prompt. This is a one-time step per user per app.

## Quick Start

### 1. Install into your project directory

Run this **from inside your existing project directory** (the one whose git repo matches your Domino project). It overlays the skill files without touching your `.git`:

```bash
bash <(curl -sL https://raw.githubusercontent.com/etanlightstone/domino_remote_mcp_agent_skill/main/setup.sh)
```

The script will:
- Download the skill files, `AGENTS.md`, `.gitignore`, and MCP configs into your directory
- Prompt you for your **Domino MCP Server URL** (the published app URL from the prerequisite step)
- Write MCP configs for **all supported agents** (Claude Code, Cursor, Codex, Kiro, Copilot)

### 2. Authenticate

**Claude Code** (built-in skill):

```
/domino-auth https://your-domino-instance.example.com
```

**Any IDE** (run in your terminal):

```bash
python3 .claude/skills/domino-auth/scripts/domino_oauth.py login https://your-domino-instance.example.com
```

This opens your browser for Domino login (Keycloak OAuth2 + PKCE). Tokens are saved to `~/.domino-mcp/tokens.json` — not in your project, so they're never committed.

### 3. Restart your IDE

The MCP server connection is established at session startup. After authenticating, restart your IDE session:

- **Claude Code:** `/exit` then `claude`
- **Cursor:** Cmd+Shift+P → "Reload Window"
- **Codex / Kiro / Copilot:** Restart your session

The Domino MCP tools will now be available.

### 4. Start working

Your IDE is now a Domino-aware agent. Try prompts like:

> "There's a dataset in this project — run a simple analysis of the data, write a model architecture and a separate training script, then train two small models to compare in Domino."

> "List all files in the project and show me what data is available."

> "Run a job that profiles the dataset and generates summary statistics."

## What Gets Installed

| Path | Purpose |
|------|---------|
| `AGENTS.md` | Agent instructions — tells the AI how to use Domino (universal standard) |
| `CLAUDE.md` | Copy of `AGENTS.md` (for Claude Code compatibility) |
| `.claude/skills/domino-auth/SKILL.md` | Skill definition (Claude Code + Cursor auto-discover this) |
| `.claude/skills/domino-auth/scripts/domino_oauth.py` | OAuth2 login (Auth Code + PKCE, device code fallback) |
| `.claude/skills/domino-auth/scripts/domino_headers.py` | Token refresh logic (used by the bridge) |
| `.claude/skills/domino-auth/scripts/domino_mcp_bridge.py` | STDIO-to-HTTP bridge — fresh token on every request |
| `.mcp.json` | MCP config for Claude Code + Copilot CLI |
| `.cursor/mcp.json` | MCP config for Cursor |
| `.kiro/settings/mcp.json` | MCP config for Kiro |
| `.codex/config.toml` | MCP config for Codex |
| `.gitignore` | Excludes tokens and local settings |
| `setup.sh` | This installer (can be deleted after setup) |

## Authentication Details

| Detail | Value |
|--------|-------|
| Identity Provider | Keycloak (built into Domino) |
| Realm | `DominoRealm` |
| Client ID | `domino-connect-client` (same as the VS Code extension) |
| Flow | Authorization Code + PKCE (localhost callback) |
| Scopes | `openid profile email domino-jwt-claims offline_access` |
| Access Token TTL | 5 minutes (auto-refreshed by the bridge per-request) |
| Refresh Token | Offline token — never expires by time |
| Token Storage | `~/.domino-mcp/tokens.json` (mode 0600, outside project) |

### Why a STDIO bridge?

Most AI coding agents cache HTTP auth headers at session startup and don't refresh them. Since Domino access tokens expire every 5 minutes, a direct HTTP connection breaks after the first token expires. The STDIO bridge solves this by running as a local child process that the IDE manages automatically — it refreshes the Bearer token on every request, so connections work indefinitely. No separate process to start, no ports to manage.

### SSL / Private CAs

For Domino instances with certificates signed by a private CA, the scripts automatically export macOS system keychain certificates. You can also set any of these environment variables to point to a custom CA bundle:

```bash
export DOMINO_CA_BUNDLE=/path/to/ca-bundle.pem
# or: SSL_CERT_FILE, REQUESTS_CA_BUNDLE, CURL_CA_BUNDLE
```

For development/testing only: `export DOMINO_INSECURE=1` disables certificate verification.

## Manual Setup (without the script)

If you prefer not to run the setup script:

1. Download the tarball and extract:
   ```bash
   curl -sL https://github.com/etanlightstone/domino_remote_mcp_agent_skill/archive/main.tar.gz \
     | tar xz --strip-components=1
   ```

2. Copy `AGENTS.md` to `CLAUDE.md` (so Claude Code finds it):
   ```bash
   cp AGENTS.md CLAUDE.md
   ```

3. Edit the MCP config for your IDE and replace the URL:

   **Claude Code / Copilot CLI** (`.mcp.json`):
   ```json
   {
     "mcpServers": {
       "domino-mcp": {
         "type": "stdio",
         "command": "python3",
         "args": [
           ".claude/skills/domino-auth/scripts/domino_mcp_bridge.py",
           "https://apps.your-domino.example.com/apps/YOUR-APP-ID/mcp"
         ]
       }
     }
   }
   ```

   **Cursor** (`.cursor/mcp.json`), **Kiro** (`.kiro/settings/mcp.json`):
   ```json
   {
     "mcpServers": {
       "domino-mcp": {
         "command": "python3",
         "args": [
           ".claude/skills/domino-auth/scripts/domino_mcp_bridge.py",
           "https://apps.your-domino.example.com/apps/YOUR-APP-ID/mcp"
         ]
       }
     }
   }
   ```

   **Codex** (`.codex/config.toml`):
   ```toml
   [mcp_servers.domino-mcp]
   command = "python3"
   args = [".claude/skills/domino-auth/scripts/domino_mcp_bridge.py", "https://apps.your-domino.example.com/apps/YOUR-APP-ID/mcp"]
   ```

4. Authenticate and restart your IDE (see Quick Start above).

## How the Agent Uses Domino

Once connected, the AI agent follows these behaviors (defined in `AGENTS.md`):

- **Runs work on Domino, not locally** — scripts execute as Domino Jobs so they have access to project data, GPUs, and the configured environment
- **Git-aware** — for Git-based projects, the agent commits and pushes before running jobs so Domino sees the latest code
- **DFS-aware** — for DFS-based projects, the agent uses the MCP file sync tools instead of git
- **MLflow instrumentation** — model training scripts include MLflow tracking automatically, so experiments appear in Domino's Experiment Manager
- **Project-scoped** — on first use, the agent asks which Domino project to target and saves it to `domino_project_settings.md` so it remembers across sessions

## Troubleshooting

| Problem | Fix |
|---------|-----|
| No Domino tools after restart | Check your IDE's MCP config file has the correct URL. Run `python3 .claude/skills/domino-auth/scripts/domino_oauth.py check` to verify auth. |
| Token / auth errors | Run `python3 .claude/skills/domino-auth/scripts/domino_headers.py` — it should print a JSON object with an `Authorization` header. If it prints `{}`, re-authenticate. |
| SSL certificate errors | Set `DOMINO_CA_BUNDLE` env var (see above). On macOS, ensure the CA cert is in your system keychain. |
| "Pass-through auth" error | Visit the app's base URL (without `/mcp`) in your browser and accept the consent prompt. |
| Bridge not starting | Verify `python3` is in your PATH and test with: `echo '{}' \| python3 .claude/skills/domino-auth/scripts/domino_mcp_bridge.py YOUR_URL` |
| Wrong MCP server URL | Edit the MCP config for your IDE (see Manual Setup) and restart. |

## Requirements

- **Python 3.7+** (for the OAuth and bridge scripts — no pip dependencies needed)
- **An MCP-capable IDE**: Claude Code, Cursor, Codex, Kiro, GitHub Copilot, etc.
- **A [Domino Remote MCP Server](https://github.com/etanlightstone/domino-remote-mcp-proj)** published as a Domino App with **identity propagation enabled** and access granted to your users (see [Prerequisites](#prerequisites--deploy-the-domino-mcp-server))
- A browser for the one-time OAuth login and the one-time identity propagation consent

## License

MIT

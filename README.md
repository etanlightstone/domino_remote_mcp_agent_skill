# Domino Remote MCP Agent Skill for Claude Code

Connect [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to a [Domino Data Lab](https://www.dominodatalab.com/) MCP server running inside a Domino project — so you can write code locally and run jobs, manage data, and train models on Domino, all from your terminal.

## How It Works

```
Your Laptop                              Domino Data Lab
┌──────────────────────┐                 ┌──────────────────────────┐
│  Claude Code          │   MCP (HTTP)    │  MCP Server (App)        │
│  ├── CLAUDE.md        │ ◄────────────► │  ├── Run jobs             │
│  ├── .mcp.json        │   + Bearer     │  ├── Manage files         │
│  └── .claude/skills/  │     token      │  ├── Check status         │
│      └── domino-auth/ │                │  └── MLflow experiments   │
│          ├── OAuth    │                └──────────────────────────┘
│          └── Headers  │
└──────────────────────┘
```

Claude Code talks to a Domino-hosted MCP server over HTTP. The skill handles OAuth2 authentication (via Keycloak) and automatically injects a Bearer token into every request. You authenticate once — the offline refresh token keeps you logged in indefinitely.

## Quick Start

### 1. Install into your project directory

Run this **from inside your existing project directory** (the one whose git repo matches your Domino project). It overlays the skill files without touching your `.git`:

```bash
bash <(curl -sL https://raw.githubusercontent.com/etanlightstone/domino_remote_mcp_agent_skill/main/setup.sh)
```

The script will:
- Download `.claude/`, `CLAUDE.md`, `.gitignore`, and `.mcp.json` into your directory
- Prompt you for your **Domino MCP Server URL** (the published app URL)
- Write a configured `.mcp.json` with your URL

> **Don't have an MCP server URL yet?** Ask your Domino admin to publish the Domino MCP Server as an App in a Domino project. The URL looks like: `https://<your-domino>/apps/<app-id>/mcp`

### 2. Authenticate

Open Claude Code and run the authentication skill:

```
/domino-auth https://your-domino-instance.example.com
```

This opens your browser for Domino login (Keycloak OAuth2 + PKCE). Tokens are saved to `~/.domino-mcp/tokens.json` — not in your project, so they're never committed.

### 3. Restart Claude Code

The MCP server connection is established at session startup. After authenticating, exit and relaunch:

```
/exit
claude
```

The Domino MCP tools will now be available. Claude will automatically call `get_domino_environment_info` to verify the connection.

### 4. Start working

Claude Code is now a Domino-aware agent. Try prompts like:

> "There's a dataset in this project — run a simple analysis of the data, write a model architecture and a separate training script, then train two small models to compare in Domino."

> "List all files in the project and show me what data is available."

> "Run a job that profiles the dataset and generates summary statistics."

> "Train a random forest and a logistic regression with MLflow tracking, then show me the experiment comparison."

## What Gets Installed

| Path | Purpose |
|------|---------|
| `.claude/skills/domino-auth/SKILL.md` | Skill definition — Claude Code auto-discovers this |
| `.claude/skills/domino-auth/scripts/domino_oauth.py` | OAuth2 login (Auth Code + PKCE, device code fallback) |
| `.claude/skills/domino-auth/scripts/domino_headers.py` | `headersHelper` — injects Bearer token, auto-refreshes |
| `.mcp.json` | MCP server configuration (your URL goes here) |
| `CLAUDE.md` | Agent instructions — tells Claude how to use Domino |
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
| Access Token TTL | 5 minutes (auto-refreshed by `headersHelper`) |
| Refresh Token | Offline token — never expires by time |
| Token Storage | `~/.domino-mcp/tokens.json` (mode 0600, outside project) |

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

2. Edit `.mcp.json` and replace the `url` value with your MCP server URL:
   ```json
   {
     "mcpServers": {
       "domino-mcp": {
         "type": "http",
         "url": "https://your-domino.example.com/apps/YOUR-APP-ID/mcp",
         "headersHelper": "python3 .claude/skills/domino-auth/scripts/domino_headers.py"
       }
     }
   }
   ```

3. Open Claude Code and run `/domino-auth <your-domino-url>`, then restart.

## How Claude Uses Domino

Once connected, Claude Code follows these behaviors (defined in `CLAUDE.md`):

- **Runs work on Domino, not locally** — scripts execute as Domino Jobs so they have access to project data, GPUs, and the configured environment
- **Git-aware** — for Git-based projects, Claude commits and pushes before running jobs so Domino sees the latest code
- **DFS-aware** — for DFS-based projects, Claude uses the MCP file sync tools instead of git
- **MLflow instrumentation** — model training scripts include MLflow tracking automatically, so experiments appear in Domino's Experiment Manager
- **Project-scoped** — on first use, Claude asks which Domino project to target and saves it to `domino_project_settings.md` so it remembers across sessions

## Troubleshooting

| Problem | Fix |
|---------|-----|
| No Domino tools after restart | Check `.mcp.json` URL is correct. Run `/domino-auth` to re-authenticate. |
| `headersHelper` errors | Run `python3 .claude/skills/domino-auth/scripts/domino_headers.py` manually — it should print a JSON object with an `Authorization` header. |
| SSL certificate errors | Set `DOMINO_CA_BUNDLE` env var (see above). On macOS, ensure the CA cert is in your system keychain. |
| Token expired | The offline refresh token should auto-renew. If not, run `/domino-auth <url>` again. |
| Wrong MCP server URL | Edit `.mcp.json` directly and restart Claude Code. |

## Requirements

- **Claude Code** (CLI, Desktop, or IDE extension)
- **Python 3.7+** (for the OAuth and headers scripts — no pip dependencies)
- **A Domino MCP Server** published as an App in your Domino instance
- A browser for the one-time OAuth login

## License

MIT

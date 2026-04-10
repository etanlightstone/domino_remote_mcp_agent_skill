#!/usr/bin/env bash
# ============================================================================
# Domino Remote MCP Agent Skill — Setup
#
# Overlays the skill files onto your current project directory and configures
# the Domino MCP server connection for all major AI coding agents.
#
# Supports: Claude Code, Cursor, Codex, Kiro, GitHub Copilot
#
# One-liner install (run from your project directory):
#
#   bash <(curl -sL https://raw.githubusercontent.com/etanlightstone/domino_remote_mcp_agent_skill/main/setup.sh)
#
# ============================================================================
set -euo pipefail

REPO="etanlightstone/domino_remote_mcp_agent_skill"
BRANCH="main"
TARBALL_URL="https://github.com/${REPO}/archive/${BRANCH}.tar.gz"

BRIDGE_SCRIPT=".claude/skills/domino-auth/scripts/domino_mcp_bridge.py"

# ── Colors ──────────────────────────────────────────────────────────────────
bold="\033[1m"
dim="\033[2m"
green="\033[32m"
cyan="\033[36m"
yellow="\033[33m"
red="\033[31m"
reset="\033[0m"

info()  { printf "${cyan}[INFO]${reset}  %s\n" "$*"; }
ok()    { printf "${green}[OK]${reset}    %s\n" "$*"; }
warn()  { printf "${yellow}[WARN]${reset}  %s\n" "$*"; }
err()   { printf "${red}[ERROR]${reset} %s\n" "$*" >&2; }

# ── Pre-flight checks ──────────────────────────────────────────────────────
command -v curl  >/dev/null 2>&1 || { err "curl is required but not found."; exit 1; }
command -v tar   >/dev/null 2>&1 || { err "tar is required but not found.";  exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 is required but not found."; exit 1; }

# ── Step 1: Download and overlay files ─────────────────────────────────────
echo
printf "${bold}Domino Remote MCP Agent Skill — Setup${reset}\n"
echo "========================================"
echo

info "Downloading skill files from github.com/${REPO} ..."

curl -sL "$TARBALL_URL" | tar xz --strip-components=1

ok "Skill files installed into $(pwd)"
echo

# ── Step 2: Prompt for the MCP server URL ──────────────────────────────────
printf "${bold}Enter your Domino MCP Server URL${reset}\n"
echo "(This is the app-published URL of the MCP server running in your Domino project.)"
echo "Example: https://apps.your-domino.example.com/apps/<app-id>/mcp"
echo
printf "  MCP Server URL: "
read -r MCP_URL

MCP_URL="$(echo "$MCP_URL" | sed 's|[[:space:]]*$||; s|/*$||')"

if [ -z "$MCP_URL" ]; then
    err "No URL provided. You can manually edit the MCP config files later."
    echo
else
    # ── Write MCP configs for all agents ────────────────────────────────

    # Claude Code + GitHub Copilot CLI (.mcp.json)
    cat > .mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "type": "stdio",
      "command": "python3",
      "args": [
        "${BRIDGE_SCRIPT}",
        "${MCP_URL}"
      ]
    }
  }
}
MCPEOF
    ok "Wrote .mcp.json (Claude Code, Copilot CLI)"

    # Cursor (.cursor/mcp.json)
    mkdir -p .cursor
    cat > .cursor/mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "command": "python3",
      "args": [
        "${BRIDGE_SCRIPT}",
        "${MCP_URL}"
      ]
    }
  }
}
MCPEOF
    ok "Wrote .cursor/mcp.json (Cursor)"

    # Kiro (.kiro/settings/mcp.json)
    mkdir -p .kiro/settings
    cat > .kiro/settings/mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "command": "python3",
      "args": [
        "${BRIDGE_SCRIPT}",
        "${MCP_URL}"
      ]
    }
  }
}
MCPEOF
    ok "Wrote .kiro/settings/mcp.json (Kiro)"

    # Codex (.codex/config.toml) — uses TOML, not JSON
    mkdir -p .codex
    cat > .codex/config.toml <<TOMLEOF
[mcp_servers.domino-mcp]
command = "python3"
args = ["${BRIDGE_SCRIPT}", "${MCP_URL}"]
TOMLEOF
    ok "Wrote .codex/config.toml (Codex)"

    echo
fi

# ── Step 3: Ensure CLAUDE.md is a copy of AGENTS.md ──────────────────────
# AGENTS.md is the primary file (universal standard).
# CLAUDE.md is a copy so Claude Code finds its preferred name.
# We use cp instead of symlink for Windows/git compatibility.
if [ -f AGENTS.md ]; then
    cp AGENTS.md CLAUDE.md
    ok "CLAUDE.md copied from AGENTS.md (Claude Code compatibility)"
fi

# ── Step 4: Extract the Domino host URL for auth ─────────────────────────
DOMINO_HOST=""
APP_BASE_URL=""
if [ -n "$MCP_URL" ]; then
    MCP_HOST="$(echo "$MCP_URL" | sed -E 's|(https?://[^/]+).*|\1|')"
    DOMINO_HOST="$(echo "$MCP_HOST" | sed -E 's|^(https?://)apps\.|\1|')"
    APP_BASE_URL="$(echo "$MCP_URL" | sed -E 's|/mcp$||')"
fi

# ── Step 5: Next steps ────────────────────────────────────────────────────
echo "========================================"
printf "${bold}Next Steps${reset}\n"
echo "========================================"
echo

if [ -n "$APP_BASE_URL" ]; then
    printf "${yellow}[!]${reset}  ${bold}First-time setup:${reset} If this is your first time using this MCP server,\n"
    echo "     visit this URL in your browser and accept the pass-through auth prompt:"
    echo
    printf "       ${dim}${APP_BASE_URL}${reset}\n"
    echo
    echo "     (You only need to do this once per app.)"
    echo
fi

echo "  1. Authenticate to Domino (opens your browser):"
echo
if [ -n "$DOMINO_HOST" ]; then
    printf "       ${dim}# Claude Code (built-in skill):${reset}\n"
    printf "       ${dim}/domino-auth ${DOMINO_HOST}${reset}\n"
    echo
    printf "       ${dim}# Any IDE (run in your terminal):${reset}\n"
    printf "       ${dim}python3 .claude/skills/domino-auth/scripts/domino_oauth.py login ${DOMINO_HOST}${reset}\n"
else
    printf "       ${dim}# Claude Code (built-in skill):${reset}\n"
    printf "       ${dim}/domino-auth https://your-domino-instance.example.com${reset}\n"
    echo
    printf "       ${dim}# Any IDE (run in your terminal):${reset}\n"
    printf "       ${dim}python3 .claude/skills/domino-auth/scripts/domino_oauth.py login https://your-domino-instance.example.com${reset}\n"
fi
echo

echo "  2. Open your IDE in this directory and restart/reload:"
echo
printf "       ${dim}claude${reset}              # Claude Code\n"
printf "       ${dim}cursor .${reset}             # Cursor\n"
printf "       ${dim}codex${reset}               # Codex\n"
printf "       ${dim}kiro${reset}                # Kiro\n"
echo

echo "  3. Start working! Example prompt:"
echo
printf "       ${dim}\"There's a dataset in this project, run a simple analysis,${reset}\n"
printf "       ${dim} write a model architecture and training script, then${reset}\n"
printf "       ${dim} train two small models to compare in Domino.\"${reset}\n"
echo
ok "Setup complete! MCP configs written for Claude Code, Cursor, Codex, Kiro, and Copilot."

#!/usr/bin/env bash
# ============================================================================
# Domino Remote MCP Agent Skill — Setup
#
# Overlays the skill files onto your current project directory and configures
# the Domino MCP server connection for your AI coding agent.
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
OAUTH_SCRIPT=".claude/skills/domino-auth/scripts/domino_oauth.py"

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

# ── Step 1: Which IDE? ────────────────────────────────────────────────────
echo
printf "${bold}Domino Remote MCP Agent Skill — Setup${reset}\n"
echo "========================================"
echo
printf "${bold}Which AI coding agent are you using?${reset}\n"
echo
echo "  1) Claude Code"
echo "  2) Cursor"
echo "  3) Codex (OpenAI)"
echo "  4) Kiro (AWS)"
echo "  5) GitHub Copilot"
echo "  6) All of the above"
echo
printf "  Enter number [1-6]: "
read -r IDE_CHOICE

case "$IDE_CHOICE" in
    1) IDE="claude"  ;;
    2) IDE="cursor"  ;;
    3) IDE="codex"   ;;
    4) IDE="kiro"    ;;
    5) IDE="copilot" ;;
    6) IDE="all"     ;;
    *) warn "Invalid choice, defaulting to all."; IDE="all" ;;
esac
echo

# ── Step 2: Download and overlay files ────────────────────────────────────
info "Downloading skill files from github.com/${REPO} ..."

curl -sL "$TARBALL_URL" | tar xz --strip-components=1

ok "Skill files installed into $(pwd)"
echo

# ── Step 3: Prompt for the MCP server URL ─────────────────────────────────
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
    # ── Write MCP config(s) for the chosen IDE ──────────────────────────

    write_claude_config() {
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
        ok "Wrote .mcp.json (Claude Code)"
    }

    write_cursor_config() {
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
    }

    write_codex_config() {
        mkdir -p .codex
        cat > .codex/config.toml <<TOMLEOF
[mcp_servers.domino-mcp]
command = "python3"
args = ["${BRIDGE_SCRIPT}", "${MCP_URL}"]
TOMLEOF
        ok "Wrote .codex/config.toml (Codex)"
    }

    write_kiro_config() {
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
    }

    write_copilot_config() {
        # Copilot CLI reads .mcp.json (same as Claude Code)
        write_claude_config
        ok "  (Copilot CLI also reads .mcp.json)"
    }

    case "$IDE" in
        claude)  write_claude_config ;;
        cursor)  write_cursor_config ;;
        codex)   write_codex_config ;;
        kiro)    write_kiro_config ;;
        copilot) write_copilot_config ;;
        all)
            write_claude_config
            write_cursor_config
            write_codex_config
            write_kiro_config
            ;;
    esac

    echo
fi

# ── Step 4: Ensure CLAUDE.md is a copy of AGENTS.md ──────────────────────
# AGENTS.md is the primary file (universal standard).
# CLAUDE.md is a copy so Claude Code finds its preferred name.
if [ -f AGENTS.md ]; then
    cp AGENTS.md CLAUDE.md
    ok "CLAUDE.md copied from AGENTS.md (Claude Code compatibility)"
fi

# ── Step 5: Extract the Domino host URL ──────────────────────────────────
DOMINO_HOST=""
APP_BASE_URL=""
if [ -n "$MCP_URL" ]; then
    MCP_HOST="$(echo "$MCP_URL" | sed -E 's|(https?://[^/]+).*|\1|')"
    DOMINO_HOST="$(echo "$MCP_HOST" | sed -E 's|^(https?://)apps\.|\1|')"
    APP_BASE_URL="$(echo "$MCP_URL" | sed -E 's|/mcp$||')"
fi

# ── Step 6: First-time pass-through auth ─────────────────────────────────
if [ -n "$APP_BASE_URL" ]; then
    echo
    printf "${yellow}[!]${reset}  ${bold}First-time setup:${reset} If this is your first time using this MCP server,\n"
    echo "     visit this URL in your browser and accept the pass-through auth prompt:"
    echo
    printf "       ${dim}${APP_BASE_URL}${reset}\n"
    echo
    echo "     (You only need to do this once per app.)"
    echo
    printf "  Have you already accepted the pass-through auth prompt? [y/N]: "
    read -r PASSTHROUGH_DONE
    PASSTHROUGH_DONE="$(echo "$PASSTHROUGH_DONE" | tr '[:upper:]' '[:lower:]')"
    if [ "$PASSTHROUGH_DONE" != "y" ] && [ "$PASSTHROUGH_DONE" != "yes" ]; then
        info "Opening the app URL in your browser..."
        if [ "$(uname)" = "Darwin" ]; then
            open "$APP_BASE_URL" 2>/dev/null || true
        elif command -v xdg-open >/dev/null 2>&1; then
            xdg-open "$APP_BASE_URL" 2>/dev/null || true
        fi
        echo
        printf "  Press Enter after you've accepted the prompt in your browser..."
        read -r
    fi
fi

# ── Step 7: Authenticate to Domino ───────────────────────────────────────
if [ -n "$DOMINO_HOST" ]; then
    echo
    printf "${bold}Authenticating to Domino...${reset}\n"
    echo
    python3 "${OAUTH_SCRIPT}" login "$DOMINO_HOST"
    echo
fi

# ── Step 8: Done ─────────────────────────────────────────────────────────
echo "========================================"
printf "${bold}Setup Complete!${reset}\n"
echo "========================================"
echo
echo "  Open your IDE in this directory and start working:"
echo
case "$IDE" in
    claude)  printf "       ${dim}claude${reset}\n" ;;
    cursor)  printf "       ${dim}cursor .${reset}\n" ;;
    codex)   printf "       ${dim}codex${reset}\n" ;;
    kiro)    printf "       ${dim}kiro${reset}\n" ;;
    copilot) printf "       ${dim}gh copilot${reset}\n" ;;
    all)
        printf "       ${dim}claude${reset}              # Claude Code\n"
        printf "       ${dim}cursor .${reset}             # Cursor\n"
        printf "       ${dim}codex${reset}               # Codex\n"
        printf "       ${dim}kiro${reset}                # Kiro\n"
        ;;
esac
echo
echo "  Example prompt:"
echo
printf "       ${dim}\"There's a dataset in this project, run a simple analysis,${reset}\n"
printf "       ${dim} write a model architecture and training script, then${reset}\n"
printf "       ${dim} train two small models to compare in Domino.\"${reset}\n"
echo
ok "All done!"

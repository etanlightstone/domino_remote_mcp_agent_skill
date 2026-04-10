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

# ── Step 1b: Which auth method? ──────────────────────────────────────────
printf "${bold}Which authentication method?${reset}\n"
echo
echo "  1) OAuth (recommended) — Browser-based login, auto-refreshing tokens"
echo "  2) API Key — Use a Domino API key from your account settings"
echo
printf "  Enter number [1-2]: "
read -r AUTH_CHOICE

case "$AUTH_CHOICE" in
    1) AUTH_METHOD="oauth"  ;;
    2) AUTH_METHOD="apikey" ;;
    *) warn "Invalid choice, defaulting to OAuth."; AUTH_METHOD="oauth" ;;
esac
echo

if [ "$AUTH_METHOD" = "oauth" ]; then
    command -v python3 >/dev/null 2>&1 || { err "python3 is required for OAuth mode but not found."; exit 1; }
fi

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
fi

# ── Step 3b: Prompt for API key (apikey mode only) ───────────────────────
API_KEY=""
if [ "$AUTH_METHOD" = "apikey" ] && [ -n "$MCP_URL" ]; then
    MCP_HOST_FOR_HINT="$(echo "$MCP_URL" | sed -E 's|(https?://)apps\.|\1|; s|/apps/.*||')"
    echo
    printf "${bold}Enter your Domino API Key${reset}\n"
    echo "(Generate one at: ${MCP_HOST_FOR_HINT}/account#apikey)"
    echo
    printf "  API Key: "
    read -r API_KEY

    if [ -z "$API_KEY" ]; then
        err "No API key provided. You can manually edit the MCP config files later."
    fi
    echo
fi

# ── Step 4: Write MCP config(s) ──────────────────────────────────────────
if [ -n "$MCP_URL" ]; then

    # ── OAuth config writers (STDIO bridge) ──────────────────────────────

    write_claude_config_oauth() {
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
        ok "Wrote .mcp.json (Claude Code — OAuth bridge)"
    }

    write_cursor_config_oauth() {
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
        ok "Wrote .cursor/mcp.json (Cursor — OAuth bridge)"
    }

    write_codex_config_oauth() {
        mkdir -p .codex
        cat > .codex/config.toml <<TOMLEOF
[mcp_servers.domino-mcp]
command = "python3"
args = ["${BRIDGE_SCRIPT}", "${MCP_URL}"]
TOMLEOF
        ok "Wrote .codex/config.toml (Codex — OAuth bridge)"
    }

    write_kiro_config_oauth() {
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
        ok "Wrote .kiro/settings/mcp.json (Kiro — OAuth bridge)"
    }

    write_copilot_config_oauth() {
        write_claude_config_oauth
        ok "  (Copilot CLI also reads .mcp.json)"
    }

    # ── API Key config writers (direct HTTP) ─────────────────────────────

    write_claude_config_apikey() {
        cat > .mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "type": "streamable-http",
      "url": "${MCP_URL}",
      "headers": {
        "X-Domino-Api-Key": "${API_KEY}"
      }
    }
  }
}
MCPEOF
        ok "Wrote .mcp.json (Claude Code — API Key)"
    }

    write_cursor_config_apikey() {
        mkdir -p .cursor
        cat > .cursor/mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "url": "${MCP_URL}",
      "headers": {
        "X-Domino-Api-Key": "${API_KEY}"
      }
    }
  }
}
MCPEOF
        ok "Wrote .cursor/mcp.json (Cursor — API Key)"
    }

    write_codex_config_apikey() {
        mkdir -p .codex
        cat > .codex/config.toml <<TOMLEOF
[mcp_servers.domino-mcp]
url = "${MCP_URL}"

[mcp_servers.domino-mcp.headers]
X-Domino-Api-Key = "${API_KEY}"
TOMLEOF
        ok "Wrote .codex/config.toml (Codex — API Key)"
    }

    write_kiro_config_apikey() {
        mkdir -p .kiro/settings
        cat > .kiro/settings/mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "url": "${MCP_URL}",
      "headers": {
        "X-Domino-Api-Key": "${API_KEY}"
      }
    }
  }
}
MCPEOF
        ok "Wrote .kiro/settings/mcp.json (Kiro — API Key)"
    }

    write_copilot_config_apikey() {
        write_claude_config_apikey
        ok "  (Copilot CLI also reads .mcp.json)"
    }

    # ── Dispatch to the correct writer ───────────────────────────────────

    if [ "$AUTH_METHOD" = "apikey" ]; then
        case "$IDE" in
            claude)  write_claude_config_apikey ;;
            cursor)  write_cursor_config_apikey ;;
            codex)   write_codex_config_apikey ;;
            kiro)    write_kiro_config_apikey ;;
            copilot) write_copilot_config_apikey ;;
            all)
                write_claude_config_apikey
                write_cursor_config_apikey
                write_codex_config_apikey
                write_kiro_config_apikey
                ;;
        esac
    else
        case "$IDE" in
            claude)  write_claude_config_oauth ;;
            cursor)  write_cursor_config_oauth ;;
            codex)   write_codex_config_oauth ;;
            kiro)    write_kiro_config_oauth ;;
            copilot) write_copilot_config_oauth ;;
            all)
                write_claude_config_oauth
                write_cursor_config_oauth
                write_codex_config_oauth
                write_kiro_config_oauth
                ;;
        esac
    fi

    echo
fi

# ── Step 5: Place agent rules file for the chosen IDE ────────────────────
# The repo contains two variants:
#   AGENTS.md         — OAuth mode (references skill files, auth architecture)
#   AGENTS_APIKEY.md  — API Key mode (simplified, no auth sections)
#
# Claude Code reads CLAUDE.md; all other agents read AGENTS.md.
# We place exactly one file (or both for "all"), then clean up the unused variant.

RULES_SOURCE="AGENTS.md"
if [ "$AUTH_METHOD" = "apikey" ]; then
    RULES_SOURCE="AGENTS_APIKEY.md"
fi

case "$IDE" in
    claude|copilot)
        mv "$RULES_SOURCE" CLAUDE.md
        ok "Placed CLAUDE.md (Claude Code)"
        ;;
    cursor|codex|kiro)
        if [ "$AUTH_METHOD" = "apikey" ]; then
            mv AGENTS_APIKEY.md AGENTS.md
        fi
        ok "Placed AGENTS.md ($IDE)"
        ;;
    all)
        if [ "$AUTH_METHOD" = "apikey" ]; then
            mv AGENTS_APIKEY.md AGENTS.md
        fi
        cp AGENTS.md CLAUDE.md
        ok "Placed AGENTS.md + CLAUDE.md (all agents)"
        ;;
esac

# Clean up whichever variant wasn't used
rm -f AGENTS_APIKEY.md 2>/dev/null || true
if [ "$IDE" = "claude" ] || [ "$IDE" = "copilot" ]; then
    rm -f AGENTS.md 2>/dev/null || true
fi

# ── Step 6: Extract the Domino host URL ──────────────────────────────────
DOMINO_HOST=""
APP_BASE_URL=""
if [ -n "$MCP_URL" ]; then
    MCP_HOST="$(echo "$MCP_URL" | sed -E 's|(https?://[^/]+).*|\1|')"
    DOMINO_HOST="$(echo "$MCP_HOST" | sed -E 's|^(https?://)apps\.|\1|')"
    APP_BASE_URL="$(echo "$MCP_URL" | sed -E 's|/mcp$||')"
fi

# ── Step 7: First-time pass-through auth ─────────────────────────────────
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

# ── Step 8: OAuth login (oauth mode only) ────────────────────────────────
if [ "$AUTH_METHOD" = "oauth" ] && [ -n "$DOMINO_HOST" ]; then
    echo
    printf "${bold}Authenticating to Domino...${reset}\n"
    echo
    python3 "${OAUTH_SCRIPT}" login "$DOMINO_HOST"
    echo
fi

# ── Step 9: API Key cleanup (apikey mode only) ───────────────────────────
if [ "$AUTH_METHOD" = "apikey" ]; then
    # Remove OAuth skill files — not needed for API key auth
    if [ -d ".claude/skills" ]; then
        rm -rf ".claude/skills"
        ok "Removed .claude/skills/ (not needed for API Key auth)"
    fi
    # Remove empty .claude dir if nothing else is in it
    if [ -d ".claude" ] && [ -z "$(ls -A .claude 2>/dev/null)" ]; then
        rmdir .claude
    fi

    # Add MCP config files to .gitignore so the API key isn't committed
    GITIGNORE_ADDITIONS=""
    if ! grep -qxF '.mcp.json' .gitignore 2>/dev/null; then
        GITIGNORE_ADDITIONS="${GITIGNORE_ADDITIONS}.mcp.json\n"
    fi
    if ! grep -qxF '.cursor/mcp.json' .gitignore 2>/dev/null; then
        GITIGNORE_ADDITIONS="${GITIGNORE_ADDITIONS}.cursor/mcp.json\n"
    fi
    if ! grep -qxF '.codex/config.toml' .gitignore 2>/dev/null; then
        GITIGNORE_ADDITIONS="${GITIGNORE_ADDITIONS}.codex/config.toml\n"
    fi
    if ! grep -qxF '.kiro/settings/mcp.json' .gitignore 2>/dev/null; then
        GITIGNORE_ADDITIONS="${GITIGNORE_ADDITIONS}.kiro/settings/mcp.json\n"
    fi
    if [ -n "$GITIGNORE_ADDITIONS" ]; then
        printf "\n# MCP configs containing API key (auto-added by setup.sh)\n" >> .gitignore
        printf "$GITIGNORE_ADDITIONS" >> .gitignore
        ok "Added MCP config files to .gitignore (protects API key)"
    fi
fi

# ── Step 10: Done ────────────────────────────────────────────────────────
echo "========================================"
printf "${bold}Setup Complete!${reset}\n"
echo "========================================"
echo
if [ "$AUTH_METHOD" = "apikey" ]; then
    echo "  Auth: API Key (configured in MCP config files)"
else
    echo "  Auth: OAuth (browser-based, auto-refreshing tokens)"
fi
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

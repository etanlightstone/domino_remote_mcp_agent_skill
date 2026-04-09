#!/usr/bin/env bash
# ============================================================================
# Domino Remote MCP Agent Skill — Setup
#
# Overlays the Claude Code skill files onto your current project directory
# (no git clone — your project's .git stays untouched) and configures the
# Domino MCP server connection.
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

# Download tarball and extract, stripping the top-level archive directory.
# This overlays .claude/, .mcp.json, CLAUDE.md, .gitignore into the CWD.
curl -sL "$TARBALL_URL" | tar xz --strip-components=1

ok "Skill files installed into $(pwd)"
echo

# ── Step 2: Prompt for the MCP server URL ──────────────────────────────────
printf "${bold}Enter your Domino MCP Server URL${reset}\n"
echo "(This is the app-published URL of the MCP server running in your Domino project.)"
echo "Example: https://your-domino.example.com/apps/<app-id>/mcp"
echo
printf "  MCP Server URL: "
read -r MCP_URL

# Trim whitespace and trailing slashes
MCP_URL="$(echo "$MCP_URL" | sed 's|[[:space:]]*$||; s|/*$||')"

if [ -z "$MCP_URL" ]; then
    err "No URL provided. You can manually edit .mcp.json later."
    echo
else
    # Write .mcp.json with the user-provided URL
    cat > .mcp.json <<MCPEOF
{
  "mcpServers": {
    "domino-mcp": {
      "type": "http",
      "url": "${MCP_URL}",
      "headersHelper": "python3 .claude/skills/domino-auth/scripts/domino_headers.py"
    }
  }
}
MCPEOF
    ok "Wrote .mcp.json with your MCP server URL"
    echo
fi

# ── Step 3: Extract the Domino host URL for auth ──────────────────────────
# e.g. https://apps.cloud-dogfood.domino.tech/apps/abc123/mcp → https://cloud-dogfood.domino.tech
DOMINO_HOST=""
if [ -n "$MCP_URL" ]; then
    # Pull out the protocol + hostname
    MCP_HOST="$(echo "$MCP_URL" | sed -E 's|(https?://[^/]+).*|\1|')"
    # Strip "apps." prefix if present (apps.foo.domino.tech → foo.domino.tech)
    DOMINO_HOST="$(echo "$MCP_HOST" | sed -E 's|^(https?://)apps\.|\1|')"
fi

# ── Step 4: Next steps ────────────────────────────────────────────────────
echo "========================================"
printf "${bold}Next Steps${reset}\n"
echo "========================================"
echo
echo "  1. Open Claude Code in this directory:"
echo
printf "       ${dim}claude${reset}\n"
echo
echo "  2. Authenticate to Domino (opens your browser):"
echo
if [ -n "$DOMINO_HOST" ]; then
    printf "       ${dim}/domino-auth ${DOMINO_HOST}${reset}\n"
else
    printf "       ${dim}/domino-auth https://your-domino-instance.example.com${reset}\n"
fi
echo
echo "  3. Restart Claude Code so the MCP tools load:"
echo
printf "       ${dim}Type /exit, then run 'claude' again${reset}\n"
echo
echo "  4. Start working! Example prompt:"
echo
printf "       ${dim}\"There's a dataset in this project, run a simple analysis,${reset}\n"
printf "       ${dim} write a model architecture and training script, then${reset}\n"
printf "       ${dim} train two small models to compare in Domino.\"${reset}\n"
echo
ok "Setup complete!"

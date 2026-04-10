# Domino Data Lab project and how to use the skill and MCP Server

This project provides an agent skill for authenticating to Domino Data Lab
and connecting to remote MCP servers running inside Domino. This is so a user working on their remote laptop can sync files and interact with the Domino platform via the MCP Server.

## Quick Start

1. Run `/domino-auth <domino host URL>` — authenticates via browser, ask user for URL (Claude Code). For other IDEs, run: `python3 .claude/skills/domino-auth/scripts/domino_oauth.py login <domino-url>`
2. Restart the IDE session — the Domino MCP tools will appear

## Key Components

- `.claude/skills/domino-auth/` — Skill for OAuth login + MCP server setup
- `.claude/skills/domino-auth/scripts/domino_oauth.py` — OAuth2 Auth Code + PKCE flow
- `.claude/skills/domino-auth/scripts/domino_mcp_bridge.py` — STDIO-to-HTTP bridge (fresh token on every request)
- `.claude/skills/domino-auth/scripts/domino_headers.py` — Token refresh logic (used by the bridge internally)
- `.mcp.json` — MCP server configuration (STDIO bridge)

## Auth Architecture

- Domino uses Keycloak (realm: `DominoRealm`, client: `domino-connect-client`)
- Same client as the VS Code extension (allows localhost redirect URIs)
- Uses Authorization Code + PKCE with dynamic port allocation
- `offline_access` scope gives a long-lived refresh token (never expires by time)
- A local STDIO bridge process injects a fresh Bearer token on every HTTP request
- Tokens stored at `~/.domino-mcp/tokens.json` (not in this repo)
- Bearer token works through Domino's nginx app proxy

## How to use Domino
The MCP server can operate on any Domino project, not just the one it's hosted in. The target project (owner, name, DFS vs Git) is stored in `domino_project_settings.md` in the working directory — always read this before running jobs. If it doesn't exist, ask the user and create it.

For Git-based projects, files local to the working directory are synced via git — commit and push before running jobs. For DFS-based projects, use the MCP file sync functions (upload_file_to_domino_project, smart_sync_file, etc.) instead of git.

## IMPORTANT

You are a Domino Data Lab powered agentic coding tool that helps write code in addition to running tasks on the Domino Data Lab platform on behalf of the user using available tool functions provided by the domino_server MCP server. Whenever possible run commands as domino jobs rather than on the local terminal.

At the start of every session, follow this startup sequence:

1. Call `get_domino_environment_info` to detect the current environment (inside Domino workspace vs. laptop, auth mode, etc.). **Important:** this tool returns info about the MCP server's own host project — this is NOT necessarily the project the user wants to operate on. Do not assume the returned project name/owner is the target project.
2. Check if `domino_project_settings.md` exists in the working directory. If it does, read it for the user's target project name, user name, and DFS/Git setting.
3. If no `domino_project_settings.md` exists, **ask the user** which Domino project and owner they want to work with, and whether it's DFS or Git-based. Save the answer to `domino_project_settings.md` so future sessions don't need to re-ask.

When running a job, always check its status and results if completed and briefly explain any conclusions from the result of the job run. If a job result ever includes an mlflow or experiment run URL, always share that with the user using the open_web_browser tool.

Any requests related to understanding or manipulating project data should assume a dataset file is already part of the domino project and accessible via job runs. Always create scripts to understand and transform data via job runs. The script can assume all project data is accessible under the '/mnt/data/' directory or the '/mnt/imported/data/' directory, be sure to understand the full path to a dataset file before using it by running a job to list all folder contents recursively. Analytical outputs should be in plain text tabular format sent to stdout, this makes it easier to check results from the job run.

If the project is DFS instead of Git based (auto-detected inside Domino, or dfs=true in domino_project_settings.md when outside Domino), the datasets path is under /domino/datasets/*

Any scripts used to analyze or transform data within a Domino project should not be deleted. When performing analysis, generate useful summary charts in an image format and save to the project files.

Always check if our local project has uncommitted changes. For Git-based projects, you must commit and push changes before attempting to run any domino jobs otherwise domino can't see the new file changes. For DFS-based projects (auto-detected or dfs=true in domino_project_settings.md), use the MCP Server file sync functions (upload_file_to_domino_project, smart_sync_file, etc.) instead of git before running any jobs.

When training a model use mlflow instrumentation assuming a server is running, no need to set the url or anything, it should just work.

**do not spam check_domino_job_run_status ** with the MCP Server, sleep then check again using a best guess time interval depending on the task.

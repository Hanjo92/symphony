#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"

if [ -f .env.local ]; then
  # shellcheck disable=SC1091
  source ./.env.local
fi

: "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"
: "${SYMPHONY_PROJECT_SLUG:?SYMPHONY_PROJECT_SLUG is required}"
: "${SOURCE_REPO_URL:?SOURCE_REPO_URL is required}"

export SYMPHONY_WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-/home/seunghus/.openclaw/workspace/symphony/workspaces}"
mkdir -p "$SYMPHONY_WORKSPACE_ROOT"

WORKFLOW_FILE="${1:-./WORKFLOW.local.md}"
PORT_FLAG=()
if [ -n "${SYMPHONY_PORT:-}" ]; then
  PORT_FLAG=(--port "$SYMPHONY_PORT")
fi

# Local helper intentionally acknowledges Symphony's preview warning so repeat runs are smoother.
ACK_FLAG=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

exec ./bin/symphony "$WORKFLOW_FILE" "${PORT_FLAG[@]}" "${ACK_FLAG[@]}"

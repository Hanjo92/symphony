#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

for extra_path in \
  "$HOME/.linuxbrew/bin" \
  "$HOME/.linuxbrew/sbin" \
  "/home/linuxbrew/.linuxbrew/bin" \
  "/home/linuxbrew/.linuxbrew/sbin"
do
  if [ -d "$extra_path" ]; then
    export PATH="$extra_path:$PATH"
  fi
done

if [ -z "${CODEX_BIN:-}" ] && [ -d "$HOME/.nvm/versions/node" ]; then
  latest_codex_bin="$(find "$HOME/.nvm/versions/node" -maxdepth 3 -type f -path '*/bin/codex' 2>/dev/null | sort -V | tail -n 1)"
  if [ -n "$latest_codex_bin" ]; then
    export PATH="$(dirname "$latest_codex_bin"):$PATH"
  fi
fi

if [ -z "${SYMPHONY_AUTOFINISH_SCRIPT:-}" ]; then
  export SYMPHONY_AUTOFINISH_SCRIPT="$PWD/scripts/workspace-after-run.sh"
fi

if [ -f .env.local ]; then
  # shellcheck disable=SC1091
  source ./.env.local
fi

WORKFLOW_FILE="${1:-./WORKFLOW.github.local.md}"

: "${SOURCE_REPO_URL:?SOURCE_REPO_URL is required}"

case "$WORKFLOW_FILE" in
  *WORKFLOW.github.local.md)
    : "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
    ;;
  *)
    : "${LINEAR_API_KEY:?LINEAR_API_KEY is required}"
    : "${SYMPHONY_PROJECT_SLUG:?SYMPHONY_PROJECT_SLUG is required}"
    ;;
 esac

export SYMPHONY_WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-$HOME/.local/share/symphony/workspaces}"
mkdir -p "$SYMPHONY_WORKSPACE_ROOT"

PORT_FLAG=()
if [ -n "${SYMPHONY_PORT:-}" ]; then
  PORT_FLAG=(--port "$SYMPHONY_PORT")
fi

# Local helper intentionally acknowledges Symphony's preview warning so repeat runs are smoother.
ACK_FLAG=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

exec ./bin/symphony "$WORKFLOW_FILE" "${PORT_FLAG[@]}" "${ACK_FLAG[@]}"

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

INSTANCE_NAME="${1:?instance name is required}"
INSTANCE_DIR="$PWD/instances/$INSTANCE_NAME"

if [ ! -d "$INSTANCE_DIR" ]; then
  echo "Unknown instance: $INSTANCE_NAME" >&2
  exit 1
fi

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

if [ -f "$INSTANCE_DIR/.env" ]; then
  # shellcheck disable=SC1090
  source "$INSTANCE_DIR/.env"
fi

WORKFLOW_FILE="$INSTANCE_DIR/WORKFLOW.github.md"

: "${SOURCE_REPO_URL:?SOURCE_REPO_URL is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${SYMPHONY_WORKSPACE_ROOT:?SYMPHONY_WORKSPACE_ROOT is required}"

mkdir -p "$SYMPHONY_WORKSPACE_ROOT"

PORT_FLAG=()
if [ -n "${SYMPHONY_PORT:-}" ]; then
  PORT_FLAG=(--port "$SYMPHONY_PORT")
fi

ACK_FLAG=(--i-understand-that-this-will-be-running-without-the-usual-guardrails)

exec ./bin/symphony "$WORKFLOW_FILE" "${PORT_FLAG[@]}" "${ACK_FLAG[@]}"

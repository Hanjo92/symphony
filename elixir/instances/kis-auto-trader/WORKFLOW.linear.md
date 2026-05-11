---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: $SYMPHONY_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
  after_run: |
    if [ -d .git ] && [ -n "${SYMPHONY_AUTOFINISH_SCRIPT:-}" ] && [ -x "${SYMPHONY_AUTOFINISH_SCRIPT}" ]; then
      "${SYMPHONY_AUTOFINISH_SCRIPT}"
    fi
  before_remove: |
    if [ -d .git ]; then
      git status --short || true
    fi
agent:
  max_concurrent_agents: 2
  max_turns: 20
codex:
  command: "${CODEX_BIN:-codex} --config shell_environment_policy.inherit=all --model ${CODEX_MODEL:-gpt-5.4} --config model_reasoning_effort=${CODEX_REASONING_EFFORT:-high} app-server"
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
github:
  enabled: true
  token: $GITHUB_TOKEN
  repo: $GITHUB_REPOSITORY
  refresh_interval_ms: 60000
  recent_workflow_runs: 5
---

You are working on a Linear ticket `{{ issue.identifier }}`.

Work only inside the provided workspace clone.

Rules:
1. Operate autonomously unless blocked by missing auth, permissions, or secrets.
2. Do not ask a human for follow-up unless there is a real blocker.
3. Validate changes before handoff.
4. Keep one running workpad comment up to date.
5. If blocked, write the blocker clearly in the workpad and move the issue according to workflow.

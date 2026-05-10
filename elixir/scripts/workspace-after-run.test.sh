#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$ROOT_DIR/workspace-after-run.sh"

make_mock_gh() {
  local mock_dir="$1"
  local log_file="$2"

  mkdir -p "$mock_dir"
  cat >"$mock_dir/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_GH_LOG:?}"
printf '%s\n' "$*" >>"$log_file"

if [[ "$1" == "auth" && "$2" == "status" ]]; then
  exit 0
fi

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  printf '%s\n' "${MOCK_GH_REPO:-Hanjo92/NoPilot}"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  printf '%s\n' "${MOCK_GH_PR_URL:-}"
  exit 0
fi

if [[ "$1" == "issue" && "$2" == "view" ]]; then
  printf '%s\n' "${MOCK_GH_ISSUE_TITLE:-Fix inline provider sync}"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "create" ]]; then
  exit 0
fi

if [[ "$1" == "issue" && "$2" == "edit" ]]; then
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$mock_dir/gh"
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  if ! grep -Fq "$pattern" "$file"; then
    echo "expected pattern not found: $pattern" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq "$pattern" "$file"; then
    echo "unexpected pattern found: $pattern" >&2
    echo "--- $file ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

make_origin_and_workspace() {
  local base_dir="$1"
  local repo_name="$2"
  local default_branch="$3"
  local bare_repo="$base_dir/${repo_name}.git"
  local seed_repo="$base_dir/${repo_name}-seed"
  local workspace="$base_dir/GH-41"

  git init --bare --initial-branch="$default_branch" "$bare_repo" >/dev/null
  git clone "$bare_repo" "$seed_repo" >/dev/null 2>&1
  (
    cd "$seed_repo"
    git config user.name "Test User"
    git config user.email "test@example.com"
    cat > README.md <<'EOF'
seed
EOF
    git add README.md
    git commit -m "seed" >/dev/null
    git push origin "$default_branch" >/dev/null
  )
  git clone "$bare_repo" "$workspace" >/dev/null 2>&1
  (
    cd "$workspace"
    git config user.name "Test User"
    git config user.email "test@example.com"
  )

  printf '%s\n' "$workspace"
}

test_creates_branch_commit_push_pr_and_done_label() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  local log_file="$tmp_dir/gh.log"
  : >"$log_file"
  make_mock_gh "$tmp_dir/bin" "$log_file"

  local workspace
  workspace="$(make_origin_and_workspace "$tmp_dir" nopilot main)"

  (
    cd "$workspace"
    printf 'updated\n' >> README.md
    PATH="$tmp_dir/bin:$PATH" \
    MOCK_GH_LOG="$log_file" \
    GITHUB_REPOSITORY="Hanjo92/NoPilot" \
    bash "$SCRIPT_UNDER_TEST" >/dev/null
  )

  local branch
  branch="$(git -C "$workspace" branch --show-current)"
  local head_message
  head_message="$(git -C "$workspace" log -1 --pretty=%s)"

  [ "$branch" = "symphony/gh-41" ] || { echo "unexpected branch: $branch" >&2; exit 1; }
  [ "$head_message" = "GH-41: apply Symphony changes" ] || { echo "unexpected commit message: $head_message" >&2; exit 1; }
  git -C "$workspace" rev-parse --verify --quiet refs/remotes/origin/symphony/gh-41 >/dev/null

  assert_contains "$log_file" "auth status"
  assert_contains "$log_file" "pr list --repo Hanjo92/NoPilot --head symphony/gh-41 --state open --json url --jq .[0].url // \"\""
  assert_contains "$log_file" "issue view 41 --repo Hanjo92/NoPilot --json title --jq .title"
  assert_contains "$log_file" "pr create --repo Hanjo92/NoPilot --head symphony/gh-41 --base main --title GH-41: Fix inline provider sync"
  assert_contains "$log_file" "issue edit 41 --repo Hanjo92/NoPilot --add-label Done --remove-label Todo --remove-label In Progress --remove-label Rework"
}

test_skips_pr_create_when_one_is_already_open() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  local log_file="$tmp_dir/gh.log"
  : >"$log_file"
  make_mock_gh "$tmp_dir/bin" "$log_file"

  local workspace
  workspace="$(make_origin_and_workspace "$tmp_dir" nopilot main)"

  (
    cd "$workspace"
    printf 'updated\n' >> README.md
    PATH="$tmp_dir/bin:$PATH" \
    MOCK_GH_LOG="$log_file" \
    MOCK_GH_PR_URL="https://github.com/Hanjo92/NoPilot/pull/123" \
    GITHUB_REPOSITORY="Hanjo92/NoPilot" \
    bash "$SCRIPT_UNDER_TEST" >/dev/null
  )

  assert_contains "$log_file" "pr list --repo Hanjo92/NoPilot --head symphony/gh-41 --state open --json url --jq .[0].url // \"\""
  assert_not_contains "$log_file" "pr create --repo Hanjo92/NoPilot"
  assert_contains "$log_file" "issue edit 41 --repo Hanjo92/NoPilot --add-label Done --remove-label Todo --remove-label In Progress --remove-label Rework"
}

test_noops_on_clean_default_branch() {
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  local log_file="$tmp_dir/gh.log"
  : >"$log_file"
  make_mock_gh "$tmp_dir/bin" "$log_file"

  local workspace
  workspace="$(make_origin_and_workspace "$tmp_dir" nopilot main)"

  (
    cd "$workspace"
    PATH="$tmp_dir/bin:$PATH" \
    MOCK_GH_LOG="$log_file" \
    GITHUB_REPOSITORY="Hanjo92/NoPilot" \
    bash "$SCRIPT_UNDER_TEST" >/dev/null
  )

  local branch
  branch="$(git -C "$workspace" branch --show-current)"
  [ "$branch" = "main" ] || { echo "unexpected branch: $branch" >&2; exit 1; }
  if [ -s "$log_file" ]; then
    echo "expected no gh calls on clean default branch" >&2
    cat "$log_file" >&2
    exit 1
  fi
}

test_creates_branch_commit_push_pr_and_done_label
test_skips_pr_create_when_one_is_already_open
test_noops_on_clean_default_branch

echo "workspace-after-run tests passed."
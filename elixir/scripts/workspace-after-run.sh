#!/usr/bin/env bash
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
  echo "git is not available; skipping after_run automation." >&2
  exit 0
fi

if [ ! -d .git ]; then
  echo "Current directory is not a git repository; skipping after_run automation." >&2
  exit 0
fi

repo="${GITHUB_REPOSITORY:-}"
issue_identifier="${SYMPHONY_ISSUE_IDENTIFIER:-$(basename "$PWD")}"
active_labels=(Todo "In Progress" Rework)
done_label="${SYMPHONY_DONE_LABEL:-Done}"
branch_prefix="${SYMPHONY_AUTOFINISH_BRANCH_PREFIX:-symphony}"
commit_prefix="${SYMPHONY_AUTOFINISH_COMMIT_PREFIX:-}"

run_git() {
  git "$@"
}

git_output() {
  git "$@" 2>/dev/null
}

gh_ready() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
}

sanitize_branch_fragment() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

issue_number_from_identifier() {
  case "$1" in
    [Gg][Hh]-[0-9]*)
      printf '%s\n' "${1#*-}"
      ;;
    *)
      return 1
      ;;
  esac
}

current_branch="$(git_output branch --show-current | tr -d '\n')"
default_branch="$(git_output symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's#^origin/##' | tr -d '\n')"

if [ -z "$default_branch" ]; then
  default_branch="main"
fi

if [ -z "$current_branch" ]; then
  current_branch="$default_branch"
fi

has_worktree_changes=0
if ! git diff --quiet --ignore-submodules --; then
  has_worktree_changes=1
fi
if ! git diff --cached --quiet --ignore-submodules --; then
  has_worktree_changes=1
fi
if [ -n "$(git status --porcelain --untracked-files=all 2>/dev/null)" ]; then
  has_worktree_changes=1
fi

has_upstream=0
if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
  has_upstream=1
fi

commits_ahead=0
if [ "$has_upstream" -eq 1 ]; then
  commits_ahead="$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || printf '0')"
fi

if [ "$has_worktree_changes" -eq 0 ] && [ "$current_branch" = "$default_branch" ] && [ "$commits_ahead" = "0" ]; then
  echo "No local changes to publish for $issue_identifier; skipping after_run automation."
  exit 0
fi

safe_issue_fragment="$(sanitize_branch_fragment "$issue_identifier")"
if [ -z "$safe_issue_fragment" ]; then
  safe_issue_fragment="issue"
fi

target_branch="$current_branch"
if [ -z "$target_branch" ] || [ "$target_branch" = "$default_branch" ]; then
  target_branch="$branch_prefix/$safe_issue_fragment"
fi

if [ "$target_branch" != "$current_branch" ]; then
  if git rev-parse --verify --quiet "$target_branch" >/dev/null; then
    run_git checkout "$target_branch" >/dev/null
  else
    run_git checkout -b "$target_branch" >/dev/null
  fi
fi

run_git add -A -- . \
  ':(exclude,glob)**/*-workpad.md' \
  ':(exclude,glob)**/*-comment.md' \
  ':(exclude,glob)**/*-finish.sh' \
  ':(exclude,glob)**/*-finish.test.sh' \
  ':(exclude,glob)**/.codex/**'

created_commit=0
if ! git diff --cached --quiet --ignore-submodules --; then
  commit_message="$issue_identifier: apply Symphony changes"
  if [ -n "$commit_prefix" ]; then
    commit_message="$commit_prefix $commit_message"
  fi
  run_git commit -m "$commit_message" >/dev/null
  created_commit=1
fi

has_upstream=0
if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
  has_upstream=1
fi

commits_ahead=0
if [ "$has_upstream" -eq 1 ]; then
  commits_ahead="$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || printf '0')"
fi

run_git push --set-upstream origin "$target_branch" >/dev/null

if ! gh_ready; then
  echo "gh is unavailable or unauthenticated; pushed branch $target_branch but skipped PR/label automation." >&2
  exit 0
fi

if [ -z "$repo" ]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

pr_url="$(gh pr list --repo "$repo" --head "$target_branch" --state open --json url --jq '.[0].url // ""')"
issue_number=""
issue_title=""
if issue_number="$(issue_number_from_identifier "$issue_identifier")"; then
  issue_title="$(gh issue view "$issue_number" --repo "$repo" --json title --jq .title 2>/dev/null || true)"
fi

pr_title="$issue_identifier: ${issue_title:-automated Symphony changes}"
pr_body="Automated Symphony follow-up for \`$issue_identifier\`."
if [ -n "$issue_number" ]; then
  pr_body="$pr_body

Closes #$issue_number"
fi

if [ -z "$pr_url" ]; then
  gh pr create \
    --repo "$repo" \
    --head "$target_branch" \
    --base "$default_branch" \
    --title "$pr_title" \
    --body "$pr_body" >/dev/null
fi

if [ -n "$issue_number" ]; then
  issue_edit_args=(issue edit "$issue_number" --repo "$repo" --add-label "$done_label")
  for label in "${active_labels[@]}"; do
    issue_edit_args+=(--remove-label "$label")
  done
  gh "${issue_edit_args[@]}" >/dev/null
fi

echo "Published $issue_identifier on branch $target_branch."
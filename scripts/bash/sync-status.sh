#!/usr/bin/env bash
# multi-repo-sync extension: sync-status.sh
#
# Read-only diagnostics. Reports the resolved configuration, the detected
# sub-repositories, and the per-target state of the root's current feature
# branch. Never mutates any repository.
#
# Usage: sync-status.sh [--json] [--branch <name>] [--verbose] [--quiet]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=scripts/bash/multi-repo-common.sh
. "$SCRIPT_DIR/multi-repo-common.sh"

JSON_MODE=false
BRANCH_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json)    JSON_MODE=true ;;
    --verbose) MRS_VERBOSE=true ;;
    --quiet)   MRS_QUIET=true ;;
    --branch)
      shift
      [ $# -gt 0 ] || { log_error "--branch requires a value"; exit 2; }
      BRANCH_OVERRIDE="$1"
      ;;
    --help|-h)
      echo "Usage: sync-status.sh [--json] [--branch <name>] [--verbose] [--quiet]" >&2
      exit 0
      ;;
    *) log_warn "Ignoring unknown argument: $1" ;;
  esac
  shift
done

ROOT="$(repo_root)"
if [ -z "$ROOT" ]; then
  log_error "Not inside a git repository."
  $JSON_MODE && printf '{"error":"not_a_git_repository","targets":[]}\n'
  exit 2
fi

load_config "$ROOT"

# Same guard as sync-feature-branches: never let an option-like or malformed
# name flow into git calls or the JSON report. current_branch is empty on a
# detached HEAD, so the report reads "<detached>" with no override given.
if [ -n "$BRANCH_OVERRIDE" ] && ! valid_branch_name "$BRANCH_OVERRIDE"; then
  log_error "Refusing to inspect unsafe branch name: '$BRANCH_OVERRIDE'"
  $JSON_MODE && printf '{"error":"invalid_branch_name","targets":[]}\n'
  exit 2
fi
BRANCH="${BRANCH_OVERRIDE:-$(current_branch)}"
MODE="$(effective_mode "$ROOT")"

# Classify a single target without mutating it.
target_state() {
  local rel="$1"
  local dir="$ROOT/$rel"
  # A registered-but-uninitialized submodule would otherwise read as missing/
  # not_a_repo here even though sync-feature-branches would initialize and
  # branch it — report it distinctly so status never contradicts sync.
  if { [ ! -e "$dir" ] || ! is_git_worktree "$dir"; } && is_submodule_path "$ROOT" "$rel"; then
    echo "uninitialized_submodule"; return
  fi
  if [ ! -e "$dir" ];           then echo "missing"; return; fi
  if ! is_git_worktree "$dir";  then echo "not_a_repo"; return; fi
  if [ -z "$BRANCH" ];          then echo "n/a"; return; fi
  if branch_exists "$dir" "$BRANCH"; then echo "present"; return; fi
  if ! has_commit "$dir";       then echo "unborn"; return; fi
  echo "absent"
}

TARGETS=""
while IFS= read -r t; do
  [ -n "$t" ] && TARGETS="$TARGETS$t"$'\n'
done < <(detect_targets "$ROOT")

if $JSON_MODE; then
  ITEMS=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    st="$(target_state "$rel")"
    item=$(printf '{"path":"%s","state":"%s"}' "$(json_escape "$rel")" "$st")
    if [ -z "$ITEMS" ]; then ITEMS="$item"; else ITEMS="$ITEMS,$item"; fi
  done <<EOF
$TARGETS
EOF
  printf '{"root_branch":"%s","configured_type":"%s","mode":"%s","scan_depth":%s,"switch":%s,"skip_branches":"%s","targets":[%s]}\n' \
    "$(json_escape "$BRANCH")" "$(json_escape "$MRS_TYPE")" "$(json_escape "$MODE")" \
    "$MRS_SCAN_DEPTH" "$MRS_SWITCH" "$(json_escape "$MRS_SKIP_BRANCHES")" "$ITEMS"
  exit 0
fi

# Human-readable report.
echo "Multi-Repo Branch Sync — status"
echo "  root              : $ROOT"
echo "  root branch       : ${BRANCH:-<detached>}"
echo "  configured type   : $MRS_TYPE"
echo "  effective mode    : $MODE"
echo "  scan_depth        : $MRS_SCAN_DEPTH"
echo "  switch            : $MRS_SWITCH"
echo "  skip_branches     : $MRS_SKIP_BRANCHES"
echo ""

if [ -z "$TARGETS" ]; then
  echo "  No sub-repositories detected."
  exit 0
fi

echo "  Detected targets:"
printf '    %-40s %s\n' "PATH" "STATE($BRANCH)"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  printf '    %-40s %s\n' "$rel" "$(target_state "$rel")"
done <<EOF
$TARGETS
EOF
exit 0

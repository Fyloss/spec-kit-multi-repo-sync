#!/usr/bin/env bash
# multi-repo-sync extension: sync-feature-branches.sh
#
# Propagates the root repository's current feature branch into every detected
# sub-repository / submodule. Idempotent: existing branches are skipped. A
# failure in one target WARNs and continues; it never aborts the caller.
#
# Usage:
#   sync-feature-branches.sh [--json] [--dry-run] [--switch] [--verbose] [--quiet]
#                            [--branch <name>]
#
# Exit codes:
#   0  success (including "nothing to do")
#   1  one or more targets failed (caller may surface this; hooks treat it as
#      informational and must not abort the native plan/tasks run)
#   2  usage / environment error (not a git repo)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=scripts/bash/multi-repo-common.sh
. "$SCRIPT_DIR/multi-repo-common.sh"

JSON_MODE=false
DRY_RUN=false
SWITCH_OVERRIDE=""   # empty = use config; "true"/"false" = override
BRANCH_OVERRIDE=""
TARGETS_OVERRIDE=""  # empty = scan for sub-repos; set = explicit affected list

while [ $# -gt 0 ]; do
  case "$1" in
    --json)    JSON_MODE=true ;;
    --dry-run) DRY_RUN=true ;;
    --switch)  SWITCH_OVERRIDE=true ;;
    --no-switch) SWITCH_OVERRIDE=false ;;
    --verbose) MRS_VERBOSE=true ;;
    --quiet)   MRS_QUIET=true ;;
    --branch)
      shift
      [ $# -gt 0 ] || { log_error "--branch requires a value"; exit 2; }
      BRANCH_OVERRIDE="$1"
      ;;
    --targets)
      shift
      [ $# -gt 0 ] || { log_error "--targets requires a value"; exit 2; }
      TARGETS_OVERRIDE="$1"
      ;;
    --help|-h)
      cat >&2 <<'USAGE'
Usage: sync-feature-branches.sh [options]
  --json          Emit a machine-readable JSON report on stdout
  --dry-run       Report what WOULD happen; create no branches
  --switch        Switch each sub-repo onto the branch (best-effort; needs clean tree)
  --no-switch     Force create-only (override config)
  --branch <name> Use this branch name instead of the root's current branch
  --targets <csv> Restrict to this comma-separated list of affected sub-repo
                  paths (relative to the root) instead of scanning for them
  --verbose       Verbose diagnostics on stderr
  --quiet         Suppress informational output
USAGE
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
[ -n "$SWITCH_OVERRIDE" ] && MRS_SWITCH="$SWITCH_OVERRIDE"

BRANCH="${BRANCH_OVERRIDE:-$(current_branch)}"
MODE="$(effective_mode "$ROOT")"

# ---- Guard rails -----------------------------------------------------------
emit_empty_report() {
  local reason="$1"
  if $JSON_MODE; then
    printf '{"root_branch":"%s","mode":"%s","scan_depth":%s,"dry_run":%s,"reason":"%s","targets":[],"summary":{"total":0,"created":0,"exists":0,"failed":0}}\n' \
      "$(json_escape "$BRANCH")" "$(json_escape "$MODE")" "$MRS_SCAN_DEPTH" "$DRY_RUN" "$(json_escape "$reason")"
  fi
}

# current_branch is empty on a detached HEAD; an explicit `--branch HEAD` is
# rejected below by valid_branch_name (git refuses it as a branch name).
if [ -z "$BRANCH" ]; then
  log_warn "Root repository is in a detached HEAD state; nothing to propagate."
  emit_empty_report "detached_head"
  exit 0
fi

# Never pass an option-like or malformed name to `git branch`/`git switch`.
if ! valid_branch_name "$BRANCH"; then
  log_error "Refusing to operate on unsafe branch name: '$BRANCH'"
  $JSON_MODE && printf '{"error":"invalid_branch_name","targets":[]}\n'
  exit 2
fi

if is_skipped_branch "$BRANCH"; then
  log_info "Branch '$BRANCH' is in skip_branches; nothing to propagate."
  emit_empty_report "skipped_branch"
  exit 0
fi

# ---- Detect targets --------------------------------------------------------
# With an explicit "affected repositories" list (parsed from plan.md by the sync
# command), restrict the run to those paths; otherwise scan for every sub-repo.
TARGETS=""
if [ -n "$TARGETS_OVERRIDE" ]; then
  while IFS= read -r t; do
    [ -n "$t" ] && TARGETS="$TARGETS$t"$'\n'
  done < <(printf '%s\n' "$TARGETS_OVERRIDE" | tr ',' '\n' | filter_explicit_targets "$ROOT")
else
  while IFS= read -r t; do
    [ -n "$t" ] && TARGETS="$TARGETS$t"$'\n'
  done < <(detect_targets "$ROOT")
fi

if [ -z "$TARGETS" ]; then
  log_info "No sub-repositories detected (mode=$MODE, scan_depth=$MRS_SCAN_DEPTH)."
  emit_empty_report "no_targets"
  exit 0
fi

log_info "Propagating branch '$BRANCH' (mode=$MODE, scan_depth=$MRS_SCAN_DEPTH, switch=$MRS_SWITCH)$([ "$DRY_RUN" = true ] && echo ' [dry-run]')"

# ---- Process each target ---------------------------------------------------
TOTAL=0; N_CREATED=0; N_EXISTS=0; N_FAILED=0
JSON_ITEMS=""

add_json_item() {
  local path="$1" status="$2" switched="$3" message="$4"
  local item
  item=$(printf '{"path":"%s","status":"%s","switched":%s,"message":"%s"}' \
    "$(json_escape "$path")" "$status" "$switched" "$(json_escape "$message")")
  if [ -z "$JSON_ITEMS" ]; then JSON_ITEMS="$item"; else JSON_ITEMS="$JSON_ITEMS,$item"; fi
}

# Best-effort switch of <dir> onto $BRANCH (honors MRS_SWITCH; needs a clean
# tree). Sets the caller's $switched; warns with <context> when it cannot switch.
try_switch() {
  local dir="$1" rel="$2" context="$3"
  [ "$MRS_SWITCH" = "true" ] || return 0
  if is_clean "$dir"; then
    if git_target "$dir" switch "$BRANCH" >/dev/null 2>&1; then
      switched=true
    else
      log_warn "[$rel] $context but switch failed"
    fi
  else
    log_warn "[$rel] $context but left it un-switched (working tree is dirty)"
  fi
}

process_target() {
  local rel="$1"
  local dir="$ROOT/$rel"
  local switched=false

  # Uninitialized submodule? Initialize it before branching, mirroring the
  # preset's `git submodule update --init "<path>"`. Only registered submodules
  # are initialized; a missing independent repo still fails as before.
  if { [ ! -e "$dir" ] || ! is_git_worktree "$dir"; } && is_submodule_path "$ROOT" "$rel"; then
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[$rel] would initialize submodule and create '$BRANCH'"
      N_CREATED=$((N_CREATED + 1))
      add_json_item "$rel" "would_create" false "dry-run: submodule would be initialized and branched"
      return
    fi
    log_info "[$rel] initializing uninitialized submodule"
    if ! init_submodule "$ROOT" "$rel"; then
      log_warn "[$rel] failed to initialize submodule — skipping"
      N_FAILED=$((N_FAILED + 1))
      add_json_item "$rel" "failed" false "submodule init failed"
      return
    fi
  fi

  if [ ! -e "$dir" ]; then
    log_warn "[$rel] path does not exist (uninitialized submodule?) — skipping"
    N_FAILED=$((N_FAILED + 1))
    add_json_item "$rel" "failed" false "path does not exist (uninitialized submodule?)"
    return
  fi
  if ! is_git_worktree "$dir"; then
    log_warn "[$rel] not a git repository — skipping"
    N_FAILED=$((N_FAILED + 1))
    add_json_item "$rel" "failed" false "not a git repository"
    return
  fi

  # Already present -> idempotent skip (optionally switch onto it).
  if branch_exists "$dir" "$BRANCH"; then
    if [ "$DRY_RUN" = "false" ]; then
      try_switch "$dir" "$rel" "branch '$BRANCH' already exists"
    fi
    log_info "[$rel] already on/has '$BRANCH' — skipped"
    N_EXISTS=$((N_EXISTS + 1))
    add_json_item "$rel" "exists" "$switched" "branch already exists"
    return
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[$rel] would create '$BRANCH'"
    N_CREATED=$((N_CREATED + 1))
    add_json_item "$rel" "would_create" false "dry-run: branch would be created"
    return
  fi

  # Need a commit to branch from (a freshly `git init`-ed repo has an unborn HEAD).
  if ! has_commit "$dir"; then
    log_warn "[$rel] no commits yet (unborn HEAD) — cannot create branch; skipping"
    N_FAILED=$((N_FAILED + 1))
    add_json_item "$rel" "failed" false "no commits yet (unborn HEAD)"
    return
  fi

  # `git branch` never touches the working tree, so it is safe even on a dirty
  # repo. Switching is the only step that can fail on a dirty tree.
  if git_target "$dir" branch "$BRANCH" >/dev/null 2>&1; then
    try_switch "$dir" "$rel" "created '$BRANCH'"
    log_info "[$rel] created '$BRANCH'$([ "$switched" = true ] && echo ' and switched')"
    N_CREATED=$((N_CREATED + 1))
    add_json_item "$rel" "created" "$switched" "branch created"
  else
    log_warn "[$rel] failed to create '$BRANCH'"
    N_FAILED=$((N_FAILED + 1))
    add_json_item "$rel" "failed" false "git branch failed"
  fi
}

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  TOTAL=$((TOTAL + 1))
  process_target "$rel"
done <<EOF
$TARGETS
EOF

# ---- Report ----------------------------------------------------------------
if $JSON_MODE; then
  printf '{"root_branch":"%s","mode":"%s","scan_depth":%s,"dry_run":%s,"switch":%s,"targets":[%s],"summary":{"total":%s,"created":%s,"exists":%s,"failed":%s}}\n' \
    "$(json_escape "$BRANCH")" "$(json_escape "$MODE")" "$MRS_SCAN_DEPTH" "$DRY_RUN" "$MRS_SWITCH" \
    "$JSON_ITEMS" "$TOTAL" "$N_CREATED" "$N_EXISTS" "$N_FAILED"
else
  log_info ""
  log_info "Summary: $TOTAL target(s) — created=$N_CREATED exists=$N_EXISTS failed=$N_FAILED"
fi

[ "$N_FAILED" -gt 0 ] && exit 1
exit 0

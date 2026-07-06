#!/usr/bin/env bash
# multi-repo-sync extension: shared helpers (config, detection, logging, JSON).
#
# Sourced by sync-feature-branches.sh and sync-status.sh. Pure POSIX-ish bash,
# kept compatible with the bash 3.2 that ships on macOS (no associative arrays,
# no `mapfile`). Detection logic is intentionally compatible with the community
# preset `spec-kit-preset-multi-repo-branching` so configuration is drop-in.

# ----------------------------------------------------------------------------
# Logging — respects MRS_QUIET and MRS_VERBOSE (set by callers from flags/env).
# ----------------------------------------------------------------------------
MRS_QUIET="${MRS_QUIET:-false}"
MRS_VERBOSE="${MRS_VERBOSE:-false}"

log_info()    { [ "$MRS_QUIET" = "true" ] || printf '%s\n' "$*" >&2; }
log_warn()    { printf 'WARN: %s\n' "$*" >&2; }
log_error()   { printf 'ERROR: %s\n' "$*" >&2; }
log_verbose() { [ "$MRS_VERBOSE" = "true" ] && printf '  %s\n' "$*" >&2; return 0; }

# ----------------------------------------------------------------------------
# Git helpers
# ----------------------------------------------------------------------------

# Absolute path of the root repository working tree.
repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Current branch of the root repository (empty if detached/unknown).
# symbolic-ref only resolves a real branch ref, so callers never see the
# literal "HEAD" that `rev-parse --abbrev-ref` reports on a detached HEAD.
current_branch() {
  git symbolic-ref --short -q HEAD 2>/dev/null
}

# True if <1> is a safe, syntactically valid git branch name. Rejects names
# that begin with '-' (which `git branch`/`git switch` would parse as options —
# an argument-injection vector when a name is supplied via --branch) and any
# name git itself considers malformed (spaces, '..', control chars, etc.).
valid_branch_name() {
  case "$1" in
    -*) return 1 ;;
  esac
  git check-ref-format --branch "$1" >/dev/null 2>&1
}

# Run git inside a *target* sub-repository with its (attacker-controllable when
# the root was cloned from an untrusted source) configuration neutralized:
#   - core.hooksPath=/dev/null  -> a malicious post-checkout hook never runs on
#                                  `git switch` (code-execution vector).
#   - core.fsmonitor=false      -> a malicious fsmonitor program never runs on
#                                  `git status` (code-execution vector).
#   - filter.<name>.clean/smudge/process -> a content filter armed by an in-tree
#                                  .gitattributes runs arbitrary shell on `git
#                                  status` (clean) and `git switch` (smudge), and
#                                  is NOT covered by the two keys above. There is
#                                  no blanket flag to disable in-tree attribute
#                                  filters, so enumerate every driver defined in
#                                  the sub-repo's own (local) config and override
#                                  each to a no-op for this call. Passing them via
#                                  GIT_CONFIG_* (not `-c key=value`, which splits
#                                  on the first '=') means a driver name
#                                  containing '=' or '.' cannot dodge the override.
# Command-line `-c` overrides repo config, so this holds even if the sub-repo
# sets these keys itself. Used for every git call that touches a target tree.
# Note: neutralizing filters requires git >= 2.31 (GIT_CONFIG_COUNT); it also
# disables any *legitimate* filter (e.g. git-lfs) defined in the sub-repo's local
# config for the duration of these branch/switch operations.
git_target() {
  local dir="$1"; shift
  local -a filter_env=()
  local count=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    filter_env+=("GIT_CONFIG_KEY_$count=filter.$name.clean"   "GIT_CONFIG_VALUE_$count=")
    count=$((count + 1))
    filter_env+=("GIT_CONFIG_KEY_$count=filter.$name.smudge"  "GIT_CONFIG_VALUE_$count=")
    count=$((count + 1))
    filter_env+=("GIT_CONFIG_KEY_$count=filter.$name.process" "GIT_CONFIG_VALUE_$count=")
    count=$((count + 1))
    filter_env+=("GIT_CONFIG_KEY_$count=filter.$name.required" "GIT_CONFIG_VALUE_$count=false")
    count=$((count + 1))
  done < <(git -C "$dir" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
             config --local --list --name-only 2>/dev/null \
             | sed -nE 's/^filter\.(.*)\.(clean|smudge|process|required)$/\1/p' \
             | sort -u)
  if [ "$count" -eq 0 ]; then
    git -C "$dir" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
  else
    env GIT_CONFIG_COUNT="$count" "${filter_env[@]}" \
      git -C "$dir" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
  fi
}

# True if <dir> is the top level of a git working tree.
# `--is-inside-work-tree` alone is not enough: from an empty directory (e.g. an
# uninitialized submodule) git discovers the PARENT repository upward and would
# answer "true" for it — so also require an empty --show-prefix (dir == toplevel).
is_git_worktree() {
  [ "$(git_target "$1" rev-parse --is-inside-work-tree --show-prefix 2>/dev/null)" = "true" ]
}

# True if <dir> has a clean working tree (no staged/unstaged changes).
is_clean() {
  [ -z "$(git_target "$1" status --porcelain 2>/dev/null)" ]
}

# True if branch <2> exists locally in repo at <1>.
branch_exists() {
  git_target "$1" show-ref --verify --quiet "refs/heads/$2"
}

# True if repo at <1> has at least one commit (HEAD is born).
has_commit() {
  git_target "$1" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

# True if <rel> is a registered submodule path in <root>/.gitmodules. Used to
# decide whether an uninitialized target should be `submodule update --init`-ed
# before branching (mirrors the preset's submodule branch command).
is_submodule_path() {
  local root="$1" rel="$2" p
  [ -f "$root/.gitmodules" ] || return 1
  while IFS= read -r p; do
    [ "$p" = "$rel" ] && return 0
  done <<EOF
$(_detect_submodules "$root")
EOF
  return 1
}

# Initialize an as-yet-uninitialized submodule before branching it, mirroring the
# preset's `git submodule update --init "<path>"`. Routed through git_target so a
# hostile fsmonitor cannot execute; a freshly cloned submodule carries no tracked
# hooks, and every later branch/switch on it goes through git_target as well.
init_submodule() {
  local root="$1" rel="$2"
  git_target "$root" submodule update --init -- "$rel" >/dev/null 2>&1
}

# Escape a string for safe embedding in JSON.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# ----------------------------------------------------------------------------
# Configuration
#
# Precedence (lowest to highest):
#   1. Built-in defaults
#   2. .specify/init-options.json  ->  multi_repo_branching.{...}   (preset key)
#   3. .specify/extensions/multi-repo-sync/multi-repo-sync-config.yml (overrides)
#
# Exposes (after `load_config`):
#   MRS_TYPE          auto | independent | submodule
#   MRS_SCAN_DEPTH    integer >= 1
#   MRS_SWITCH        true | false   (switch the sub-repo onto the branch)
#   MRS_SKIP_BRANCHES space-separated branch names to never fan out
#   MRS_EXCLUDE       newline-separated path fragments to exclude (independent mode)
# ----------------------------------------------------------------------------

# Read multi_repo_branching.* from a JSON init-options file. Emits `key=value`
# lines on stdout. Uses python3 when available, falls back to jq, then to a
# tolerant grep/sed scan of the flat keys we care about.
_read_init_options() {
  local file="$1"
  [ -f "$file" ] || return 0

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
m = data.get("multi_repo_branching") or {}
if not isinstance(m, dict):
    sys.exit(0)
def emit(k, v):
    if v is not None:
        print("%s=%s" % (k, v))
emit("type", m.get("type"))
emit("scan_depth", m.get("scan_depth"))
sw = m.get("switch")
if sw is not None:
    emit("switch", str(sw).lower())
sb = m.get("skip_branches")
if isinstance(sb, list):
    emit("skip_branches", " ".join(str(x) for x in sb))
ex = m.get("exclude")
if isinstance(ex, list):
    for item in ex:
        print("exclude=%s" % item)
PY
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '
      .multi_repo_branching // {} |
      (if .type then "type=\(.type)" else empty end),
      (if .scan_depth then "scan_depth=\(.scan_depth)" else empty end),
      (if .switch != null then "switch=\(.switch)" else empty end),
      (if (.skip_branches|type) == "array" then "skip_branches=\(.skip_branches|join(" "))" else empty end),
      (if (.exclude|type) == "array" then (.exclude[] | "exclude=\(.)") else empty end)
    ' "$file" 2>/dev/null
    return 0
  fi

  # Last resort: scrape flat scalar keys (type, scan_depth, switch) only.
  # Scope the scan to the multi_repo_branching object first: init-options.json
  # is a shared file where sibling objects can carry keys of the same names.
  local scoped
  scoped="$(sed -n '/"multi_repo_branching"/,/}/p' "$file" 2>/dev/null \
    | sed '1s/.*"multi_repo_branching"//')"
  printf '%s\n' "$scoped" | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"/type=\1/' | head -n1
  printf '%s\n' "$scoped" | grep -oE '"scan_depth"[[:space:]]*:[[:space:]]*[0-9]+' 2>/dev/null \
    | sed -E 's/.*:[[:space:]]*([0-9]+)/scan_depth=\1/' | head -n1
  printf '%s\n' "$scoped" | grep -oE '"switch"[[:space:]]*:[[:space:]]*(true|false)' 2>/dev/null \
    | sed -E 's/.*:[[:space:]]*(true|false)/switch=\1/' | head -n1
}

# List-valued YAML scalars (skip_branches, exclude) may be written as a single
# comma/space-separated string. Re-emit them so they match the multi-line form
# produced from JSON arrays (and PowerShell's `-split '[,\s]+'`):
#   - exclude:        one `exclude=<item>` line per item (append semantics)
#   - skip_branches:  a single space-separated line (assigned, then word-split)
# Scalar keys pass through untouched.
_expand_yaml_list_values() {
  local key val item
  while IFS='=' read -r key val; do
    case "$key" in
      exclude)
        set -f   # split on whitespace only; never glob a '*' in the config value
        for item in ${val//,/ }; do
          [ -n "$item" ] && printf 'exclude=%s\n' "$item"
        done
        set +f
        ;;
      skip_branches)
        printf 'skip_branches=%s\n' "${val//,/ }"
        ;;
      *)
        printf '%s=%s\n' "$key" "$val"
        ;;
    esac
  done
}

# Read flat `key: value` scalars from the extension-local YAML config.
_read_yaml_config() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Strip comments, trim, keep simple `key: value` lines for known keys.
  grep -E '^[[:space:]]*(type|scan_depth|switch|skip_branches|exclude)[[:space:]]*:' "$file" 2>/dev/null \
    | sed -E 's/[[:space:]]*#.*$//' \
    | sed -E 's/^[[:space:]]*([a-z_]+)[[:space:]]*:[[:space:]]*(.*)$/\1=\2/' \
    | sed -E 's/=[[:space:]]*"(.*)"[[:space:]]*$/=\1/' \
    | sed -E "s/=[[:space:]]*'(.*)'[[:space:]]*\$/=\1/" \
    | _expand_yaml_list_values
}

_apply_config_pairs() {
  # Reads `key=value` lines from stdin and assigns to MRS_* variables.
  local key val
  while IFS='=' read -r key val; do
    [ -n "$key" ] || continue
    case "$key" in
      type)          MRS_TYPE="$val" ;;
      scan_depth)    MRS_SCAN_DEPTH="$val" ;;
      switch)        MRS_SWITCH="$val" ;;
      skip_branches) MRS_SKIP_BRANCHES="$val" ;;
      exclude)       MRS_EXCLUDE="$(printf '%s\n%s' "$MRS_EXCLUDE" "$val")" ;;
    esac
  done
}

load_config() {
  local root="$1"

  # 1. Defaults (match the preset: type=auto, scan_depth=2). The preset creates
  #    branches with `checkout -b`, which also switches the sub-repo onto the new
  #    branch, so switching is the default here too (best-effort on a clean tree).
  MRS_TYPE="auto"
  MRS_SCAN_DEPTH="2"
  MRS_SWITCH="true"
  MRS_SKIP_BRANCHES="main master"
  MRS_EXCLUDE=""

  # 2. Preset-compatible init-options.json.
  local init_json="$root/.specify/init-options.json"
  if [ -f "$init_json" ]; then
    log_verbose "Reading config from .specify/init-options.json"
    _apply_config_pairs < <(_read_init_options "$init_json")
  fi

  # 3. Extension-local override.
  local ext_cfg="$root/.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml"
  if [ -f "$ext_cfg" ]; then
    log_verbose "Applying overrides from multi-repo-sync-config.yml"
    _apply_config_pairs < <(_read_yaml_config "$ext_cfg")
  fi

  # Normalize / validate.
  case "$MRS_TYPE" in
    auto|independent|submodule) ;;
    *) log_warn "Unknown type '$MRS_TYPE'; falling back to 'auto'"; MRS_TYPE="auto" ;;
  esac
  case "$MRS_SCAN_DEPTH" in
    ''|*[!0-9]*) log_warn "Invalid scan_depth '$MRS_SCAN_DEPTH'; using 2"; MRS_SCAN_DEPTH="2" ;;
    *) if [ "$MRS_SCAN_DEPTH" -lt 1 ]; then
         log_warn "Invalid scan_depth '$MRS_SCAN_DEPTH'; using 2"; MRS_SCAN_DEPTH="2"
       fi ;;
  esac
  [ "$MRS_SWITCH" = "true" ] || MRS_SWITCH="false"
}

# Resolve "auto" to the concrete mode for a given root.
effective_mode() {
  local root="$1"
  if [ "$MRS_TYPE" = "auto" ]; then
    if [ -f "$root/.gitmodules" ]; then echo "submodule"; else echo "independent"; fi
  else
    echo "$MRS_TYPE"
  fi
}

# ----------------------------------------------------------------------------
# Target detection — prints one relative path per detected sub-repository.
# ----------------------------------------------------------------------------

_detect_submodules() {
  local root="$1"
  [ -f "$root/.gitmodules" ] || return 0
  if git config -f "$root/.gitmodules" --get-regexp '^submodule\..*\.path$' >/dev/null 2>&1; then
    # -z separates each key from its value with a newline and entries with a NUL,
    # so a path (or submodule name) that contains spaces survives intact — a
    # plain "split on first whitespace" would truncate it.
    git config -f "$root/.gitmodules" -z --get-regexp '^submodule\..*\.path$' 2>/dev/null \
      | while IFS= read -r -d '' entry; do
          printf '%s\n' "${entry#*$'\n'}"
        done
  else
    # Fallback parse if git config cannot read the file.
    grep -E '^[[:space:]]*path[[:space:]]*=' "$root/.gitmodules" 2>/dev/null \
      | sed -E 's/^[[:space:]]*path[[:space:]]*=[[:space:]]*//'
  fi
}

_detect_independent() {
  local root="$1"
  local depth="$2"
  # .git lives one level below the repo dir, so search one deeper than scan_depth.
  local maxdepth=$((depth + 1))
  # Find every .git (dir or file) below the root, excluding the root's own.
  ( cd "$root" || return 0
    find . -mindepth 2 -maxdepth "$maxdepth" -name .git \( -type d -o -type f \) 2>/dev/null \
      | sed -E 's#/\.git$##; s#^\./##' \
      | sort -u
  )
}

# Apply gitignore + configured excludes; print surviving relative paths.
_filter_targets() {
  local root="$1"
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ "$path" = "." ] && continue
    # Respect .gitignore (independent repos nested under an ignored dir).
    # `--` keeps an option-like path (e.g. `path = --stdin` planted in a cloned
    # .gitmodules) from being parsed as a check-ignore flag.
    if git -C "$root" check-ignore -q -- "$path" 2>/dev/null; then
      log_verbose "skip (gitignored): $path"
      continue
    fi
    # Configured excludes (substring/path-fragment match).
    local skip=false ex
    while IFS= read -r ex; do
      [ -n "$ex" ] || continue
      case "$path" in
        "$ex"|"$ex"/*|*/"$ex"|*/"$ex"/*) skip=true; break ;;
      esac
    done <<EOF
$MRS_EXCLUDE
EOF
    if [ "$skip" = "true" ]; then
      log_verbose "skip (excluded): $path"
      continue
    fi
    printf '%s\n' "$path"
  done
}

# Drop any detected path that is absolute or escapes the root via '..'.
# Submodule paths come from .gitmodules, which is attacker-controllable in a
# cloned repository; the fan-out must never touch a repo outside the root tree.
#
# The lexical checks below stop textual traversal; they do NOT catch a path that
# is itself a symlink/junction pointing outside the tree (e.g. `path = linked`
# where `linked` -> /some/external/repo). For paths that exist we therefore also
# resolve the physical location (`pwd -P` follows symlinks) and require it to
# stay under the root's physical path.
_reject_unsafe_paths() {
  local root="$1" rootphys p phys
  rootphys="$(cd "$root" 2>/dev/null && pwd -P)" || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      /*|..|../*|*/..|*/../*) log_verbose "Rejecting unsafe target path: $p"; continue ;;
    esac
    if [ -e "$root/$p" ]; then
      phys="$(cd "$root/$p" 2>/dev/null && pwd -P)"
      case "$phys" in
        "$rootphys"/*) ;;
        *) log_verbose "Rejecting target outside root tree: $p"; continue ;;
      esac
    fi
    printf '%s\n' "$p"
  done
}

# Public: print detected target paths (relative to root), one per line.
detect_targets() {
  local root="$1"
  local mode
  mode="$(effective_mode "$root")"
  case "$mode" in
    submodule)   _detect_submodules "$root" ;;
    independent) _detect_independent "$root" "$MRS_SCAN_DEPTH" ;;
  esac | _filter_targets "$root" | _reject_unsafe_paths "$root" | sort -u
}

# Public: validate a caller-supplied target list (one relative path per line on
# stdin) and print the safe subset. Used for the "affected repositories" list
# parsed from plan.md: the paths are intentional (so gitignore/exclude rules are
# not re-applied), but they still pass through the path-traversal / outside-root
# guard so an attacker-influenced plan.md can never branch outside the root tree.
filter_explicit_targets() {
  local root="$1"
  # Trim whitespace around comma-split items (the PowerShell twin Trim()s too);
  # sed also newline-terminates the final item so the read loop in
  # _reject_unsafe_paths never drops an unterminated last line.
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
    | _reject_unsafe_paths "$root" | sort -u
}

# True if the given branch name is in the skip list.
is_skipped_branch() {
  local branch="$1" name
  set -f   # word-split on whitespace without pathname expansion (a '*' in config
           # must not glob the filesystem)
  for name in $MRS_SKIP_BRANCHES; do
    if [ "$branch" = "$name" ]; then set +f; return 0; fi
  done
  set +f
  return 1
}

#!/usr/bin/env bash
# Test plan / harness for the bash implementation of multi-repo-sync.
#
# Builds throwaway git repositories under a temp dir and asserts behaviour for
# every scenario in the extension's test plan. Run from anywhere:
#   bash tests/test-bash.sh
#
# Exit 0 = all scenarios passed.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SCRIPTS="$HERE/../scripts/bash"
SYNC="$SCRIPTS/sync-feature-branches.sh"
STATUS="$SCRIPTS/sync-status.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mrs-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL - %s\n' "$1"; }
check(){ # check <description> <condition-cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

mkrepo() { # mkrepo <dir>  -> init + one commit
  ( mkdir -p "$1" && cd "$1" && git init -q -b main && echo x > file.txt \
    && git add . && git commit -qm init )
}
# `git -C <dir>` discovers a repository upward, so an empty directory nested in
# the root test repo would resolve to the ROOT and make branch assertions pass
# vacuously (masking the uninitialized-submodule regression). Require <dir> to
# be its own worktree toplevel before looking the branch up.
is_repo_top() { [ "$(git -C "$1" rev-parse --is-inside-work-tree --show-prefix 2>/dev/null)" = "true" ]; }
has_branch() { is_repo_top "$1" && git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
no_branch()  { ! has_branch "$1" "$2"; }
on_branch()  { [ "$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$2" ]; }

# ---------------------------------------------------------------------------
echo "Scenario 1: independent mode + scan_depth limit + gitignore"
R="$WORK/s1"; mkrepo "$R"
mkrepo "$R/services/api"; mkrepo "$R/services/web"; mkrepo "$R/libs/shared"
mkrepo "$R/ignored/vendor"; mkrepo "$R/a/b/c"
( cd "$R" && echo "ignored/" > .gitignore && git add .gitignore && git commit -qm ig )
mkdir -p "$R/.specify"
echo '{ "multi_repo_branching": { "type": "independent", "scan_depth": 2 } }' > "$R/.specify/init-options.json"
( cd "$R" && git switch -qc 001-feature )
( cd "$R" && "$SYNC" --quiet )
check "creates branch in services/api"   has_branch "$R/services/api" 001-feature
check "creates branch in services/web"    has_branch "$R/services/web" 001-feature
check "creates branch in libs/shared"     has_branch "$R/libs/shared" 001-feature
check "skips gitignored ignored/vendor"   no_branch  "$R/ignored/vendor" 001-feature
check "respects scan_depth (skips a/b/c)" no_branch  "$R/a/b/c" 001-feature

echo "Scenario 2: idempotent re-run (already exists)"
out="$( cd "$R" && "$SYNC" --json --quiet )"
check "re-run reports exists, zero created" bash -c "echo '$out' | grep -q '\"created\":0'"
check "re-run still has the branch"          has_branch "$R/services/api" 001-feature

echo "Scenario 3: submodule mode (auto-detect via .gitmodules)"
R2="$WORK/s2"; mkrepo "$WORK/upstream"
mkrepo "$R2"
( cd "$R2" && git -c protocol.file.allow=always submodule add -q "$WORK/upstream" vendor/lib >/dev/null 2>&1 && git commit -qm sub )
mkdir -p "$R2/.specify"; echo '{ "multi_repo_branching": { "type": "auto" } }' > "$R2/.specify/init-options.json"
( cd "$R2" && git switch -qc 002-feature && "$SYNC" --quiet )
check "auto resolves to submodule + creates branch" has_branch "$R2/vendor/lib" 002-feature

echo "Scenario 4: dry-run creates nothing"
R3="$WORK/s3"; mkrepo "$R3"; mkrepo "$R3/sub"
( cd "$R3" && git switch -qc 003-feature && "$SYNC" --dry-run --quiet )
check "dry-run does not create the branch" no_branch "$R3/sub" 003-feature

echo "Scenario 5: failure isolation (dirty tree w/ --switch, unborn HEAD)"
R4="$WORK/s4"; mkrepo "$R4"
mkrepo "$R4/clean"
mkrepo "$R4/dirty"; ( cd "$R4/dirty" && echo more >> file.txt )   # dirty working tree
( mkdir -p "$R4/unborn" && cd "$R4/unborn" && git init -q -b main ) # no commit
( cd "$R4" && git switch -qc 004-feature )
( cd "$R4" && "$SYNC" --switch --quiet ); rc=$?
check "exit code 1 signals isolated failure" test "$rc" -eq 1
check "clean sub got branch and switched"     bash -c "[ \"\$(git -C '$R4/clean' rev-parse --abbrev-ref HEAD)\" = 004-feature ]"
check "dirty sub got branch (not switched)"   has_branch "$R4/dirty" 004-feature
check "dirty sub left on main"                bash -c "[ \"\$(git -C '$R4/dirty' rev-parse --abbrev-ref HEAD)\" = main ]"
check "unborn sub failed (no branch)"         no_branch "$R4/unborn" 004-feature

echo "Scenario 6: skip_branches guard (on main = no-op)"
R5="$WORK/s5"; mkrepo "$R5"; mkrepo "$R5/sub"
out="$( cd "$R5" && "$SYNC" --json --quiet )"
check "on main reports skipped_branch reason" bash -c "echo '$out' | grep -q 'skipped_branch'"
check "sub repo untouched (only its own main)" \
  bash -c "[ \"\$(git -C '$R5/sub' for-each-ref --format='%(refname:short)' refs/heads | wc -l | tr -d ' ')\" = 1 ]"

echo "Scenario 7: status command is read-only"
R6="$WORK/s6"; mkrepo "$R6"; mkrepo "$R6/sub"
( cd "$R6" && git switch -qc 007-feature && "$STATUS" --json --quiet >/dev/null )
check "status did not create any branch" no_branch "$R6/sub" 007-feature

echo "Scenario 8: YAML override config — list values (exclude space-separated, skip_branches comma-separated)"
R7="$WORK/s7"; mkrepo "$R7"
mkrepo "$R7/vendor"; mkrepo "$R7/keep"
mkdir -p "$R7/.specify/extensions/multi-repo-sync"
cat > "$R7/.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml" <<'YML'
type: independent
scan_depth: 2
exclude: vendor third_party
skip_branches: develop, main
YML
( cd "$R7" && git switch -qc 008-feature && "$SYNC" --quiet )
check "exclude skips 'vendor' (space-separated list)" no_branch  "$R7/vendor" 008-feature
check "exclude keeps non-excluded 'keep'"             has_branch "$R7/keep"   008-feature
( cd "$R7" && git switch -qc develop )
out8="$( cd "$R7" && "$SYNC" --json --quiet )"
check "skip_branches honors comma-separated 'develop'" bash -c "echo '$out8' | grep -q 'skipped_branch'"

echo "Scenario 9: rejects unsafe branch names (git argument-injection guard)"
R8="$WORK/s8"; mkrepo "$R8"; mkrepo "$R8/sub"
( cd "$R8" && git switch -qc 009-feature )
# An option-like name (leading '-') must never reach `git branch`/`git switch`.
( cd "$R8" && "$SYNC" --branch '-D' --quiet ); rc9=$?
check "exit code 2 for option-like branch name" test "$rc9" -eq 2
check "sub repo untouched (only its own main)" \
  bash -c "[ \"\$(git -C '$R8/sub' for-each-ref refs/heads | wc -l | tr -d ' ')\" = 1 ]"

echo "Scenario 10: rejects path-traversal submodule targets (malicious .gitmodules)"
R9="$WORK/s9"; mkrepo "$R9"
OUTSIDE="$WORK/outside"; mkrepo "$OUTSIDE"
# Hand-craft a .gitmodules whose path escapes the root working tree.
cat > "$R9/.gitmodules" <<GM
[submodule "evil"]
	path = ../outside
	url = $OUTSIDE
GM
( cd "$R9" && git add .gitmodules && git commit -qm gm )
mkdir -p "$R9/.specify"; echo '{ "multi_repo_branching": { "type": "submodule" } }' > "$R9/.specify/init-options.json"
( cd "$R9" && git switch -qc 010-feature && "$SYNC" --quiet )
check "traversal target outside root is not branched" no_branch "$OUTSIDE" 010-feature

echo "Scenario 11: malicious sub-repo hooks/fsmonitor never execute on --switch"
R10="$WORK/s10"; mkrepo "$R10"; mkrepo "$R10/evil"
# Plant a malicious post-checkout hook in the nested (attacker-controlled) repo;
# `git switch` would run it unless hooks are neutralized.
SENTINEL_HOOK="$WORK/pwned-post-checkout"
cat > "$R10/evil/.git/hooks/post-checkout" <<HOOK
#!/usr/bin/env bash
touch "$SENTINEL_HOOK"
HOOK
chmod +x "$R10/evil/.git/hooks/post-checkout"
# Plant a malicious fsmonitor program; `git status` would run it unless disabled.
SENTINEL_FSM="$WORK/pwned-fsmonitor"
cat > "$WORK/fsmon.sh" <<FSM
#!/usr/bin/env bash
touch "$SENTINEL_FSM"
FSM
chmod +x "$WORK/fsmon.sh"
git -C "$R10/evil" config core.fsmonitor "$WORK/fsmon.sh"
( cd "$R10" && git switch -qc 011-feature && "$SYNC" --switch --quiet )
check "post-checkout hook in sub-repo did NOT execute" test ! -e "$SENTINEL_HOOK"
check "fsmonitor program in sub-repo did NOT execute"  test ! -e "$SENTINEL_FSM"
check "branch is still created in the sub-repo"        has_branch "$R10/evil" 011-feature

echo "Scenario 12: rejects a symlinked submodule target escaping the root tree"
R11="$WORK/s11"; mkrepo "$R11"
OUTSIDE2="$WORK/outside2"; mkrepo "$OUTSIDE2"
# A submodule path that is lexically safe ('linked') but is a symlink to an
# external repository — must be resolved physically and rejected.
ln -s "$OUTSIDE2" "$R11/linked"
cat > "$R11/.gitmodules" <<GM
[submodule "linked"]
	path = linked
	url = $OUTSIDE2
GM
( cd "$R11" && git add .gitmodules && git commit -qm gm2 )
mkdir -p "$R11/.specify"; echo '{ "multi_repo_branching": { "type": "submodule" } }' > "$R11/.specify/init-options.json"
( cd "$R11" && git switch -qc 012-feature && "$SYNC" --quiet )
check "symlinked target outside root is not branched" no_branch "$OUTSIDE2" 012-feature

echo "Scenario 13: switch-by-default puts clean sub-repos on the new branch"
R12="$WORK/s12"; mkrepo "$R12"; mkrepo "$R12/sub"
( cd "$R12" && git switch -qc 013-feature && "$SYNC" --quiet )
check "sub got branch" has_branch "$R12/sub" 013-feature
check "sub switched onto branch (no --switch needed)" on_branch "$R12/sub" 013-feature

echo "Scenario 14: --targets restricts to the affected repositories (path-safe)"
R13="$WORK/s13"; mkrepo "$R13"; mkrepo "$R13/svc-a"; mkrepo "$R13/svc-b"
OUTSIDE3="$WORK/outside3"; mkrepo "$OUTSIDE3"
( cd "$R13" && git switch -qc 014-feature && "$SYNC" --quiet --targets "svc-a,../outside3" )
check "affected svc-a got branch"             has_branch "$R13/svc-a" 014-feature
check "unaffected svc-b untouched"            no_branch  "$R13/svc-b" 014-feature
check "--targets rejects path-traversal item" no_branch  "$OUTSIDE3"  014-feature

echo "Scenario 15: uninitialized submodule is initialized before branching"
UP2="$WORK/upstream2"; mkrepo "$UP2"
R14="$WORK/s14"; mkrepo "$R14"
( cd "$R14" && git config protocol.file.allow always \
    && git -c protocol.file.allow=always submodule add -q "$UP2" vendor/lib >/dev/null 2>&1 \
    && git commit -qm sub )
# Empty the working tree so the submodule looks like a fresh, unchecked-out clone.
( cd "$R14" && git submodule deinit -f vendor/lib >/dev/null 2>&1 )
mkdir -p "$R14/.specify"; echo '{ "multi_repo_branching": { "type": "submodule" } }' > "$R14/.specify/init-options.json"
( cd "$R14" && git switch -qc 015-feature && "$SYNC" --quiet )
check "submodule re-initialized (gitlink present)"     test -e "$R14/vendor/lib/.git"
check "uninitialized submodule initialized + branched" has_branch "$R14/vendor/lib" 015-feature

echo "Scenario 16: submodule path containing a space is detected in full"
UP3="$WORK/upstream3"; mkrepo "$UP3"
R15="$WORK/s15"; mkrepo "$R15"
( cd "$R15" && git config protocol.file.allow always \
    && git -c protocol.file.allow=always submodule add -q "$UP3" "my lib" >/dev/null 2>&1 \
    && git commit -qm sub )
mkdir -p "$R15/.specify"; echo '{ "multi_repo_branching": { "type": "submodule" } }' > "$R15/.specify/init-options.json"
( cd "$R15" && "$STATUS" --json --quiet 2>/dev/null ) > "$WORK/out16.json"
check "submodule path with space detected in full" grep -q '"path":"my lib"' "$WORK/out16.json"

echo "Scenario 17: detached root HEAD reported as detached; target state is n/a"
R16="$WORK/s16"; mkrepo "$R16"; mkrepo "$R16/sub"
( cd "$R16" && git checkout -q --detach )
( cd "$R16" && "$STATUS" --json --quiet 2>/dev/null ) > "$WORK/out17.json"
check "detached root branch is empty in JSON" grep -q '"root_branch":""' "$WORK/out17.json"
check "detached target state is n/a"          grep -q '"state":"n/a"'    "$WORK/out17.json"

echo "Scenario 18: --targets parses every entry (single item, padded list)"
R17="$WORK/s17"; mkrepo "$R17"; mkrepo "$R17/svc-a"; mkrepo "$R17/svc-b"
( cd "$R17" && git switch -qc 018-feature && "$SYNC" --quiet --targets "svc-b" )
check "single --targets entry is branched" has_branch "$R17/svc-b" 018-feature
( cd "$R17" && "$SYNC" --quiet --targets "svc-a, svc-b" ); rc18=$?
check "padded list: svc-a branched"              has_branch "$R17/svc-a" 018-feature
check "padded list: svc-b (after space) branched" has_branch "$R17/svc-b" 018-feature
check "padded list exits 0"                       test "$rc18" -eq 0

echo "Scenario 19: scan_depth 0 is invalid and falls back to the default (2)"
R18="$WORK/s18"; mkrepo "$R18"; mkrepo "$R18/services/api"
mkdir -p "$R18/.specify"
echo '{ "multi_repo_branching": { "type": "independent", "scan_depth": 0 } }' > "$R18/.specify/init-options.json"
( cd "$R18" && git switch -qc 019-feature && "$SYNC" --quiet )
check "scan_depth 0 falls back to 2 (depth-2 repo branched)" has_branch "$R18/services/api" 019-feature

echo "Scenario 20: grep fallback parser is scoped to multi_repo_branching"
R19="$WORK/s19"; mkdir -p "$R19"
cat > "$R19/init-options.json" <<'JSON'
{
  "project": { "type": "independent" },
  "multi_repo_branching": { "type": "submodule" }
}
JSON
# Run _read_init_options on a PATH without python3/jq so the grep path is taken.
BIN20="$WORK/limited-bin"; mkdir -p "$BIN20"
for tool in bash grep sed head sort tr; do
  p="$(command -v "$tool" 2>/dev/null)" && ln -s "$p" "$BIN20/$tool"
done
out20="$(PATH="$BIN20" bash -c ". '$SCRIPTS/multi-repo-common.sh'; _read_init_options '$R19/init-options.json'")"
check "fallback resolves type from multi_repo_branching" \
  bash -c "printf '%s\n' '$out20' | grep -q '^type=submodule$'"

echo "Scenario 21: yml exclude appends to init-options excludes (empty value is ignored)"
R20="$WORK/s20"; mkrepo "$R20"
mkrepo "$R20/vendor"; mkrepo "$R20/third_party"; mkrepo "$R20/keep"
mkdir -p "$R20/.specify/extensions/multi-repo-sync"
echo '{ "multi_repo_branching": { "type": "independent", "exclude": ["vendor"] } }' > "$R20/.specify/init-options.json"
echo 'exclude: third_party' > "$R20/.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml"
( cd "$R20" && git switch -qc 021-feature && "$SYNC" --quiet )
check "init-options exclude still honored (vendor skipped)" no_branch  "$R20/vendor" 021-feature
check "yml exclude appended (third_party skipped)"          no_branch  "$R20/third_party" 021-feature
check "non-excluded repo branched"                          has_branch "$R20/keep" 021-feature
# A bare `exclude:` line (the shipped template ends with one) must not reset the list.
echo 'exclude:' > "$R20/.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml"
( cd "$R20" && git switch -qc 021b-feature && "$SYNC" --quiet )
check "empty yml exclude keeps init-options excludes" no_branch "$R20/vendor" 021b-feature

echo "Scenario 22: status reports an uninitialized submodule distinctly"
UP4="$WORK/upstream4"; mkrepo "$UP4"
R21="$WORK/s21"; mkrepo "$R21"
( cd "$R21" && git config protocol.file.allow always \
    && git -c protocol.file.allow=always submodule add -q "$UP4" vendor/lib >/dev/null 2>&1 \
    && git commit -qm sub \
    && git submodule deinit -f vendor/lib >/dev/null 2>&1 )
mkdir -p "$R21/.specify"; echo '{ "multi_repo_branching": { "type": "submodule" } }' > "$R21/.specify/init-options.json"
( cd "$R21" && git switch -qc 022-feature && "$STATUS" --json --quiet 2>/dev/null ) > "$WORK/out22.json"
check "status reports uninitialized_submodule" grep -q '"state":"uninitialized_submodule"' "$WORK/out22.json"

echo "Scenario 23: --branch HEAD is rejected; a truly detached root still reports detached_head"
R22="$WORK/s22"; mkrepo "$R22"; mkrepo "$R22/sub"
( cd "$R22" && "$SYNC" --branch HEAD --quiet ); rc23=$?
check "exit code 2 for --branch HEAD" test "$rc23" -eq 2
( cd "$R22" && git checkout -q --detach && "$SYNC" --json --quiet ) > "$WORK/out23.json"; rc23b=$?
check "detached root reports detached_head" grep -q '"reason":"detached_head"' "$WORK/out23.json"
check "detached root exits 0"               test "$rc23b" -eq 0

echo "Scenario 24: malicious sub-repo content filter never executes on status/switch"
R23f="$WORK/s23f"; mkrepo "$R23f"
# Vector A: filter.<name>.clean runs on `git status` (the is_clean probe) to
# normalize a stat-dirty file before comparing it to the index. Neither
# core.hooksPath nor core.fsmonitor disables it.
mkrepo "$R23f/evilA"
SENTINEL_CLEAN="$WORK/pwned-filter-clean"
( cd "$R23f/evilA" && printf '* filter=x\n' > .gitattributes && git add .gitattributes && git commit -qm attrs )
git -C "$R23f/evilA" config filter.x.clean "touch '$SENTINEL_CLEAN'; cat"
git -C "$R23f/evilA" config filter.x.required true
# Make the tracked file stat-dirty so status must re-read it through the clean
# filter (an attacker ships the index/mtime that forces this).
( cd "$R23f/evilA" && echo tampered >> file.txt )
# Vector B: filter.<name>.smudge runs on `git switch` to a branch whose tree
# differs, rewriting the working file.
mkrepo "$R23f/evilB"
SENTINEL_SMUDGE="$WORK/pwned-filter-smudge"
( cd "$R23f/evilB" && printf '* filter=x\n' > .gitattributes && git add .gitattributes && git commit -qm attrs )
( cd "$R23f/evilB" && git switch -qc 024-feature && echo y > file.txt && git commit -qam y && git switch -q main )
# clean=cat keeps git's overwrite-safety check working so the switch proceeds and
# actually applies the (malicious) smudge — without it the required filter aborts
# the switch and the smudge assertion would pass vacuously.
git -C "$R23f/evilB" config filter.x.clean cat
git -C "$R23f/evilB" config filter.x.smudge "touch '$SENTINEL_SMUDGE'; cat"
git -C "$R23f/evilB" config filter.x.required true
( cd "$R23f" && git switch -qc 024-feature && "$SYNC" --switch --quiet )
check "clean filter in sub-repo did NOT execute on status" test ! -e "$SENTINEL_CLEAN"
check "smudge filter in sub-repo did NOT execute on switch" test ! -e "$SENTINEL_SMUDGE"
check "switch onto the divergent branch still succeeds"     on_branch "$R23f/evilB" 024-feature
check "branch is still created in the dirty sub-repo"       has_branch "$R23f/evilA" 024-feature

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

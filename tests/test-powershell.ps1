#!/usr/bin/env pwsh
# Test plan / harness for the PowerShell implementation of multi-repo-sync.
# Mirrors tests/test-bash.sh. Run on any pwsh 7+ host (Windows/macOS/Linux):
#   pwsh -NoProfile -File tests/test-powershell.ps1
# Exit 0 = all scenarios passed.

$ErrorActionPreference = 'Continue'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$psDir   = Join-Path $here '../scripts/powershell'
$sync    = Join-Path $psDir 'sync-feature-branches.ps1'
$status  = Join-Path $psDir 'sync-status.ps1'

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("mrs-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

$env:GIT_AUTHOR_NAME='test'; $env:GIT_AUTHOR_EMAIL='test@example.com'
$env:GIT_COMMITTER_NAME='test'; $env:GIT_COMMITTER_EMAIL='test@example.com'

$script:pass = 0; $script:fail = 0
function Ok  { param($m) $script:pass++; Write-Host "  ok   - $m" }
function Bad { param($m) $script:fail++; Write-Host "  FAIL - $m" }
function Check { param($desc, [scriptblock]$cond) if (& $cond) { Ok $desc } else { Bad $desc } }

function New-Repo { param($dir)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Push-Location $dir
    git init -q -b main; 'x' | Out-File file.txt; git add .; git commit -qm init
    Pop-Location
}
# `git -C <dir>` discovers a repository upward, so an empty directory nested in
# the root test repo would resolve to the ROOT and make branch assertions pass
# vacuously (masking the uninitialized-submodule regression). Require <dir> to
# be its own worktree toplevel before looking the branch up.
function Test-RepoTop { param($dir)
    $out = git -C $dir rev-parse --is-inside-work-tree --show-prefix 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ((@($out) -join "`n").TrimEnd() -eq 'true')
}
function Has-Branch { param($dir,$b)
    if (-not (Test-RepoTop $dir)) { return $false }
    git -C $dir show-ref --verify --quiet "refs/heads/$b"; return ($LASTEXITCODE -eq 0)
}
function On-Branch  { param($dir,$b) return ((git -C $dir rev-parse --abbrev-ref HEAD 2>$null) -eq $b) }

try {
    Write-Host "Scenario 1: independent mode + scan_depth + gitignore"
    $r = Join-Path $work 's1'; New-Repo $r
    New-Repo (Join-Path $r 'services/api'); New-Repo (Join-Path $r 'services/web')
    New-Repo (Join-Path $r 'libs/shared'); New-Repo (Join-Path $r 'ignored/vendor'); New-Repo (Join-Path $r 'a/b/c')
    Push-Location $r; 'ignored/' | Out-File .gitignore; git add .gitignore; git commit -qm ig; Pop-Location
    New-Item -ItemType Directory -Path (Join-Path $r '.specify') -Force | Out-Null
    '{ "multi_repo_branching": { "type": "independent", "scan_depth": 2 } }' | Out-File (Join-Path $r '.specify/init-options.json')
    Push-Location $r; git switch -qc 001-feature; & $sync -Quiet; Pop-Location
    Check "creates branch in services/api"   { Has-Branch (Join-Path $r 'services/api') 001-feature }
    Check "creates branch in services/web"    { Has-Branch (Join-Path $r 'services/web') 001-feature }
    Check "creates branch in libs/shared"     { Has-Branch (Join-Path $r 'libs/shared') 001-feature }
    Check "skips gitignored ignored/vendor"   { -not (Has-Branch (Join-Path $r 'ignored/vendor') 001-feature) }
    Check "respects scan_depth (skips a/b/c)" { -not (Has-Branch (Join-Path $r 'a/b/c') 001-feature) }

    Write-Host "Scenario 2: idempotent re-run"
    Push-Location $r; $out = & $sync -Json -Quiet; Pop-Location
    Check "re-run reports created:0" { $out -match '"created":0' }

    Write-Host "Scenario 3: submodule auto-detect"
    $up = Join-Path $work 'upstream'; New-Repo $up
    $r2 = Join-Path $work 's2'; New-Repo $r2
    Push-Location $r2
    git -c protocol.file.allow=always submodule add -q $up vendor/lib *> $null; git commit -qm sub
    New-Item -ItemType Directory -Path '.specify' -Force | Out-Null
    '{ "multi_repo_branching": { "type": "auto" } }' | Out-File '.specify/init-options.json'
    git switch -qc 002-feature; & $sync -Quiet; Pop-Location
    Check "auto->submodule creates branch" { Has-Branch (Join-Path $r2 'vendor/lib') 002-feature }

    Write-Host "Scenario 4: dry-run creates nothing"
    $r3 = Join-Path $work 's3'; New-Repo $r3; New-Repo (Join-Path $r3 'sub')
    Push-Location $r3; git switch -qc 003-feature; & $sync -DryRun -Quiet; Pop-Location
    Check "dry-run creates nothing" { -not (Has-Branch (Join-Path $r3 'sub') 003-feature) }

    Write-Host "Scenario 5: failure isolation (dirty + unborn) with -Switch"
    $r4 = Join-Path $work 's4'; New-Repo $r4
    New-Repo (Join-Path $r4 'clean')
    New-Repo (Join-Path $r4 'dirty'); 'more' | Add-Content (Join-Path $r4 'dirty/file.txt')
    New-Item -ItemType Directory -Path (Join-Path $r4 'unborn') -Force | Out-Null
    Push-Location (Join-Path $r4 'unborn'); git init -q -b main; Pop-Location
    Push-Location $r4; git switch -qc 004-feature; & $sync -Switch -Quiet; $rc = $LASTEXITCODE; Pop-Location
    Check "exit code 1 on isolated failure" { $rc -eq 1 }
    Check "clean got branch and switched"   { (Has-Branch (Join-Path $r4 'clean') 004-feature) -and ((git -C (Join-Path $r4 'clean') rev-parse --abbrev-ref HEAD) -eq '004-feature') }
    Check "dirty got branch, not switched"  { (Has-Branch (Join-Path $r4 'dirty') 004-feature) -and ((git -C (Join-Path $r4 'dirty') rev-parse --abbrev-ref HEAD) -eq 'main') }
    Check "unborn failed (no branch)"        { -not (Has-Branch (Join-Path $r4 'unborn') 004-feature) }

    Write-Host "Scenario 6: skip_branches guard"
    $r5 = Join-Path $work 's5'; New-Repo $r5; New-Repo (Join-Path $r5 'sub')
    Push-Location $r5; $out = & $sync -Json -Quiet; Pop-Location
    Check "on main reports skipped_branch" { $out -match 'skipped_branch' }
    Check "sub repo untouched (only its own main)" { (@(git -C (Join-Path $r5 'sub') for-each-ref --format='%(refname:short)' refs/heads)).Count -eq 1 }

    Write-Host "Scenario 7: status is read-only"
    $r6 = Join-Path $work 's6'; New-Repo $r6; New-Repo (Join-Path $r6 'sub')
    Push-Location $r6; git switch -qc 007-feature; & $status -Json -Quiet | Out-Null; Pop-Location
    Check "status creates nothing" { -not (Has-Branch (Join-Path $r6 'sub') 007-feature) }

    Write-Host "Scenario 8: YAML override config — list values (exclude space-separated, skip_branches comma-separated)"
    $r7 = Join-Path $work 's7'; New-Repo $r7
    New-Repo (Join-Path $r7 'vendor'); New-Repo (Join-Path $r7 'keep')
    New-Item -ItemType Directory -Path (Join-Path $r7 '.specify/extensions/multi-repo-sync') -Force | Out-Null
    @(
        'type: independent'
        'scan_depth: 2'
        'exclude: vendor third_party'
        'skip_branches: develop, main'
    ) | Out-File (Join-Path $r7 '.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml')
    Push-Location $r7; git switch -qc 008-feature; & $sync -Quiet; Pop-Location
    Check "exclude skips 'vendor' (space-separated list)" { -not (Has-Branch (Join-Path $r7 'vendor') 008-feature) }
    Check "exclude keeps non-excluded 'keep'"             { Has-Branch (Join-Path $r7 'keep') 008-feature }
    Push-Location $r7; git switch -qc develop; $out8 = & $sync -Json -Quiet; Pop-Location
    Check "skip_branches honors comma-separated 'develop'" { $out8 -match 'skipped_branch' }

    Write-Host "Scenario 9: rejects unsafe branch names (git argument-injection guard)"
    $r8 = Join-Path $work 's8'; New-Repo $r8; New-Repo (Join-Path $r8 'sub')
    Push-Location $r8; git switch -qc 009-feature
    # An option-like name (leading '-') must never reach git branch/switch.
    & $sync -Branch '-D' -Quiet; $rc9 = $LASTEXITCODE; Pop-Location
    Check "exit code 2 for option-like branch name" { $rc9 -eq 2 }
    Check "sub repo untouched (only its own main)" {
        (@(git -C (Join-Path $r8 'sub') for-each-ref refs/heads).Count) -eq 1
    }

    Write-Host "Scenario 10: rejects path-traversal submodule targets (malicious .gitmodules)"
    $r9 = Join-Path $work 's9'; New-Repo $r9
    $outside = Join-Path $work 'outside'; New-Repo $outside
    @(
        '[submodule "evil"]'
        "`tpath = ../outside"
        "`turl = $outside"
    ) | Out-File (Join-Path $r9 '.gitmodules')
    Push-Location $r9; git add .gitmodules; git commit -qm gm; Pop-Location
    New-Item -ItemType Directory -Path (Join-Path $r9 '.specify') -Force | Out-Null
    '{ "multi_repo_branching": { "type": "submodule" } }' | Out-File (Join-Path $r9 '.specify/init-options.json')
    Push-Location $r9; git switch -qc 010-feature; & $sync -Quiet; Pop-Location
    Check "traversal target outside root is not branched" { -not (Has-Branch $outside 010-feature) }

    Write-Host "Scenario 11: malicious sub-repo post-checkout hook never executes on -Switch"
    $r10 = Join-Path $work 's10'; New-Repo $r10
    $evil = Join-Path $r10 'evil'; New-Repo $evil
    $hookDir = Join-Path $evil '.git/hooks'
    New-Item -ItemType Directory -Path $hookDir -Force | Out-Null
    # The hook drops a sentinel into its own worktree (the cwd when hooks run);
    # `git switch` would run it unless hooks are neutralized.
    (@('#!/bin/sh', 'touch pwned-post-checkout') -join "`n") |
        Out-File -FilePath (Join-Path $hookDir 'post-checkout') -Encoding ascii -NoNewline
    if (-not $IsWindows) { chmod +x (Join-Path $hookDir 'post-checkout') }
    # Plant a malicious fsmonitor program; `git status` would run it unless
    # disabled (mirrors the bash suite's fsmonitor sentinel).
    $fsmSentinel = Join-Path $work 'pwned-fsmonitor'
    if (-not $IsWindows) {
        $fsmScript = Join-Path $work 'fsmon.sh'
        (@('#!/bin/sh', "touch '$fsmSentinel'") -join "`n") |
            Out-File -FilePath $fsmScript -Encoding ascii -NoNewline
        chmod +x $fsmScript
        git -C $evil config core.fsmonitor $fsmScript
    }
    Push-Location $r10; git switch -qc 011-feature; & $sync -Switch -Quiet; Pop-Location
    Check "post-checkout hook in sub-repo did NOT execute" { -not (Test-Path (Join-Path $evil 'pwned-post-checkout')) }
    if (-not $IsWindows) {
        Check "fsmonitor program in sub-repo did NOT execute" { -not (Test-Path $fsmSentinel) }
    }
    Check "branch is still created in the sub-repo"        { Has-Branch $evil 011-feature }

    if (-not $IsWindows) {
        Write-Host "Scenario 12: rejects a symlinked submodule target escaping the root tree"
        $r11 = Join-Path $work 's11'; New-Repo $r11
        $outside2 = Join-Path $work 'outside2'; New-Repo $outside2
        # A submodule path that is lexically safe ('linked') but is a symlink to
        # an external repository — must be resolved physically and rejected.
        New-Item -ItemType SymbolicLink -Path (Join-Path $r11 'linked') -Target $outside2 | Out-Null
        @('[submodule "linked"]', "`tpath = linked", "`turl = $outside2") | Out-File (Join-Path $r11 '.gitmodules')
        Push-Location $r11; git add .gitmodules; git commit -qm gm2; Pop-Location
        New-Item -ItemType Directory -Path (Join-Path $r11 '.specify') -Force | Out-Null
        '{ "multi_repo_branching": { "type": "submodule" } }' | Out-File (Join-Path $r11 '.specify/init-options.json')
        Push-Location $r11; git switch -qc 012-feature; & $sync -Quiet; Pop-Location
        Check "symlinked target outside root is not branched" { -not (Has-Branch $outside2 012-feature) }
    }

    Write-Host "Scenario 13: switch-by-default puts clean sub-repos on the new branch"
    $r12 = Join-Path $work 's12'; New-Repo $r12; New-Repo (Join-Path $r12 'sub')
    Push-Location $r12; git switch -qc 013-feature; & $sync -Quiet; Pop-Location
    Check "sub got branch"                              { Has-Branch (Join-Path $r12 'sub') 013-feature }
    Check "sub switched onto branch (no -Switch needed)" { On-Branch (Join-Path $r12 'sub') 013-feature }

    Write-Host "Scenario 14: -Targets restricts to the affected repositories (path-safe)"
    $r13 = Join-Path $work 's13'; New-Repo $r13
    New-Repo (Join-Path $r13 'svc-a'); New-Repo (Join-Path $r13 'svc-b')
    $outside3 = Join-Path $work 'outside3'; New-Repo $outside3
    Push-Location $r13; git switch -qc 014-feature; & $sync -Quiet -Targets 'svc-a,../outside3'; Pop-Location
    Check "affected svc-a got branch"            { Has-Branch (Join-Path $r13 'svc-a') 014-feature }
    Check "unaffected svc-b untouched"           { -not (Has-Branch (Join-Path $r13 'svc-b') 014-feature) }
    Check "-Targets rejects path-traversal item" { -not (Has-Branch $outside3 014-feature) }

    Write-Host "Scenario 15: uninitialized submodule is initialized before branching"
    $up2 = Join-Path $work 'upstream2'; New-Repo $up2
    $r14 = Join-Path $work 's14'; New-Repo $r14
    Push-Location $r14
    git config protocol.file.allow always
    git -c protocol.file.allow=always submodule add -q $up2 vendor/lib *> $null; git commit -qm sub
    git submodule deinit -f vendor/lib *> $null
    New-Item -ItemType Directory -Path '.specify' -Force | Out-Null
    '{ "multi_repo_branching": { "type": "submodule" } }' | Out-File '.specify/init-options.json'
    git switch -qc 015-feature; & $sync -Quiet; Pop-Location
    Check "submodule re-initialized (gitlink present)"     { Test-Path -LiteralPath (Join-Path $r14 'vendor/lib/.git') }
    Check "uninitialized submodule initialized + branched" { Has-Branch (Join-Path $r14 'vendor/lib') 015-feature }

    Write-Host "Scenario 16: submodule path containing a space is detected in full"
    $up3 = Join-Path $work 'upstream3'; New-Repo $up3
    $r15 = Join-Path $work 's15'; New-Repo $r15
    Push-Location $r15
    git config protocol.file.allow always
    git -c protocol.file.allow=always submodule add -q $up3 'my lib' *> $null; git commit -qm sub
    New-Item -ItemType Directory -Path '.specify' -Force | Out-Null
    '{ "multi_repo_branching": { "type": "submodule" } }' | Out-File '.specify/init-options.json'
    $out16 = & $status -Json -Quiet
    Pop-Location
    Check "submodule path with space detected in full" { $out16 -match '"path":"my lib"' }

    Write-Host "Scenario 17: detached root HEAD reported as detached; target state is n/a"
    $r16 = Join-Path $work 's16'; New-Repo $r16; New-Repo (Join-Path $r16 'sub')
    Push-Location $r16; git checkout -q --detach; $out17 = & $status -Json -Quiet; Pop-Location
    Check "detached root branch is empty in JSON" { $out17 -match '"root_branch":""' }
    Check "detached target state is n/a"          { $out17 -match '"state":"n/a"' }

    Write-Host "Scenario 18: -Targets parses every entry (single item, padded list)"
    $r17 = Join-Path $work 's17'; New-Repo $r17
    New-Repo (Join-Path $r17 'svc-a'); New-Repo (Join-Path $r17 'svc-b')
    Push-Location $r17; git switch -qc 018-feature; & $sync -Quiet -Targets 'svc-b'; Pop-Location
    Check "single -Targets entry is branched" { Has-Branch (Join-Path $r17 'svc-b') 018-feature }
    Push-Location $r17; & $sync -Quiet -Targets 'svc-a, svc-b'; $rc18 = $LASTEXITCODE; Pop-Location
    Check "padded list: svc-a branched"               { Has-Branch (Join-Path $r17 'svc-a') 018-feature }
    Check "padded list: svc-b (after space) branched" { Has-Branch (Join-Path $r17 'svc-b') 018-feature }
    Check "padded list exits 0"                       { $rc18 -eq 0 }

    Write-Host "Scenario 19: scan_depth 0 is invalid and falls back to the default (2)"
    $r18 = Join-Path $work 's18'; New-Repo $r18; New-Repo (Join-Path $r18 'services/api')
    New-Item -ItemType Directory -Path (Join-Path $r18 '.specify') -Force | Out-Null
    '{ "multi_repo_branching": { "type": "independent", "scan_depth": 0 } }' | Out-File (Join-Path $r18 '.specify/init-options.json')
    Push-Location $r18; git switch -qc 019-feature; & $sync -Quiet; Pop-Location
    Check "scan_depth 0 falls back to 2 (depth-2 repo branched)" { Has-Branch (Join-Path $r18 'services/api') 019-feature }

    Write-Host "Scenario 21: yml exclude appends to init-options excludes (empty value is ignored)"
    $r20 = Join-Path $work 's20'; New-Repo $r20
    New-Repo (Join-Path $r20 'vendor'); New-Repo (Join-Path $r20 'third_party'); New-Repo (Join-Path $r20 'keep')
    New-Item -ItemType Directory -Path (Join-Path $r20 '.specify/extensions/multi-repo-sync') -Force | Out-Null
    '{ "multi_repo_branching": { "type": "independent", "exclude": ["vendor"] } }' | Out-File (Join-Path $r20 '.specify/init-options.json')
    'exclude: third_party' | Out-File (Join-Path $r20 '.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml')
    Push-Location $r20; git switch -qc 021-feature; & $sync -Quiet; Pop-Location
    Check "init-options exclude still honored (vendor skipped)" { -not (Has-Branch (Join-Path $r20 'vendor') 021-feature) }
    Check "yml exclude appended (third_party skipped)"          { -not (Has-Branch (Join-Path $r20 'third_party') 021-feature) }
    Check "non-excluded repo branched"                          { Has-Branch (Join-Path $r20 'keep') 021-feature }
    # A bare `exclude:` line (the shipped template ends with one) must not reset the list.
    'exclude:' | Out-File (Join-Path $r20 '.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml')
    Push-Location $r20; git switch -qc 021b-feature; & $sync -Quiet; Pop-Location
    Check "empty yml exclude keeps init-options excludes" { -not (Has-Branch (Join-Path $r20 'vendor') 021b-feature) }

    Write-Host "Scenario 22: status reports an uninitialized submodule distinctly"
    $up4 = Join-Path $work 'upstream4'; New-Repo $up4
    $r21 = Join-Path $work 's21'; New-Repo $r21
    Push-Location $r21
    git config protocol.file.allow always
    git -c protocol.file.allow=always submodule add -q $up4 vendor/lib *> $null; git commit -qm sub
    git submodule deinit -f vendor/lib *> $null
    New-Item -ItemType Directory -Path '.specify' -Force | Out-Null
    '{ "multi_repo_branching": { "type": "submodule" } }' | Out-File '.specify/init-options.json'
    git switch -qc 022-feature; $out22 = & $status -Json -Quiet
    Pop-Location
    Check "status reports uninitialized_submodule" { $out22 -match '"state":"uninitialized_submodule"' }

    Write-Host "Scenario 23: -Branch HEAD is rejected; a truly detached root still reports detached_head"
    $r22 = Join-Path $work 's22'; New-Repo $r22; New-Repo (Join-Path $r22 'sub')
    Push-Location $r22; & $sync -Branch HEAD -Quiet; $rc23 = $LASTEXITCODE; Pop-Location
    Check "exit code 2 for -Branch HEAD" { $rc23 -eq 2 }
    Push-Location $r22; git checkout -q --detach; $out23 = & $sync -Json -Quiet; $rc23b = $LASTEXITCODE; Pop-Location
    Check "detached root reports detached_head" { $out23 -match '"reason":"detached_head"' }
    Check "detached root exits 0"               { $rc23b -eq 0 }

    Write-Host "Scenario 24: repo path containing wildcard chars is handled literally"
    $r23 = Join-Path $work 's23'; New-Repo $r23
    $br = Join-Path $r23 'pkgs[legacy]'
    [System.IO.Directory]::CreateDirectory($br) | Out-Null
    git -C $br init -q -b main
    [System.IO.File]::WriteAllText((Join-Path $br 'file.txt'), 'x')
    git -C $br add .; git -C $br commit -qm init
    Push-Location $r23; git switch -qc 024-feature; & $sync -Quiet; $rc24 = $LASTEXITCODE; Pop-Location
    Check "bracket-named repo branched"  { Has-Branch $br 024-feature }
    Check "no spurious failure (exit 0)" { $rc24 -eq 0 }

    Write-Host "Scenario 25: exclude matching is case-sensitive (bash parity)"
    $r24 = Join-Path $work 's24'; New-Repo $r24; New-Repo (Join-Path $r24 'vendor')
    New-Item -ItemType Directory -Path (Join-Path $r24 '.specify/extensions/multi-repo-sync') -Force | Out-Null
    @('type: independent', 'exclude: Vendor') | Out-File (Join-Path $r24 '.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml')
    Push-Location $r24; git switch -qc 025-feature; & $sync -Quiet; Pop-Location
    Check "exclude 'Vendor' does not skip 'vendor'" { Has-Branch (Join-Path $r24 'vendor') 025-feature }

    Write-Host "Scenario 26: malicious sub-repo content filter never executes on status/switch"
    $r25 = Join-Path $work 's25'; New-Repo $r25
    # Vector A: filter.<name>.clean runs on `git status` (the is_clean probe) to
    # normalize a stat-dirty file. Not blocked by hooksPath/fsmonitor.
    $evilA = Join-Path $r25 'evilA'; New-Repo $evilA
    $sentClean = Join-Path $work 'pwned-filter-clean'
    Push-Location $evilA
    '* filter=x' | Out-File -Encoding ascii .gitattributes; git add .gitattributes; git commit -qm attrs
    Pop-Location
    git -C $evilA config filter.x.clean "touch '$sentClean'; cat"
    git -C $evilA config filter.x.required true
    'tampered' | Add-Content (Join-Path $evilA 'file.txt')   # make it stat-dirty
    # Vector B: filter.<name>.smudge runs on `git switch` to a branch whose tree
    # differs, rewriting the working file.
    $evilB = Join-Path $r25 'evilB'; New-Repo $evilB
    $sentSmudge = Join-Path $work 'pwned-filter-smudge'
    Push-Location $evilB
    '* filter=x' | Out-File -Encoding ascii .gitattributes; git add .gitattributes; git commit -qm attrs
    git switch -qc 026-feature; 'y' | Out-File -Encoding ascii file.txt; git commit -qam y; git switch -q main
    Pop-Location
    # clean=cat keeps git's overwrite-safety check working so the switch proceeds
    # and actually applies the (malicious) smudge (else it would pass vacuously).
    git -C $evilB config filter.x.clean cat
    git -C $evilB config filter.x.smudge "touch '$sentSmudge'; cat"
    git -C $evilB config filter.x.required true
    Push-Location $r25; git switch -qc 026-feature; & $sync -Switch -Quiet; Pop-Location
    Check "clean filter in sub-repo did NOT execute on status" { -not (Test-Path $sentClean) }
    Check "smudge filter in sub-repo did NOT execute on switch" { -not (Test-Path $sentSmudge) }
    Check "switch onto the divergent branch still succeeds"     { On-Branch $evilB 026-feature }
    Check "branch is still created in the dirty sub-repo"       { Has-Branch $evilA 026-feature }

    Write-Host ""
    Write-Host "Results: $($script:pass) passed, $($script:fail) failed"
}
finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
exit ([int]($script:fail -ne 0))

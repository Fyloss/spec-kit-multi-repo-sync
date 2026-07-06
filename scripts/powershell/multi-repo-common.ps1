<#
.SYNOPSIS
    multi-repo-sync extension: shared helpers (config, detection, logging).
.DESCRIPTION
    Dot-sourced by sync-feature-branches.ps1 and sync-status.ps1. Behaviour is
    kept equivalent to scripts/bash/multi-repo-common.sh. Detection is
    compatible with the community preset `spec-kit-preset-multi-repo-branching`.
#>

$script:MrsQuiet   = $false
$script:MrsVerbose = $false

function Write-MrsInfo    { param([string]$Message) if (-not $script:MrsQuiet) { [Console]::Error.WriteLine($Message) } }
function Write-MrsWarn    { param([string]$Message) [Console]::Error.WriteLine("WARN: $Message") }
function Write-MrsError   { param([string]$Message) [Console]::Error.WriteLine("ERROR: $Message") }
function Write-MrsVerbose { param([string]$Message) if ($script:MrsVerbose) { [Console]::Error.WriteLine("  $Message") } }

# ----------------------------------------------------------------------------
# Git helpers
# ----------------------------------------------------------------------------
function Get-RepoRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0) { return $root.Trim() }
    return $null
}

function Get-CurrentBranch {
    # $null when detached: symbolic-ref only resolves a real branch ref, so
    # callers never see the literal "HEAD" that `rev-parse --abbrev-ref` reports.
    $b = git symbolic-ref --short -q HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $b) { return "$b".Trim() }
    return $null
}

# True if the name is a safe, syntactically valid git branch name. Rejects names
# beginning with '-' (which `git branch`/`git switch` would parse as options - an
# argument-injection vector via -Branch) and any name git considers malformed.
function Test-ValidBranchName {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name) -or $Name.StartsWith('-')) { return $false }
    git check-ref-format --branch $Name 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
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
# Note: neutralizing filters needs git >= 2.31 (GIT_CONFIG_COUNT) and pwsh 7+; it
# also disables any *legitimate* filter (e.g. git-lfs) defined in the sub-repo's
# local config for the duration of these branch/switch operations.
function Invoke-GitTarget {
    # Simple (non-advanced) function: every argument is captured verbatim in
    # $args with no parameter binding, so git flags like '--verify' pass through
    # untouched. $args[0] = target dir; the rest = git arguments.
    $dir = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $names = [System.Collections.Generic.List[string]]::new()
    $keys = git -C $dir -c core.hooksPath=/dev/null -c core.fsmonitor=false config --local --list --name-only 2>$null
    foreach ($k in @($keys)) {
        if ($k -match '^filter\.(.*)\.(?:clean|smudge|process|required)$' -and -not $names.Contains($Matches[1])) {
            $names.Add($Matches[1])
        }
    }
    $applied = [System.Collections.Generic.List[int]]::new()
    try {
        if ($names.Count -gt 0) {
            $i = 0
            foreach ($n in $names) {
                foreach ($kv in @(
                        @("filter.$n.clean",    ''),
                        @("filter.$n.smudge",   ''),
                        @("filter.$n.process",  ''),
                        @("filter.$n.required", 'false'))) {
                    [System.Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$i",   $kv[0], 'Process')
                    [System.Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$i", $kv[1], 'Process')
                    $applied.Add($i); $i++
                }
            }
            [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', "$i", 'Process')
        }
        git -C $dir -c core.hooksPath=/dev/null -c core.fsmonitor=false @rest
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $null, 'Process')
        foreach ($j in $applied) {
            [System.Environment]::SetEnvironmentVariable("GIT_CONFIG_KEY_$j",   $null, 'Process')
            [System.Environment]::SetEnvironmentVariable("GIT_CONFIG_VALUE_$j", $null, 'Process')
        }
    }
}

# Containment checks compare physical paths case-insensitively only on Windows
# (whose filesystems are); on a case-sensitive filesystem (PowerShell on
# Linux/macOS) a case-variant path is a DIFFERENT location and must not slip
# past the outside-root guard.
$script:MrsPathComparison = if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}

# Resolve a path to its physical location, following symlinks/junctions. Returns
# the final target for a link, otherwise the path's own full name. Used to keep
# the fan-out confined to the root tree (a symlinked target must not escape it).
function Resolve-PhysicalPath {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    # ResolveLinkTarget(final:$true) is .NET 6+ (PowerShell 7.1+). On Windows
    # PowerShell 5.1 (.NET Framework) the method does not exist, so detect it and
    # fall back to the provider's link Target - resolved to a full path under the
    # link's own parent - so the outside-root guard still follows symlinks there.
    if ($item.PSObject.Methods.Name -contains 'ResolveLinkTarget') {
        $target = $item.ResolveLinkTarget($true)
        if ($target) { return $target.FullName }
        return $item.FullName
    }
    $linkTarget = $item.Target
    if ($linkTarget) {
        $t = @($linkTarget)[0]
        if (-not [System.IO.Path]::IsPathRooted($t)) {
            $t = Join-Path (Split-Path -Parent $item.FullName) $t
        }
        return [System.IO.Path]::GetFullPath($t)
    }
    return $item.FullName
}

function Test-GitWorktree {
    param([string]$Dir)
    # `--is-inside-work-tree` alone is not enough: from an empty directory (e.g.
    # an uninitialized submodule) git discovers the PARENT repository upward and
    # would answer "true" for it - so also require an empty --show-prefix
    # (dir == toplevel).
    $out = Invoke-GitTarget $Dir rev-parse --is-inside-work-tree --show-prefix 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ((@($out) -join "`n").TrimEnd() -eq 'true')
}

function Test-CleanTree {
    param([string]$Dir)
    $status = Invoke-GitTarget $Dir status --porcelain 2>$null
    return [string]::IsNullOrWhiteSpace($status)
}

function Test-BranchExists {
    param([string]$Dir, [string]$Branch)
    Invoke-GitTarget $Dir show-ref --verify --quiet "refs/heads/$Branch" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-HasCommit {
    param([string]$Dir)
    Invoke-GitTarget $Dir rev-parse --verify --quiet HEAD 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ----------------------------------------------------------------------------
# Configuration  (defaults -> init-options.json -> extension-local yml)
# Sets module-scoped: $MrsType $MrsScanDepth $MrsSwitch $MrsSkipBranches $MrsExclude
# ----------------------------------------------------------------------------
function Read-InitOptions {
    param([string]$Path)
    $pairs = @{}
    if (-not (Test-Path $Path)) { return $pairs }
    try {
        $data = Get-Content -Raw -Path $Path | ConvertFrom-Json
    } catch { return $pairs }
    $m = $data.multi_repo_branching
    if ($null -eq $m) { return $pairs }
    if ($m.PSObject.Properties.Name -contains 'type')          { $pairs['type']          = [string]$m.type }
    if ($m.PSObject.Properties.Name -contains 'scan_depth')    { $pairs['scan_depth']    = [string]$m.scan_depth }
    if ($m.PSObject.Properties.Name -contains 'switch')        { $pairs['switch']        = ([string]$m.switch).ToLower() }
    if ($m.PSObject.Properties.Name -contains 'skip_branches') { $pairs['skip_branches'] = ($m.skip_branches -join ' ') }
    if ($m.PSObject.Properties.Name -contains 'exclude')       { $pairs['exclude']       = @($m.exclude) }
    return $pairs
}

function Read-YamlConfig {
    param([string]$Path)
    $pairs = @{}
    if (-not (Test-Path $Path)) { return $pairs }
    foreach ($line in (Get-Content -Path $Path)) {
        $clean = ($line -replace '#.*$', '').Trim()
        if ($clean -match '^(type|scan_depth|switch|skip_branches|exclude)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            $pairs[$key] = $val
        }
    }
    return $pairs
}

function Initialize-MrsConfig {
    param([string]$Root)

    # Defaults (match the preset). The preset creates branches with `checkout -b`,
    # which also switches the sub-repo onto the new branch, so switching is the
    # default here too (best-effort, only on a clean working tree).
    $script:MrsType         = 'auto'
    $script:MrsScanDepth    = 2
    $script:MrsSwitch       = $true
    $script:MrsSkipBranches = @('main', 'master')
    $script:MrsExclude      = @()

    $applyPairs = {
        param($pairs)
        foreach ($k in $pairs.Keys) {
            switch ($k) {
                'type'          { $script:MrsType = [string]$pairs[$k] }
                'scan_depth'    { $script:MrsScanDepth = $pairs[$k] }
                'switch'        { $script:MrsSwitch = ([string]$pairs[$k]).ToLower() -eq 'true' }
                'skip_branches' { $script:MrsSkipBranches = @(([string]$pairs[$k]) -split '[,\s]+' | Where-Object { $_ }) }
                'exclude'       {
                    # Append (the bash twin appends too): the yml adds to the
                    # init-options excludes, and an empty value (a bare
                    # `exclude:` line) must not reset the accumulated list.
                    $vals = if ($pairs[$k] -is [array]) { @($pairs[$k]) }
                            else { @(([string]$pairs[$k]) -split '[,\s]+') }
                    $vals = @($vals | Where-Object { $_ })
                    if ($vals.Count -gt 0) { $script:MrsExclude = @($script:MrsExclude) + $vals }
                }
            }
        }
    }

    $initJson = Join-Path $Root '.specify/init-options.json'
    if (Test-Path $initJson) {
        Write-MrsVerbose 'Reading config from .specify/init-options.json'
        & $applyPairs (Read-InitOptions $initJson)
    }
    $extCfg = Join-Path $Root '.specify/extensions/multi-repo-sync/multi-repo-sync-config.yml'
    if (Test-Path $extCfg) {
        Write-MrsVerbose 'Applying overrides from multi-repo-sync-config.yml'
        & $applyPairs (Read-YamlConfig $extCfg)
    }

    # Normalize / validate.
    if ($script:MrsType -notin @('auto', 'independent', 'submodule')) {
        Write-MrsWarn "Unknown type '$($script:MrsType)'; falling back to 'auto'"
        $script:MrsType = 'auto'
    }
    $depth = 0
    if (-not [int]::TryParse([string]$script:MrsScanDepth, [ref]$depth) -or $depth -lt 1) {
        Write-MrsWarn "Invalid scan_depth '$($script:MrsScanDepth)'; using 2"
        $depth = 2
    }
    $script:MrsScanDepth = $depth
}

function Get-EffectiveMode {
    param([string]$Root)
    if ($script:MrsType -eq 'auto') {
        if (Test-Path (Join-Path $Root '.gitmodules')) { return 'submodule' }
        return 'independent'
    }
    return $script:MrsType
}

# ----------------------------------------------------------------------------
# Target detection
# ----------------------------------------------------------------------------
function Get-Submodules {
    param([string]$Root)
    $gm = Join-Path $Root '.gitmodules'
    if (-not (Test-Path $gm)) { return @() }
    $lines = git config -f $gm --get-regexp '^submodule\..*\.path$' 2>$null
    if ($LASTEXITCODE -eq 0 -and $lines) {
        # Each line is "submodule.<name>.path <value>". Strip the key (which ends
        # in the fixed ".path" suffix) and the following whitespace, so a path or
        # submodule name containing spaces survives - splitting on the first
        # whitespace would truncate it.
        return @($lines | ForEach-Object { $_ -replace '^submodule\..*\.path\s+', '' } | Where-Object { $_ })
    }
    # Fallback parse.
    return @(Get-Content $gm | Where-Object { $_ -match '^\s*path\s*=' } |
             ForEach-Object { ($_ -replace '^\s*path\s*=\s*', '').Trim() })
}

function Test-SubmodulePath {
    # True if <Rel> is a registered submodule path in <Root>/.gitmodules. Used to
    # decide whether an uninitialized target should be `submodule update --init`-ed
    # before branching (mirrors the preset's submodule branch command).
    param([string]$Root, [string]$Rel)
    if (-not (Test-Path (Join-Path $Root '.gitmodules'))) { return $false }
    return (@(Get-Submodules $Root) -contains $Rel)
}

function Initialize-Submodule {
    # Initialize an as-yet-uninitialized submodule before branching it, mirroring
    # the preset's `git submodule update --init "<path>"`. Routed through
    # Invoke-GitTarget so a hostile fsmonitor cannot execute; a freshly cloned
    # submodule carries no tracked hooks, and every later branch/switch on it
    # goes through Invoke-GitTarget as well.
    param([string]$Root, [string]$Rel)
    Invoke-GitTarget $Root submodule update --init -- $Rel 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-IndependentRepos {
    param([string]$Root, [int]$Depth)
    $results = New-Object System.Collections.Generic.List[string]
    # Consider directories up to $Depth levels below $Root; a sub-repo is a dir containing .git.
    # Get-ChildItem -Depth counts the levels of recursion *under* $Root (0 = immediate children),
    # so the deepest directory we want at $Depth levels maps to -Depth ($Depth - 1).
    $rootFull = (Resolve-Path $Root).Path
    $recurseDepth = [Math]::Max($Depth - 1, 0)
    $dirs = Get-ChildItem -Path $rootFull -Directory -Recurse -Depth $recurseDepth -Force -ErrorAction SilentlyContinue
    foreach ($d in $dirs) {
        if ($d.Name -eq '.git') { continue }
        $dotGit = Join-Path $d.FullName '.git'
        if (Test-Path -LiteralPath $dotGit) {
            $rel = $d.FullName.Substring($rootFull.Length).TrimStart('\', '/') -replace '\\', '/'
            if ($rel) { $results.Add($rel) }
        }
    }
    return @($results | Sort-Object -Unique)
}

function Select-Targets {
    # -PathSafetyOnly keeps the path-traversal / outside-root guard but skips the
    # gitignore and exclude filters. Used for an explicit "affected repositories"
    # list parsed from plan.md: those paths are intentional, but must still never
    # branch outside the root tree even if plan.md was attacker-influenced.
    param([string]$Root, [string[]]$Paths, [switch]$PathSafetyOnly)
    $kept = New-Object System.Collections.Generic.List[string]
    # The root's physical path is invariant across targets - resolve it once.
    $sep = [System.IO.Path]::DirectorySeparatorChar
    try { $rootResolved = Resolve-PhysicalPath $Root } catch { $rootResolved = $null }
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p) -or $p -eq '.') { continue }
        # Reject paths that are absolute or escape the root via '..'. Submodule
        # paths come from .gitmodules (attacker-controllable in a cloned repo);
        # the fan-out must never touch a repo outside the root tree.
        $norm = $p -replace '\\', '/'
        if ($norm -match '^([a-zA-Z]:)?/' -or $norm -eq '..' -or $norm -match '(^|/)\.\.(/|$)') {
            Write-MrsVerbose "skip (unsafe path): $p"; continue
        }
        # Lexical checks above stop textual traversal but not a path that is
        # itself a symlink/junction pointing outside the tree. For paths that
        # exist, resolve the physical location (following links) and require it
        # to stay under the root's physical path.
        $full = Join-Path $Root $p
        if (Test-Path -LiteralPath $full) {
            try {
                $resolved = Resolve-PhysicalPath $full
            } catch { Write-MrsVerbose "skip (unresolvable path): $p"; continue }
            if (-not $rootResolved -or
                -not $resolved.StartsWith($rootResolved.TrimEnd($sep) + $sep, $script:MrsPathComparison)) {
                Write-MrsVerbose "skip (outside root): $p"; continue
            }
        }
        if (-not $PathSafetyOnly) {
            # Respect .gitignore. `--` keeps an option-like path (e.g.
            # `path = --stdin` planted in a cloned .gitmodules) from being
            # parsed as a check-ignore flag.
            git -C $Root check-ignore -q -- $p 2>$null
            if ($LASTEXITCODE -eq 0) { Write-MrsVerbose "skip (gitignored): $p"; continue }
            # Configured excludes: literal, case-sensitive path-segment match
            # (bash `case` parity) - the configured value must not act as a
            # wildcard pattern.
            $skip = $false
            foreach ($ex in $script:MrsExclude) {
                if ([string]::IsNullOrWhiteSpace($ex)) { continue }
                if ($p -ceq $ex -or
                    $p.StartsWith("$ex/", [System.StringComparison]::Ordinal) -or
                    $p.EndsWith("/$ex", [System.StringComparison]::Ordinal) -or
                    $p.Contains("/$ex/")) { $skip = $true; break }
            }
            if ($skip) { Write-MrsVerbose "skip (excluded): $p"; continue }
        }
        $kept.Add($p)
    }
    return @($kept | Sort-Object -Unique)
}

function Get-Targets {
    param([string]$Root)
    $mode = Get-EffectiveMode $Root
    switch ($mode) {
        'submodule'   { $raw = Get-Submodules $Root }
        'independent' { $raw = Get-IndependentRepos $Root $script:MrsScanDepth }
        default       { $raw = @() }
    }
    return Select-Targets -Root $Root -Paths $raw
}

function Test-SkippedBranch {
    param([string]$Branch)
    # -ccontains: git ref names are case-sensitive (bash twin compares bytes).
    return ($script:MrsSkipBranches -ccontains $Branch)
}

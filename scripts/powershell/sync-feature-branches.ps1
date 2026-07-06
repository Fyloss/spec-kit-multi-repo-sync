<#
.SYNOPSIS
    Propagate the root repository's current feature branch into every detected
    sub-repository / submodule. Idempotent; failures are isolated per target.
.PARAMETER Json     Emit a machine-readable JSON report on stdout.
.PARAMETER DryRun   Report what WOULD happen; create no branches.
.PARAMETER Switch   Switch each sub-repo onto the branch (best-effort, clean tree).
.PARAMETER NoSwitch Force create-only (override config).
.PARAMETER Branch   Use this branch name instead of the root's current branch.
.PARAMETER Targets  Comma-separated list of affected sub-repo paths (relative to
                    the root) to restrict the run to, instead of scanning.
.PARAMETER Verbose  Verbose diagnostics on stderr.
.PARAMETER Quiet    Suppress informational output.
.OUTPUTS
    Exit 0 success / nothing-to-do, 1 if any target failed, 2 on env error.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$DryRun,
    [switch]$Switch,
    [switch]$NoSwitch,
    [string]$Branch,
    [string]$Targets,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'multi-repo-common.ps1')
$script:MrsVerbose = $PSBoundParameters.ContainsKey('Verbose') -or $VerbosePreference -ne 'SilentlyContinue'
$script:MrsQuiet   = [bool]$Quiet

$root = Get-RepoRoot
if (-not $root) {
    Write-MrsError 'Not inside a git repository.'
    if ($Json) { Write-Output '{"error":"not_a_git_repository","targets":[]}' }
    exit 2
}

Initialize-MrsConfig -Root $root
if ($Switch)   { $script:MrsSwitch = $true }
if ($NoSwitch) { $script:MrsSwitch = $false }

if (-not $Branch) { $Branch = [string](Get-CurrentBranch) }
$mode = Get-EffectiveMode $root

function Write-EmptyReport {
    param([string]$Reason)
    if ($Json) {
        $o = [ordered]@{
            root_branch = $Branch; mode = $mode; scan_depth = $script:MrsScanDepth
            dry_run = [bool]$DryRun; reason = $Reason; targets = @()
            summary = [ordered]@{ total = 0; created = 0; exists = 0; failed = 0 }
        }
        Write-Output ($o | ConvertTo-Json -Depth 5 -Compress)
    }
}

# Get-CurrentBranch is empty on a detached HEAD; an explicit `-Branch HEAD` is
# rejected below by Test-ValidBranchName (git refuses it as a branch name).
if ([string]::IsNullOrEmpty($Branch)) {
    Write-MrsWarn 'Root repository is in a detached HEAD state; nothing to propagate.'
    Write-EmptyReport 'detached_head'; exit 0
}
# Never pass an option-like or malformed name to `git branch`/`git switch`.
if (-not (Test-ValidBranchName $Branch)) {
    Write-MrsError "Refusing to operate on unsafe branch name: '$Branch'"
    if ($Json) { Write-Output '{"error":"invalid_branch_name","targets":[]}' }
    exit 2
}
if (Test-SkippedBranch $Branch) {
    Write-MrsInfo "Branch '$Branch' is in skip_branches; nothing to propagate."
    Write-EmptyReport 'skipped_branch'; exit 0
}

# NOTE: this local must NOT be called `$targets` - PowerShell variable names are
# case-insensitive, so that would assign into the [string]$Targets PARAMETER and
# flatten the array into a single space-joined path.
if ($Targets) {
    # Explicit "affected repositories" list (parsed from plan.md): restrict to
    # these paths, but still pass them through the path-safety guard.
    $explicit = @($Targets -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $targetList = @(Select-Targets -Root $root -Paths $explicit -PathSafetyOnly)
} else {
    $targetList = @(Get-Targets -Root $root)
}
if (-not $targetList -or $targetList.Count -eq 0) {
    Write-MrsInfo "No sub-repositories detected (mode=$mode, scan_depth=$($script:MrsScanDepth))."
    Write-EmptyReport 'no_targets'; exit 0
}

$dryTag = if ($DryRun) { ' [dry-run]' } else { '' }
Write-MrsInfo "Propagating branch '$Branch' (mode=$mode, scan_depth=$($script:MrsScanDepth), switch=$($script:MrsSwitch))$dryTag"

$items = New-Object System.Collections.Generic.List[object]
$created = 0; $exists = 0; $failed = 0

function Add-Item {
    param([string]$Path, [string]$Status, [bool]$Switched, [string]$Message)
    $items.Add([ordered]@{ path = $Path; status = $Status; switched = $Switched; message = $Message })
}

function Invoke-BestEffortSwitch {
    # Best-effort switch of a target onto $Branch (honors MrsSwitch; needs a
    # clean tree). Returns $true when switched; warns with $Context otherwise.
    param([string]$Dir, [string]$Rel, [string]$Context)
    if (-not $script:MrsSwitch) { return $false }
    if (Test-CleanTree $Dir) {
        Invoke-GitTarget $Dir switch $Branch 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Write-MrsWarn "[$Rel] $Context but switch failed"
    } else {
        Write-MrsWarn "[$Rel] $Context but left it un-switched (working tree is dirty)"
    }
    return $false
}

foreach ($rel in $targetList) {
    $dir = Join-Path $root $rel
    $switched = $false

    # Uninitialized submodule? Initialize it before branching, mirroring the
    # preset's `git submodule update --init "<path>"`. Only registered submodules
    # are initialized; a missing independent repo still fails as before.
    if (((-not (Test-Path -LiteralPath $dir)) -or (-not (Test-GitWorktree $dir))) -and (Test-SubmodulePath $root $rel)) {
        if ($DryRun) {
            Write-MrsInfo "[$rel] would initialize submodule and create '$Branch'"
            $created++; Add-Item $rel 'would_create' $false 'dry-run: submodule would be initialized and branched'; continue
        }
        Write-MrsInfo "[$rel] initializing uninitialized submodule"
        if (-not (Initialize-Submodule $root $rel)) {
            Write-MrsWarn "[$rel] failed to initialize submodule - skipping"
            $failed++; Add-Item $rel 'failed' $false 'submodule init failed'; continue
        }
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        Write-MrsWarn "[$rel] path does not exist (uninitialized submodule?) - skipping"
        $failed++; Add-Item $rel 'failed' $false 'path does not exist (uninitialized submodule?)'; continue
    }
    if (-not (Test-GitWorktree $dir)) {
        Write-MrsWarn "[$rel] not a git repository - skipping"
        $failed++; Add-Item $rel 'failed' $false 'not a git repository'; continue
    }

    if (Test-BranchExists $dir $Branch) {
        if (-not $DryRun) {
            $switched = Invoke-BestEffortSwitch $dir $rel "branch '$Branch' already exists"
        }
        Write-MrsInfo "[$rel] already on/has '$Branch' - skipped"
        $exists++; Add-Item $rel 'exists' $switched 'branch already exists'; continue
    }

    if ($DryRun) {
        Write-MrsInfo "[$rel] would create '$Branch'"
        $created++; Add-Item $rel 'would_create' $false 'dry-run: branch would be created'; continue
    }

    if (-not (Test-HasCommit $dir)) {
        Write-MrsWarn "[$rel] no commits yet (unborn HEAD) - cannot create branch; skipping"
        $failed++; Add-Item $rel 'failed' $false 'no commits yet (unborn HEAD)'; continue
    }

    Invoke-GitTarget $dir branch $Branch 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $switched = Invoke-BestEffortSwitch $dir $rel "created '$Branch'"
        $sfx = if ($switched) { ' and switched' } else { '' }
        Write-MrsInfo "[$rel] created '$Branch'$sfx"
        $created++; Add-Item $rel 'created' $switched 'branch created'
    } else {
        Write-MrsWarn "[$rel] failed to create '$Branch'"
        $failed++; Add-Item $rel 'failed' $false 'git branch failed'
    }
}

if ($Json) {
    $o = [ordered]@{
        root_branch = $Branch; mode = $mode; scan_depth = $script:MrsScanDepth
        dry_run = [bool]$DryRun; switch = [bool]$script:MrsSwitch; targets = $items
        summary = [ordered]@{ total = $targetList.Count; created = $created; exists = $exists; failed = $failed }
    }
    Write-Output ($o | ConvertTo-Json -Depth 6 -Compress)
} else {
    Write-MrsInfo ''
    Write-MrsInfo "Summary: $($targetList.Count) target(s) - created=$created exists=$exists failed=$failed"
}

if ($failed -gt 0) { exit 1 }
exit 0

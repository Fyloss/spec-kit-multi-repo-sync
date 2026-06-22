<#
.SYNOPSIS
    Read-only diagnostics for multi-repo-sync: resolved configuration, detected
    sub-repositories, and per-target state of the root's current feature branch.
    Never mutates any repository.
.PARAMETER Json    Emit a machine-readable JSON report on stdout.
.PARAMETER Branch  Inspect this branch name instead of the root's current branch.
.PARAMETER Quiet   Suppress informational output.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$Branch,
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

# Same guard as sync-feature-branches: never let an option-like or malformed
# name flow into git calls or the JSON report. Get-CurrentBranch is empty on a
# detached HEAD, so the report reads "<detached>" with no override given.
if ($Branch -and -not (Test-ValidBranchName $Branch)) {
    Write-MrsError "Refusing to inspect unsafe branch name: '$Branch'"
    if ($Json) { Write-Output '{"error":"invalid_branch_name","targets":[]}' }
    exit 2
}
if (-not $Branch) { $Branch = [string](Get-CurrentBranch) }
$mode = Get-EffectiveMode $root

function Get-TargetState {
    param([string]$Rel)
    $dir = Join-Path $root $Rel
    # A registered-but-uninitialized submodule would otherwise read as missing/
    # not_a_repo here even though sync-feature-branches would initialize and
    # branch it - report it distinctly so status never contradicts sync.
    if (((-not (Test-Path -LiteralPath $dir)) -or (-not (Test-GitWorktree $dir))) -and (Test-SubmodulePath $root $Rel)) {
        return 'uninitialized_submodule'
    }
    if (-not (Test-Path -LiteralPath $dir)) { return 'missing' }
    if (-not (Test-GitWorktree $dir)) { return 'not_a_repo' }
    if ([string]::IsNullOrEmpty($Branch)) { return 'n/a' }
    if (Test-BranchExists $dir $Branch) { return 'present' }
    if (-not (Test-HasCommit $dir))   { return 'unborn' }
    return 'absent'
}

$targets = Get-Targets -Root $root

if ($Json) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($rel in $targets) {
        $items.Add([ordered]@{ path = $rel; state = (Get-TargetState $rel) })
    }
    $o = [ordered]@{
        root_branch    = $Branch
        configured_type = $script:MrsType
        mode           = $mode
        scan_depth     = $script:MrsScanDepth
        switch         = [bool]$script:MrsSwitch
        skip_branches  = ($script:MrsSkipBranches -join ' ')
        targets        = $items
    }
    Write-Output ($o | ConvertTo-Json -Depth 5 -Compress)
    exit 0
}

Write-Output 'Multi-Repo Branch Sync - status'
Write-Output "  root              : $root"
Write-Output "  root branch       : $(if ($Branch) { $Branch } else { '<detached>' })"
Write-Output "  configured type   : $($script:MrsType)"
Write-Output "  effective mode    : $mode"
Write-Output "  scan_depth        : $($script:MrsScanDepth)"
Write-Output "  switch            : $($script:MrsSwitch)"
Write-Output "  skip_branches     : $($script:MrsSkipBranches -join ' ')"
Write-Output ''

if (-not $targets -or $targets.Count -eq 0) {
    Write-Output '  No sub-repositories detected.'
    exit 0
}

Write-Output '  Detected targets:'
Write-Output ("    {0,-40} {1}" -f 'PATH', "STATE($Branch)")
foreach ($rel in $targets) {
    Write-Output ("    {0,-40} {1}" -f $rel, (Get-TargetState $rel))
}
exit 0

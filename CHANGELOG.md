# Changelog

All notable changes to `spec-kit-multi-repo-sync` are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Diagram illustrating the extension's flow in the README's **How it works**
  section (`docs/assets/how-it-works.png`), optimized for the web with
  `pngquant` (1.3MB → 267KB, same dimensions, no visible quality loss).

## [1.0.0] - 2026-07-06

Initial release. The branching behaviour is aligned with the community preset
`spec-kit-preset-multi-repo-branching` while keeping a hook-based,
upgrade-safe design.

### Added
- Hook-based feature-branch fan-out via `after_plan` and `after_tasks`, so the
  behaviour integrates with native Spec Kit commands **without overriding** them
  and survives `specify self upgrade`.
- Two-phase flow mirroring the preset (discover in *plan*, branch in *tasks*):
  - New `/speckit.multi-repo-sync.analyze` command, wired to the `after_plan`
    hook, that discovers sub-repositories and records the ones the feature
    affects in an **Affected Repositories** table inside `plan.md`.
  - The `after_tasks` hook runs `sync`, which reads that table and branches
    only the affected repositories (falling back to all detected when no table
    is present).
- Detection logic compatible with the community preset
  `spec-kit-preset-multi-repo-branching`:
  - `auto` mode (submodule if `.gitmodules` exists, otherwise independent).
  - `submodule` mode (paths parsed from `.gitmodules`).
  - `independent` mode (scan for nested `.git`, honouring `git check-ignore`).
  - `scan_depth` limit (default `2`).
- Configuration read from `.specify/init-options.json` under
  `multi_repo_branching`, with an optional extension-local override file
  (`multi-repo-sync-config.yml`).
- Namespaced helper commands:
  - `/speckit.multi-repo-sync.sync` — manual / hook-driven fan-out, with
    `--dry-run` and `--switch` support.
  - `/speckit.multi-repo-sync.status` — read-only report of targets and per-target
    branch state.
- `--targets <csv>` / `-Targets` flag on the sync script to restrict the run to
  an explicit, path-safety-validated list of affected sub-repositories.
- Automatic `git submodule update --init` of uninitialized submodules before
  branching, mirroring the preset's submodule branch command (routed through the
  hardened git wrapper).
- Idempotent branch creation (existing branches are skipped).
- Per-target failure isolation (dirty tree, unborn HEAD, missing/uninitialized
  submodule, non-repo) — warnings are aggregated and never abort the native run.
- Cross-platform implementation: Bash (`scripts/bash`) and PowerShell
  (`scripts/powershell`) with equivalent behaviour.
- `skip_branches` guard (default `main master`) to avoid pointless fan-out.
- Test harnesses for both Bash and PowerShell covering all documented scenarios.

### Changed
- **Switching is the default** (`switch: true`), mirroring the preset's
  `git checkout -b`: each sub-repo is created *and* switched onto the new branch
  on a clean tree (a dirty tree still only creates the branch). Set
  `switch: false` or pass `--no-switch` for create-only behaviour.
- **`config-template.yml` ships all keys commented out.** The file has the
  highest configuration precedence, so its previously active defaults
  (`type: auto`, `scan_depth: 2`, `switch: true`, `skip_branches: main master`)
  silently overrode the user's `init-options.json` settings when the template
  was installed unmodified.
- The always-zero `skipped` counter was removed from the JSON `summary` (no code
  path ever produced a per-target `skipped` status).
- `Select-Targets` (PowerShell) resolves the root's physical path once per run
  instead of once per candidate target.

### Fixed
- **PowerShell multi-target sync no longer collapses the target list.** The
  detected targets were assigned to a local variable named `$targets` — the
  same (case-insensitive) name as the `[string]$Targets` parameter — which
  flattened the array into one space-joined path, so any run with two or more
  targets branched nothing and reported the joined path as missing.
- **Uninitialized submodules are actually initialized and branched.** The
  worktree check used bare `git rev-parse --is-inside-work-tree`, which walks up
  from an empty submodule directory and finds the ROOT repository — sync
  reported the branch as `exists` (resolved against the root) without ever
  initializing the submodule. Both implementations now require the directory to
  be its own worktree toplevel (`--show-prefix`).
- **Bash `--targets` no longer drops the last entry** (the unterminated final
  line was discarded by the read loop) **and now trims whitespace around
  commas**, matching the PowerShell `-Targets` behaviour.
- **PowerShell exclude configuration matches Bash.** The yml `exclude` value now
  APPENDS to the init-options excludes instead of replacing them, and an empty
  `exclude:` line no longer resets the accumulated list.
- **Exclude and `skip_branches` matching is literal and case-sensitive in
  PowerShell** (Bash parity): the exclude value no longer acts as a `-like`
  wildcard pattern, and `skip_branches` uses `-ccontains` (git ref names are
  case-sensitive).
- **Paths containing `[` / `]` are handled literally in PowerShell.** Target
  existence checks and independent-repo discovery use `Test-Path -LiteralPath`,
  so a repo like `pkgs[legacy]` is branched instead of reported missing.
- **`scan_depth: 0` behaves the same on all platforms.** Bash silently clamped
  it to 1 while PowerShell warned and used the default 2; both now warn and
  use 2.
- **The Bash grep fallback parser for `init-options.json` is scoped to the
  `multi_repo_branching` object**, so a sibling object's `type` / `scan_depth` /
  `switch` key can no longer be picked up on hosts without `python3` or `jq`.
- **`status` reports a registered-but-uninitialized submodule as
  `uninitialized_submodule`** instead of `missing`/`present`, so its diagnosis
  no longer contradicts what `sync` would do; `status` now validates
  `--branch` / `-Branch` exactly like `sync` (exit 2 on unsafe names).
- **An explicit `--branch HEAD` is rejected as an invalid branch name** (exit 2)
  instead of being misreported as a detached-HEAD state; detached detection now
  relies on `git symbolic-ref` in both implementations.
- **A sub-repo that already has the branch but cannot be switched (dirty tree or
  switch failure) now emits the same warning as the just-created path** instead
  of staying silent.
- **`speckit.multi-repo-sync.status` translates flags for PowerShell.** The
  command template documented bash-style `--branch` but injected it verbatim
  into the `sync-status.ps1` invocation, which failed parameter binding.
- README: unified `specify self upgrade` wording; release download URL updated
  to the current version.
- **Single-repo / unaffected features no longer report a spurious failure.** The
  `sync` command now treats a sole `_none_`/`—` row in the **Affected
  Repositories** table as "nothing to do" instead of passing the sentinel to the
  script as a target path.
- **Windows PowerShell 5.1 support restored.** `Resolve-PhysicalPath` no longer
  hard-depends on `ResolveLinkTarget` (.NET 6 / PowerShell 7.1+); it falls back
  to the provider link target on 5.1, so target detection no longer silently
  drops every on-disk sub-repository there.
- **Submodule paths containing spaces are detected in full.** Both the Bash and
  PowerShell submodule parsers no longer truncate a path (or submodule name) at
  the first space.
- **Detached root HEAD is reported correctly by `status`.** A detached root is
  shown as `<detached>` with per-target state `n/a`, instead of querying a branch
  literally named `HEAD` in each sub-repository.

### Security
- **Content-filter drivers in an untrusted sub-repo can no longer execute code.**
  The hardened git wrapper neutralized `core.hooksPath` and `core.fsmonitor` but
  not `filter.<name>.clean/smudge/process`, which git runs on `git status`
  (clean) and `git switch` (smudge) when armed by an in-tree `.gitattributes` —
  a remote-code-execution path on a cloned malicious repo, reachable on the
  default auto-`sync` path. The wrapper now enumerates every filter driver in the
  sub-repo's local config and overrides each to a no-op (via `GIT_CONFIG_*`, so a
  driver name containing `=` or `.` cannot dodge the override) on both Bash and
  PowerShell. Requires git >= 2.31; also disables any legitimate sub-repo-local
  filter (e.g. git-lfs) for the duration of these branch/switch operations.
- **Symlink containment guard is case-sensitive off Windows (PowerShell).** The
  outside-root check compared physical paths with `OrdinalIgnoreCase` on every
  platform, so on a case-sensitive filesystem a `.gitmodules` path symlinked to
  a case-variant sibling (e.g. `/home/u/PROJ/evil` vs root `/home/u/proj`) could
  slip past the guard. Comparison is now case-insensitive on Windows only.
- **`git check-ignore` calls pass `--` before the path** (Bash and PowerShell),
  so an option-like path planted in a cloned `.gitmodules` (e.g. `path =
  --stdin`, which silently consumed the remaining target list) can no longer be
  parsed as a flag.

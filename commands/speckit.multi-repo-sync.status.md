---
description: "Report detected sub-repositories / submodules and their per-target branch state (read-only)"
---

# Multi-Repo Branch Sync — Status

Inspect, **without making any change**, how this extension sees the project:
the resolved configuration, the detection mode in effect, the list of detected
sub-repositories / submodules, and whether each one already has the root's
current feature branch.

Use this to verify configuration and to preview what
`/speckit.multi-repo-sync.sync` would act on.

## User Input

Optional flags:

- `--branch <name>` — inspect a specific branch instead of the root's current one.
- `--verbose` / `--quiet` — adjust logging.

## Execution

Run the read-only status script and use its JSON output.

- **Bash / macOS / Linux:**

  ```bash
  .specify/extensions/multi-repo-sync/scripts/bash/sync-status.sh --json {{ARGS}}
  ```

- **PowerShell / Windows:**

  ```powershell
  .specify/extensions/multi-repo-sync/scripts/powershell/sync-status.ps1 -Json {{ARGS}}
  ```

  (Translate `{{ARGS}}` to the platform's flag style: `--branch X`→`-Branch X`,
  `--quiet`→`-Quiet`, `--verbose`→`-Verbose`.)

## Reporting

From the JSON, present:

1. `configured_type` vs `mode` (the resolved mode after `auto` resolution),
   plus `scan_depth`, `switch`, and `skip_branches`.
2. A table of each detected target `path` and its `state` for the inspected branch:
   - `present`   — the branch already exists there (sync would skip it)
   - `absent`    — branch missing; sync would create it
   - `unborn`    — the sub-repo has no commits yet; sync would fail it (isolated)
   - `uninitialized_submodule` — registered in `.gitmodules` but not checked
     out; sync would initialize it and create the branch
   - `not_a_repo`/`missing` — path is not a usable git working tree

If there are no targets, state that the project looks single-repo.

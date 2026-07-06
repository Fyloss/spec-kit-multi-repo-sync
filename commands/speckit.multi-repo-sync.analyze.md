---
description: "Discover sub-repositories and record which ones the feature affects in plan.md (Affected Repositories table)"
---

# Multi-Repo Branch Sync — Analyze

Discover the project's sub-repositories / git submodules and decide which of them
the **current feature** affects, then record that decision in the feature's
`plan.md` as an **Affected Repositories** table. The companion
`speckit.multi-repo-sync.sync` command later creates the feature branch in
exactly those repositories.

This command **only** reads the repository structure and edits the feature's
`plan.md`. It never creates branches, never touches Spec Kit core files, and
never changes any repository's branch.

## When this runs

It runs automatically via the `after_plan` hook declared in this extension's
`extension.yml`, right after `plan.md` is generated. It can also be invoked
manually to refresh the table.

## Execution

1. **Discover candidate sub-repositories** by running the platform status script
   from the installed extension directory and parsing its JSON output — do not
   re-implement detection yourself.

   - **Bash / macOS / Linux:**

     ```bash
     .specify/extensions/multi-repo-sync/scripts/bash/sync-status.sh --json
     ```

   - **PowerShell / Windows:**

     ```powershell
     .specify/extensions/multi-repo-sync/scripts/powershell/sync-status.ps1 -Json
     ```

   The JSON contains `mode` (`independent` or `submodule`) and a `targets` array
   of detected sub-repositories (`path`, `state`). The `mode` is the `Type` for
   every detected target.

2. **Identify the affected repositories.** Read the current feature's `spec.md`
   and `plan.md` (the ones for the active branch under `specs/`). For each
   candidate from step 1, decide whether the feature plausibly touches it — e.g.
   the spec/plan mentions the component, its directory, its API, or work that
   must land inside that sub-repository. When in doubt, include the repository:
   creating an unused branch is cheap and idempotent, whereas a missing branch
   forces manual work later.

3. **Write the Affected Repositories table into `plan.md`.** Insert (or replace,
   if it already exists) a section exactly like this, near the top of the plan
   after the header:

   ```markdown
   ## Affected Repositories

   | Repo Path | Type | Reason |
   |-----------|------|--------|
   | services/api | independent | Feature adds the `/orders` endpoint here |
   | libs/shared  | independent | Shared DTOs consumed by the new endpoint |
   ```

   - Use the relative `path` from the status JSON for `Repo Path`.
   - Use the discovery `mode` for `Type` (`independent` or `submodule`).
   - Keep `Reason` to one short, specific phrase.
   - If no sub-repositories are detected, or none are affected, write the section
     with a single explanatory row instead of a target, e.g.
     `| _none_ | — | Feature is confined to the root repository |`, so the
     downstream `sync` step has an explicit, empty result to read.

## Reporting

Report concisely: the detected `mode`, how many candidates were found, and which
repositories you marked as affected (with their one-line reasons). State that the
table was written to `plan.md` and that branches will be created by the
`after_tasks` sync step.

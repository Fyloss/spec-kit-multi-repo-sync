# Examples

Sample configurations and repository layouts for `spec-kit-multi-repo-sync`.

Copy the relevant JSON into your project's `.specify/init-options.json` (the key
`multi_repo_branching` is read directly — it is drop-in compatible with the
community preset `spec-kit-preset-multi-repo-branching`).

## Files

- [`init-options.independent.json`](./init-options.independent.json) — explicit
  `independent` mode with `scan_depth`, excludes, and custom skip-branches.
- [`init-options.submodule.json`](./init-options.submodule.json) — `submodule`
  mode (paths read from `.gitmodules`).

## Layout A — independent nested repositories

Each component keeps its own git history. There is **no** `.gitmodules` file, so
`type: auto` resolves to `independent`.

```
my-product/                 # root repo (Spec Kit lives here)
├── .git/
├── .specify/
│   └── init-options.json   # { "multi_repo_branching": { "type": "auto", "scan_depth": 2 } }
├── services/
│   ├── api/                # services/api/.git      -> detected (depth 2)
│   └── web/                # services/web/.git      -> detected (depth 2)
├── libs/
│   └── shared/             # libs/shared/.git       -> detected (depth 2)
├── vendor/
│   └── upstream/           # vendor/upstream/.git   -> excluded via "exclude": ["vendor"]
└── infra/
    └── modules/
        └── network/        # infra/modules/network/.git -> NOT detected (depth 3 > scan_depth 2)
```

Running `/speckit.specify "add auth"` creates branch `001-add-auth` on the root.
After `/plan` (and `/tasks`), the `after_plan`/`after_tasks` hooks create
`001-add-auth` in `services/api`, `services/web`, and `libs/shared`.

## Layout B — git submodules

Components are wired as submodules; `type: auto` resolves to `submodule` because
`.gitmodules` exists. No filesystem scan is performed — paths come from
`.gitmodules` directly, so `scan_depth` is irrelevant.

```
my-product/
├── .git/
├── .gitmodules             # path = vendor/lib  ; path = plugins/auth
├── .specify/
│   └── init-options.json   # { "multi_repo_branching": { "type": "auto" } }
├── vendor/
│   └── lib/                # submodule -> detected
└── plugins/
    └── auth/               # submodule -> detected
```

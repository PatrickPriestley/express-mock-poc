# Fix playbook

Remediation know-how for `ghas-remediate`. This is the single home for it; do
not copy these rules into other prompts or skills.

## Choosing a fix type

Work top to bottom. The first type that applies is the one to use.

| # | Fix type | When |
|---|---|---|
| 0 | `remove_override` | The package already has an override/resolution AND the parent's declared range now includes the patched version. Remove the override; for npm the script then runs a lockfile-only `npm update <pkg>`, because the old pin otherwise stays in the lock. |
| 1 | `refresh` | Transitive, and the parent's **current** declared range already permits the patched version. Only the lockfile moves (`npm update <pkg> --package-lock-only --ignore-scripts`; no install scripts run). |
| 2 | `bump` | Direct dependency. Bump to the patched version on the same major. The script keeps the manifest's range style: an exact pin stays exact, `~` stays `~`. Pass `--prefix` only to change it on purpose. |
| 3 | `parent_bump` | Transitive, parent's range excludes the patch, but the latest **same-major** parent release declares a range that includes it. Bump the parent. |
| 4 | `override` | Transitive, nothing above applies. Add `overrides` / `resolutions` / pnpm `overrides` pinned to the patched version. When the copies span several major lines, the script writes one entry per line that needs it (`"js-yaml@^3": "^3.15.1"`), so no copy changes line. |
| 5 | none: report | The only patched version is on a new major (0.x: a new minor), for the package or for any copy an override would force. A copy whose own line has a patch is not this case: pass every line's patched version (`3.15.1,4.3.1`). `apply-fix.sh` refuses it (exit 3, `"reason": "major_version"`). Report `skipped: needs major (<from> → <to>)` and stop; a person decides. Also non-npm ecosystems the script does not cover. |

Detection commands:

```bash
npm ls <package> --json                      # who pulls it in, and at what version
npm view <parent> dependencies --json        # parent's current declared range
npm view <parent>@latest version dependencies --json   # latest parent and its range
```

Multiple parents: every parent must have a viable same-major bump for
`parent_bump`; otherwise fall through to `override`.

## Applying

```bash
bash scripts/apply-fix.sh <repo-path> <package> <version>[,<version>...] <remove_override|refresh|bump|parent_bump|override>
```

`<version>` is the patched version, or one per release line when the
advisory is patched on several. Each copy moves to the patch on its own
line; copies already patched are left alone (`"status": "already_patched"`
when all are).

For `parent_bump`, pass the **parent** package and the parent's target
version, then confirm with `npm ls <vulnerable package>` that the transitive
resolved at or above the patched version.

The script handles npm, yarn, and pnpm manifests, plus `requirements*.txt`,
`pyproject.toml`, and `go.mod` for `bump`. Maven is not supported: the script
returns an error for a `pom.xml` repo, and the group is reported as
`failed: unsupported ecosystem` for a person to pick up. For anything else,
edit by hand and explain it in the PR body.

## pnpm

The script detects pnpm from `pnpm-lock.yaml` in the package directory or
above it (a workspace keeps one lockfile at its root), so run it from the
package that declares the dependency. All five fix types work:

- Relocks with `pnpm install --lockfile-only --ignore-scripts`, so nothing is
  installed and no install script runs. `refresh` and `remove_override` then
  run `pnpm update <pkg> --depth Infinity --lockfile-only`.
- `override` writes to the workspace root's `pnpm-workspace.yaml`
  `overrides:` map when the pnpm on `PATH` is 11 or later (pnpm 11 ignores
  `pnpm.overrides` in `package.json`) or when that file already has an
  `overrides:` map; otherwise to `pnpm.overrides` in the root `package.json`.
  It edits the YAML line by line, keeping comments, and creates the file if
  needed (pnpm accepts one with only settings). A flow-style map
  (`overrides: {...}`) is refused; leave that group for a person.
- `remove_override` deletes the entry from both places.
- If the pnpm on `PATH` rewrites `lockfileVersion`, the script restores the
  files and stops. Use the pnpm the repo pins (`packageManager` field, via
  corepack) and run it again.

`verify-fix.sh` reads resolved versions from the lockfile and audits with
`pnpm audit`.

yarn: `refresh` is refused, there is no audit step, and closure is read
through `npm ls`. Treat a yarn fix as unverified and say so in the PR body.
yarn `resolutions` cannot be scoped by version, so a fix whose copies span
several major lines stops with an error; leave it for a person.

## Checks the verify script does not do for you

- **ESM/CJS.** When a person has approved a major change (`--allow-major`), inspect the
  installed package's `package.json` for `"type": "module"` or ESM-only
  `"exports"`. If the repo uses `require("<package>")`, a pure-ESM target
  installs fine and fails at runtime. Pin to the highest CJS-compatible
  version that still fixes the advisory, and say so.
- **npm major used by CI.** Read `actions/setup-node` in the repo's workflows
  and regenerate the lockfile with the same npm major. Lockfile v2 vs v3
  churn is the usual symptom of getting this wrong.
- **Lockfile scope.** `git diff --stat -- package-lock.json`. If packages
  other than the target and its direct dependents changed, restore the base
  lockfile and re-apply with `npm install <package>@<version>` (direct) or
  the refresh/override path (transitive). Security PRs should not bundle a
  stale-lockfile catch-up.
- **Stale overrides.** After any fix, list every entry in
  `overrides`/`resolutions`/`pnpm.overrides`. If the parent's range now
  includes the overridden version, remove the entry in the same PR.
- **Workspaces.** If `package.json` has `workspaces`, run `npm ls` from the
  root to find which workspace owns the vulnerable resolution and edit that
  manifest, not the root, unless the root is the owner.

## Python (uv / pyproject)

| Situation | Fix type | What `apply-fix.sh` does |
|---|---|---|
| Declared range already admits the patched version | `refresh` | `uv lock --upgrade-package <pkg>`; only `uv.lock` changes |
| Direct dependency | `bump` | edits the specifier in `pyproject.toml` / `requirements*.txt`, then relocks |
| Transitive dependency | `override` | sets `<pkg>>=<patched>` in `[tool.uv] constraint-dependencies` (`--prefix '=='` to pin, matching the repo's style; quote it, zsh reads a bare `==` as a command), then relocks |

- Never pin a transitive in `[project] dependencies`.
- **Lock revision.** The relock tries uv binaries in order (`GHAS_UV`, `PATH`,
  Homebrew, `~/.local/bin`, then mise installs called directly) and keeps the
  first one that leaves the `revision = N` header of `uv.lock` unchanged. A
  repo's pinned uv can be older than the uv that wrote the lock, and would
  rewrite the whole file. If none matches, stop. Do not hand-edit the header.
- **mise in fresh clones.** A clone's `.mise.toml` is untrusted, so the mise
  `uv` shim refuses to run there. Do not `mise trust` a clone. The scripts
  skip a shim that fails and call an installed uv directly. For your own
  commands, use the `uv_bin` path that `apply-fix.sh` and `verify-fix.sh`
  report. Node, npm and yarn have no such fallback: if their shim refuses,
  the install fails, and you report it (SKILL.md step 6). Never write a
  shim or wrapper of your own.
- Run the repo's test command if one exists. `verify-fix.sh` does lock
  check, install, closure and OSV audit for you. Tests only run when you pass
  `--test-command`.

## Go

- `go get <module>@v<version>` then `go mod tidy`; verify with
  `go list -m <module>`.

This is `bump`-only in the script. An override for a transitive needs a
`replace` directive by hand.

## Known patterns worth remembering

- Prototype pollution, ReDoS, and dependency-confusion advisories make the
  **whole module** vulnerable; any import is exposure. Do not downgrade
  priority because "we only call one function".
- Dev-only transitives (`dependencyScope: DEVELOPMENT`) are still worth
  fixing when the fix is a lockfile refresh. Skip them only when the fix
  would be an override that risks the toolchain.
- Dependabot PRs never block a fix (see SKILL.md step 2). A non-Dependabot
  PR that bumps the package but not far enough (below the first patched
  version) does **not** cover the advisory: read
  `covering_pr.package_lines_added` before skipping.

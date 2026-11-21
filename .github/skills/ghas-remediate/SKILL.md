---
name: ghas-remediate
description: >
  Use when asked to fix or remediate Dependabot/GHAS vulnerability alerts:
  a VULN Jira ticket ("remediate VULN-123"), a repository ("fix the open
  alerts in web-backend"), a specific CVE or GHSA in a repo, or
  "remediate this week's triage". Also the skill the scheduled remediation
  automation runs. Applies a dependency fix, verifies it, and opens a PR for
  human review. Never dismisses alerts, never merges, never pushes to a
  default branch. Triage, scoring, and ticket creation are out of scope;
  they belong to the weekly triage.
---

# GHAS Remediation

Turn an open Dependabot alert (or a VULN ticket full of them) into a verified
pull request. One repo at a time, one branch per fix, review by a human.

## Where enforcement lives

This skill is guidance. The hard limits are GitHub configuration, and the
skill assumes they are in place (see `README.md` → Enforcement):

| Guarantee | Enforced by |
|---|---|
| Cannot dismiss or alter alerts | The GitHub App token has no Dependabot alerts write permission |
| Cannot merge | Default-branch ruleset: required review, required checks, no app bypass |
| Cannot push to the default branch | Same ruleset |
| Diff touches only manifests and lockfiles | Required status check `dependency-only-diff` |
| Tests pass before merge | The target repo's own CI, required by the ruleset |

Everything below exists to make the PR *good*, not to make it *safe*. Safety
does not depend on you following these instructions.

## Mode

Read `MODE` from the invoking prompt. If absent, default to `pr` for a human
invocation and `plan` for a scheduled run.

| MODE | Writes to GitHub |
|---|---|
| `plan` | None. Steps 1–7 still run: clone, branch, apply, verify, and commit locally in the temp workspace. Nothing is pushed. |
| `branch` | Push the fix branch. No PR. |
| `draft-pr` | Push and open a **draft** PR. |
| `pr` | Push and open a ready-for-review PR. |

Never do more than the MODE allows, even if asked mid-run. Changing MODE is
the operator's job, in the automation or the command.

## Inputs

Resolve the request into one or more **units**: `(repo, [alerts])`.

- **VULN ticket key** (`VULN-123`): fetch the ticket read-only, trying the
  Jira CLI, then the Atlassian MCP (exact commands in
  `references/ticket-contract.md` → "Tooling"). First check that it is a
  dependency ticket (see **Not a dependency ticket** below). Then parse the
  description per that file: repo, CVE/GHSA list, packages, patched
  versions.
- **Repo name**: fetch its open alerts with
  `bash scripts/fetch-alerts.sh <org> --repos-file <file with one line>`
  and take every alert with a `firstPatchedVersion`.
- **CVE/GHSA + repo**: same fetch, filtered to that advisory.
- **"This week's triage"**: list open VULN tickets created in the last 7 days
  (`project = VULN AND created >= -7d AND status in (Backlog, Open)`), one
  unit per ticket.

Read `config/remediate-config.json` (overlay `remediate-config.local.json`)
for `github_org`, `jira_project`, `branch_pattern`, `mono_repos`, and
`local_repo_base_path`. This skill needs no other skill installed.

Skip alerts with no `firstPatchedVersion` (nothing to fix yet) and say so.

**Not a dependency ticket.** A VULN ticket is a dependency ticket only when
it has the `vulnerability` label, or its description names at least one
GHSA or CVE together with a package (the findings table, or a GHSA/CVE and a
package in the summary). Anything else, such as a code flaw ("api-monorepo
accepts expired JWTs") or an end-of-life upgrade, is not this skill's work:
stop without fetching alerts, cloning or changing anything, and report one
row with Action `skipped: not a dependency ticket`. Never fall back to
fixing every open alert in the repository the summary names: a ticket only
ever covers the advisories it lists.

**Already fixed.** For a ticket, match its findings against the open alerts
you just fetched. A finding with no open alert in that repo is already
resolved. If none of the ticket's findings is open, the unit is finished:
do not check PRs, clone, apply, or search git history. Report one row per
package with Action `skipped: already fixed`. For the Link, run
`gh pr list --repo <org>/<repo> --state merged --search "<package>" --limit 5`
once and link the merged PR that changed the package, if one is clear;
otherwise leave it empty. If only some findings are open, continue with
those and report the rest as `skipped: already fixed`. The ticket's Jira
status is not evidence either way; the open alerts are.

## Steps, per unit

### 1. Group

Group the unit's alerts by `(manifest path, package)`. One group is one fix
and one branch. A mono-repo unit (see `mono_repos` in config) is split by
sub-service path prefix first.

The target is the patched version, **per release line** (major, or 0.minor
below 1.0). An alert's `firstPatchedVersion` is only the patch for the line
Dependabot matched, but one lockfile can hold copies on several lines
(js-yaml 3.x under one parent and 4.x under another). Collect every patched
version each advisory publishes:

```bash
gh api /advisories/<GHSA> --jq '.vulnerabilities[] | select(.package.name == "<package>") | .first_patched_version'
```

and, per line, keep the highest across the group's advisories. Pass the
whole list, comma-separated, as `<version>` to `apply-fix.sh` and as
`--patched` to `verify-fix.sh` (`3.15.1,4.3.1`). The script moves each copy
within its own line, and refuses only a copy whose line has no patch. A
ticket's "Required action" that says "per major line" or lists several
versions for one package is this case.

### 2. Check existing coverage

```bash
bash scripts/check-existing-prs.sh --repo <org>/<repo> --package <pkg> \
  --manifest <alert's vulnerableManifestPath> \
  --advisory GHSA-xxxx [--advisory GHSA-yyyy] --branch <planned branch>
```

Always pass `--manifest`. Without it, a PR that changes the same package in
another service of the repository (`service-a/` for a `service-b/` alert) looks
like coverage.

Act on `skip`, not on your own reading of the PR list:

- `skip: true`, `skip_reason: "covering PR"` → a non-Dependabot PR is open
  and already changes this dependency (`covering_pr`, with the package lines
  it adds). Skip the group and link it. If `covering_pr.package_lines_added`
  shows a version below the patched one, it does not cover the advisory:
  continue, and note the PR in the report.
- `skip: true`, `skip_reason: "branch exists"` → work is already in flight on
  the planned branch. Skip.
- `skip: false` → continue, **even when `dependabot_pr` is set**. Dependabot
  PRs lag, bundle unrelated bumps, and stall on CI, so they never block a fix.
  Name the Dependabot PR in your PR body's Notes so the reviewer can close
  whichever one they do not merge.

### 3. Workspace

- Scheduled / cloud run: `git clone --depth 50 <clone url> /tmp/ghas-remediate/<repo>`
  on the default branch.
- Local run with `local_repo_base_path` configured: use
  `<local_repo_base_path>/<repo>` only if it is on the default branch and
  clean (`git status --porcelain` empty); otherwise clone to a temp dir.
- `plan` mode: always clone to a temp dir, never the local checkout, so the
  plan's local commit cannot land in a working repo.
- One workspace per repository, not per group. When a unit has several
  groups, clone once and give each group its own worktree from the default
  branch: `git -C <clone> worktree add /tmp/ghas-remediate/<repo>-<TICKET>-g<n> -b <branch> origin/<default>`
  (`g1`, `g2`, … in group order). Never clone the same repository once per
  group. Keep package names out of workspace paths: some builds read their
  own path (a Vite config that checks for `storybook`, for example) and
  behave differently.

Never write triage artifacts into the target repo. Logs go to
`/tmp/ghas-remediate/logs/<repo>/`.

### 4. Branch

- Ticket known and the branch will cover all of the ticket's findings:
  `vuln/<TICKET>` (from `branch_pattern`).
- Ticket known, several groups: `vuln/<TICKET>-<package>`.
- No ticket: `security/<package>-<YYYYMMDD>`.

`git switch -c <branch>` from the default branch (a worktree made with
`worktree add -b <branch>` is already on it).

### 5. Choose and apply the fix

Follow `references/fix-playbook.md` → "Choosing a fix type". In order of
preference: `remove_override`, `refresh`, `bump`, `parent_bump`, `override`.
Apply the mechanical ones with the script:

```bash
bash scripts/apply-fix.sh <repo-path> <package> <version>[,<version>...] <fix-type>
```

Its JSON reports `target_version` (the one it applied, or one per line),
`overrides` (the entries it wrote: plain `"<package>"`, or
`"<package>@^<line>"` per line when the copies span several), and
`resolved`. `"status": "already_patched"` means every copy is already
patched on its line; report the group `skipped: already fixed`.

**When the script fails, stop.** If `apply-fix.sh` prints an `error`, or
`"status": "no_match"`, the group ends there: report
`failed: apply-fix (<its message>)` and go to the next group. Do not make
the change yourself. No hand edit of the manifest, no `uv lock`, `npm
install` or other package-manager command of your own, no second attempt
through a different file. A `no_match` on a package the alert names is a
script bug; the report is how it gets fixed.

pnpm overrides go in `pnpm-workspace.yaml` when the pnpm in use is 11 or
later (pnpm 11 ignores `pnpm.overrides` in `package.json`) or when that file
already has an `overrides:` map; otherwise in `package.json`. The script
picks the file. If it exits saying it cannot edit `pnpm-workspace.yaml` (a
flow-style map), report the group for a person; do not edit it by hand.

For Python, `bump` matches the name per PEP 503 and keeps extras and markers
(`PyJWT[crypto]==2.8.0 ; python_version >= "3.9"`).

For Python, run it from the directory that holds `pyproject.toml` and
`uv.lock`, and pass `--manifest <path>` with the alert's manifest relative to
that directory (`--manifest tests/requirements-test.txt`). Without it, a
`bump` edits every `requirements*.txt` and `pyproject.toml` in the directory,
and none below it. It covers `bump`, `override` (a `[tool.uv] constraint-dependencies`
entry) and `refresh` (`uv lock --upgrade-package`), and it relocks for you,
so do not run `uv lock` yourself afterwards. If it reports that no uv could
relock without changing the `uv.lock` revision, stop and report it. Never
hand-edit `uv.lock`. To pin with `==`, quote it: `--prefix '=='` (zsh reads a
bare `==` as a command lookup).

**Do not touch what the script wrote.** After `apply-fix.sh`, make no edit of
your own to the manifest, not even a comment. A comment on the line that
cites an older advisory stays as it is: the old floor is still true, and the
commit message records the new advisory.

**Major versions.** `apply-fix.sh` refuses any fix that moves the package,
or any copy an override would force, to a new major version (0.x: a new
minor). It exits 3 with `"status": "refused", "reason": "major_version"` and
changes nothing. Then stop that group and report
`skipped: needs major (<from> → <to>)`. Do not reach the same change another
way: no hand edit of the manifest, `overrides`, `pnpm-workspace.yaml` or the
lockfile, and no override that pushes a parent's dependency outside its
declared range. Pass `--allow-major` only when the user approved that exact
change in this session, never in a scheduled run.

**Lockstep families.** Some packages are released together and must match:
`storybook` with `@storybook/*`, `@babel/*`, `@angular/*`, `@nestjs/*`,
`vitest` with `@vitest/*`, and the like. When you bump one, also bump each
member the manifest pins at the same old version to the same target, with
`apply-fix.sh` per member (the major-version rule applies to each). Name
them in the commit body.

Use your own judgment only where the script cannot: multiple parents, a
pure-ESM target behind CJS imports, non-npm ecosystems the script does not
cover. This is for choosing the fix before you run the script, never for
finishing a fix the script refused or failed. Yarn cannot scope a resolution by version, so a yarn group whose
copies span several lines goes to a person. When you make a manual edit,
say exactly why in the PR body.

### 6. Verify

```bash
bash scripts/verify-fix.sh --repo-path <repo-path> --package <pkg> \
  --patched <version>[,<version>...] --advisory GHSA-xxxx [--advisory ...] \
  [--test-command "<repo's test command>"] --log-dir /tmp/ghas-remediate/logs/<repo>
```

The script installs from the lockfile (for uv, after `uv lock --check`
confirms the lock matches `pyproject.toml`), confirms every resolved copy of
the package is at or above the patched version on its own release line, and confirms the target
advisories are gone: through `npm audit` for npm, `pnpm audit` for pnpm, and
`yarn audit` (yarn 1) or `yarn npm audit` (yarn 2+) for yarn, and
through OSV for each resolved Python version. It runs the build and tests when they exist, and
lists changed files. For Python, pass the repo's test command as written
(e.g. `uv run pytest tests`); the script puts a working uv first on `PATH`.
A Python fix whose audit could not run fails. Use `--skip-audit` only when
OSV is unreachable, and say so in the PR body. Read its JSON. Then:

- `install.ok: false` → read `install.log` first. A private registry that
  refuses the token (`401`, `YN0041 Invalid authentication`), or a tool shim
  that will not run (mise: "Config files ... are not trusted"), is an
  environment problem, not a bad fix: report
  `failed: install (<the error line>)` and stop the group. Do not try
  another fix type for it.
- `pass: false` → do **not** push. Try the next fix type in the playbook
  order once. If it still fails, record the failure (tests, build, closure,
  or audit) with the log path and move on. Do not loosen, skip, or delete
  tests to get green.
- `build.preexisting_failure: true` → the build also fails on the base
  commit (`build.base`), built the same way, so the fix did not cause it and
  `pass` is not blocked. Compare `build.log` with `build-baseline.log`. If
  the fix added errors, treat it as a failure. Otherwise state "build already
  failing on base" with the base SHA in the PR body. Do not try to repair the
  build in a remediation PR.
- `manifest_only: false` → re-read the diff. If the extra files are not
  required by the fix, restore them. If they are (migration change), keep
  them and flag it; the `dependency-only-diff` check will fail on the PR and
  that is the signal for the reviewer.
- Review `git diff -- package.json`: only the intended lines may change. If
  `npm install` re-sorted keys, restore the base file and re-apply the one
  change.

### 7. Commit

Subject, exactly:

```
[<TICKET>][<SEVERITY>] Resolve outstanding GHSA vulnerabilities.
```

`SEVERITY` is the highest GHAS severity in the group, uppercase. Without a
ticket, drop that segment: `[<SEVERITY>] Resolve outstanding GHSA vulnerabilities.`
Body: package, from → to, fix type, advisories, one line per verification
check. Commit only the files the fix needs. Write the message to a new file
and commit with `git commit -F <file>`: inside plain double quotes,
`-m "...\n..."` stores a literal `\n`, not a line break. Make the file with
`mktemp "${TMPDIR:-/tmp}/ghas-commit.XXXXXX"` and write the whole message in
one go. Never reuse a fixed path such as `/tmp/ghas-remediate/<TICKET>-commit-message.txt`:
an earlier run's message is still there, and editing it mixes two bodies.

### 8. Publish (per MODE)

`plan`: stop here and report. Leave the local commit in the temp workspace
and give its path in the report, so a reviewer can inspect the diff or
delete it.

`branch`: `git push -u origin <branch>`.

`draft-pr` / `pr`: push, then `gh pr create` (add `--draft` for `draft-pr`)
with:

- Title: `[<TICKET>] Fix <GHSA or CVE> — <package> → <version>` (no ticket:
  drop the prefix).
- Body: use `references/pr-body.md`. It must contain the ticket key as a bare
  token (the weekly triage scans PR bodies for `VULN-\d+`), every advisory id,
  the fix type, the verification table from the script output, and the
  sentence "Created by the GHAS remediation agent. It does not merge or
  dismiss alerts."

Never `gh pr merge`, never `gh pr review --approve`, never touch alert state,
never push to `main`/`master`/`develop`. (The ruleset and token make these
fail anyway. Do not try.)

Jira is read-only in this skill. Do not comment on or transition the ticket;
the next weekly run links PRs to tickets by scanning PR bodies.

### 9. Report

End every run, whatever MODE, with one table:

| Repo | Package | Alerts | Fix type | Verification | Action | Link |
|---|---|---|---|---|---|---|

`Action` is one of: `PR opened`, `draft opened`, `branch pushed`, `planned`,
`skipped: already fixed`, `skipped: covering PR`, `skipped: branch exists`,
`skipped: no patch`, `skipped: needs major (<from> → <to>)`,
`skipped: not a dependency ticket`, `failed: <check>`. For
`skipped: already fixed` and `skipped: not a dependency ticket`, leave Fix type and
Verification as `—`: nothing was fixed or verified in this run. Links are clickable. A scheduled run sends this table (and
nothing else) to the configured Slack channel; see
`automations/remediation.md`.

## Failure handling

- A failing fix never blocks the other groups or units. Finish everything
  else, then report.
- Network or API errors: retry once, then record and move on.
- Something unexpected that needs a decision (two viable fixes with different
  risk, a repo whose tests already fail on the default branch): in a human
  session, stop and ask. In a scheduled run, do the conservative thing (skip,
  or open as draft if MODE permits) and say why in the report.

## Common mistakes

- Wrapping, shimming or replacing a package manager or test runner (a
  `yarn` script on `PATH` that rewrites `install`, an alias, a changed
  flag) to get past an error. The verification is then of your wrapper, not
  of the repo. Report the error instead.
- Finishing a fix by hand after `apply-fix.sh` failed or reported
  `no_match` (step 5).

- Skipping a group because Dependabot has a PR open. Only a non-Dependabot
  PR that changes the dependency, or an existing branch, skips (step 2).
- Opening a PR that duplicates another person's open fix. Always run step 2.
- Working around an `apply-fix.sh` major-version refusal by editing files
  by hand. A refusal ends the group; report it.
- Cloning and digging through git history for a ticket whose alerts are all
  closed. Report `skipped: already fixed` and stop.
- Treating a ticket with no GHSA/CVE (a code flaw, an EOL upgrade) as a
  request to fix the repository's open alerts. Report
  `skipped: not a dependency ticket` and stop.
- Passing only the alert's `firstPatchedVersion` when the lockfile has
  copies on several major lines. The guard then refuses a fix that exists;
  pass every line's patched version.
- Regenerating the lockfile with a different npm major than the repo's CI
  uses. Check `actions/setup-node` in the repo's workflows first. For pnpm,
  use the version in the `packageManager` field; the script stops if the
  lockfile format would change.
- Leaving a now-redundant override behind. Audit `overrides` / `resolutions`
  before committing.
- Putting the ticket key only in the title. The weekly scan reads the body.

# Reading VULN tickets

`ghas-remediate` only reads Jira. It never creates, comments on, or
transitions a ticket. The ticket format is owned by the weekly triage, which
writes it; this file is the consumer's view of it. If the triage changes a
heading or a table column, update this file in the same change.

## Tooling

Try in order; use the first that is installed and authenticated:

1. **Jira CLI** (`jira` command).
2. **Atlassian MCP** (`searchJiraIssuesUsingJql`). Run
   `getAccessibleAtlassianResources` first and use the returned `id` as
   `cloudId` in every call. Use the read tools only.

Do not reconstruct ticket contents from local transcripts or old reports.

## What a ticket looks like

Summary: `[{repo}][{PRIORITY}] {primary_package} — {CVE_or_GHSA}`
(`[{repo}/{sub-service}][...]` for a mono-repo listed in `mono_repos`)

Description, in this order:

```
## Affected repository: {repo}

## SLA driver
- Vulnerability: {CVE_or_GHSA}
- ...

| CVE | GHSA | Package | Original discovery date | Original GHAS severity | CVSS | Composite score | Priority | Internal Target | Status |

## Scoring justification
## Current state
## Required action
## References
- Advisory: https://github.com/advisories/{GHSA}
- Dependabot alert: {html_url}
```

## What to take from it

| Need | Where |
|---|---|
| Repository | `## Affected repository:` heading, or the summary prefix. A `[{repo}/{sub-service}]` ticket covers only the alerts whose manifest path is under that sub-service's prefix in `mono_repos` (`config/remediate-config.json`). |
| Advisories | `CVE` and `GHSA` columns, one row per finding |
| Packages | `Package` column |
| Severity for the commit subject | `Original GHAS severity` column, highest in the group |
| Patched versions | `## Required action` when it names them. Otherwise fetch the repo's open alerts with `scripts/fetch-alerts.sh` and read `firstPatchedVersion` for each GHSA. |

Ignore `## Current state`: PR state recorded on a ticket is stale by
definition. Step 2 (`check-existing-prs.sh`) decides coverage.

## When it does not parse

Older tickets have free-form descriptions. If the summary or description
names at least one GHSA or CVE and its package, take the repo name from the
summary, fetch that repo's open alerts, and keep only those advisories.

If it names no GHSA or CVE, it is not a dependency ticket (a code flaw such
as VULN-201, or an end-of-life upgrade such as VULN-202): stop and report
`skipped: not a dependency ticket`. Never widen a ticket to every open
alert in the repository.

The repository line is not always `{repo}` or `{repo}/{sub-service}`.
Older tickets write `api-monorepo (billing sub-service)` or
`api-monorepo (e2e-tests manifest)`: read the word before the parenthesis as the
repo and the first word inside it as the sub-service. A sub-service missing
from `mono_repos` (`e2e-tests`, `shared-packages/test-toolkit`) is a
directory of that name at the repo root: keep the alerts whose
`vulnerableManifestPath` starts with it.

## Patched versions per release line

"Required action" can list several patched versions for one package ("3.15.1
or 4.3.1 depending on major line in use", "patched lines are 7.30.1 and
6.29.1"). Keep all of them: they are the per-line list `apply-fix.sh` and
`verify-fix.sh` take (SKILL.md → "1. Group").

## Jira unavailable

Fall back to the repo's open alerts and write "ticket not read" in the PR
body, so the next weekly run can link the PR to its ticket.

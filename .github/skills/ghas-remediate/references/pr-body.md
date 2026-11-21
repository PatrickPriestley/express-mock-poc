## Security fix: {{GHSA_OR_CVE_LIST}}

Ticket: {{TICKET_KEY}} <!-- bare key, e.g. VULN-123; the weekly triage scans for it. Write "none" if there is no ticket. -->

| Field | Value |
|---|---|
| Package | `{{PACKAGE}}` ({{ECOSYSTEM}}) |
| Manifest | `{{MANIFEST_PATH}}` |
| Version | {{CURRENT_VERSION}} → {{TARGET_VERSION}} |
| Fix type | {{FIX_TYPE}} |
| Advisories | {{ONE LINE PER GHSA/CVE, LINKED TO https://github.com/advisories/<GHSA>}} |
| Highest severity | {{SEVERITY}} |

## Verification

| Check | Result |
|---|---|
| Install from lockfile | {{install.ok}} |
| Resolved versions ≥ {{TARGET_VERSION}} | {{closure.ok}} ({{closure.resolved}}) |
| Target advisories absent from audit | {{audit.ok}} |
| Build | {{build.ran ? build.ok : "no build script"}} |
| Tests | {{tests.ran ? tests.ok : "no test script"}} |
| Manifest/lockfile only | {{manifest_only}} |

Logs: `{{LOG_DIR}}` on the runner (not committed).

## Notes

{{WHY THIS FIX TYPE; ANY MANUAL EDIT AND WHY; ANY STALE OVERRIDE REMOVED; ANY CAVEAT FOR THE REVIEWER}}
{{IF dependabot_pr: "Overlaps Dependabot PR <url>; merge one and close the other."}}

---
Created by the GHAS remediation agent. It does not merge or dismiss alerts.

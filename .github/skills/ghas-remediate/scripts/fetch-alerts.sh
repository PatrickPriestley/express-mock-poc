#!/usr/bin/env bash
set -euo pipefail

# Fetch a repository's open Dependabot alerts via GraphQL, paginated.
#
# Usage:
#   fetch-alerts.sh <org> --repos-file FILE [--output FILE]
#   (FILE holds one repo name per line; `-` reads stdin,
#    e.g. `printf 'api-monorepo\n' | fetch-alerts.sh <org> --repos-file -`)
#
# Output (default /tmp/ghas_all_alerts.json): one JSON document per repo, each
# shaped data.organization.repositories.nodes[0].vulnerabilityAlerts.nodes[].
#
# This is the per-repo path of ghas-weekly-triage/scripts/fetch-alerts.sh, kept
# here so ghas-remediate installs and runs without the triage skill. The
# org-wide and --count modes stay in the triage copy. GraphQL is used because
# the REST alerts endpoint needs the security_events scope.

ORG="${1:?usage: fetch-alerts.sh <org> --repos-file FILE [--output FILE]}"
shift

OUTPUT="/tmp/ghas_all_alerts.json"
REPOS_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="${2:?--output requires a path}"; shift 2 ;;
    --repos-file) REPOS_FILE="${2:?--repos-file requires a path}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPOS_FILE" ] || { echo "usage: fetch-alerts.sh <org> --repos-file FILE [--output FILE]" >&2; exit 2; }

# Snapshot the repo list into a regular file. The Python fetcher below reads
# its own program from stdin, so a pipe passed straight through would look
# like an empty list.
REPOS_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
trap 'rm -f "$REPOS_SNAPSHOT"' EXIT
if [ "$REPOS_FILE" = "-" ]; then
  cat > "$REPOS_SNAPSHOT"
else
  [ -e "$REPOS_FILE" ] || { echo "repos file not found: $REPOS_FILE" >&2; exit 2; }
  cat "$REPOS_FILE" > "$REPOS_SNAPSHOT"
fi
REPOS_FILE="$REPOS_SNAPSHOT"
grep -q '[^[:space:]]' "$REPOS_FILE" || { echo "repos file has no repo names; nothing to fetch" >&2; exit 2; }

ALERT_FIELDS='
  number
  createdAt
  dismissedAt
  autoDismissedAt
  vulnerableManifestPath
  vulnerableRequirements
  securityAdvisory {
    ghsaId
    summary
    severity
    cvss { score vectorString }
    cwes(first: 5) { nodes { cweId name } }
  }
  securityVulnerability {
    package { name ecosystem }
    severity
    firstPatchedVersion { identifier }
    vulnerableVersionRange
  }
  dependabotUpdate {
    pullRequest {
      number title url state createdAt updatedAt body
    }
  }
'

# Paginated: one page of 100 would silently drop alerts on a busy repo.
ALERT_FIELDS_FILE=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
printf '%s' "$ALERT_FIELDS" > "$ALERT_FIELDS_FILE"
python3 - "$ORG" "$REPOS_FILE" "$OUTPUT" "$ALERT_FIELDS_FILE" <<'PYEOF'
import json
import subprocess
import sys

org, repos_file, output_path, fields_file = sys.argv[1:5]
with open(fields_file) as f:
    alert_fields = f.read()

QUERY = f"""
query($owner: String!, $repo: String!, $endCursor: String = null) {{
  repository(owner: $owner, name: $repo) {{
    vulnerabilityAlerts(first: 100, after: $endCursor, states: OPEN) {{
      pageInfo {{ hasNextPage endCursor }}
      nodes {{ {alert_fields} }}
    }}
  }}
}}
"""


def fetch_repo(repo):
    nodes = []
    cursor = None
    page = 0
    while True:
        page += 1
        cmd = ["gh", "api", "graphql", "-f", f"owner={org}", "-f", f"repo={repo}", "-f", f"query={QUERY}"]
        if cursor:
            cmd += ["-f", f"endCursor={cursor}"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        doc = json.loads(result.stdout, strict=False)
        conn = (doc.get("data") or {}).get("repository") or {}
        conn = conn.get("vulnerabilityAlerts") or {}
        nodes.extend(conn.get("nodes", []))
        page_info = conn.get("pageInfo") or {}
        if page_info.get("hasNextPage") and page_info.get("endCursor"):
            cursor = page_info["endCursor"]
        else:
            break
        if page >= 20:  # safety valve — 2000+ open alerts on one repo is implausible
            print(f"warning: {repo} still paginating after {page} pages (>{page * 100} alerts) — stopping", file=sys.stderr)
            break
    return nodes


fetched, failed = 0, []
with open(repos_file) as f, open(output_path, "w") as out:
    for line in f:
        repo = line.strip()
        if not repo:
            continue
        fetched += 1
        # One repo that errors (404, no Dependabot access, a 502 twice) must not
        # drop every other repo's alerts. Record it and carry on.
        for attempt in (1, 2):
            try:
                nodes = fetch_repo(repo)
                break
            except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
                why = ((getattr(e, "stderr", None) or str(e)).strip().splitlines() or ["unknown error"])[-1]
        else:
            failed.append((repo, why))
            continue
        if len(nodes) > 100:
            print(f"{repo}: fetched {len(nodes)} alerts across {(len(nodes) + 99) // 100} page(s)", file=sys.stderr)
        # Wrap into the same shape parse_alerts.py expects from the org-wide
        # query (data.organization.repositories.nodes[]) so one parser
        # handles both fetch modes.
        wrapped = {"data": {"organization": {"repositories": {"nodes": [{"name": repo, "vulnerabilityAlerts": {"nodes": nodes}}]}}}}
        out.write(json.dumps(wrapped))
        out.write("\n")

if fetched == 0:
    sys.exit(f"error: read no repo names from {repos_file}; {output_path} is empty")
for repo, why in failed:
    print(f"warning: could not fetch {repo}: {why}", file=sys.stderr)
if failed:
    print(f"warning: {len(failed)} of {fetched} repos not fetched; their alerts are missing from {output_path}: "
          + ", ".join(r for r, _ in failed), file=sys.stderr)
if len(failed) == fetched:
    sys.exit(f"error: no repo could be fetched; {output_path} is empty")
print(f"wrote {output_path} (per-repo fetch, paginated, {fetched - len(failed)} of {fetched} repos)", file=sys.stderr)
PYEOF
rm -f "$ALERT_FIELDS_FILE"

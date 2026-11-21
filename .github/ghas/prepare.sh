#!/usr/bin/env bash
# Deterministic half of the GHAS remediation workflow. Runs in a normal
# Actions step (outside the agent sandbox) with the job's read-only token,
# and does the GitHub reads the skill's steps 1-2 would otherwise do with `gh`:
#
#   1. open Dependabot alerts for this repository (REST, paginated)
#   2. group them by (manifest, package), keeping alerts that have a patch
#   3. every patched version each advisory publishes for the package
#   4. check-existing-prs.sh for the group's planned branch
#
# Output: $OUT_DIR/groups.json, an array of groups the agent works through,
# highest severity first. The agent never decides coverage itself.
#
# Usage: prepare.sh <owner/repo> <out-dir>
set -euo pipefail

REPO="${1:?owner/repo}"
OUT_DIR="${2:?out dir}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../skills/ghas-remediate"
TODAY="$(date -u +%Y%m%d)"
mkdir -p "$OUT_DIR"

if ! gh api --paginate "repos/$REPO/dependabot/alerts?state=open&per_page=100" > "$OUT_DIR/alerts.raw.json" 2> "$OUT_DIR/alerts.err"; then
  echo "::error::Could not read Dependabot alerts for $REPO: $(head -c 300 "$OUT_DIR/alerts.err")"
  echo "::error::Enable Dependabot alerts (Settings > Code security) and grant vulnerability-alerts: read."
  exit 1
fi
# --paginate concatenates arrays; flatten them.
jq -s 'add // []' "$OUT_DIR/alerts.raw.json" > "$OUT_DIR/alerts.json"

# Group by manifest + package. Alerts without a first patched version are kept
# aside so the report can say "skipped: no patch".
jq '
  def rank: {"critical":4,"high":3,"medium":2,"low":1}[.] // 0;
  map({
      number, severity: .security_advisory.severity,
      ghsa: .security_advisory.ghsa_id, cve: .security_advisory.cve_id,
      package: .dependency.package.name, ecosystem: .dependency.package.ecosystem,
      manifest: .dependency.manifest_path,
      first_patched: .security_vulnerability.first_patched_version.identifier
    })
  | group_by([.manifest, .package])
  | map({
      manifest: .[0].manifest, package: .[0].package, ecosystem: .[0].ecosystem,
      severity: (max_by(.severity | rank) | .severity),
      advisories: (map(.ghsa) | unique), alerts: map(.number),
      has_patch: (map(.first_patched) | any(. != null))
    })
  | sort_by(-(.severity | rank), .package)
' "$OUT_DIR/alerts.json" > "$OUT_DIR/groups.base.json"

: > "$OUT_DIR/groups.lines"
count=$(jq length "$OUT_DIR/groups.base.json")
for i in $(seq 0 $((count - 1))); do
  g=$(jq -c ".[$i]" "$OUT_DIR/groups.base.json")
  pkg=$(jq -r .package <<<"$g")
  manifest=$(jq -r .manifest <<<"$g")
  mapfile -t advs < <(jq -r '.advisories[]' <<<"$g")
  slug=$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')
  branch="security/${slug}-${TODAY}"

  # Every patched version the advisories publish for this package, so copies on
  # several release lines each get their own target (skill step 1).
  patched=$(for a in "${advs[@]}"; do
      gh api "/advisories/$a" --jq ".vulnerabilities[] | select(.package.name == \"$pkg\") | .first_patched_version // empty" 2>/dev/null || true
    done | sort -uV | paste -sd, -)

  adv_args=(); for a in "${advs[@]}"; do adv_args+=(--advisory "$a"); done
  if ! coverage=$(bash "$SKILL/scripts/check-existing-prs.sh" --repo "$REPO" --package "$pkg" \
        --manifest "$manifest" "${adv_args[@]}" --branch "$branch" 2>>"$OUT_DIR/coverage.err"); then
    coverage='{"error":"check-existing-prs.sh failed","skip":true,"skip_reason":"coverage check failed"}'
  fi
  jq -c --arg branch "$branch" --arg patched "$patched" --argjson coverage "$coverage" \
    '. + {branch: $branch, patched_versions: $patched, coverage: $coverage}' <<<"$g" >> "$OUT_DIR/groups.lines"
done
jq -s . "$OUT_DIR/groups.lines" > "$OUT_DIR/groups.json"
rm -f "$OUT_DIR/groups.lines" "$OUT_DIR/groups.base.json" "$OUT_DIR/alerts.raw.json"

{
  echo "### GHAS remediation input"
  echo
  echo "| Severity | Package | Manifest | Patched | Coverage |"
  echo "|---|---|---|---|---|"
  jq -r '.[] | "| \(.severity) | `\(.package)` | `\(.manifest)` | \(if .patched_versions == "" then "none" else .patched_versions end) | \(if .coverage.skip then .coverage.skip_reason else "open" end) |"' "$OUT_DIR/groups.json"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "Prepared $(jq length "$OUT_DIR/groups.json") group(s) in $OUT_DIR/groups.json"

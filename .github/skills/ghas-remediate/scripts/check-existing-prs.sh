#!/usr/bin/env bash
#
# check-existing-prs.sh — Is this alert group already being fixed by someone else?
#
# Usage: check-existing-prs.sh --repo <owner/name> --package <pkg> [--manifest <path>]
#                              [--advisory GHSA-... ]... [--branch <name>]
#
# --manifest is the alert's manifest path (vulnerableManifestPath). With it, a
# PR counts only through dependency files in that file's directory or an
# ancestor (a workspace root lockfile); a PR that changes a sibling service
# (service-a/ for a service-b/ alert) does not cover the group.
#
# Output (JSON):
#   covering_pr    open PR NOT authored by Dependabot that changes a dependency
#                  manifest/lockfile AND either cites one of the advisories
#                  (title/body/branch) or edits lines for the package in those
#                  files; else null. Includes the package's added lines.
#   dependabot_pr  open Dependabot PR that cites an advisory or names the package,
#                  else null. Informational only: it never causes a skip.
#   branch_exists  true if --branch already exists on origin
#   skip           true when covering_pr is set or branch_exists is true
#   skip_reason    "covering PR" | "branch exists" | null
#
# Policy: fix even when Dependabot has an open PR (they often lag, group
# unrelated bumps, or stall on CI). Skip only when a person or another tool
# already has a PR open that changes this dependency.
set -euo pipefail

REPO="" PACKAGE="" BRANCH="" MANIFEST="" MANIFEST_SET=false
ADVISORIES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --package) PACKAGE="${2:?}"; shift 2 ;;
    --advisory) ADVISORIES+=("${2:?}"); shift 2 ;;
    --branch) BRANCH="${2:?}"; shift 2 ;;
    --manifest) MANIFEST="${2:?}"; MANIFEST_SET=true; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO" ] && [ -n "$PACKAGE" ] || { echo "usage: check-existing-prs.sh --repo <owner/name> --package <pkg> [--manifest <path>] [--advisory GHSA-...] [--branch <name>]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v gh >/dev/null || { echo '{"error":"gh CLI not installed"}'; exit 1; }
command -v jq >/dev/null || { echo '{"error":"jq not installed"}'; exit 1; }

if ! PRS=$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json number,url,title,body,headRefName,author,isDraft,files 2>/dev/null); then
  echo '{"error":"gh pr list failed; cannot tell whether the group is covered"}'; exit 1
fi
[ -n "$PRS" ] || PRS="[]"

PKG_LC=$(printf '%s' "$PACKAGE" | tr '[:upper:]' '[:lower:]')
ADV_JSON=$(printf '%s\n' "${ADVISORIES[@]:-}" | jq -R 'select(length > 0) | ascii_downcase' | jq -s '.')
# The manifest's directory, "" for the repo root; null without --manifest.
MDIR_JSON=null
if [ "$MANIFEST_SET" = true ]; then
  MDIR=$(dirname "$MANIFEST"); MDIR=${MDIR#./}; [ "$MDIR" = "." ] && MDIR=""
  MDIR_JSON=$(jq -n --arg d "$MDIR" '$d')
fi
DEP_FILES='(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|pnpm-workspace\.yaml|pyproject\.toml|uv\.lock|poetry\.lock|Pipfile|Pipfile\.lock|requirements[^/]*\.txt|setup\.cfg|setup\.py|go\.mod|go\.sum|pom\.xml|build\.gradle(\.kts)?|Gemfile|Gemfile\.lock|Cargo\.toml|Cargo\.lock)$'

# jq helpers shared by both queries.
JQ_DEFS='
  def hay: ((.title // "") + "\n" + (.body // "") + "\n" + (.headRefName // "")) | ascii_downcase;
  def pkg_re: "(^|[^a-z0-9@/._-])" + ($pkg | gsub("[.*+?^${}()|\\[\\]\\\\]"; "\\\\\(.)")) + "($|[^a-z0-9@/._-])";
  def cites_advisory: (hay as $h | ($adv | any(. as $a | $h | contains($a))));
  def names_package: (hay | test(pkg_re));
  def is_dependabot: ((.author.login // "") | ascii_downcase | contains("dependabot"));
  def in_scope: (if $mdir == null then true
                 else ((if test("/") then sub("/[^/]*$"; "") else "" end) as $d
                       | $d == $mdir or $d == "" or ($mdir | startswith($d + "/"))) end);
  def touches_deps: ([.files[]?.path | select(test($dep_files) and in_scope)] | length > 0);
  def brief: {number, url, title, headRefName, author: .author.login, isDraft};
'

DEPENDABOT_PR=$(echo "$PRS" | jq -c --arg pkg "$PKG_LC" --argjson adv "$ADV_JSON" --arg dep_files "$DEP_FILES" --argjson mdir "$MDIR_JSON" "$JQ_DEFS"'
  map(select(is_dependabot and (cites_advisory or names_package))) | .[0] // null | if . then brief else null end')

# Non-Dependabot PRs that change dependency files are candidates. A candidate
# covers the group if it cites an advisory, or its diff edits lines for the
# package inside dependency files (checked below, one `gh pr diff` each).
CANDIDATES=$(echo "$PRS" | jq -c --arg pkg "$PKG_LC" --argjson adv "$ADV_JSON" --arg dep_files "$DEP_FILES" --argjson mdir "$MDIR_JSON" "$JQ_DEFS"'
  [.[] | select((is_dependabot | not) and touches_deps) | brief + {cites: cites_advisory}]')

COVERING="null"
while IFS= read -r cand; do
  [ -n "$cand" ] || continue
  num=$(echo "$cand" | jq -r '.number')
  diff=$(gh pr diff "$num" --repo "$REPO" 2>/dev/null || true)
  # Added lines that change this package's own entry (see pr_dep_lines.py).
  dir_args=(); [ "$MANIFEST_SET" = true ] && dir_args=(--dir "${MDIR:-.}")
  lines=$(printf '%s\n' "$diff" | python3 "$SCRIPT_DIR/pr_dep_lines.py" "$PACKAGE" ${dir_args[@]+"${dir_args[@]}"} 2>/dev/null || echo "[]")
  if [ "$(echo "$cand" | jq -r '.cites')" = "true" ] || [ "$(echo "$lines" | jq 'length')" -gt 0 ]; then
    COVERING=$(echo "$cand" | jq -c --argjson l "$lines" 'del(.cites) + {package_lines_added: $l}')
    break
  fi
done < <(echo "$CANDIDATES" | jq -c '.[]')

BRANCH_EXISTS=false
if [ -n "$BRANCH" ]; then
  if gh api "repos/${REPO}/branches/${BRANCH}" --silent >/dev/null 2>&1; then
    BRANCH_EXISTS=true
  fi
fi

jq -n --arg repo "$REPO" --arg pkg "$PACKAGE" --arg branch "$BRANCH" --argjson branch_exists "$BRANCH_EXISTS" \
  --argjson covering "$COVERING" --argjson dependabot "$DEPENDABOT_PR" '
  {
    repo: $repo, package: $pkg,
    covering_pr: $covering,
    dependabot_pr: $dependabot,
    branch: (if $branch == "" then null else $branch end), branch_exists: $branch_exists,
    skip: ($covering != null or $branch_exists),
    skip_reason: (if $covering != null then "covering PR" elif $branch_exists then "branch exists" else null end)
  }'

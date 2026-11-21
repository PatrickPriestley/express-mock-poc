#!/usr/bin/env bash
# Offline test for prepare.sh: a stub `gh` serves two pages of alerts, the
# advisories' patched versions, the open PR list and branch lookups.
# Run: bash .github/ghas/prepare.test.sh
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; echo "       $2"; }
check() { local name="$1" want="$2" got="$3"; [ "$want" = "$got" ] && ok "$name" || bad "$name" "want [$want] got [$got]"; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub. $STUB_MODE=fail-alerts makes the alerts call fail.
case "$*" in
  *dependabot/alerts*)
    [ "${STUB_MODE:-}" = fail-alerts ] && { echo "HTTP 403: Dependabot alerts are disabled" >&2; exit 1; }
    # Two pages, as --paginate prints them: two JSON arrays back to back.
    cat <<'JSON'
[{"number":1,"security_advisory":{"severity":"high","ghsa_id":"GHSA-aaaa","cve_id":"CVE-1"},
  "dependency":{"package":{"name":"lodash","ecosystem":"npm"},"manifest_path":"package-lock.json"},
  "security_vulnerability":{"first_patched_version":{"identifier":"4.17.21"}}},
 {"number":2,"security_advisory":{"severity":"critical","ghsa_id":"GHSA-bbbb","cve_id":null},
  "dependency":{"package":{"name":"@scope/pkg","ecosystem":"npm"},"manifest_path":"package-lock.json"},
  "security_vulnerability":{"first_patched_version":{"identifier":"2.0.1"}}}]
[{"number":3,"security_advisory":{"severity":"medium","ghsa_id":"GHSA-cccc","cve_id":null},
  "dependency":{"package":{"name":"lodash","ecosystem":"npm"},"manifest_path":"package-lock.json"},
  "security_vulnerability":{"first_patched_version":{"identifier":"4.17.23"}}},
 {"number":4,"security_advisory":{"severity":"low","ghsa_id":"GHSA-dddd","cve_id":null},
  "dependency":{"package":{"name":"aaa-nopatch","ecosystem":"npm"},"manifest_path":"package-lock.json"},
  "security_vulnerability":{"first_patched_version":null}}]
JSON
    ;;
  *"/advisories/GHSA-aaaa"*) printf '4.17.21\n' ;;
  *"/advisories/GHSA-cccc"*) printf '4.17.23\n3.10.2\n' ;;
  *"/advisories/GHSA-bbbb"*) printf '2.0.1\n' ;;
  *"/advisories/"*) ;;
  "pr list"*) echo '[]' ;;
  *"/branches/"*) exit 1 ;;   # no planned branch exists yet
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

echo "prepare.sh"
out="$tmp/out"
PATH="$tmp/bin:$PATH" GITHUB_STEP_SUMMARY="$tmp/summary.md" bash "$here/prepare.sh" owner/repo "$out" >/dev/null 2>"$tmp/err"
check "exits 0 on a normal run" 0 $?
g="$out/groups.json"
check "groups alerts by manifest and package, across pages" 3 "$(jq length "$g")"
check "orders groups by highest severity" "@scope/pkg,lodash,aaa-nopatch" "$(jq -r 'map(.package)|join(",")' "$g")"
check "a group's severity is its highest alert's" high "$(jq -r '.[]|select(.package=="lodash")|.severity' "$g")"
check "keeps every advisory and alert of a group" "GHSA-aaaa,GHSA-cccc|1,3" "$(jq -r '.[]|select(.package=="lodash")|"\(.advisories|join(","))|\(.alerts|join(","))"' "$g")"
check "collects every patched release line, version-sorted" "3.10.2,4.17.21,4.17.23" "$(jq -r '.[]|select(.package=="lodash")|.patched_versions' "$g")"
check "a group with no patch says so" "false|" "$(jq -r '.[]|select(.package=="aaa-nopatch")|"\(.has_patch)|\(.patched_versions)"' "$g")"
check "branch name is safe for a scoped package" "security/scope-pkg-" "$(jq -r '.[]|select(.package=="@scope/pkg")|.branch' "$g" | sed 's/[0-9]*$//')"
check "carries the coverage check's verdict" "false" "$(jq -r '.[0].coverage.skip' "$g")"
grep -q '| critical | `@scope/pkg` |' "$tmp/summary.md" && ok "writes the step summary table" || bad "writes the step summary table" "$(cat "$tmp/summary.md")"

out2="$tmp/out2"
PATH="$tmp/bin:$PATH" STUB_MODE=fail-alerts bash "$here/prepare.sh" owner/repo "$out2" >"$tmp/out2.log" 2>&1
check "fails when alerts cannot be read" 1 $?
grep -q 'Enable Dependabot alerts' "$tmp/out2.log" && ok "says how to fix unreadable alerts" || bad "says how to fix unreadable alerts" "$(cat "$tmp/out2.log")"

echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]

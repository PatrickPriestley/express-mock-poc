#!/usr/bin/env bash
# lib-semver.sh — version helpers shared by apply-fix.sh and verify-fix.sh.
#
# A fix can name more than one patched version, one per release line, when an
# advisory is patched on several lines (js-yaml 3.15.1 and 4.3.1, say). Such a
# list is passed as one comma-separated argument: "3.15.1,4.3.1".

# The breaking-change line of a version or range: its major, or 0.<minor> below
# 1.0. Reads the first version number in the string, so "^3.24.1" and
# ">=3.0.0 <4" are both line 3. Prints nothing when there is no version in it.
semver_line() {
  local v
  v=$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1) || true
  [ -n "$v" ] || return 0
  case "$v" in 0.*) echo "$v" ;; *) echo "${v%%.*}" ;; esac
}

# 0 when $1 >= $2 (numeric major.minor.patch; prerelease and build ignored).
version_gte() {
  local a="${1#v}" b="${2#v}"; a="${a%%-*}"; b="${b%%-*}"; a="${a%%+*}"; b="${b%%+*}"
  local IFS=.; local -a A=($a) B=($b)
  for i in 0 1 2; do
    local x="${A[$i]:-0}" y="${B[$i]:-0}"
    [[ "$x" =~ ^[0-9]+$ ]] || x=0; [[ "$y" =~ ^[0-9]+$ ]] || y=0
    if (( x > y )); then return 0; fi
    if (( x < y )); then return 1; fi
  done
  return 0
}

# The patched versions in a comma-separated list, one per line, keeping the
# highest per release line (two advisories can patch the same line at
# different versions), lowest line first.
targets_norm() { # csv
  python3 - "$1" <<'PY'
import re, sys
def key(v):
    nums = [int(x) for x in re.findall(r"\d+", v.lstrip("v").split("-")[0].split("+")[0])[:3]]
    return nums + [0] * (3 - len(nums))
def line(v):
    k = key(v)
    return (0, k[1]) if k[0] == 0 else (k[0],)
best = {}
for t in filter(None, (s.strip() for s in sys.argv[1].split(","))):
    if line(t) not in best or key(t) > key(best[line(t)]):
        best[line(t)] = t
for t in sorted(best.values(), key=key):
    print(t)
PY
}

# The patched version on the same release line as $1, from a csv list.
target_for() { # version, csv
  local line t
  line=$(semver_line "$1")
  [ -n "$line" ] || return 0
  while IFS= read -r t; do
    [ "$(semver_line "$t")" = "$line" ] && { echo "$t"; return 0; }
  done < <(targets_norm "$2")
  return 0 # no match prints nothing; callers run under set -e
}

# 0 when version $1 is patched against the csv list: at least the patched
# version on its own line, or, when its line has none, newer than every
# patched version (a later line the advisory never affected).
copy_patched() { # version, csv
  local t max
  t=$(target_for "$1" "$2")
  if [ -n "$t" ]; then version_gte "$1" "$t"; return; fi
  max=$(targets_norm "$2" | tail -1)
  [ -n "$max" ] && version_gte "$1" "$max"
}

#!/usr/bin/env bash
# lib-pnpm.sh — pnpm helpers shared by apply-fix.sh and verify-fix.sh.
# Source this file after `cd` into the project.

_PNPM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Directory holding pnpm-lock.yaml: the current directory, or the nearest
# ancestor up to the git root (a workspace keeps one lockfile at its root).
# Prints nothing when the project does not use pnpm.
pnpm_lock_dir() {
  local d top
  d=$(pwd -P)
  top=$(git rev-parse --show-toplevel 2>/dev/null || echo "$d")
  while :; do
    [ -f "$d/pnpm-lock.yaml" ] && { printf '%s\n' "$d"; return 0; }
    [ "$d" = "$top" ] || [ "$d" = "/" ] && return 0
    d=$(dirname "$d")
  done
}

# Every version of a package the lockfile resolves, as a JSON array.
pnpm_resolved() { # package, lock dir
  python3 "$_PNPM_LIB_DIR/pnpm_lock.py" resolved "$1" "$2/pnpm-lock.yaml" 2>/dev/null || echo "[]"
}

pnpm_lockfile_version() { # lock dir
  python3 "$_PNPM_LIB_DIR/pnpm_lock.py" version "$1/pnpm-lock.yaml" 2>/dev/null
}

# True when the workspace file sets overrides itself; package.json's
# pnpm.overrides is then not the place to edit.
pnpm_workspace_has_overrides() { # lock dir
  [ -f "$1/pnpm-workspace.yaml" ] && grep -qE '^overrides:' "$1/pnpm-workspace.yaml"
}

#!/usr/bin/env bash
#
# apply-fix.sh — Apply a dependency fix to a repo (bump or override)
#
# Usage: apply-fix.sh [--dry-run] [--prefix PREFIX] [--allow-major] [--manifest PATH] <repo-path> <package> <version>[,<version>...] <fix-type>
#   fix-type: bump | override | refresh | parent_bump | remove_override
#   version:  the patched version, or one per release line when the advisory
#             is patched on several ("3.15.1,4.3.1"). Each copy of the package
#             moves to the patched version on its own line. A bump takes the
#             one on the declared range's line. An override writes one entry
#             per line that needs it, scoped by version ("js-yaml@^3"), when
#             the copies span more than one line. A copy whose line has no
#             patched version is refused as a major change (see --allow-major).
#   --dry-run    Print what would change without modifying files
#   --allow-major  Permit a fix that moves the package to a new major version
#                (0.x: a new minor). Without it, such a fix is refused with
#                status "refused" and exit code 3, before anything changes.
#                Pass it only after a person has approved that change.
#   --manifest   Python: the alert's manifest (vulnerableManifestPath, relative
#                to repo-path), e.g. tests/requirements-test.txt. A bump then
#                edits that file only. Without it, a bump edits every
#                requirements*.txt and pyproject.toml in repo-path.
#   --prefix     Version prefix for npm bumps/overrides (default: ^);
#                for Python overrides, >= (default) or ==.
#                An npm bump without --prefix keeps the range style the
#                manifest already uses: an exact pin stays exact, ~ stays ~.
#
# Python (uv): bump edits the specifier, override sets
# [tool.uv] constraint-dependencies, refresh runs uv lock --upgrade-package.
# All three relock with a uv that preserves uv.lock's revision (see lib-uv.sh)
# and report it as uv_bin. bump matches names per PEP 503 and keeps extras
# (pyjwt[crypto]) and markers (see py_spec.py).
#
# pnpm overrides go in pnpm-workspace.yaml when the pnpm on PATH is 11 or
# later (pnpm 11 ignores package.json's pnpm.overrides) or when that file
# already has an overrides map; otherwise in package.json's pnpm.overrides.
#
# Output: JSON with changed files and status
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-uv.sh"
source "$SCRIPT_DIR/lib-pnpm.sh"
source "$SCRIPT_DIR/lib-semver.sh"
UV_BIN=""

# ─── Defaults for optional flags ────────────────────────────────────────────
DRY_RUN=false
ALLOW_MAJOR=false
VERSION_PREFIX="^"
PREFIX_SET=false
MANIFEST=""

# ─── Parse optional flags first, then positional args ────────────────────────
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift;;
    --allow-major) ALLOW_MAJOR=true; shift;;
    --prefix) VERSION_PREFIX="$2"; PREFIX_SET=true; shift 2;;
    --manifest) MANIFEST="${2:?--manifest needs a path}"; shift 2;;
    --) shift; POSITIONAL+=("$@"); set --; break;;
    -*) echo "{\"error\":\"unknown flag: $1\"}"; exit 1;;
    *) POSITIONAL+=("$1"); shift;;
  esac
done

REPO_PATH="${POSITIONAL[0]:?Usage: apply-fix.sh [--dry-run] [--prefix PREFIX] <repo-path> <package> <version> <fix-type>}"
PACKAGE="${POSITIONAL[1]:?}" TARGET_VERSION="${POSITIONAL[2]:?}" FIX_TYPE="${POSITIONAL[3]:-bump}"

# Basic input validation
[[ -z "$REPO_PATH" || -z "$PACKAGE" || -z "$TARGET_VERSION" ]] && { echo '{"error":"missing required args"}'; exit 1; }
[[ "$PACKAGE" =~ [^a-zA-Z0-9@/_.-] ]] && { echo '{"error":"invalid package name"}'; exit 1; }
[[ "$TARGET_VERSION" =~ [^a-zA-Z0-9.,_-] ]] && { echo '{"error":"invalid version"}'; exit 1; }
[[ "$FIX_TYPE" =~ ^(bump|override|refresh|parent_bump|remove_override)$ ]] || { echo '{"error":"invalid fix-type, must be bump|override|refresh|parent_bump|remove_override"}'; exit 1; }

[ -d "$REPO_PATH" ] || { echo '{"error":"repo not found"}'; exit 1; }
cd "$REPO_PATH"

CHANGED_FILES=""
RESOLVED_JSON=""
OVERRIDES_JSON=""
PICKED=""

# The patched versions, highest per release line. TARGET_VERSION becomes the
# one this fix applies once it is known; with a single version it is that one.
TARGETS_CSV=$(targets_norm "$TARGET_VERSION" | paste -sd, -)
[ -n "$TARGETS_CSV" ] || { echo '{"error":"invalid version"}'; exit 1; }
TARGET_MAX=$(targets_norm "$TARGETS_CSV" | tail -1)
MULTI_TARGET=false; [[ "$TARGETS_CSV" == *,* ]] && MULTI_TARGET=true
[ "$MULTI_TARGET" = false ] && TARGET_VERSION="$TARGETS_CSV"

# ─── Major-version guard ──────────────────────────────────────────────────────
# A fix may move a copy of the package only within its release line (major, or
# 0.<minor> below 1.0). A copy whose line has no patched version is refused:
# status "refused", exit 3, nothing changed.
refuse_major() { # from, to
  [ -n "${PNPM_SNAP:-}" ] && rm -rf "$PNPM_SNAP"
  [ -n "${YARN_SNAP:-}" ] && rm -rf "$YARN_SNAP"
  jq -n --arg pkg "$PACKAGE" --arg from "$1" --arg to "$2" --arg type "$FIX_TYPE" --arg targets "$TARGETS_CSV" \
    '{package:$pkg, fix_type:$type, status:"refused", reason:"major_version", from:$from, to:$to,
      targets:($targets | split(",")),
      message:"\($pkg) \($from) -> \($to) crosses a major version. Do not apply it by other means; report the group as skipped: needs major and leave the decision to a person."}'
  exit 3
}

# Sets PICKED to the patched version on the line of a declared version or
# range ($1); refuses when that line has none. Without a version in $1 (or
# with --allow-major) it takes the highest patched version.
pick_target() { # current version or range
  PICKED=$(target_for "$1" "$TARGETS_CSV")
  [ -n "$PICKED" ] && return 0
  PICKED="$TARGET_MAX"
  [ "$ALLOW_MAJOR" = true ] || [ -z "$(semver_line "$1")" ] && return 0
  refuse_major "$1" "$TARGET_MAX"
}

# Plans an override from the copies the lockfile resolves (args). Sets
# OV_KEYS/OV_VALS: the package name alone when every copy is on one line,
# else one "<package>@^<line>" entry per line that has a vulnerable copy.
# Copies already patched are left alone; a vulnerable copy whose line has no
# patched version is refused.
OV_KEYS=() OV_VALS=()
plan_override() { # resolved versions...
  local v t lines="" need="" force_max=false
  for v in "$@"; do
    lines="$lines $(semver_line "$v")"
    copy_patched "$v" "$TARGETS_CSV" && continue
    t=$(target_for "$v" "$TARGETS_CSV")
    if [ -z "$t" ]; then
      [ "$ALLOW_MAJOR" = true ] || refuse_major "$v" "$TARGET_MAX"
      force_max=true; continue
    fi
    case " $need " in *" $t "*) ;; *) need="$need $t" ;; esac
  done
  if [ $# -eq 0 ]; then
    # Nothing in a lockfile to read: one entry, which needs one target.
    [ "$MULTI_TARGET" = false ] || { echo '{"error":"several patched versions but no lockfile to choose between them"}'; exit 1; }
    OV_KEYS=("$PACKAGE"); OV_VALS=("${VERSION_PREFIX}${TARGET_VERSION}"); return 0
  fi
  if [ "$force_max" = true ]; then
    OV_KEYS=("$PACKAGE"); OV_VALS=("${VERSION_PREFIX}${TARGET_MAX}"); TARGET_VERSION="$TARGET_MAX"; return 0
  fi
  need="${need# }"
  [ -n "$need" ] || return 0
  local nlines; nlines=$(printf '%s\n' $lines | sort -u | wc -l | tr -d ' ')
  if [ "$nlines" = 1 ]; then
    OV_KEYS=("$PACKAGE"); OV_VALS=("${VERSION_PREFIX}${need}"); TARGET_VERSION="$need"; return 0
  fi
  for t in $need; do
    OV_KEYS+=("$PACKAGE@^$(semver_line "$t")"); OV_VALS+=("${VERSION_PREFIX}${t}")
  done
  TARGET_VERSION=$(printf '%s\n' $need | paste -sd, -)
}

# The planned override as a JSON object, for the output.
ov_json() {
  local i out="{}"
  for i in "${!OV_KEYS[@]}"; do
    out=$(jq -c --arg k "${OV_KEYS[$i]}" --arg v "${OV_VALS[$i]}" '. + {($k): $v}' <<<"$out")
  done
  echo "$out"
}

# ─── npm / yarn / pnpm ───────────────────────────────────────────────────────
# Every version of $PACKAGE the npm lockfile resolves, as a JSON array.
# Walks dependency maps only; `.. | .version` would pick the root package's own version.
npm_resolved() {
  npm ls "$PACKAGE" --json --all --package-lock-only 2>/dev/null \
    | jq -c --arg p "$PACKAGE" '[.. | objects | select(has("dependencies")) | .dependencies[$p]? | select(. != null) | .version] | unique' 2>/dev/null \
    || echo "[]"
}

# Move $PACKAGE to the newest version its parents' ranges allow, lockfile only.
# --package-lock-only: no node_modules, so no dependency install scripts run in the clone.
npm_targeted_update() {
  npm update "$PACKAGE" --package-lock-only --ignore-scripts 2>&1 | tail -3 >&2
  RESOLVED_JSON=$(npm_resolved)
  echo "  Resolved to: $(echo "$RESOLVED_JSON" | jq -r 'join(", ")') (target: >= $TARGET_VERSION)" >&2
}

# pnpm: the lockfile (and any override) lives at the workspace root, which may
# be above the package being fixed. PNPM_DIR is that root; empty for npm/yarn.
PNPM_DIR="" PNPM_SNAP="" PNPM_LOCK_VERSION=""

rel() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1]))' "$1"; }

# Put back what a pnpm fix changed and stop. Used when the pnpm on PATH would
# rewrite the lockfile in a different format than the repo's own pnpm.
pnpm_abort() { # message
  cp "$PNPM_SNAP/pnpm-lock.yaml" "$PNPM_DIR/pnpm-lock.yaml"
  cp "$PNPM_SNAP/root-package.json" "$PNPM_DIR/package.json"
  [ -f "$PNPM_SNAP/package.json" ] && cp "$PNPM_SNAP/package.json" package.json
  if [ -f "$PNPM_SNAP/pnpm-workspace.yaml" ]; then cp "$PNPM_SNAP/pnpm-workspace.yaml" "$PNPM_DIR/pnpm-workspace.yaml"
  else rm -f "$PNPM_DIR/pnpm-workspace.yaml"; fi
  rm -rf "$PNPM_SNAP"
  jq -n --arg pkg "$PACKAGE" --arg e "$1" '{package:$pkg, status:"error", error:$e}'
  exit 1
}

pnpm_targeted_update() {
  local recursive=()
  [ -f "$PNPM_DIR/pnpm-workspace.yaml" ] && recursive=(-r)
  (cd "$PNPM_DIR" && pnpm update "$PACKAGE" --depth Infinity --lockfile-only ${recursive[@]+"${recursive[@]}"}) 2>&1 | tail -3 >&2
}

# Relock without installing (no node_modules, so no install scripts run), then
# refuse the result if this pnpm changed the lockfile format.
pnpm_relock() {
  pnpm install --lockfile-only --ignore-scripts 2>&1 | tail -5 >&2
  if [ "$FIX_TYPE" = "remove_override" ] || [ "$FIX_TYPE" = "refresh" ]; then pnpm_targeted_update; fi
  local after; after=$(pnpm_lockfile_version "$PNPM_DIR")
  if [ "$after" != "$PNPM_LOCK_VERSION" ]; then
    pnpm_abort "pnpm $(pnpm --version 2>/dev/null) rewrote lockfileVersion $PNPM_LOCK_VERSION -> $after; run with the pnpm the repo pins (packageManager field / corepack)"
  fi
  RESOLVED_JSON=$(pnpm_resolved "$PACKAGE" "$PNPM_DIR")
  echo "  Resolved to: $(echo "$RESOLVED_JSON" | jq -r 'join(", ")') (target: >= $TARGET_VERSION)" >&2
  rm -rf "$PNPM_SNAP"
}

# Relock yarn without running any package's install scripts: yarn 2+ updates
# the lockfile only; yarn 1 has no such mode, so it installs with
# --ignore-scripts. On failure, put package.json and yarn.lock back and stop
# with the error, so nothing is left half-applied.
YARN_SNAP=""
yarn_relock() {
  local log rc
  log=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
  if python3 "$SCRIPT_DIR/yarn_lock.py" berry yarn.lock; then
    rc=0; yarn install --mode=update-lockfile >"$log" 2>&1 || rc=$?
  else
    rc=0; yarn install --ignore-scripts >"$log" 2>&1 || rc=$?
  fi
  tail -3 "$log" >&2
  if [ "$rc" -ne 0 ]; then
    cp "$YARN_SNAP/package.json" "$YARN_SNAP/yarn.lock" .
    rm -rf "$YARN_SNAP"
    jq -n --arg pkg "$PACKAGE" --arg e "$(grep -v '^\s*$' "$log" | tail -1)" --argjson rc "$rc" \
      '{package:$pkg, status:"error", error:"yarn install failed (exit \($rc)): \($e). package.json and yarn.lock restored."}'
    rm -f "$log"; exit 1
  fi
  rm -rf "$YARN_SNAP" "$log"
}

fix_npm() {
  local pm="npm" root_manifest="package.json" lockfile="package-lock.json" ov_file=""
  if [ -f "yarn.lock" ]; then
    pm="yarn"; lockfile="yarn.lock"
    # Snapshot both files: a failed relock puts them back before it reports.
    if [ "$DRY_RUN" = false ]; then
      YARN_SNAP=$(mktemp -d "${TMPDIR:-/tmp}/ghas.XXXXXX")
      cp package.json yarn.lock "$YARN_SNAP/"
    fi
  else
    PNPM_DIR=$(pnpm_lock_dir)
    if [ -n "$PNPM_DIR" ]; then
      pm="pnpm"
      root_manifest=$(rel "$PNPM_DIR/package.json"); lockfile=$(rel "$PNPM_DIR/pnpm-lock.yaml")
      if [ "$DRY_RUN" = false ]; then
        command -v pnpm >/dev/null || { echo '{"error":"pnpm repo but pnpm is not installed"}'; exit 1; }
        [ -f "$PNPM_DIR/package.json" ] || { echo '{"error":"pnpm-lock.yaml has no package.json beside it"}'; exit 1; }
        PNPM_LOCK_VERSION=$(pnpm_lockfile_version "$PNPM_DIR")
        PNPM_SNAP=$(mktemp -d "${TMPDIR:-/tmp}/ghas.XXXXXX")
        cp "$PNPM_DIR/pnpm-lock.yaml" "$PNPM_SNAP/pnpm-lock.yaml"
        cp "$PNPM_DIR/package.json" "$PNPM_SNAP/root-package.json"
        [ "$root_manifest" != "package.json" ] && [ -f package.json ] && cp package.json "$PNPM_SNAP/package.json"
        [ -f "$PNPM_DIR/pnpm-workspace.yaml" ] && cp "$PNPM_DIR/pnpm-workspace.yaml" "$PNPM_SNAP/pnpm-workspace.yaml"
      fi
      # Where pnpm reads overrides: pnpm-workspace.yaml for pnpm 11+ (which
      # ignores package.json's pnpm.overrides) or when that file already has them.
      local pnpm_major
      pnpm_major=$(pnpm --version 2>/dev/null | cut -d. -f1)
      if pnpm_workspace_has_overrides "$PNPM_DIR" || { [ -n "$pnpm_major" ] && [ "$pnpm_major" -ge 11 ] 2>/dev/null; }; then
        ov_file=$(rel "$PNPM_DIR/pnpm-workspace.yaml")
      fi
    fi
  fi

  # An override forces every copy of the package; none may change major. This
  # runs before the hand-edit path below, so a refused override stays refused.
  if [ "$FIX_TYPE" = "override" ]; then
    local current_json="[]" v
    local -a current=()
    if [ "$pm" = "pnpm" ]; then current_json=$(pnpm_resolved "$PACKAGE" "$PNPM_DIR")
    elif [ "$pm" = "npm" ] && [ -f package-lock.json ]; then current_json=$(npm_resolved)
    fi
    while IFS= read -r v; do [ -n "$v" ] && current+=("$v"); done < <(echo "$current_json" | jq -r '.[]' 2>/dev/null)
    plan_override ${current[@]+"${current[@]}"}
    if [ ${#OV_KEYS[@]} -eq 0 ]; then
      [ -n "$PNPM_SNAP" ] && rm -rf "$PNPM_SNAP"
      jq -n --arg pkg "$PACKAGE" --argjson r "$current_json" \
        '{package:$pkg, status:"already_patched", resolved:$r, message:"every resolved copy is already at or above its patched version; nothing to override"}'
      exit 0
    fi
    # yarn: copies are not read (no lockfile reader), so it only ever gets the
    # plain entry, and a list of several patched versions stops above.
    OVERRIDES_JSON=$(ov_json)
  fi

  if [ "$FIX_TYPE" = "remove_override" ]; then
    # Remove an existing override that is no longer needed — the parent's
    # declared range already includes the patched version.
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
    if [ "$DRY_RUN" = true ]; then
      echo "DRY RUN: Would remove override for $PACKAGE from $root_manifest" >&2
    else
      case "$pm" in
        yarn) jq --arg p "$PACKAGE" 'if .resolutions then .resolutions |= del(.[$p]) else . end' package.json > "$tmp" ;;
        pnpm) jq --arg p "$PACKAGE" 'if .pnpm.overrides then .pnpm.overrides |= del(.[$p]) else . end' "$root_manifest" > "$tmp" ;;
        *)    jq --arg p "$PACKAGE" 'if .overrides then .overrides |= del(.[$p]) else . end' package.json > "$tmp" ;;
      esac
      mv "$tmp" "$root_manifest"
      if [ "$pm" = "pnpm" ] && [ -f "$PNPM_DIR/pnpm-workspace.yaml" ]; then
        python3 "$SCRIPT_DIR/pnpm_ws_overrides.py" del "$PNPM_DIR/pnpm-workspace.yaml" "$PACKAGE" \
          || { pnpm_abort "could not edit overrides in pnpm-workspace.yaml; edit it by hand"; }
      fi
    fi
    CHANGED_FILES="$root_manifest"
    if [ "$pm" = "pnpm" ] && [ "$DRY_RUN" = false ] && [ -f "$PNPM_DIR/pnpm-workspace.yaml" ] \
       && ! cmp -s "$PNPM_DIR/pnpm-workspace.yaml" "$PNPM_SNAP/pnpm-workspace.yaml"; then
      CHANGED_FILES="$CHANGED_FILES $(rel "$PNPM_DIR/pnpm-workspace.yaml")"
    fi
  elif [ "$FIX_TYPE" = "refresh" ]; then
    # Targeted update: parent range already permits patched version. Resolve the
    # newest version in range without touching any manifest.
    if [ "$pm" = "yarn" ]; then
      echo '{"error":"refresh is not supported for yarn; use override, or update the lock by hand"}'; exit 1
    fi
    if [ "$DRY_RUN" = true ]; then
      echo "DRY RUN: Would update $PACKAGE in $lockfile only" >&2
    elif [ "$pm" = "pnpm" ]; then
      pnpm_relock
    else
      npm_targeted_update
    fi
    CHANGED_FILES="$lockfile"
    return
  elif [ "$FIX_TYPE" = "override" ]; then
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
    local ov_target="${ov_file:-$root_manifest}"
    if [ "$DRY_RUN" = true ]; then
      echo "DRY RUN: Would set overrides $OVERRIDES_JSON in $ov_target" >&2
      rm -f "$tmp"
    elif [ -n "$ov_file" ]; then
      rm -f "$tmp"
      for i in "${!OV_KEYS[@]}"; do
        python3 "$SCRIPT_DIR/pnpm_ws_overrides.py" set "$PNPM_DIR/pnpm-workspace.yaml" "${OV_KEYS[$i]}" "${OV_VALS[$i]}" \
          || pnpm_abort "could not edit overrides in pnpm-workspace.yaml; edit it by hand, keeping every copy on its current major version"
      done
    else
      case "$pm" in
        yarn) jq --argjson o "$OVERRIDES_JSON" '.resolutions = ((.resolutions // {}) + $o)' package.json > "$tmp" ;;
        pnpm) jq --argjson o "$OVERRIDES_JSON" '.pnpm //= {} | .pnpm.overrides = ((.pnpm.overrides // {}) + $o)' "$root_manifest" > "$tmp" ;;
        *)    jq --argjson o "$OVERRIDES_JSON" '.overrides = ((.overrides // {}) + $o)' package.json > "$tmp" ;;
      esac
      mv "$tmp" "$root_manifest"
    fi
    CHANGED_FILES="$ov_target"
  else
    # Direct version bump or parent_bump — both update the package version
    # in the appropriate dependency section of package.json.
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
    local section
    section=$(jq -r --arg p "$PACKAGE" '
      if .dependencies[$p] then "dependencies"
      elif .devDependencies[$p] then "devDependencies"
      else empty end
    ' package.json 2>/dev/null || echo "")

    if [ -n "$section" ]; then
      pick_target "$(jq -r --arg p "$PACKAGE" --arg s "$section" '.[$s][$p]' package.json)"
      TARGET_VERSION="$PICKED"
      # Keep the manifest's range style unless --prefix was given. Writing ^ over
      # an exact pin lets npm resolve a newer minor than the patched version.
      if [ "$PREFIX_SET" = false ]; then
        local current
        current=$(jq -r --arg p "$PACKAGE" --arg s "$section" '.[$s][$p]' package.json)
        case "$current" in
          [0-9]*|v[0-9]*|=*) VERSION_PREFIX="" ;;
          "~"*) VERSION_PREFIX="~" ;;
        esac
      fi
      if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would modify package.json — change $PACKAGE ($section) to ${VERSION_PREFIX}${TARGET_VERSION}" >&2
      else
        jq --arg p "$PACKAGE" --arg v "${VERSION_PREFIX}${TARGET_VERSION}" --arg s "$section" \
          '.[$s][$p] = $v' package.json > "$tmp" && mv "$tmp" package.json
      fi
      CHANGED_FILES="package.json"
    else
      [ -n "$PNPM_SNAP" ] && rm -rf "$PNPM_SNAP"
    fi
  fi

  # Regenerate lockfile
  if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would regenerate lockfile" >&2
  elif [ "$pm" = "pnpm" ]; then
    if [ -n "$CHANGED_FILES" ]; then pnpm_relock; CHANGED_FILES="$CHANGED_FILES $lockfile"; fi
  elif [ "$pm" = "yarn" ]; then
    yarn_relock
    CHANGED_FILES="$CHANGED_FILES yarn.lock"
  elif [ -f "package-lock.json" ]; then
    npm install --package-lock-only --ignore-scripts 2>&1 | tail -5 >&2
    # Dropping an override leaves the old pin in the lock when it still satisfies
    # the parent's range; move it to the newest allowed version explicitly.
    [ "$FIX_TYPE" = "remove_override" ] && npm_targeted_update
    [ -z "$RESOLVED_JSON" ] && RESOLVED_JSON=$(npm_resolved)
    CHANGED_FILES="$CHANGED_FILES package-lock.json"
  fi
}

# ─── Python ───────────────────────────────────────────────────────────────────
# Relock with the first working uv that keeps uv.lock's `revision` header.
# Never hand-edit the lock to restore it.
uv_relock() { # extra uv lock args...
  local before after c snapshot
  before=$(uv_lock_revision uv.lock)
  snapshot=$(mktemp "${TMPDIR:-/tmp}/ghas.XXXXXX")
  cp uv.lock "$snapshot"
  while IFS= read -r c; do
    if ! "$c" lock "$@" >&2 2>&1; then
      echo "uv lock failed with $c; trying next uv" >&2
      cp "$snapshot" uv.lock; continue
    fi
    after=$(uv_lock_revision uv.lock)
    if [ -z "$before" ] || [ "$after" = "$before" ]; then
      UV_BIN="$c"; rm -f "$snapshot"; return 0
    fi
    echo "$c rewrote uv.lock revision $before -> $after; trying next uv" >&2
    cp "$snapshot" uv.lock
  done < <(uv_working_candidates)
  rm -f "$snapshot"
  jq -n --arg pkg "$PACKAGE" --arg rev "$before" \
    '{package:$pkg, status:"error", error:"no runnable uv could relock without changing uv.lock revision \($rev); set GHAS_UV to a matching uv"}'
  exit 1
}

fix_python() {
  if [[ "$FIX_TYPE" =~ ^(parent_bump|remove_override)$ ]]; then
    echo "{\"error\":\"fix type '$FIX_TYPE' not supported for Python ecosystem\"}"
    exit 1
  fi

  if [ "$FIX_TYPE" = "refresh" ]; then
    # The declared range already admits the patched version: move only this package in the lock.
    [ -f uv.lock ] || { echo '{"error":"python refresh needs uv.lock"}'; exit 1; }
    if [ "$DRY_RUN" = true ]; then
      echo "DRY RUN: Would run uv lock --upgrade-package $PACKAGE" >&2
    else
      uv_relock --upgrade-package "$PACKAGE"
    fi
    CHANGED_FILES="uv.lock"
    return
  fi

  if [ "$FIX_TYPE" = "override" ]; then
    # Transitive: constrain it under [tool.uv] constraint-dependencies, never pin it in [project].
    [ -f pyproject.toml ] || { echo '{"error":"python override needs pyproject.toml ([tool.uv] constraint-dependencies)"}'; exit 1; }
    # The constraint applies to the one resolved copy; it must stay on its line.
    local locked=""
    [ -f uv.lock ] && locked=$(python3 - "$PACKAGE" <<'PYLOCK' 2>/dev/null || true
import re, sys, tomllib
n = lambda s: re.sub(r"[-_.]+", "-", s).lower()
lock = tomllib.load(open("uv.lock", "rb"))
print("\n".join(sorted({p["version"] for p in lock.get("package", []) if n(p.get("name", "")) == n(sys.argv[1])})))
PYLOCK
)
    if [ -n "$locked" ]; then
      local lv; for lv in $locked; do pick_target "$lv"; done
      TARGET_VERSION="$PICKED"
    elif [ "$MULTI_TARGET" = true ]; then
      echo '{"error":"several patched versions but no uv.lock to choose between them"}'; exit 1
    fi
    local spec_op=">="
    case "$VERSION_PREFIX" in "^"|">=") spec_op=">=" ;; "==") spec_op="==" ;;
      *) echo '{"error":"python override --prefix must be >= or =="}'; exit 1 ;; esac
    if [ "$DRY_RUN" = true ]; then
      echo "DRY RUN: Would set [tool.uv] constraint-dependencies $PACKAGE$spec_op$TARGET_VERSION" >&2
    else
      python3 "$SCRIPT_DIR/uv_constraint.py" pyproject.toml "$PACKAGE" "$spec_op$TARGET_VERSION" >&2 \
        || { echo '{"error":"could not edit [tool.uv] constraint-dependencies"}'; exit 1; }
    fi
    CHANGED_FILES="pyproject.toml"
    if [ "$DRY_RUN" = false ] && [ -f uv.lock ]; then
      uv_relock; CHANGED_FILES="$CHANGED_FILES uv.lock"
    fi
    return
  fi

  local -a py_files=() py_current=()
  local spec
  if [ -n "$MANIFEST" ]; then
    py_files=("$MANIFEST")
  else
    for f in requirements*.txt pyproject.toml; do [ -f "$f" ] && py_files+=("$f"); done
  fi
  while IFS= read -r spec; do [ -n "$spec" ] && py_current+=("$spec"); done < <(
    python3 "$SCRIPT_DIR/py_spec.py" current "$PACKAGE" ${py_files[@]+"${py_files[@]}"} 2>/dev/null || true)
  # Every declared version must have a patched version on its line; the first
  # one picks the target (they are one package, so one line in practice).
  for spec in ${py_current[@]+"${py_current[@]}"}; do pick_target "$spec"; done
  if [ ${#py_current[@]} -gt 0 ]; then pick_target "${py_current[0]}"
  elif [ "$MULTI_TARGET" = true ]; then
    echo '{"error":"several patched versions but no pinned version to choose between them"}'; exit 1
  fi
  TARGET_VERSION="${PICKED:-$TARGET_VERSION}"

  local edited
  for f in ${py_files[@]+"${py_files[@]}"}; do
    if [ "$DRY_RUN" = true ]; then
      # Edit a copy with the same file name: py_spec.py reads the format from it.
      edited=$(mktemp -d "${TMPDIR:-/tmp}/ghas.XXXXXX"); cp "$f" "$edited/"
      if python3 "$SCRIPT_DIR/py_spec.py" bump "$PACKAGE" "$TARGET_VERSION" "$edited/$(basename "$f")"; then
        echo "DRY RUN: Would modify $f — change $PACKAGE to $TARGET_VERSION" >&2
        CHANGED_FILES="$CHANGED_FILES $f"
      fi
      rm -rf "$edited"
    elif python3 "$SCRIPT_DIR/py_spec.py" bump "$PACKAGE" "$TARGET_VERSION" "$f"; then
      CHANGED_FILES="$CHANGED_FILES $f"
    fi
  done
  if [ "$DRY_RUN" = false ] && [[ " $CHANGED_FILES " == *" pyproject.toml "* ]] && [ -f uv.lock ]; then
    uv_relock; CHANGED_FILES="$CHANGED_FILES uv.lock"
  fi
}

# ─── Go ───────────────────────────────────────────────────────────────────────
fix_go() {
  [ "$MULTI_TARGET" = false ] || { echo '{"error":"several patched versions are not supported for Go; pass the one for the module major in go.mod"}'; exit 1; }
  if [[ "$FIX_TYPE" =~ ^(parent_bump|remove_override)$ ]]; then
    echo "{\"error\":\"fix type '$FIX_TYPE' not supported for Go ecosystem\"}"
    exit 1
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would run go get ${PACKAGE}@v${TARGET_VERSION#v} and go mod tidy" >&2
  else
    go get "${PACKAGE}@v${TARGET_VERSION#v}" 2>&1 | tail -3 >&2
    go mod tidy 2>&1 >&2
  fi
  CHANGED_FILES="go.mod go.sum"
}

# ─── Detect and apply ────────────────────────────────────────────────────────
if [ -n "$MANIFEST" ]; then
  [ -f "$MANIFEST" ] || { jq -n --arg m "$MANIFEST" '{error:"manifest not found under repo-path: \($m)"}'; exit 1; }
  [[ "$(basename "$MANIFEST")" =~ ^(requirements.*\.txt|pyproject\.toml)$ ]] \
    || { jq -n --arg m "$MANIFEST" '{error:"--manifest is for Python requirements*.txt or pyproject.toml, not \($m)"}'; exit 1; }
fi
if [ -z "$MANIFEST" ] && { [ -f "package.json" ] || [ -f "yarn.lock" ] || [ -f "pnpm-lock.yaml" ]; }; then
  fix_npm
elif [ -n "$MANIFEST" ] || [ -f "pyproject.toml" ] || compgen -G "requirements*.txt" >/dev/null; then
  fix_python
elif [ -f "go.mod" ]; then
  fix_go
elif [ -f "pom.xml" ]; then
  # Maven versions live in properties, dependencyManagement and parent POMs;
  # a text edit of pom.xml is not reliable, so this script does not attempt it.
  echo '{"error":"unsupported ecosystem: Maven. Leave the group for a person and report it."}'; exit 1
else
  echo '{"error":"unsupported ecosystem"}'; exit 1
fi

# Output result
TRIMMED_FILES=$(echo "$CHANGED_FILES" | tr -s ' ' | sed 's/^ *//;s/ *$//')
if [ -z "$TRIMMED_FILES" ]; then
  jq -n --arg pkg "$PACKAGE" --arg msg "Package not found in any manifest" \
    '{package:$pkg, status:"no_match", message:$msg}'
else
  local_status="applied"
  [ "$DRY_RUN" = true ] && local_status="dry_run"
  jq -n --arg pkg "$PACKAGE" --arg ver "$TARGET_VERSION" --arg type "$FIX_TYPE" \
    --arg files "$TRIMMED_FILES" --arg st "$local_status" --arg uv "$UV_BIN" --arg resolved "$RESOLVED_JSON" \
    --arg ov "$OVERRIDES_JSON" --arg targets "$TARGETS_CSV" \
    '{package:$pkg, target_version:$ver, fix_type:$type, changed_files:($files | split(" ") | map(select(. != ""))), status:$st}
     + (if ($targets | contains(",")) then {targets:($targets | split(","))} else {} end)
     + (if $ov != "" then {overrides:($ov | fromjson)} else {} end)
     + (if $uv != "" then {uv_bin:$uv} else {} end)
     + (if $resolved != "" then {resolved:($resolved | fromjson)} else {} end)'
fi

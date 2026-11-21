#!/usr/bin/env bash
#
# verify-fix.sh — Deterministic verification of an applied dependency fix.
#
# Usage: verify-fix.sh --repo-path <path> --package <pkg> --patched <version>[,<version>...]
#                      [--advisory GHSA-...]... [--test-command "<cmd>"]
#                      [--skip-tests] [--skip-build] [--skip-audit] [--log-dir <dir>]
#
# Audit: npm uses `npm audit`; pnpm uses `pnpm audit`; yarn uses `yarn audit`
# (yarn 1) or `yarn npm audit --all --recursive` (yarn 2+); Python (uv) asks OSV (GHAS_OSV_API, default
# https://api.osv.dev) about each resolved version. --skip-audit records
# audit.skipped=true; otherwise a Python fix whose audit did not run fails.
#
# Closure: every resolved copy must be at or above the patched version on its
# own release line. Pass one patched version per line when the advisory is
# patched on several (--patched 3.15.1,4.3.1); a copy on a line with none
# passes only when it is newer than all of them.
#
# Build: when the build fails, the merge-base with origin/HEAD is built the
# same way in a throwaway worktree. If the base fails too, the failure is
# recorded as build.preexisting_failure and does not block `pass`; both logs
# (build.log, build-baseline.log) are kept. Tests get no such allowance.
#
# Output (JSON): ecosystem, install, closure, audit, build, tests,
#                changed_files, manifest_only, pass
#
# The target repo's CI is the enforcement; this script exists so the agent has
# evidence before it pushes and so the PR body can show it. It never modifies
# the repo except through the package manager's own install.
set -uo pipefail

REPO_PATH="" PACKAGE="" PATCHED="" TEST_COMMAND="" LOG_DIR=""
SKIP_TESTS=false SKIP_BUILD=false SKIP_AUDIT=false
ADVISORIES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-path) REPO_PATH="${2:?}"; shift 2 ;;
    --package) PACKAGE="${2:?}"; shift 2 ;;
    --patched) PATCHED="${2:?}"; shift 2 ;;
    --advisory) ADVISORIES+=("${2:?}"); shift 2 ;;
    --test-command) TEST_COMMAND="${2:?}"; shift 2 ;;
    --skip-tests) SKIP_TESTS=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --skip-audit) SKIP_AUDIT=true; shift ;;
    --log-dir) LOG_DIR="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$REPO_PATH" ] && [ -n "$PACKAGE" ] && [ -n "$PATCHED" ] || {
  echo "usage: verify-fix.sh --repo-path <path> --package <pkg> --patched <version> [--advisory GHSA-...] [--test-command cmd]" >&2; exit 2; }
[ -d "$REPO_PATH" ] || { echo '{"error":"repo path not found"}'; exit 1; }
command -v jq >/dev/null || { echo '{"error":"jq not installed"}'; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib-uv.sh"
source "$SCRIPT_DIR/lib-pnpm.sh"
source "$SCRIPT_DIR/lib-semver.sh"
OSV_API="${GHAS_OSV_API:-https://api.osv.dev}"

cd "$REPO_PATH"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/ghas-remediate/logs/$(basename "$PWD")}"
mkdir -p "$LOG_DIR"
TIMEOUT="${GHAS_VERIFY_TIMEOUT_SECONDS:-600}"

run() { # name, cmd...  -> sets RUN_EXIT, writes log
  local name="$1"; shift
  if command -v timeout >/dev/null; then
    timeout "$TIMEOUT" "$@" >"$LOG_DIR/$name.log" 2>&1; RUN_EXIT=$?
  else
    "$@" >"$LOG_DIR/$name.log" 2>&1; RUN_EXIT=$?
  fi
}
run_sh() { # name, shell string
  local name="$1"; shift
  if command -v timeout >/dev/null; then
    timeout "$TIMEOUT" bash -lc "$*" >"$LOG_DIR/$name.log" 2>&1; RUN_EXIT=$?
  else
    bash -lc "$*" >"$LOG_DIR/$name.log" 2>&1; RUN_EXIT=$?
  fi
}

ECOSYSTEM="unknown"
PNPM_DIR=""
if [ -f package.json ]; then
  # A pnpm workspace keeps its one lockfile at the workspace root.
  [ -f yarn.lock ] || PNPM_DIR=$(pnpm_lock_dir)
  if [ -n "$PNPM_DIR" ]; then ECOSYSTEM="pnpm"; elif [ -f yarn.lock ]; then ECOSYSTEM="yarn"; else ECOSYSTEM="npm"; fi
elif [ -f uv.lock ] || [ -f pyproject.toml ]; then ECOSYSTEM="python"
fi

# yarn 2+ ("berry", a yarn.lock with __metadata) rejects yarn 1's
# --frozen-lockfile and --ignore-scripts; its equivalents are --immutable and
# --mode=skip-build.
YARN_BERRY=false
YARN_INSTALL=(yarn install --frozen-lockfile --ignore-scripts)
if [ "$ECOSYSTEM" = yarn ] && python3 "$SCRIPT_DIR/yarn_lock.py" berry yarn.lock; then
  YARN_BERRY=true
  YARN_INSTALL=(yarn install --immutable --mode=skip-build)
fi

INSTALL_OK=false; INSTALL_EXIT=null
CLOSURE_OK=false; RESOLVED="[]"
AUDIT_OK=null; AUDIT_TARGET_PRESENT=null; AUDIT_PARSE_OK=false; AUDIT_SOURCE=""
BUILD_RAN=false; BUILD_OK=null; BUILD_BASELINE_OK=null; BUILD_BASE_REF=""; BUILD_PREEXISTING=false
TESTS_RAN=false; TESTS_OK=null; TESTS_CMD=""

case "$ECOSYSTEM" in
  npm|yarn|pnpm)
    case "$ECOSYSTEM" in
      npm)  run install npm ci --ignore-scripts ;;
      yarn) run install "${YARN_INSTALL[@]}" ;;
      pnpm) run install pnpm install --frozen-lockfile --ignore-scripts ;;
    esac
    INSTALL_EXIT=$RUN_EXIT; [ "$RUN_EXIT" -eq 0 ] && INSTALL_OK=true

    # Closure: every resolved copy of the package must be patched on its line.
    if [ "$ECOSYSTEM" = "pnpm" ]; then
      # The frozen install above proved the lockfile is what gets installed, so
      # read it directly; `npm ls` does not understand a pnpm node_modules.
      RESOLVED=$(pnpm_resolved "$PACKAGE" "$PNPM_DIR")
      echo "$RESOLVED" >"$LOG_DIR/ls.log"
    elif [ "$ECOSYSTEM" = "yarn" ]; then
      # Same reasoning for yarn: the immutable install matched yarn.lock, and
      # `npm ls` cannot read a yarn 2+ install.
      RESOLVED=$(python3 "$SCRIPT_DIR/yarn_lock.py" resolved "$PACKAGE" yarn.lock 2>/dev/null || echo "[]")
      echo "$RESOLVED" >"$LOG_DIR/ls.log"
    else
      run ls npm ls "$PACKAGE" --json --all
      RESOLVED=$(jq -c --arg p "$PACKAGE" '[.. | objects | select(has("dependencies")) | .dependencies[$p]? | select(. != null) | .version] | unique' "$LOG_DIR/ls.log" 2>/dev/null || echo "[]")
    fi
    if [ "$(echo "$RESOLVED" | jq 'length')" -gt 0 ]; then
      CLOSURE_OK=true
      while IFS= read -r v; do
        copy_patched "$v" "$PATCHED" || CLOSURE_OK=false
      done < <(echo "$RESOLVED" | jq -r '.[]')
    fi

    # Audit: pass when none of the target advisories appear. Unrelated advisories are reported, not failed.
    if [ "$ECOSYSTEM" = "npm" ] && [ "$SKIP_AUDIT" = false ]; then
      AUDIT_SOURCE="npm audit"
      run audit npm audit --json
      if jq empty "$LOG_DIR/audit.log" 2>/dev/null; then
        AUDIT_PARSE_OK=true
        if [ ${#ADVISORIES[@]} -gt 0 ]; then
          ADV_JSON=$(printf '%s\n' "${ADVISORIES[@]}" | jq -R 'ascii_downcase' | jq -s '.')
          AUDIT_TARGET_PRESENT=$(jq --argjson adv "$ADV_JSON" '
            [.vulnerabilities // {} | .[] | .via[]? | objects | ((.url // "") + " " + (.source // "" | tostring) + " " + (.title // "")) | ascii_downcase] as $hay
            | ($adv | any(. as $a | $hay | any(contains($a))))' "$LOG_DIR/audit.log")
          [ "$AUDIT_TARGET_PRESENT" = "false" ] && AUDIT_OK=true || AUDIT_OK=false
        else
          AUDIT_OK=true
        fi
      else
        AUDIT_OK=false
      fi
    elif [ "$ECOSYSTEM" = "pnpm" ] && [ "$SKIP_AUDIT" = false ]; then
      # `pnpm audit` exits non-zero when it finds anything; only its JSON matters.
      # A registry failure yields {"error": ...}, which counts as "did not run".
      AUDIT_SOURCE="pnpm audit"
      # stdout only: a warning on stderr must not corrupt the JSON.
      if command -v timeout >/dev/null; then
        (cd "$PNPM_DIR" && timeout "$TIMEOUT" pnpm audit --json) >"$LOG_DIR/audit.log" 2>"$LOG_DIR/audit.err"
      else
        (cd "$PNPM_DIR" && pnpm audit --json) >"$LOG_DIR/audit.log" 2>"$LOG_DIR/audit.err"
      fi
      if jq -e 'type == "object" and (has("error") | not)' "$LOG_DIR/audit.log" >/dev/null 2>&1; then
        AUDIT_PARSE_OK=true
        if [ ${#ADVISORIES[@]} -gt 0 ]; then
          ADV_JSON=$(printf '%s\n' "${ADVISORIES[@]}" | jq -R 'ascii_downcase' | jq -s '.')
          AUDIT_TARGET_PRESENT=$(jq --argjson adv "$ADV_JSON" '
            [.advisories // {} | .[] | ((.github_advisory_id // "") + " " + (.url // "") + " " + ((.cves // []) | join(" "))) | ascii_downcase] as $hay
            | ($adv | any(. as $a | $hay | any(contains($a))))' "$LOG_DIR/audit.log")
          [ "$AUDIT_TARGET_PRESENT" = "false" ] && AUDIT_OK=true || AUDIT_OK=false
        else
          AUDIT_OK=true
        fi
      else
        AUDIT_OK=false
      fi
    elif [ "$ECOSYSTEM" = "yarn" ] && [ "$SKIP_AUDIT" = false ]; then
      # Both print one JSON object per line and exit non-zero when they find
      # anything, so the exit code alone says nothing. The audit ran when
      # every line is JSON and: yarn 1 printed its auditSummary; yarn 2+
      # exited 0 (nothing found) or printed at least one advisory.
      if [ "$YARN_BERRY" = true ]; then
        AUDIT_SOURCE="yarn npm audit"; AUDIT_CMD=(yarn npm audit --all --recursive --json)
      else
        AUDIT_SOURCE="yarn audit"; AUDIT_CMD=(yarn audit --json)
      fi
      if command -v timeout >/dev/null; then
        timeout "$TIMEOUT" "${AUDIT_CMD[@]}" >"$LOG_DIR/audit.log" 2>"$LOG_DIR/audit.err"
      else
        "${AUDIT_CMD[@]}" >"$LOG_DIR/audit.log" 2>"$LOG_DIR/audit.err"
      fi
      AUDIT_EXIT=$?
      if jq -se --argjson berry "$YARN_BERRY" --argjson rc "$AUDIT_EXIT" '
           if $berry then ($rc == 0 or any(.[]; type == "object" and has("children")))
           else (any(.[]; .type? == "auditSummary") and (any(.[]; .type? == "error") | not)) end'            "$LOG_DIR/audit.log" >/dev/null 2>&1; then
        AUDIT_PARSE_OK=true
        if [ ${#ADVISORIES[@]} -gt 0 ]; then
          ADV_JSON=$(printf '%s\n' "${ADVISORIES[@]}" | jq -R 'ascii_downcase' | jq -s '.')
          AUDIT_TARGET_PRESENT=$(jq -s --argjson adv "$ADV_JSON" '
            [.. | strings | ascii_downcase] as $hay | ($adv | any(. as $a | $hay | any(contains($a))))' "$LOG_DIR/audit.log")
          [ "$AUDIT_TARGET_PRESENT" = "false" ] && AUDIT_OK=true || AUDIT_OK=false
        else
          AUDIT_OK=true
        fi
      else
        AUDIT_OK=false
      fi
    fi

    if [ "$SKIP_BUILD" = false ] && [ "$(jq -r '.scripts.build // empty' package.json)" != "" ]; then
      BUILD_RAN=true
      case "$ECOSYSTEM" in npm) run build npm run build ;; yarn) run build yarn build ;; pnpm) run build pnpm build ;; esac
      [ "$RUN_EXIT" -eq 0 ] && BUILD_OK=true || BUILD_OK=false
      # A failing build only blocks the fix if the base commit builds. Rebuild the
      # base the same way (same install flags) in a throwaway worktree to tell.
      if [ "$BUILD_OK" = false ]; then
        BUILD_BASE_REF=$(git merge-base HEAD "$(git rev-parse --verify -q origin/HEAD || echo HEAD)" 2>/dev/null || true)
        if [ -n "$BUILD_BASE_REF" ]; then
          SUBDIR=$(git rev-parse --show-prefix)
          BASE_WT=$(mktemp -d "${TMPDIR:-/tmp}/ghas-verify-base.XXXXXX")
          if git worktree add -q --detach "$BASE_WT" "$BUILD_BASE_REF" >"$LOG_DIR/build-baseline.log" 2>&1; then
            (
              cd "$BASE_WT/$SUBDIR" || exit 1
              case "$ECOSYSTEM" in
                npm)  npm ci --ignore-scripts && npm run build ;;
                yarn) "${YARN_INSTALL[@]}" && yarn build ;;
                pnpm) pnpm install --frozen-lockfile --ignore-scripts && pnpm build ;;
              esac
            ) >>"$LOG_DIR/build-baseline.log" 2>&1
            [ $? -eq 0 ] && BUILD_BASELINE_OK=true || BUILD_BASELINE_OK=false
            git worktree remove --force "$BASE_WT" >/dev/null 2>&1 || rm -rf "$BASE_WT"
          fi
          [ "$BUILD_BASELINE_OK" = false ] && BUILD_PREEXISTING=true
        fi
      fi
    fi

    if [ "$SKIP_TESTS" = false ]; then
      if [ -n "$TEST_COMMAND" ]; then
        TESTS_CMD="$TEST_COMMAND"
      else
        TS=$(jq -r '.scripts.test // empty' package.json)
        if [ -n "$TS" ] && ! echo "$TS" | grep -q "no test specified"; then
          case "$ECOSYSTEM" in npm) TESTS_CMD="npm test" ;; yarn) TESTS_CMD="yarn test" ;; pnpm) TESTS_CMD="pnpm test" ;; esac
        fi
      fi
      if [ -n "$TESTS_CMD" ]; then
        TESTS_RAN=true; run_sh tests "$TESTS_CMD"
        [ "$RUN_EXIT" -eq 0 ] && TESTS_OK=true || TESTS_OK=false
      fi
    fi
    ;;

  python)
    # Pick the first runnable uv that agrees the lock matches pyproject.toml.
    # `uv lock --check` failing for every candidate means the lock is stale.
    UV_BIN=""
    if [ -f uv.lock ]; then
      : >"$LOG_DIR/lock-check.log"
      while IFS= read -r c; do
        if "$c" lock --check >>"$LOG_DIR/lock-check.log" 2>&1; then UV_BIN="$c"; break; fi
        echo "lock --check failed with $c" >>"$LOG_DIR/lock-check.log"
      done < <(uv_working_candidates)
    fi
    if [ -n "$UV_BIN" ]; then
      run install "$UV_BIN" sync --frozen; INSTALL_EXIT=$RUN_EXIT; [ "$RUN_EXIT" -eq 0 ] && INSTALL_OK=true
      RESOLVED=$(python3 - "$PACKAGE" <<'PY' 2>/dev/null || echo "[]"
import sys, tomllib
pkg = sys.argv[1].lower().replace("_", "-")
with open("uv.lock", "rb") as f:
    lock = tomllib.load(f)
print(__import__("json").dumps(sorted({p["version"] for p in lock.get("package", []) if p.get("name", "").lower().replace("_", "-") == pkg})))
PY
)
      if [ "$(echo "$RESOLVED" | jq 'length')" -gt 0 ]; then
        CLOSURE_OK=true
        while IFS= read -r v; do copy_patched "$v" "$PATCHED" || CLOSURE_OK=false; done < <(echo "$RESOLVED" | jq -r '.[]')
      fi
    elif [ -f uv.lock ]; then
      echo "python: no runnable uv passed 'uv lock --check' (stale lock, or uv unavailable); see lock-check.log" >"$LOG_DIR/install.log"
    else
      echo "python: no uv.lock; install/closure not verified" >"$LOG_DIR/install.log"
    fi

    # Audit: ask OSV which advisories affect each resolved version of the package.
    # A Python fix only passes when this ran clean (or --skip-audit was explicit).
    if [ "$SKIP_AUDIT" = false ] && [ "$(echo "$RESOLVED" | jq 'length')" -gt 0 ]; then
      AUDIT_SOURCE="osv"; AUDIT_PARSE_OK=true; FOUND="[]"
      : >"$LOG_DIR/audit.log"
      while IFS= read -r v; do
        body=$(jq -nc --arg n "$PACKAGE" --arg v "$v" '{package:{name:$n, ecosystem:"PyPI"}, version:$v}')
        if ! resp=$(curl -fsS --max-time 30 -H 'Content-Type: application/json' -d "$body" "$OSV_API/v1/query" 2>>"$LOG_DIR/audit.log"); then
          AUDIT_PARSE_OK=false; break
        fi
        printf '%s %s\n' "$v" "$resp" >>"$LOG_DIR/audit.log"
        ids=$(echo "$resp" | jq -c '[.vulns[]? | ([.id] + (.aliases // []))[] | ascii_downcase]' 2>/dev/null) \
          || { AUDIT_PARSE_OK=false; break; }
        FOUND=$(jq -cn --argjson a "$FOUND" --argjson b "$ids" '$a + $b | unique')
      done < <(echo "$RESOLVED" | jq -r '.[]')
      if [ "$AUDIT_PARSE_OK" = true ]; then
        if [ ${#ADVISORIES[@]} -gt 0 ]; then
          ADV_JSON=$(printf '%s\n' "${ADVISORIES[@]}" | jq -R 'ascii_downcase' | jq -s '.')
          AUDIT_TARGET_PRESENT=$(jq -n --argjson adv "$ADV_JSON" --argjson f "$FOUND" '$adv | any(. as $a | $f | index($a) != null)')
        else
          AUDIT_TARGET_PRESENT=$(jq -n --argjson f "$FOUND" '$f | length > 0')
        fi
        [ "$AUDIT_TARGET_PRESENT" = "false" ] && AUDIT_OK=true || AUDIT_OK=false
      else
        AUDIT_OK=false
      fi
    fi
    [ "$SKIP_AUDIT" = false ] && [ "$AUDIT_OK" = null ] && AUDIT_OK=false

    if [ "$SKIP_TESTS" = false ] && [ -n "$TEST_COMMAND" ]; then
      TESTS_RAN=true; TESTS_CMD="$TEST_COMMAND"
      # Put the chosen uv first on PATH so `uv run ...` in the test command avoids a blocked mise shim.
      if [ -n "$UV_BIN" ]; then
        run_sh tests "export PATH=$(printf '%q' "$(dirname "$UV_BIN")"):\$PATH; $TEST_COMMAND"
      else
        run_sh tests "$TEST_COMMAND"
      fi
      [ "$RUN_EXIT" -eq 0 ] && TESTS_OK=true || TESTS_OK=false
    fi
    ;;
esac

# Restore anything the install touched that is tracked (e.g. a committed node_modules) so the diff is honest.
git restore -- node_modules .venv 2>/dev/null || true
git clean -fdq -- node_modules .venv 2>/dev/null || true

CHANGED=$(git status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n' | sed -n 's/^.. //p' | jq -R . | jq -s 'unique')
MANIFEST_ONLY=$(echo "$CHANGED" | jq 'all(test("(^|/)(package\\.json|package-lock\\.json|npm-shrinkwrap\\.json|yarn\\.lock|pnpm-lock\\.yaml|pnpm-workspace\\.yaml|pyproject\\.toml|uv\\.lock|poetry\\.lock|requirements[^/]*\\.txt|go\\.mod|go\\.sum|pom\\.xml|Gemfile|Gemfile\\.lock)$"))')

PASS=false
if [ "$INSTALL_OK" = true ] && [ "$CLOSURE_OK" = true ] \
   && [ "$AUDIT_OK" != "false" ] && { [ "$BUILD_OK" != "false" ] || [ "$BUILD_PREEXISTING" = true ]; } \
   && [ "$TESTS_OK" != "false" ]; then
  PASS=true
fi

jq -n \
  --arg ecosystem "$ECOSYSTEM" --arg package "$PACKAGE" --arg patched "$PATCHED" --arg log_dir "$LOG_DIR" \
  --argjson install_ok "$INSTALL_OK" --argjson install_exit "$INSTALL_EXIT" \
  --argjson closure_ok "$CLOSURE_OK" --argjson resolved "$RESOLVED" \
  --argjson audit_ok "$AUDIT_OK" --argjson audit_target_present "$AUDIT_TARGET_PRESENT" --argjson audit_parse_ok "$AUDIT_PARSE_OK" \
  --arg audit_source "$AUDIT_SOURCE" --argjson audit_skipped "$SKIP_AUDIT" --arg uv_bin "${UV_BIN:-}" \
  --argjson build_ran "$BUILD_RAN" --argjson build_ok "$BUILD_OK" \
  --argjson build_baseline_ok "$BUILD_BASELINE_OK" --argjson build_preexisting "$BUILD_PREEXISTING" --arg build_base "$BUILD_BASE_REF" \
  --argjson tests_ran "$TESTS_RAN" --argjson tests_ok "$TESTS_OK" --arg tests_cmd "$TESTS_CMD" \
  --argjson changed "$CHANGED" --argjson manifest_only "$MANIFEST_ONLY" --argjson pass "$PASS" '
  {
    ecosystem: $ecosystem, package: $package, patched: $patched, log_dir: $log_dir,
    install: {ok: $install_ok, exit: $install_exit},
    closure: {ok: $closure_ok, resolved: $resolved},
    audit: {ok: $audit_ok, target_present: $audit_target_present, parse_ok: $audit_parse_ok,
            source: (if $audit_source == "" then null else $audit_source end), skipped: $audit_skipped},
    build: {ran: $build_ran, ok: $build_ok, baseline_ok: $build_baseline_ok,
            preexisting_failure: $build_preexisting, base: (if $build_base == "" then null else $build_base end)},
    tests: {ran: $tests_ran, ok: $tests_ok, command: (if $tests_cmd == "" then null else $tests_cmd end)},
    changed_files: $changed, manifest_only: $manifest_only, pass: $pass
  } + (if $uv_bin != "" then {uv_bin: $uv_bin} else {} end)'

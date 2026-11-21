#!/usr/bin/env bash
# lib-uv.sh — locate a usable uv binary for Python (uv) remediation.
#
# Why: a fresh clone's .mise.toml is untrusted, so a mise `uv` shim on PATH
# refuses to run inside it; and the uv version a repo pins may write an older
# uv.lock `revision` than the one committed, which churns the whole lockfile.
# Callers try candidates in order and keep the first one that both runs and
# leaves the lock format alone. Source this file after `cd` into the project.
#
# Override with GHAS_UV=/path/to/uv (tried first).

# All candidate paths, most preferred first. May contain duplicates or
# non-existent paths; uv_working_candidates filters them.
uv_candidates() {
  [ -n "${GHAS_UV:-}" ] && printf '%s\n' "$GHAS_UV"
  type -ap uv 2>/dev/null
  printf '%s\n' /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv"
  # mise-managed installs, called directly (not via the shim), newest first.
  ls -d "$HOME"/.local/share/mise/installs/uv/*/uv-*/uv "$HOME"/.local/share/mise/installs/uv/*/uv 2>/dev/null | sort -r
}

# Candidates that exist, are executable, and run in the current directory.
uv_working_candidates() {
  local seen=" " c
  while IFS= read -r c; do
    [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ] || continue
    case "$seen" in *" $c "*) continue ;; esac
    seen="$seen$c "
    "$c" --version >/dev/null 2>&1 || continue
    printf '%s\n' "$c"
  done < <(uv_candidates)
}

# Print the `revision = N` header of a uv.lock (empty if absent).
uv_lock_revision() {
  sed -n 's/^revision = \([0-9][0-9]*\)[[:space:]]*$/\1/p' "${1:-uv.lock}" 2>/dev/null | head -1
}

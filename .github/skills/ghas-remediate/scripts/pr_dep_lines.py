#!/usr/bin/env python3
"""Which added lines in a PR diff change a given package's dependency entry?

Usage: gh pr diff N | pr_dep_lines.py <package> [--dir <manifest dir>]
Prints a JSON array (max 10) of added lines that change the package.

--dir limits it to files in the alert's manifest directory or an ancestor of
it (a workspace root lockfile). A sibling (service-a/ for a service-b/ alert) is
another service's dependency and does not count.

- Manifests (package.json, pyproject.toml, requirements*.txt, go.mod, go.sum,
  pom.xml, Gemfile, Cargo.toml, ...): an added line that names the package.
- Lockfiles (package-lock.json, yarn.lock, pnpm-lock.yaml, uv.lock,
  poetry.lock, Gemfile.lock, Cargo.lock): an added line inside the package's
  OWN entry, i.e. within a few lines after that entry's header. A mention as
  someone else's dependency (axios's "follow-redirects": "^1.15.6") does not
  count, so an unrelated parent bump does not look like a fix.
"""
import json
import re
import sys

MANIFEST = re.compile(r"(^|/)(package\.json|npm-shrinkwrap\.json|pnpm-workspace\.yaml|pyproject\.toml|Pipfile|requirements[^/]*\.txt|"
                      r"setup\.cfg|setup\.py|go\.mod|go\.sum|pom\.xml|build\.gradle(\.kts)?|Gemfile|Cargo\.toml)$")
LOCKFILE = re.compile(r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|uv\.lock|poetry\.lock|Pipfile\.lock|"
                      r"Gemfile\.lock|Cargo\.lock)$")
PY_FILE = re.compile(r"(^|/)(pyproject\.toml|Pipfile(\.lock)?|requirements[^/]*\.txt|setup\.(cfg|py)|uv\.lock|poetry\.lock)$")

# Lockfile entry headers; group 1 is the package name.
HEADERS = [
    re.compile(r'"(?:[^"]*/)?node_modules/((?:@[^/"]+/)?[^/"]+)"\s*:\s*\{'),  # package-lock.json
    re.compile(r'^\s*name\s*=\s*"([^"]+)"'),                                  # uv.lock, poetry.lock, Cargo.lock
    re.compile(r'^"?((?:@[^/@\s"]+/)?[^@\s"]+)@'),                            # yarn.lock (unindented key)
    re.compile(r'^\s+/?((?:@[^/@\s]+/)?[^@\s/]+)@[^\s]*:\s*$'),               # pnpm-lock.yaml packages key
    re.compile(r'^ {4}(\S+) \('),                                             # Gemfile.lock spec
]
ENTRY_SPAN = 6  # lines after a header that still belong to its entry's version fields


def norm(name, python):
    name = name.lower()
    return re.sub(r"[-_.]+", "-", name) if python else name


def in_scope(path, mdir):
    """path is in mdir or in one of its ancestors ("" is the repo root)."""
    if mdir is None:
        return True
    d = path.rsplit("/", 1)[0] if "/" in path else ""
    return d == mdir or d == "" or mdir.startswith(d + "/")


def norm_dir(d):
    d = d.strip().strip("/")
    return "" if d in ("", ".") else d


def main():
    pkg_raw = sys.argv[1]
    mdir = norm_dir(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--dir" else None
    out, kind, python, since = [], None, False, 99
    for raw in sys.stdin.read().splitlines():
        if raw.startswith("diff --git "):
            path = raw.split(" b/", 1)[-1]
            kind = "lock" if LOCKFILE.search(path) else "manifest" if MANIFEST.search(path) else None
            if not in_scope(path, mdir):
                kind = None
            python = bool(PY_FILE.search(path))
            pkg = norm(pkg_raw, python)
            # "@<range>" after the name is a version-scoped override key
            # ("js-yaml@^3"); "@" followed by anything else is another name.
            boundary = re.compile(r"(^|[^a-z0-9@/._-])" + re.escape(pkg) + r"($|[^a-z0-9@/._-]|@[\^~<>=*0-9])")
            since = 99
            continue
        if kind is None or raw.startswith(("+++", "---", "\\")):
            continue
        if raw.startswith("@@"):
            since = 99
            continue
        line = raw[1:]
        added = raw.startswith("+")
        if kind == "manifest":
            text = norm(line, python) if python else line.lower()
            if added and boundary.search(text):
                out.append(line.strip())
            continue
        header = next((m.group(1) for h in HEADERS if (m := h.search(line))), None)
        if header is not None:
            since = 0 if norm(header, python) == pkg else 99
            if since == 0 and added:
                out.append(line.strip())
            continue
        since += 1
        if added and since <= ENTRY_SPAN:
            out.append(line.strip())
    print(json.dumps(out[:10]))


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read or bump one package's requirement in requirements*.txt or pyproject.toml.

Usage:
  py_spec.py current <package> <file>...         print each pinned/lower-bound version, one per line
  py_spec.py bump <package> <version> <file>      rewrite the requirement in place

Names match per PEP 503 (case, `-`, `_` and `.` are equivalent), and extras
are kept: `PyJWT[crypto]==2.8.0` and `pyjwt[crypto]>=2.8` both match `pyjwt`.

bump keeps the operator when the first clause is ==, ~= or >=, and writes
>= otherwise (or when there is no version). Later clauses (`,<3`) and
environment markers (`; python_version < "3.12"`) are kept. Exit 0 when a
line changed, 1 when the package is not in the file.

pyproject.toml: only quoted PEP 508 strings are edited ([project]
dependencies, optional-dependencies, [dependency-groups]). Poetry's
`name = "^1.2"` tables are not.
"""
import re
import sys

NAME = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"
# name, extras, specifier (up to a marker, comment or quote), rest
REQ = re.compile(rf"^(\s*)({NAME})(\s*\[[^\]]*\])?(\s*)([^;#\"']*?)(\s*(?:[;#].*)?)$")
QUOTED = re.compile(r"""(["'])([^"'\n]+)\1""")
CLAUSE = re.compile(r"^(===|==|~=|>=|<=|!=|>|<)\s*([^\s,]+)")


def norm(n):
    return re.sub(r"[-_.]+", "-", n).lower()


def parse(text, pkg):
    m = REQ.match(text)
    # "name @ url" is a direct reference: no version to bump.
    if m and norm(m.group(2)) == norm(pkg) and not m.group(5).strip().startswith("@"):
        return m
    return None


# A `key = "value"` line in pyproject.toml (name, version, requires-python…)
# is not a requirement; `key = [ ... ]` and array items are.
# The "=" must not start "==": "dnspython==2.9.0" is a requirement, not a key.
SCALAR = re.compile(r"""^\s*[\w."'-]+\s*=(?!=)\s*[^\[\s=]""")


def texts(path, line):
    if requirements_lines(path):
        return [line]
    if SCALAR.match(line):
        return []
    return [q[1] for q in QUOTED.findall(line)]


def current(m):
    c = CLAUSE.match(m.group(5).strip())
    return c.group(2) if c and c.group(1) in ("==", "~=", ">=", "===") else None


def bumped(m, version):
    spec = m.group(5).strip()
    c = CLAUSE.match(spec)
    if c and c.group(1) in ("==", "~=", ">="):
        new = c.group(1) + version + spec[c.end():]
    elif c:
        rest = spec[c.end():].lstrip()
        new = ">=" + version + ("," + rest.lstrip(",").lstrip() if rest else "")
    else:
        new = ">=" + version
    return m.group(1) + m.group(2) + (m.group(3) or "") + new + m.group(6)


def requirements_lines(path):
    return path.endswith(".txt")


def main():
    op = sys.argv[1] if len(sys.argv) > 1 else ""
    if op == "current" and len(sys.argv) >= 4:
        pkg = sys.argv[2]
        for path in sys.argv[3:]:
            for line in open(path).read().splitlines():
                for t in texts(path, line):
                    m = parse(t, pkg)
                    if m and current(m):
                        print(current(m))
        return 0
    if op == "bump" and len(sys.argv) == 5:
        pkg, version, path = sys.argv[2:5]
        out, changed = [], False
        for line in open(path).read().splitlines(keepends=True):
            body, nl = (line[:-1], "\n") if line.endswith("\n") else (line, "")
            if requirements_lines(path):
                m = parse(body, pkg)
                if m:
                    body, changed = bumped(m, version), True
            elif not SCALAR.match(body):
                def sub(q):
                    nonlocal changed
                    m = parse(q.group(2), pkg)
                    if not m:
                        return q.group(0)
                    changed = True
                    return q.group(1) + bumped(m, version) + q.group(1)
                body = QUOTED.sub(sub, body)
            out.append(body + nl)
        if changed:
            open(path, "w").write("".join(out))
        return 0 if changed else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

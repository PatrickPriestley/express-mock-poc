#!/usr/bin/env python3
"""Add or update one entry in pyproject.toml's [tool.uv] constraint-dependencies.

Usage: uv_constraint.py <pyproject.toml> <package> <specifier>
  e.g. uv_constraint.py pyproject.toml dnspython '>=2.9.0'

Edits the text in place so comments and formatting elsewhere survive:
- an existing entry for the package (PEP 503 name match) is replaced;
- otherwise the entry is appended to the array, matching its indentation;
- a missing key is added under [tool.uv]; a missing table is appended.
Prints "updated" or "added". Exits non-zero, file untouched, on any doubt.
"""
import re
import sys

KEY = "constraint-dependencies"


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def req_name(req):
    m = re.match(r"\s*([A-Za-z0-9][A-Za-z0-9._-]*)", req)
    return norm(m.group(1)) if m else None


def array_span(text, start):
    """Given the index of '[' that opens an array, return index just past its ']'."""
    depth, i, n = 0, start, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            triple = text[i:i + 3] == c * 3
            q = c * 3 if triple else c
            i += len(q)
            while i < n and text[i:i + len(q)] != q:
                i += 2 if (c == '"' and text[i] == "\\") else 1
            i += len(q)
            continue
        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unterminated array")


def edit(text, pkg, spec):
    entry = f'"{pkg}{spec}"'
    lines = text.split("\n")
    hdr = next((i for i, l in enumerate(lines) if l.strip() == "[tool.uv]"), None)
    if hdr is None:
        sep = "" if text.endswith("\n") else "\n"
        return text + f"{sep}\n[tool.uv]\n{KEY} = [\n    {entry},\n]\n", "added"

    offsets = [0]
    for l in lines:
        offsets.append(offsets[-1] + len(l) + 1)
    end = next((i for i in range(hdr + 1, len(lines)) if re.match(r"\s*\[", lines[i])), len(lines))
    key = next((i for i in range(hdr + 1, end) if re.match(rf"\s*{re.escape(KEY)}\s*=", lines[i])), None)
    if key is None:
        lines.insert(hdr + 1, f"{KEY} = [\n    {entry},\n]")
        return "\n".join(lines), "added"

    open_idx = text.index("[", offsets[key])
    close_idx = array_span(text, open_idx)  # just past ']'
    body = text[open_idx + 1:close_idx - 1]

    literals = [(m.start(), m.end(), m.group(2)) for m in re.finditer(r"([\"'])((?:(?!\1).)*)\1", body)]
    for s, e, val in literals:
        if req_name(val) == norm(pkg):
            new_body = body[:s] + entry + body[e:]
            return text[:open_idx + 1] + new_body + text[close_idx - 1:], "updated"

    if not literals:
        new_body = f"\n    {entry},\n"
    elif "\n" not in body:
        s, e, _ = literals[-1]
        new_body = body[:e] + f", {entry}" + body[e:]
    else:
        s, e, _ = literals[-1]
        rest = body[e:]
        if not re.match(r"\s*,", rest):
            body = body[:e] + "," + rest
            e += 1
        else:
            comma = rest.index(",")
            e += comma + 1
        line_start = body.rfind("\n", 0, s) + 1
        indent = re.match(r"[ \t]*", body[line_start:]).group(0) or "    "
        line_end = body.find("\n", e)
        line_end = len(body) if line_end == -1 else line_end
        new_body = body[:line_end] + f"\n{indent}{entry}," + body[line_end:]
    return text[:open_idx + 1] + new_body + text[close_idx - 1:], "added"


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    path, pkg, spec = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", pkg) or not re.fullmatch(r"(==|>=)[A-Za-z0-9._+-]+", spec):
        sys.exit("invalid package or specifier")
    text = open(path, encoding="utf-8").read()
    new, action = edit(text, pkg, spec)
    try:
        import tomllib
    except ImportError:  # Python < 3.11: skip the parse check
        tomllib = None
    if tomllib:
        data = tomllib.loads(new)
        got = data.get("tool", {}).get("uv", {}).get(KEY, [])
        if f"{pkg}{spec}" not in got:
            sys.exit(f"edit did not produce {pkg}{spec} in [tool.uv].{KEY}; file untouched")
        if sum(1 for r in got if req_name(r) == norm(pkg)) != 1:
            sys.exit(f"{pkg} appears more than once in [tool.uv].{KEY}; file untouched")
    open(path, "w", encoding="utf-8").write(new)
    print(action)


if __name__ == "__main__":
    main()

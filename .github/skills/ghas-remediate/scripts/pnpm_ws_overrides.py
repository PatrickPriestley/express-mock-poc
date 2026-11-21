#!/usr/bin/env python3
"""Edit the top-level `overrides:` map of a pnpm-workspace.yaml in place.

Usage:
  pnpm_ws_overrides.py set <file> <key> <value>   add or replace one entry
  pnpm_ws_overrides.py del <file> <key>           remove one entry (no-op if absent)

pnpm 11 reads overrides only from pnpm-workspace.yaml. This is a line edit,
not a YAML round trip, so comments and the rest of the file stay as they
are. It handles the block form pnpm writes:

  overrides:
    follow-redirects: 1.15.6
    'js-yaml@^3': ^3.15.1

and refuses a flow map (`overrides: {...}`) or anything else it cannot
edit safely, exiting 2 so the caller can leave it to a person. The file is
created when it does not exist (pnpm accepts a settings-only workspace file).
"""
import os
import re
import sys

KEY_LINE = re.compile(r"""^(\s+)(['"]?)(.+?)\2\s*:(\s.*)?$""")


def quote(s):
    return s if re.fullmatch(r"[A-Za-z0-9_./-]+", s) else "'" + s.replace("'", "''") + "'"


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("set", "del"):
        print(__doc__, file=sys.stderr)
        return 2
    op, path, key = sys.argv[1], sys.argv[2], sys.argv[3]
    value = sys.argv[4] if op == "set" else None
    lines = open(path).read().splitlines() if os.path.exists(path) else []

    start = next((i for i, l in enumerate(lines) if re.match(r"^overrides\s*:", l)), None)
    if start is not None and lines[start].split(":", 1)[1].split("#", 1)[0].strip():
        print("overrides is not a block map; edit it by hand", file=sys.stderr)
        return 2

    if start is None:
        if op == "del":
            return 0
        if lines and lines[-1].strip():
            lines.append("")
        lines += ["overrides:", f"  {quote(key)}: {quote(value)}"]
    else:
        end, indent, hit = start + 1, "  ", None
        while end < len(lines) and (not lines[end].strip() or lines[end][0] in " \t"):
            m = KEY_LINE.match(lines[end])
            if m:
                indent = m.group(1)
                if m.group(3) == key:
                    hit = end
            end += 1
        if op == "del":
            if hit is None:
                return 0
            del lines[hit]
            end -= 1
            # Drop the `overrides:` line when the block is now empty; blank
            # lines that were inside it stay, as separators.
            if not any(l.strip() for l in lines[start + 1:end]):
                del lines[start]
        else:
            entry = f"{indent}{quote(key)}: {quote(value)}"
            if hit is not None:
                lines[hit] = entry
            else:
                last = end
                while last > start + 1 and not lines[last - 1].strip():
                    last -= 1
                lines.insert(last, entry)

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

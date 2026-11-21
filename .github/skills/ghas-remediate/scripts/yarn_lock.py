#!/usr/bin/env python3
"""Read a yarn.lock (yarn 1 or yarn 2+ "berry").

Usage:
  yarn_lock.py resolved <package> <yarn.lock>   JSON array of the versions it resolves
  yarn_lock.py berry <yarn.lock>                exit 0 when the lock is yarn 2+

An entry header is an unindented line of comma-separated descriptors:
  yarn 1:  csv-parse@^5.0.0, "csv-parse@^5.5.0":   then   version "5.6.0"
  berry:   "csv-parse@npm:^5.0.0, csv-parse@npm:^5.5.0":   then   version: 5.6.0
A descriptor names the package when the text before its range "@" is the name
(scoped names keep their leading "@"). Aliases ("foo@npm:bar@1") count as foo,
the name the dependency tree sees; the version is the one the entry installs.
"""
import json
import re
import sys

VERSION = re.compile(r'^\s+version:?\s+"?([^"\s]+)"?\s*$')


def names(header):
    out = set()
    for d in header.rstrip().rstrip(":").split(","):
        d = d.strip().strip('"')
        at = d.find("@", 1)  # skip a scope's leading "@"
        if at > 0:
            out.add(d[:at])
    return out


def resolved(pkg, path):
    found, current = set(), False
    for line in open(path, encoding="utf-8"):
        if not line.strip() or line.startswith("#"):
            continue
        if not line[0].isspace():
            current = pkg in names(line)
            continue
        if current:
            m = VERSION.match(line)
            if m:
                found.add(m.group(1))
                current = False
    return sorted(found)


def is_berry(path):
    return any(l.startswith("__metadata:") for l in open(path, encoding="utf-8"))


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "resolved":
        print(json.dumps(resolved(sys.argv[2], sys.argv[3])))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "berry":
        return 0 if is_berry(sys.argv[2]) else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Read facts from a pnpm-lock.yaml without a YAML parser.

Usage:
  pnpm_lock.py resolved <package> [lockfile]   JSON array of resolved versions
  pnpm_lock.py version [lockfile]              the lockfileVersion value

Package keys under `packages:` and `snapshots:` across lockfile versions:
  v9    lodash@4.17.21          '@scope/pkg@1.2.3(peer@1.0.0)'
  v6-8  /lodash@4.17.21         /@scope/pkg@1.2.3(peer@1.0.0)
  v5    /lodash/4.17.21         /@scope/pkg/1.2.3_peer@1.0.0
"""
import json
import re
import sys


def entry_keys(text):
    section = None
    for line in text.splitlines():
        if re.match(r"^[A-Za-z]", line):
            section = line.split(":", 1)[0]
            continue
        if section not in ("packages", "snapshots"):
            continue
        m = re.match(r"^  (?! )(.+)$", line)
        if not m:
            continue
        body = m.group(1)
        if body[0] in "'\"":
            end = body.find(body[0], 1)
            if end < 0:
                continue
            key = body[1:end]
        else:
            m2 = re.match(r"^(.*?):(\s|$)", body)
            if not m2:
                continue
            key = m2.group(1)
        yield key


NAME = r"((?:@[^/@]+/)?[^/@]+)"


def split_key(key):
    key = key.lstrip("/").split("(", 1)[0]
    m = re.match("^" + NAME + r"@(.+)$", key)       # v6+: name@version
    if m:
        return m.group(1), m.group(2)
    m = re.match("^" + NAME + r"/([^_/]+)", key)     # v5: name/version[_peers]
    if m:
        return m.group(1), m.group(2)
    return key, ""


def main():
    cmd = sys.argv[1]
    if cmd == "version":
        path = sys.argv[2] if len(sys.argv) > 2 else "pnpm-lock.yaml"
        m = re.search(r"^lockfileVersion:\s*['\"]?([^'\"\s]+)", open(path).read(), re.M)
        print(m.group(1) if m else "")
        return
    pkg = sys.argv[2]
    path = sys.argv[3] if len(sys.argv) > 3 else "pnpm-lock.yaml"
    versions = {v for n, v in map(split_key, entry_keys(open(path).read())) if n == pkg and v}
    print(json.dumps(sorted(versions)))


if __name__ == "__main__":
    main()

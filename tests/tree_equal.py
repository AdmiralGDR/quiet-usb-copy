#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AdmiralGDR
#
"""Compare two directory trees without following symlinks or other filesystems.

Filenames are hex-encoded so newlines and odd bytes stay on one manifest line.
This helper is for tests only. Quiet USB Copy does not use Python.
"""

import hashlib
import os
import stat
import sys


def esc(text):
    return os.fsencode(text).hex()


def walk(root):
    root = os.path.abspath(root)
    root_dev = os.lstat(root).st_dev
    rows = []

    def rec(path):
        rel = os.path.relpath(path, root)
        if rel == ".":
            rel = ""
        st = os.lstat(path)
        mode = st.st_mode
        if rel and stat.S_ISLNK(mode):
            rows.append("L\t%s\t%s" % (esc(rel), esc(os.readlink(path))))
            return
        if rel and stat.S_ISREG(mode):
            digest = hashlib.sha256()
            with open(path, "rb") as handle:
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
            rows.append("F\t%s\t%s" % (esc(rel), digest.hexdigest()))
            return
        if rel and not stat.S_ISDIR(mode):
            rows.append("S\t%s\t%o" % (esc(rel), mode & 0o170000))
            return
        if rel:
            if st.st_dev != root_dev:
                rows.append("M\t%s" % esc(rel))
                return
            rows.append("D\t%s" % esc(rel))
        if stat.S_ISDIR(mode) and not stat.S_ISLNK(mode):
            if rel and st.st_dev != root_dev:
                return
            for name in sorted(os.listdir(path)):
                rec(os.path.join(path, name))

    rec(root)
    return sorted(rows)


def text_of(rows):
    if not rows:
        return ""
    return "\n".join(rows) + "\n"


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: tree_equal.py equal|manifest|cmpmanifest ...\n")
        return 2
    cmd = argv[1]
    if cmd == "equal" and len(argv) == 4:
        left = walk(argv[2])
        right = walk(argv[3])
        if left != right:
            sys.stderr.write("manifest mismatch\n")
            right_set = set(right)
            left_set = set(left)
            shown = 0
            for line in left:
                if line not in right_set:
                    if shown < 24:
                        sys.stderr.write("only-src %s\n" % line)
                    shown += 1
            for line in right:
                if line not in left_set:
                    if shown < 24:
                        sys.stderr.write("only-dst %s\n" % line)
                    shown += 1
            if shown > 24:
                sys.stderr.write("... %d more mismatches\n" % (shown - 24))
            return 1
        return 0
    if cmd == "manifest" and len(argv) == 4:
        with open(argv[3], "w", encoding="utf-8") as handle:
            handle.write(text_of(walk(argv[2])))
        return 0
    if cmd == "cmpmanifest" and len(argv) == 4:
        with open(argv[2], "r", encoding="utf-8") as handle:
            saved = handle.read()
        current = text_of(walk(argv[3]))
        if saved != current:
            sys.stderr.write("tree changed\n")
            return 1
        return 0
    sys.stderr.write("usage: tree_equal.py equal DIR DIR | manifest DIR FILE | cmpmanifest FILE DIR\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))

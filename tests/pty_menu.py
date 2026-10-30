#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AdmiralGDR
#
# Test-only pseudoterminal driver. The product does not call this file.
import os
import select
import signal
import sys
import time


def main(argv):
    timeout = 25.0
    infile = None
    outfile = None
    args = argv[1:]
    while args and args[0].startswith("--"):
        if args[0] == "--timeout" and len(args) > 1:
            timeout = float(args[1])
            args = args[2:]
        elif args[0] == "--input" and len(args) > 1:
            infile = args[1]
            args = args[2:]
        elif args[0] == "--output" and len(args) > 1:
            outfile = args[1]
            args = args[2:]
        elif args[0] == "--":
            args = args[1:]
            break
        else:
            sys.stderr.write("pty_menu: bad arguments\n")
            return 2
    if not args or not infile or not outfile:
        sys.stderr.write("pty_menu: need --input, --output and a command\n")
        return 2
    with open(infile, "rb") as handle:
        payload = handle.read()
    import pty

    pid, fd = pty.fork()
    if pid == 0:
        os.execv(args[0], args)
        os._exit(127)
    started = time.monotonic()
    deadline = started + timeout
    first = None
    esc = 0
    out = b""
    sent = False
    status = None
    reaped = False
    eof = False
    while not reaped:
        now = time.monotonic()
        if now >= deadline:
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
            try:
                _, status = os.waitpid(pid, 0)
            except ChildProcessError:
                status = 0
            reaped = True
            break
        watch = [] if eof else [fd]
        readable, _, _ = select.select(watch, [], [], 0.1)
        if fd in readable:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if chunk:
                if first is None:
                    first = time.monotonic() - started
                if b"\x1b" in chunk:
                    esc = 1
                out += chunk
            else:
                # The launcher closes the slave when it detaches. The master
                # must stay open until the process exits, or the kernel sends
                # SIGHUP and the copy never starts.
                eof = True
        if not sent and (first is not None or time.monotonic() - started > 0.05):
            try:
                os.write(fd, payload)
            except OSError:
                pass
            sent = True
        try:
            wpid, st = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            status = 0
            reaped = True
            break
        if wpid == pid:
            status = st
            reaped = True
            break
        if eof:
            time.sleep(0.05)
    extra, esc2 = drain(fd)
    out += extra
    if esc2:
        esc = 1
    try:
        os.close(fd)
    except OSError:
        pass
    if status is None:
        code = 124
    elif os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
    elif os.WIFSIGNALED(status):
        code = 128 + os.WTERMSIG(status)
    else:
        code = 124
    with open(outfile, "wb") as handle:
        handle.write(out)
    if first is None:
        shown = "-1"
    else:
        shown = "%.4f" % first
    sys.stdout.write("PTY_EXIT=%s\nPTY_FIRST=%s\nPTY_ESC=%s\n" % (code, shown, esc))
    return 0


def drain(fd):
    data = b""
    esc = 0
    while True:
        readable, _, _ = select.select([fd], [], [], 0.05)
        if not readable:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        if b"\x1b" in chunk:
            esc = 1
        data += chunk
    return data, esc


if __name__ == "__main__":
    sys.exit(main(sys.argv))

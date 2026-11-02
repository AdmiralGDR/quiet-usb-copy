#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AdmiralGDR
#
# Dev-only project check. The copy program does not call this file.
# It does not install packages and does not ask for a password.
# Usage: sh tests/check.sh

set +e
ROOT=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT" || exit 1
fail=0

note() {
    printf '%s\n' "$1"
}

note "syntax"
sh -n quiet_usb_copy.sh || fail=1
sh -n tests/run.sh || fail=1
sh -n tests/cases_040.sh || fail=1
sh -n tests/check.sh || fail=1
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s sh quiet_usb_copy.sh || fail=1
else
    note "UNVERIFIED shellcheck"
fi

note "suite"
sh tests/run.sh
suite_rc=$?
if [ "$suite_rc" -ne 0 ]; then
    fail=1
fi

note "cli"
cli_work=$(mktemp -d /tmp/quc-check.XXXXXX) || exit 1
case $cli_work in
    /tmp/quc-check.*) ;;
    *)
        note "FAIL cli work dir"
        exit 1
        ;;
esac
export HOME="$cli_work/home"
export XDG_STATE_HOME="$cli_work/state"
export XDG_RUNTIME_DIR="$cli_work/run"
export XDG_DATA_HOME="$cli_work/data"
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME" \
    "$cli_work/src" "$cli_work/dst" || fail=1
printf 'a\n' > "$cli_work/src/a.txt" || fail=1

ver_out=$(sh quiet_usb_copy.sh version) || fail=1
printf '%s\n' "$ver_out" | grep -q 'quiet-usb-copy 0.4.0-rc.5' || fail=1
printf '%s\n' "$ver_out" | grep -q 'build 20261101.3' || fail=1
printf '%s\n' "$ver_out" | grep -q '^sha256=' || fail=1

help_out=$(sh quiet_usb_copy.sh help) || fail=1
printf '%s\n' "$help_out" | grep -q 'plan' || fail=1
printf '%s\n' "$help_out" | grep -q 'cleanup' || fail=1
printf '%s\n' "$help_out" | grep -q 'status' || fail=1
printf '%s\n' "$help_out" | grep -q 'report' || fail=1

doc_out=$(sh quiet_usb_copy.sh doctor) || fail=1
printf '%s\n' "$doc_out" | grep -q '^compat_level=LIMITED$' || fail=1
printf '%s\n' "$doc_out" | grep -q '^fs_gate=UNKNOWN$' || fail=1
printf '%s\n' "$doc_out" | grep -q '^fd_publish=SUPPORTED$' || fail=1
printf '%s\n' "$doc_out" | grep -q '^compat_level=SUPPORTED$' && fail=1
printf '%s\n' "$doc_out" | grep -q 'не означает совместимость файловой системы' || fail=1

sh quiet_usb_copy.sh selftest >/dev/null || fail=1

plan_out=$(sh quiet_usb_copy.sh plan "$cli_work/src" "$cli_work/dst")
plan_ec=$?
case $plan_ec in
    0|1) ;;
    *) fail=1 ;;
esac
printf '%s\n' "$plan_out" | grep -q 'Копирование не запускается.' || fail=1
printf '%s\n' "$plan_out" | grep -q '^plan_level=' || fail=1
if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ]; then
    note "FAIL plan created a job"
    fail=1
fi

status_out=$(sh quiet_usb_copy.sh status --machine)
status_ec=$?
if [ "$status_ec" -ne 1 ] || ! printf '%s\n' "$status_out" | grep -q '^error_code=E_NOJOB$'; then
    fail=1
fi

report_out=$(sh quiet_usb_copy.sh report --verbose)
report_ec=$?
if [ "$report_ec" -ne 1 ] || ! printf '%s\n' "$report_out" | grep -q '^error_code=E_NOJOB$'; then
    fail=1
fi

clean_out=$(sh quiet_usb_copy.sh cleanup --dry-run) || fail=1
printf '%s\n' "$clean_out" | grep -q 'Удаление не выполнялось.' || fail=1
printf '%s\n' "$clean_out" | grep -q '^error_code=E_OK$' || fail=1

sh quiet_usb_copy.sh rollback >/dev/null 2>"$cli_work/rollback.err"
roll_ec=$?
if [ "$roll_ec" -eq 0 ]; then
    note "FAIL rollback changed state"
    fail=1
fi
if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ]; then
    note "FAIL rollback created a job"
    fail=1
fi

# rollback/ exists only in a developer working copy.
# A published tree has no such directory; these checks are skipped.
note "rollback trees"
for tree in rollback/0.3.0 rollback/0.4.0-rc.2 rollback/0.4.0-rc.3 rollback/0.4.0-rc.4; do
    if [ ! -d "$tree" ]; then
        note "SKIP $tree"
        continue
    fi
    if [ ! -f "$tree/SHA256SUMS" ] || [ ! -f "$tree/quiet_usb_copy.sh" ]; then
        note "FAIL missing $tree"
        fail=1
        continue
    fi
    if ! (cd "$tree" && sha256sum -c SHA256SUMS >/dev/null); then
        note "FAIL checksum $tree"
        fail=1
    fi
done

rm -rf -- "$cli_work"

note "UNVERIFIED real-usb"
note "UNVERIFIED fat32"
note "UNVERIFIED exfat"
note "UNVERIFIED ntfs"
note "UNVERIFIED fedora"
note "UNVERIFIED rhel"
note "UNVERIFIED redos"
note "UNVERIFIED dest-hardlink"
note "UNVERIFIED destination-filesystem"
note "UNVERIFIED rollback-is-file-restore"

if [ "$fail" -eq 0 ]; then
    note "RESULT PASS"
    exit 0
fi
note "RESULT FAIL"
exit 1

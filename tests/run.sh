#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AdmiralGDR
#
# Tests for Quiet USB Copy. No root on the host, no real USB devices.
# Isolated tmpfs mounts live in a user and mount namespace.
# Usage: sh tests/run.sh

set +e
set +f

if [ "${QUC_IN_NS:-}" != 1 ]; then
    if ! command -v unshare >/dev/null 2>&1; then
        echo "FAIL setup: unshare is not available"
        exit 1
    fi
    exec unshare --user --map-root-user --mount --propagation private \
        env QUC_IN_NS=1 /bin/sh "$0" "$@"
fi

ROOT=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
SCRIPT=$ROOT/quiet_usb_copy.sh
TREE=$ROOT/tests/tree_equal.py
SH=/bin/sh
ORIG_PATH=$PATH
WORK=$(mktemp -d /tmp/quc-tests.XXXXXX) || exit 1
passes=0
fails=0
current=setup

case $WORK in
    /tmp/quc-tests.*) ;;
    *)
        echo "FAIL setup: unexpected work dir $WORK"
        exit 1
        ;;
esac

kill_matching() {
    needle=$1
    for cmdf in /proc/[0-9]*/cmdline; do
        pid=${cmdf#/proc/}
        pid=${pid%/cmdline}
        if [ "$pid" = "$$" ]; then
            continue
        fi
        data=$(tr '\0' ' ' < "$cmdf" 2>/dev/null || true)
        case $data in
            *"$needle"*)
                kill -TERM "$pid" 2>/dev/null || true
                ;;
        esac
    done
}

umount_work() {
    list=$WORK/umount.list
    : > "$list"
    while IFS= read -r line || [ -n "$line" ]; do
        set -- $line
        mp=$5
        case $mp in
            "$WORK"/*) printf '%s\n' "$mp" >> "$list" ;;
        esac
    done < /proc/self/mountinfo
    awk '{ print length($0), $0 }' "$list" | sort -nr | while read -r _len mp; do
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    done
}

cleanup() {
    kill_matching "$WORK"
    sleep 0.2
    umount_work
    case $WORK in
        /tmp/quc-tests.*) rm -rf -- "$WORK" ;;
    esac
}
trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM

pass() {
    printf 'PASS %s\n' "$current"
    passes=$((passes + 1))
}

fail() {
    printf 'FAIL %s: %s\n' "$current" "$*"
    fails=$((fails + 1))
    if [ -n "${XDG_STATE_HOME:-}" ] && [ -d "$XDG_STATE_HOME/quiet-usb-copy" ]; then
        "$SH" "$SCRIPT" report 2>&1 | tail -n 50
        find "$XDG_STATE_HOME/quiet-usb-copy/jobs" -name log -type f 2>/dev/null | while IFS= read -r logf; do
            printf 'LOG %s\n' "$logf"
            tail -n 40 "$logf"
        done
    fi
}

begin_test() {
    current=$1
    PATH=$ORIG_PATH
    unset QUC_FILE_PAUSE
    unset QUC_POST_COPY_DELAY
    unset QUC_FAKE_VOLUMES
    unset LD_PRELOAD
    export HOME=$WORK/home
    export XDG_STATE_HOME=$WORK/xdg-$current
    export XDG_RUNTIME_DIR=$WORK/run-$current
    export LC_ALL=C
    mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$WORK/t-$current"
    quc_run_dir=
    quc_runtime_base=
    quc_job_dir=
    quc_stop_requested=0
    cd "$WORK" || return 1
    printf 'RUN %s\n' "$current"
}

end_test() {
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        "$SH" "$SCRIPT" stop >/dev/null 2>&1 || true
        kill_matching "$XDG_STATE_HOME"
    fi
    kill_matching "$WORK/t-$current"
    sleep 0.2
    umount_work
}

run_case() {
    begin_test "$1"
    shift
    "$@"
    end_test
}

run_quiet() {
    quc_out=$WORK/last.out
    quc_err=$WORK/last.err
    : > "$quc_out"
    : > "$quc_err"
    "$@" >"$quc_out" 2>"$quc_err"
    quc_ec=$?
    quc_out_n=$(wc -c < "$quc_out" | tr -d ' ')
    quc_err_n=$(wc -c < "$quc_err" | tr -d ' ')
}

run_start() {
    run_quiet "$SH" "$SCRIPT" start "$@"
    quc_noisy=0
    if [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        quc_noisy=1
        printf 'NOISY stdout=%s stderr=%s\n' "$quc_out_n" "$quc_err_n"
        cat "$quc_out" "$quc_err"
    fi
}

run_resume() {
    run_quiet "$SH" "$SCRIPT" resume "$@"
    quc_noisy=0
    if [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        quc_noisy=1
        printf 'NOISY resume stdout=%s stderr=%s\n' "$quc_out_n" "$quc_err_n"
    fi
}

job_field() {
    key=$1
    cur=$XDG_STATE_HOME/quiet-usb-copy/current
    if [ ! -f "$cur" ]; then
        return 1
    fi
    id=$(cat "$cur")
    state=$XDG_STATE_HOME/quiet-usb-copy/jobs/$id/state
    if [ ! -f "$state" ]; then
        return 1
    fi
    awk -F= -v k="$key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$state"
}

wait_done() {
    max=${1:-120}
    i=0
    st=''
    while [ "$i" -lt "$max" ]; do
        st=$(job_field copy_status || true)
        case $st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN)
                printf '%s\n' "$st"
                return 0
                ;;
        esac
        sleep 0.25
        i=$((i + 1))
    done
    printf '%s\n' "${st:-TIMEOUT}"
    return 1
}

wait_phase() {
    needle=$1
    max=${2:-80}
    i=0
    while [ "$i" -lt "$max" ]; do
        ph=$(job_field phase || true)
        case $ph in
            *"$needle"*) return 0 ;;
        esac
        st=$(job_field copy_status || true)
        case $st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) return 1 ;;
        esac
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

make_pair() {
    src=$WORK/t-$current/src
    dst=$WORK/t-$current/dst
    ssize=${1:-64m}
    dsize=${2:-64m}
    mkdir -p "$src" "$dst"
    mount -t tmpfs -o size="$ssize" tmpfs "$src" || return 1
    mount -t tmpfs -o size="$dsize" tmpfs "$dst" || return 1
}

trees_ok() {
    python3 "$TREE" equal "$1" "$2"
}

save_src() {
    python3 "$TREE" manifest "$src" "$WORK/t-$current/snap"
}

src_same() {
    python3 "$TREE" cmpmanifest "$WORK/t-$current/snap" "$src"
}

count_live() {
    needle=$1
    n=0
    for cmdf in /proc/[0-9]*/cmdline; do
        pid=${cmdf#/proc/}
        pid=${pid%/cmdline}
        if [ "$pid" = "$$" ]; then
            continue
        fi
        data=$(tr '\0' ' ' < "$cmdf" 2>/dev/null || true)
        case $data in
            *"$needle"*) n=$((n + 1)) ;;
        esac
    done
    printf '%s\n' "$n"
}

# --- static and unit tests, no mounts required beyond the namespace ---

test_static() {
    bad=0
    dash -n "$SCRIPT" || bad=1
    bash -n "$SCRIPT" || bad=1
    if command -v busybox >/dev/null 2>&1; then
        busybox sh -n "$SCRIPT" || bad=1
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -s sh "$SCRIPT" || bad=1
    fi
    if grep -n -E '(^|[^A-Za-z0-9_])(eval|sudo|pkexec|umount|mkfs|losetup|notify-send|zenity)([^A-Za-z0-9_]|$)' "$SCRIPT" | grep -v '^[[:space:]]*#' >/dev/null; then
        echo "forbidden token"
        grep -n -E '(^|[^A-Za-z0-9_])(eval|sudo|pkexec|umount|mkfs|losetup|notify-send|zenity)([^A-Za-z0-9_]|$)' "$SCRIPT" | grep -v '^[[:space:]]*#'
        bad=1
    fi
    if grep -n -E '(^|[^A-Za-z0-9_])mount([^A-Za-z0-9_]|$)' "$SCRIPT" | grep -v '^[[:space:]]*#' >/dev/null; then
        echo "mount command"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" help
    if [ "$quc_ec" -ne 0 ]; then
        bad=1
    fi
    if ! grep -q 'start' "$quc_out" || ! grep -q 'doctor' "$quc_out" || ! grep -q 'cleanup' "$quc_out"; then
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" version
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^quiet-usb-copy 0.3.0$' "$quc_out" || ! grep -q '^build 20261029.2$' "$quc_out"; then
        echo "version output"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then
        pass
    else
        fail "syntax, shellcheck, or forbidden command"
    fi
}

test_units() {
    bad=0
    quc_resolve_tools || bad=1

    sample=$(printf 'a\nb\t \\"ё')
    enc=$(quc_hex_encode "$sample")
    if ! quc_decode_hex_var "$enc"; then
        bad=1
    fi
    if [ "$quc_decoded" != "$sample" ]; then
        echo "hex roundtrip mismatch"
        bad=1
    fi
    python3 -c 'import sys; sys.stdout.buffer.write(bytes(range(1,256)))' > "$WORK/bytes"
    data=$(cat "$WORK/bytes" && printf x)
    data=${data%x}
    enc=$(quc_hex_encode "$data")
    quc_decode_hex_var "$enc" || bad=1
    printf '%s' "$quc_decoded" > "$WORK/bytes.out"
    cmp -s "$WORK/bytes" "$WORK/bytes.out" || bad=1

    shown=$(quc_display_path "$(printf 'a\nb')")
    case $shown in
        *'\x0a'*) ;;
        *) echo "display escape failed: $shown"; bad=1 ;;
    esac
    lines=$(printf '%s\n' "$shown" | wc -l | tr -d ' ')
    if [ "$lines" != 1 ]; then
        bad=1
    fi

    got=$(quc_decide_copy_status '' 2 0 0 0 0)
    [ "$got" = SUCCESS ] || bad=1
    got=$(quc_decide_copy_status '' 0 0 1 0 0)
    [ "$got" = UNCERTAIN ] || bad=1
    got=$(quc_decide_copy_status '' 1 1 0 0 0)
    [ "$got" = PARTIAL ] || bad=1
    got=$(quc_decide_copy_status '' 0 2 0 0 0)
    [ "$got" = FAILED ] || bad=1
    got=$(quc_decide_copy_status '' 0 0 0 1 0)
    [ "$got" = PARTIAL ] || bad=1
    got=$(quc_decide_copy_status CANCELLED 3 0 0 0 0)
    [ "$got" = CANCELLED ] || bad=1
    got=$(quc_decide_copy_status '' 1 0 0 0 1)
    [ "$got" = UNCERTAIN ] || bad=1

    quc_paths_nested /mnt/usb1 /mnt/usb10 && bad=1
    quc_paths_nested /mnt/usb1 /mnt/usb1/a || bad=1
    quc_is_system_path /tmp || bad=1
    quc_is_system_path /tmp/not-root && bad=1
    quc_is_system_path / || bad=1

    if [ "$(quc_fat_limit vfat)" != 4294967295 ]; then
        bad=1
    fi
    if [ -n "$(quc_fat_limit ext4)" ]; then
        bad=1
    fi
    quc_cmp_num 4294967296 4294967295 gt || bad=1
    quc_cmp_num 4294967295 4294967295 gt && bad=1
    quc_fat_name_bad vfat 'dir/CON' || bad=1
    quc_fat_name_bad vfat 'aux.txt' || bad=1
    quc_fat_name_bad vfat 'foo:bar' || bad=1
    quc_fat_name_bad vfat 'trail.' || bad=1
    quc_fat_name_bad vfat 'readme.txt' && bad=1
    quc_fat_name_bad ext4 'CON' && bad=1
    quc_fat_component_bad "$(printf 'a\nb')" || bad=1

    quc_job_dir=$WORK/unit-scan
    mkdir -p "$quc_job_dir" "$WORK/unit-src" "$WORK/unit-dst"
    quc_source=$WORK/unit-src
    quc_target=$WORK/unit-dst
    python3 - "$quc_source" "$quc_target" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
name = "a\nb"
with open(os.path.join(src, name), "w", encoding="utf-8") as handle:
    handle.write("x")
with open(os.path.join(dst, name), "w", encoding="utf-8") as handle:
    handle.write("x")
PY
    scan=$(quc_dest_unexpected)
    scan_rc=$?
    if [ "$scan_rc" -ne 0 ] || [ -n "$scan" ]; then
        echo "newline name looked unexpected rc=$scan_rc"
        bad=1
    fi
    printf 'y\n' > "$quc_target/extra.txt"
    scan=$(quc_dest_unexpected)
    scan_rc=$?
    if [ "$scan_rc" -ne 0 ] || [ -z "$scan" ]; then
        echo "extra file not detected rc=$scan_rc"
        bad=1
    elif ! quc_decode_hex_var "$scan"; then
        echo "extra path did not decode"
        bad=1
    else
        case $quc_decoded in
            */extra.txt) ;;
            *) echo "unexpected path"; bad=1 ;;
        esac
    fi

    names=$WORK/unit-names
    mkdir -p "$names/папка ё"
    python3 - "$names" <<'PY'
import os, sys
root = sys.argv[1]
open(os.path.join(root, "plain.txt"), "w", encoding="utf-8").write("p")
open(os.path.join(root, "space name.txt"), "w", encoding="utf-8").write("s")
open(os.path.join(root, "папка ё", "файл.txt"), "w", encoding="utf-8").write("u")
open(os.path.join(root, "-dash"), "w", encoding="utf-8").write("d")
open(os.path.join(root, "a\nb"), "w", encoding="utf-8").write("n")
PY
    cat > "$WORK/check_plan.py" <<'PY'
import subprocess, sys
root, plan = sys.argv[1], sys.argv[2]
out = subprocess.check_output(["find", root, "-xdev", "-print0"])
expected = {p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p}
got = set()
with open(plan, "r", encoding="ascii") as handle:
    for line in handle:
        line = line.strip()
        if line:
            got.add(bytes.fromhex(line).decode("utf-8", "surrogateescape"))
missing = expected - got
extra = got - expected
if missing or extra:
    sys.stderr.write("missing=%r extra=%r\n" % (sorted(missing), sorted(extra)))
    sys.exit(1)
if len(got) < 2:
    sys.stderr.write("plan too small\n")
    sys.exit(1)
PY
    cat > "$WORK/trunc_awk.sh" <<'EOF'
#!/bin/sh
prog=$1
shift
awk_bin=/usr/bin/gawk
if [ ! -x "$awk_bin" ]; then
    awk_bin=/usr/bin/awk
fi
if [ "$#" -eq 1 ] && [ -f "$1" ]; then
    tmp=$1.trunc
    python3 -c 'import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read().split(b"\x00", 1)[0]
open(dst, "wb").write(data)
' "$1" "$tmp" || exit 1
    "$awk_bin" "$prog" "$tmp"
    rc=$?
    rm -f -- "$tmp"
    exit "$rc"
fi
exec "$awk_bin" "$prog" "$@"
EOF
    chmod +x "$WORK/trunc_awk.sh"
    quc_job_dir=$WORK/unit-plan
    mkdir -p "$quc_job_dir"
    quc_log_file=$quc_job_dir/log
    saved_awk=$quc_bin_awk
    : > "$quc_log_file"
    quc_bin_awk=$WORK/trunc_awk.sh
    quc_write_plan "$quc_job_dir/trunc.hex" "$names"
    prc=$?
    quc_bin_awk=$saved_awk
    if [ "$prc" -ne 0 ]; then
        echo "truncating awk plan rc=$prc"
        bad=1
    elif ! grep -q 'запасной разбор' "$quc_log_file"; then
        echo "short awk did not use the fallback"
        cat "$quc_log_file"
        bad=1
    elif ! python3 "$WORK/check_plan.py" "$names" "$quc_job_dir/trunc.hex"; then
        bad=1
    fi
    : > "$quc_log_file"
    quc_write_plan "$quc_job_dir/gawk.hex" "$names"
    prc=$?
    if [ "$prc" -ne 0 ]; then
        echo "gawk plan rc=$prc"
        bad=1
    elif grep -q 'запасной разбор' "$quc_log_file"; then
        echo "gawk unexpectedly used the fallback"
        bad=1
    elif ! python3 "$WORK/check_plan.py" "$names" "$quc_job_dir/gawk.hex"; then
        bad=1
    fi
    if [ -x /usr/bin/mawk ]; then
        : > "$quc_log_file"
        quc_bin_awk=/usr/bin/mawk
        quc_write_plan "$quc_job_dir/mawk.hex" "$names"
        prc=$?
        quc_bin_awk=$saved_awk
        if [ "$prc" -ne 0 ]; then
            echo "mawk plan rc=$prc"
            bad=1
        elif ! python3 "$WORK/check_plan.py" "$names" "$quc_job_dir/mawk.hex"; then
            bad=1
        fi
    fi
    quc_bin_awk=$saved_awk

    quc_job_dir=$WORK/unit-sync
    mkdir -p "$quc_job_dir"
    saved_sync=$quc_bin_sync
    cat > "$WORK/sync-file-only" <<'EOF'
#!/bin/sh
for a do
    case $a in
        -d|--data) exit 1 ;;
    esac
done
exit 0
EOF
    cat > "$WORK/sync-none" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$WORK/sync-lie" <<'EOF'
#!/bin/sh
echo "sync: unrecognized option '-d'" >&2
exit 0
EOF
    chmod +x "$WORK/sync-file-only" "$WORK/sync-none" "$WORK/sync-lie"
    quc_bin_sync=$WORK/sync-file-only
    quc_probe_copy_tools
    if [ "$quc_sync_mode" != file ]; then
        echo "sync file mode=$quc_sync_mode"
        bad=1
    fi
    quc_bin_sync=$WORK/sync-none
    quc_probe_copy_tools
    if [ "$quc_sync_mode" != none ]; then
        echo "sync none mode=$quc_sync_mode"
        bad=1
    fi
    quc_bin_sync=$WORK/sync-lie
    quc_probe_copy_tools
    if [ "$quc_sync_mode" != none ]; then
        echo "sync lie mode=$quc_sync_mode"
        bad=1
    fi
    if [ -x /usr/bin/sync ]; then
        quc_bin_sync=/usr/bin/sync
        quc_probe_copy_tools
        if [ "$quc_sync_mode" != data ]; then
            echo "host sync mode=$quc_sync_mode"
            bad=1
        fi
    fi
    quc_bin_sync=$saved_sync
    quc_sync_mode=none

    msg=$(quc_disk_pair_problem /dev/no-such-quc-disk-a /dev/no-such-quc-disk-b)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "unknown disks were accepted"
        bad=1
    fi
    case $msg in
        *'не определён'*) ;;
        *) echo "unknown disk message: $msg"; bad=1 ;;
    esac
    msg=$(quc_disk_pair_problem tmpfs tmpfs)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -n "$msg" ]; then
        echo "tmpfs pair rejected: $msg"
        bad=1
    fi
    : > "$WORK/disks.txt"
    named=0
    for part in /sys/class/block/*/partition; do
        [ -f "$part" ] || continue
        node=${part%/partition}
        base=${node##*/}
        spec=/dev/$base
        [ -e "$spec" ] || continue
        dname=$(quc_disk_name "$spec" 0) || dname=
        if [ -z "$dname" ]; then
            echo "partition unnamed: $spec"
            bad=1
            continue
        fi
        printf '%s %s\n' "$spec" "$dname" >> "$WORK/disks.txt"
        named=1
    done
    if [ -d /dev/disk/by-id ]; then
        for link in /dev/disk/by-id/*; do
            [ -L "$link" ] || continue
            dname=$(quc_disk_name "$link" 0) || dname=
            if [ -z "$dname" ]; then
                echo "by-id unresolved: $link"
                bad=1
                continue
            fi
            printf '%s %s\n' "$link" "$dname" >> "$WORK/disks.txt"
        done
    else
        echo "no by-id directory"
        bad=1
    fi
    spec1=
    disk1=
    same_hit=0
    diff_hit=0
    while IFS= read -r line || [ -n "$line" ]; do
        spec=${line%% *}
        dname=${line#* }
        if [ -z "$spec1" ]; then
            spec1=$spec
            disk1=$dname
            continue
        fi
        if [ "$dname" = "$disk1" ] && [ "$same_hit" -eq 0 ]; then
            msg=$(quc_disk_pair_problem "$spec1" "$spec")
            rc=$?
            if [ "$rc" -eq 0 ] || [ -z "$msg" ]; then
                echo "same disk allowed: $spec1 $spec"
                bad=1
            fi
            case $msg in
                *'одного физического диска'*) ;;
                *) echo "same disk message: $msg"; bad=1 ;;
            esac
            same_hit=1
        fi
        if [ "$dname" != "$disk1" ] && [ "$diff_hit" -eq 0 ]; then
            msg=$(quc_disk_pair_problem "$spec1" "$spec")
            rc=$?
            if [ "$rc" -ne 0 ] || [ -n "$msg" ]; then
                echo "different disks rejected: $spec1 $spec $msg"
                bad=1
            fi
            diff_hit=1
        fi
    done < "$WORK/disks.txt"
    if [ "$named" -ne 1 ] || [ "$same_hit" -ne 1 ] || [ "$diff_hit" -ne 1 ]; then
        echo "disk pairs same=$same_hit diff=$diff_hit named=$named"
        bad=1
    fi
    msg=$(quc_disk_pair_problem "$spec1" /dev/no-such-quc-disk-b)
    rc=$?
    if [ "$rc" -eq 0 ] || [ -z "$msg" ]; then
        echo "half-identified pair accepted"
        bad=1
    fi
    by_spec=
    by_disk=
    other_spec=
    while IFS= read -r line || [ -n "$line" ]; do
        spec=${line%% *}
        dname=${line#* }
        case $spec in
            /dev/disk/by-id/*)
                if [ -z "$by_spec" ]; then
                    by_spec=$spec
                    by_disk=$dname
                fi
                ;;
        esac
    done < "$WORK/disks.txt"
    while IFS= read -r line || [ -n "$line" ]; do
        spec=${line%% *}
        dname=${line#* }
        if [ -n "$by_disk" ] && [ "$dname" != "$by_disk" ]; then
            other_spec=$spec
            break
        fi
    done < "$WORK/disks.txt"
    if [ -z "$by_spec" ] || [ -z "$other_spec" ]; then
        echo "no by-id pair"
        bad=1
    else
        msg=$(quc_disk_pair_problem "$by_spec" "$other_spec")
        rc=$?
        if [ "$rc" -ne 0 ] || [ -n "$msg" ]; then
            echo "nonstandard name rejected: $by_spec vs $other_spec: $msg"
            bad=1
        fi
    fi

    quc_default_job_vars
    quc_job_id=unit-report
    quc_copy_status=SUCCESS
    quc_verify_status=checksum
    quc_verify_tool=sha256sum
    quc_sync_status=command_ok
    quc_sync_unconfirmed=0
    quc_source=/mnt/src
    quc_target=/mnt/dst
    quc_files_done=1
    quc_files_total=1
    report=$(quc_print_job 1)
    case $report in
        *'copy_status=SUCCESS'*) ;;
        *) echo "report lost copy"; bad=1 ;;
    esac
    case $report in
        *'verify_status=checksum'*) ;;
        *) echo "report lost verify"; bad=1 ;;
    esac
    case $report in
        *'sync_status=command_ok'*) ;;
        *) echo "report lost sync"; bad=1 ;;
    esac
    case $report in
        *'Извлечение:'*) ;;
        *) echo "report lost eject"; bad=1 ;;
    esac
    case $report in
        *'можно извлекать'*) echo "report allows removal"; bad=1 ;;
    esac
    quc_sync_status=unconfirmed
    quc_sync_unconfirmed=1
    report=$(quc_print_job 1)
    case $report in
        *'copy_status=SUCCESS'*'sync_status=unconfirmed'*'Извлечение:'*) ;;
        *) echo "unconfirmed report mixed axes"; bad=1 ;;
    esac
    quc_sync_mode=none

    quc_default_job_vars
    quc_copy_status=SUCCESS
    quc_verify_status=checksum
    quc_sync_status=command_ok
    quc_files_done=3
    quc_files_total=3
    quc_profile=gentle
    quc_source=/mnt/src
    quc_target=/mnt/dst
    text=$(quc_print_human)
    case $text in
        *'Копирование завершено.'*) ;;
        *) echo "human success"; bad=1 ;;
    esac
    case $text in
        *'Файлы: 3 из 3'*) ;;
        *) echo "human files"; bad=1 ;;
    esac
    case $text in
        *'Проверка содержимого: завершена'*) ;;
        *) echo "human verify"; bad=1 ;;
    esac
    case $text in
        *'Для извлечения'*) ;;
        *) echo "human eject"; bad=1 ;;
    esac
    case $text in
        *'Режим: бережный'*) ;;
        *) echo "human gentle"; bad=1 ;;
    esac
    case $text in
        *'можно извлекать'*|*'copy_status='*) echo "human leaked machine or eject permission"; bad=1 ;;
    esac
    quc_copy_status=PARTIAL
    quc_verify_status=none
    quc_sync_status=unconfirmed
    quc_error=
    text=$(quc_print_human)
    case $text in
        *'Копирование завершено частично.'*) ;;
        *) echo "human partial"; bad=1 ;;
    esac
    case $text in
        *'Копирование завершено.'*) echo "partial called done"; bad=1 ;;
    esac
    case $text in
        *'Подробнее: report'*) ;;
        *) echo "human partial report"; bad=1 ;;
    esac
    case $text in
        *'Синхронизация: сброс данных на носитель не подтверждён.'*) ;;
        *) echo "human unconfirmed"; bad=1 ;;
    esac
    quc_copy_status=UNCERTAIN
    text=$(quc_print_human)
    case $text in
        *'Результат копирования не подтверждён.'*) ;;
        *) echo "human uncertain"; bad=1 ;;
    esac
    quc_answer_is_yes "да" || { echo "yes da"; bad=1; }
    quc_answer_is_yes "yes" && { echo "yes english"; bad=1; }
    quc_answer_is_yes "Да" && { echo "yes capital"; bad=1; }
    quc_volume_candidate /dev/sdb1 vfat /media/DISK yes || { echo "vol accept"; bad=1; }
    quc_volume_candidate /dev/weird-name1 exfat /media/ODD yes || { echo "vol odd name"; bad=1; }
    quc_volume_candidate tmpfs tmpfs /media/DISK yes && { echo "vol tmpfs"; bad=1; }
    quc_volume_candidate /dev/sda1 ext4 /home yes && { echo "vol home"; bad=1; }
    quc_volume_candidate /dev/nvme0n1p1 ext4 /mnt/data no && { echo "vol internal"; bad=1; }
    quc_volume_candidate /dev/mmcblk0p1 vfat /media/ODD unknown && { echo "vol unknown"; bad=1; }
    volfile=$WORK/t-$current/volumes.tsv
    if ! quc_collect_volumes "$volfile"; then
        echo "collect failed"
        bad=1
    fi
    if [ -f "$volfile" ]; then
        while IFS= read -r vline || [ -n "$vline" ]; do
            [ -n "$vline" ] || continue
            vfs=$(printf '%s\n' "$vline" | awk -F '\t' 'NR == 1 { print $2; exit }')
            vsrc_hex=$(printf '%s\n' "$vline" | awk -F '\t' 'NR == 1 { print $3; exit }')
            vmp_hex=$(printf '%s\n' "$vline" | awk -F '\t' 'NR == 1 { print $1; exit }')
            vrem=$(printf '%s\n' "$vline" | awk -F '\t' 'NR == 1 { print $6; exit }')
            quc_decode_hex_var "$vsrc_hex" || { echo "src hex"; bad=1; continue; }
            vsrc=$quc_decoded
            quc_decode_hex_var "$vmp_hex" || { echo "mp hex"; bad=1; continue; }
            vmp=$quc_decoded
            case $vsrc in
                /dev/*) ;;
                *) echo "non-dev volume $vsrc"; bad=1 ;;
            esac
            if [ "$vrem" != yes ] || [ "$vfs" = tmpfs ] || [ "$vmp" = / ]; then
                echo "volume policy fs=$vfs rem=$vrem mp=$vmp"
                bad=1
            fi
        done < "$volfile"
    fi

    plant_job() {
        pj_id=$1
        pj_status=$2
        quc_default_job_vars
        quc_job_id=$pj_id
        quc_source=$keep
        quc_target=$destkeep
        quc_source_spec=tmpfs
        quc_target_spec=tmpfs
        quc_copy_status=$pj_status
        quc_profile=gentle
        quc_files_done=2
        quc_files_total=4
        quc_verify_status=none
        quc_sync_status=unconfirmed
        quc_job_dir=$quc_jobs_dir/$pj_id
        mkdir -p "$quc_job_dir" || return 1
        quc_log_file=$quc_job_dir/log
        printf 'kept\n' > "$quc_log_file" || return 1
        quc_save_state || return 1
    }
    keep=$WORK/t-$current/user-data
    destkeep=$WORK/t-$current/user-dest
    mkdir -p "$keep" "$destkeep"
    printf 'keep\n' > "$keep/file.txt"
    printf 'dest\n' > "$destkeep/file.txt"
    if ! quc_prepare_state || ! quc_runtime_prepare; then
        echo "state or runtime prepare"
        bad=1
    else
        quc_default_job_vars
        quc_job_id=empty-spec-1
        quc_source=$keep
        quc_target=$destkeep
        quc_copy_status=FAILED
        quc_job_dir=$quc_jobs_dir/empty-spec-1
        mkdir -p "$quc_job_dir"
        quc_log_file=$quc_job_dir/log
        : > "$quc_log_file"
        if ! quc_save_state || ! quc_load_state "$quc_job_dir/state" || [ "$quc_copy_status" != FAILED ] || [ -n "$quc_source_spec" ]; then
            echo "empty spec did not load"
            bad=1
        fi
        rm -rf "$quc_jobs_dir/empty-spec-1"
        plant_job cleanup-success-1 SUCCESS || { echo "plant success"; bad=1; }
        plant_job cleanup-running-1 RUNNING || { echo "plant running"; bad=1; }
        mkdir -p "$quc_jobs_dir/cleanup-bad-1"
        printf 'copy_status=SUCCESS\n' > "$quc_jobs_dir/cleanup-bad-1/state"
        ln -s /tmp "$quc_jobs_dir/cleanup-link-1"
        printf '%s\n' cleanup-success-1 > "$quc_current"
        mkdir -p "$quc_runtime_base/jobs/cleanup-success-1" "$quc_runtime_base/jobs/cleanup-running-1"
        printf 'plan\n' > "$quc_runtime_base/jobs/cleanup-success-1/plan.hex"
        printf 'plan\n' > "$quc_runtime_base/jobs/cleanup-running-1/plan.hex"
        printf 'menu\n' > "$quc_runtime_base/menu.42"
        printf 'held\n' > "$quc_lockfile"
        run_quiet "$SH" "$SCRIPT" cleanup
        if [ "$quc_ec" -ne 0 ]; then
            echo "cleanup ec=$quc_ec"
            cat "$quc_out" "$quc_err"
            bad=1
        fi
        if ! grep -q '^Удалено служебных заданий: 2$' "$quc_out" || ! grep -q '^Оставлено незавершённых: 2$' "$quc_out"; then
            echo "cleanup counts"
            cat "$quc_out" "$quc_err"
            bad=1
        fi
        if [ -d "$quc_jobs_dir/cleanup-success-1" ] || [ ! -d "$quc_jobs_dir/cleanup-running-1" ]; then
            echo "cleanup removed the wrong job"
            bad=1
        fi
        if [ ! -f "$quc_jobs_dir/cleanup-running-1/state" ] || [ ! -f "$quc_jobs_dir/cleanup-running-1/log" ]; then
            echo "running recovery files missing"
            bad=1
        fi
        if ! grep -q '^copy_status=RUNNING$' "$quc_jobs_dir/cleanup-running-1/state" || ! grep -q '^profile=gentle$' "$quc_jobs_dir/cleanup-running-1/state"; then
            echo "running state changed"
            bad=1
        fi
        if [ -e "$quc_runtime_base/jobs/cleanup-success-1" ] || [ ! -f "$quc_runtime_base/jobs/cleanup-running-1/plan.hex" ]; then
            echo "runtime scratch policy"
            bad=1
        fi
        if [ -e "$quc_runtime_base/menu.42" ] || [ -L "$quc_jobs_dir/cleanup-link-1" ] || [ ! -d "$quc_jobs_dir/cleanup-bad-1" ]; then
            echo "menu, link, or unreadable job"
            bad=1
        fi
        if [ -f "$quc_current" ]; then
            echo "current still points at a removed job"
            bad=1
        fi
        if [ ! -f "$quc_lockfile" ] || [ ! -f "$keep/file.txt" ] || [ ! -f "$destkeep/file.txt" ]; then
            echo "cleanup touched user data or lockfile"
            bad=1
        fi
        rm -rf "$quc_jobs_dir/cleanup-running-1" "$quc_jobs_dir/cleanup-bad-1" "$quc_runtime_base/jobs/cleanup-running-1"
        plant_job cleanup-success-2 SUCCESS || { echo "plant success 2"; bad=1; }
        printf '%s\n' cleanup-success-2 > "$quc_current"
        printf 'pid=1\nstarttime=1\ntoken=t\njob=cleanup-success-2\n' > "$quc_owner"
        printf 'held\n' > "$quc_lockfile"
        mkdir -p "$quc_state_dir/lock.d"
        printf 'err\n' > "$quc_last_error"
        run_quiet "$SH" "$SCRIPT" cleanup
        if [ "$quc_ec" -ne 0 ] || ! grep -q '^Удалено служебных заданий: 1$' "$quc_out" || ! grep -q '^Оставлено незавершённых: 0$' "$quc_out"; then
            echo "second cleanup"
            cat "$quc_out" "$quc_err"
            bad=1
        fi
        if [ -d "$quc_jobs_dir/cleanup-success-2" ] || [ ! -f "$quc_lockfile" ] || [ -f "$quc_owner" ] || [ -f "$quc_last_error" ] || [ -d "$quc_state_dir/lock.d" ] || [ -f "$quc_current" ]; then
            echo "finished-job cleanup leftovers"
            bad=1
        fi
        if [ ! -f "$keep/file.txt" ] || [ ! -f "$destkeep/file.txt" ]; then
            echo "user files removed"
            bad=1
        fi
    fi
    quc_run_dir=
    quc_runtime_base=
    quc_job_dir=
    quc_stop_requested=0

    if [ "$bad" -eq 0 ]; then
        pass
    else
        fail "unit checks"
    fi
}

test_T01() {
    bad=0
    make_pair || { fail "mount"; return; }
    python3 - "$src" <<'PY'
import os, sys
root = sys.argv[1]
os.makedirs(os.path.join(root, "a", "b"))
with open(os.path.join(root, "top.txt"), "w", encoding="utf-8") as h:
    h.write("top\n")
with open(os.path.join(root, "a", "b", "c.txt"), "w", encoding="utf-8") as h:
    h.write("nested\n")
os.link(os.path.join(root, "top.txt"), os.path.join(root, "a", "hard.txt"))
PY
    save_src || bad=1
    run_quiet "$SH" "$SCRIPT" check "$src" "$dst"
    grep -q '^check_result=OK$' "$quc_out" || bad=1
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 120)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    i1=$(stat -c '%i' "$src/top.txt")
    i2=$(stat -c '%i' "$src/a/hard.txt")
    j1=$(stat -c '%i' "$dst/top.txt")
    j2=$(stat -c '%i' "$dst/a/hard.txt")
    if [ "$i1" != "$i2" ] || [ "$j1" = "$j2" ]; then
        echo "hardlink inodes src=$i1/$i2 dst=$j1/$j2"
        bad=1
    fi
    if [ "$(job_field files_done)" != "$(job_field files_total)" ]; then
        echo "count $(job_field files_done)/$(job_field files_total)"
        bad=1
    fi
    if [ "$(job_field verify_status)" != size ]; then
        echo "verify $(job_field verify_status)"
        bad=1
    fi
    if [ "$(job_field sync_status)" != command_ok ]; then
        echo "sync $(job_field sync_status)"
        bad=1
    fi
    if [ -n "$(job_field error)" ]; then
        echo "error field: $(job_field error)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status
    if ! grep -q '^copy_status=SUCCESS$' "$quc_out" || ! grep -q '^verify_status=size$' "$quc_out" || ! grep -q '^sync_status=command_ok$' "$quc_out"; then
        echo "status axes"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if ! grep -q 'Извлечение:' "$quc_out" || ! grep -q 'штатную процедуру' "$quc_out"; then
        echo "eject sentence missing"
        bad=1
    fi
    if grep -q 'можно извлекать' "$quc_out"; then
        echo "status allows removal"
        bad=1
    fi
    if [ "$(job_field profile)" != gentle ]; then
        echo "profile $(job_field profile)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if grep -q 'copy_status=' "$quc_out" || grep -q 'можно извлекать' "$quc_out" || ! grep -q 'Копирование завершено.' "$quc_out" || ! grep -q 'Для извлечения' "$quc_out" || ! grep -q 'Файлы:' "$quc_out" || ! grep -q 'Проверка содержимого:' "$quc_out" || ! grep -q 'Синхронизация:' "$quc_out"; then
        echo "human status"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^copy_status=SUCCESS$' "$quc_out"; then
        echo "machine status"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human --verbose
    if ! grep -q 'Копирование завершено.' "$quc_out" || ! grep -q 'Диагностика:' "$quc_out" || ! grep -q '^copy_status=SUCCESS$' "$quc_out" || ! grep -q '^profile=gentle$' "$quc_out"; then
        echo "verbose human status"
        cat "$quc_out"
        bad=1
    fi
    jid=$(cat "$XDG_STATE_HOME/quiet-usb-copy/current")
    jdir=$XDG_STATE_HOME/quiet-usb-copy/jobs/$jid
    if [ ! -f "$jdir/state" ] || [ ! -f "$jdir/log" ] || [ -e "$jdir/plan.hex" ] || [ -e "$jdir/plan.0" ] || [ -e "$jdir/transfer.err" ] || [ -e "$jdir/ready" ]; then
        echo "scratch left in the job dir"
        find "$jdir" -maxdepth 1 -print
        bad=1
    fi
    if [ -d "$XDG_RUNTIME_DIR/quiet-usb-copy/jobs/$jid" ] || [ -d "$XDG_STATE_HOME/quiet-usb-copy/run/jobs/$jid" ]; then
        echo "runtime job dir remains"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "recursive copy"; fi
}

test_T02() {
    bad=0
    make_pair || { fail "mount"; return; }
    python3 - "$src" <<'PY'
import os, sys
root = sys.argv[1]
os.makedirs(os.path.join(root, "dir"))
with open(os.path.join(root, ".hidden"), "w", encoding="utf-8") as h:
    h.write("h\n")
with open(os.path.join(root, "dir", ".dot"), "w", encoding="utf-8") as h:
    h.write("d\n")
PY
    save_src
    run_start "$src" "$dst"
    st=$(wait_done)
    [ "$st" = SUCCESS ] || bad=1
    [ "$quc_noisy" -eq 0 ] || bad=1
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "hidden files status=$st"; fi
}

test_T03() {
    bad=0
    make_pair || { fail "mount"; return; }
    python3 - "$src" <<'PY'
import os, sys
root = sys.argv[1]
os.makedirs(os.path.join(root, "empty", "nested"))
os.makedirs(os.path.join(root, "also empty"))
with open(os.path.join(root, "empty", "keep.txt"), "w", encoding="utf-8") as h:
    h.write("k\n")
PY
    save_src
    run_start "$src" "$dst"
    st=$(wait_done)
    [ "$st" = SUCCESS ] || bad=1
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ ! -d "$dst/also empty" ] || [ -n "$(find "$dst/also empty" -mindepth 1 -print)" ]; then
        bad=1
    fi
    if [ ! -d "$dst/empty/nested" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "empty dirs status=$st"; fi
}

test_T04() {
    bad=0
    make_pair || { fail "mount"; return; }
    python3 - "$src" <<'PY'
import os, sys
root = sys.argv[1]
folder = os.path.join(root, "папка ё")
os.makedirs(folder)
with open(os.path.join(folder, "файл.txt"), "w", encoding="utf-8") as h:
    h.write("привет\n")
with open(os.path.join(root, "a b c.txt"), "w", encoding="utf-8") as h:
    h.write("spaces\n")
PY
    save_src
    run_start "$src" "$dst"
    st=$(wait_done)
    [ "$st" = SUCCESS ] || bad=1
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "unicode/spaces status=$st"; fi
}

test_T05() {
    bad=0
    make_pair || { fail "mount"; return; }
    python3 - "$src" <<'PY'
import os, sys
root = sys.argv[1]
names = ["a'b", "a$b", "a;b", "a&b", "a|b", "a*b", "a?b", "a[b]", "a\\b", "-dash", "tab\there", "line1\nline2", "quote\"x"]
for i, name in enumerate(names):
    with open(os.path.join(root, name), "w", encoding="utf-8") as h:
        h.write("n%d\n" % i)
with open(os.path.join(root, "plain.txt"), "w", encoding="utf-8") as h:
    h.write("p\n")
PY
    save_src
    run_start "$src" "$dst"
    st=$(wait_done)
    [ "$st" = SUCCESS ] || bad=1
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "special names status=$st"; fi
}

expect_reject() {
    phrase=$1
    run_quiet "$SH" "$SCRIPT" check "$src" "$dst"
    if [ "$quc_ec" -eq 0 ] || ! grep -q '^check_result=REJECT$' "$quc_out" || ! grep -q "$phrase" "$quc_out"; then
        echo "check did not reject"
        cat "$quc_out" "$quc_err"
        return 1
    fi
    run_start "$src" "$dst"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        return 1
    fi
    if [ "$(job_field copy_status)" != FAILED ]; then
        echo "copy_status=$(job_field copy_status)"
        return 1
    fi
    run_quiet "$SH" "$SCRIPT" report
    if ! grep -q "$phrase" "$quc_out"; then
        echo "report missed phrase"
        cat "$quc_out"
        return 1
    fi
    return 0
}

test_T06() {
    bad=0
    dst=$WORK/t-$current/dst
    src=$WORK/t-$current/missing-src
    mkdir -p "$dst"
    mount -t tmpfs -o size=16m tmpfs "$dst" || { fail "mount"; return; }
    expect_reject "не существует" || bad=1
    if [ -e "$src" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "missing source"; fi
}

test_T07() {
    bad=0
    src=$WORK/t-$current/src
    dst=$WORK/t-$current/missing-dst
    mkdir -p "$src"
    mount -t tmpfs -o size=16m tmpfs "$src" || { fail "mount"; return; }
    echo x > "$src/a.txt"
    expect_reject "не существует" || bad=1
    if [ -e "$dst" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "missing dest"; fi
}

test_T08() {
    bad=0
    make_pair || { fail "mount"; return; }
    echo x > "$src/a.txt"
    src_keep=$src
    dst=$src
    expect_reject "один и тот же" || bad=1
    mkdir -p "$src_keep/child"
    src=$src_keep
    dst=$src_keep/child
    run_quiet "$SH" "$SCRIPT" check "$src" "$dst"
    if ! grep -q '^check_result=REJECT$' "$quc_out" || ! grep -q "внутри другого" "$quc_out"; then
        echo "nested not rejected"
        cat "$quc_out"
        bad=1
    fi
    usb1=$WORK/t-$current/usb1
    usb10=$WORK/t-$current/usb10
    mkdir -p "$usb1" "$usb10"
    mount -t tmpfs -o size=8m tmpfs "$usb1" || bad=1
    mount -t tmpfs -o size=8m tmpfs "$usb10" || bad=1
    echo y > "$usb1/y.txt"
    run_quiet "$SH" "$SCRIPT" check "$usb1" "$usb10"
    if ! grep -q '^check_result=OK$' "$quc_out"; then
        echo "usb1/usb10 rejected"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "same or nested paths"; fi
}

test_T09() {
    bad=0
    src=$WORK/t-$current/src
    dst=$WORK/t-$current/plain
    mkdir -p "$src" "$dst"
    mount -t tmpfs -o size=16m tmpfs "$src" || { fail "mount"; return; }
    echo x > "$src/a.txt"
    expect_reject "точкой монтирования" || bad=1
    if [ -e "$dst/a.txt" ]; then
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" check "$src" /
    if ! grep -q '^check_result=REJECT$' "$quc_out"; then
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" check / "$dst"
    if ! grep -q '^check_result=REJECT$' "$quc_out"; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "not mounted or system root"; fi
}

test_T10() {
    bad=0
    make_pair || { fail "mount"; return; }
    echo KEEP > "$dst/keep.txt"
    echo other > "$src/other.txt"
    expect_reject "не пустое" || bad=1
    if [ "$(cat "$dst/keep.txt")" != KEEP ] || [ -e "$dst/other.txt" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "non-empty dest"; fi
}

test_T11() {
    bad=0
    make_pair || { fail "mount"; return; }
    echo ok > "$src/ok.txt"
    echo secret > "$src/quc-unreadable"
    chmod 000 "$src/quc-unreadable"
    gcc -shared -fPIC -O2 -o "$WORK/eacess.so" "$ROOT/tests/eacess_preload.c" -ldl || {
        fail "preload compile"
        return
    }
    save_src
    LD_PRELOAD=$WORK/eacess.so
    export LD_PRELOAD
    run_start "$src" "$dst"
    unset LD_PRELOAD
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 160)
    if [ "$st" = SUCCESS ] || [ "$st" != PARTIAL ]; then
        echo "status=$st"
        bad=1
    fi
    if [ "$(job_field files_failed)" = 0 ]; then
        bad=1
    fi
    cmp -s "$src/ok.txt" "$dst/ok.txt" || bad=1
    if [ -e "$dst/quc-unreadable" ] || [ -L "$dst/quc-unreadable" ]; then
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "unreadable file status=$st"; fi
}

test_T12() {
    bad=0
    make_pair 8m 256k || { fail "mount"; return; }
    echo small > "$src/a.txt"
    run_quiet "$SH" "$SCRIPT" check "$src" "$dst"
    if ! grep -q '^check_result=REJECT$' "$quc_out" || ! grep -q "недостаточно" "$quc_out"; then
        echo "space check"
        cat "$quc_out"
        bad=1
    fi
    run_start "$src" "$dst"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    if [ "$(job_field copy_status)" != FAILED ]; then
        bad=1
    fi
    if [ -e "$dst/a.txt" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "no space"; fi
}

test_T13() {
    bad=0
    make_pair || { fail "mount"; return; }
    echo one > "$src/a.txt"
    echo two > "$src/b.txt"
    export QUC_FILE_PAUSE=8
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    pid=$(awk -F= '$1=="pid"{print $2; exit}' "$XDG_STATE_HOME/quiet-usb-copy/owner")
    case $pid in
        ''|0|1|*[!0-9]*) bad=1 ;;
        *) kill -TERM "$pid" 2>/dev/null || bad=1 ;;
    esac
    st=$(wait_done 80)
    if [ "$st" != INTERRUPTED ]; then
        echo "status=$st"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "interrupt status=$st"; fi
}

test_T14() {
    bad=0
    src_a=$WORK/t-$current/src-a
    dst_a=$WORK/t-$current/dst-a
    src_b=$WORK/t-$current/src-b
    dst_b=$WORK/t-$current/dst-b
    mkdir -p "$src_a" "$dst_a" "$src_b" "$dst_b"
    mount -t tmpfs -o size=16m tmpfs "$src_a" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$dst_a" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$src_b" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$dst_b" || { fail "mount"; return; }
    echo a > "$src_a/a.txt"
    echo b > "$src_b/b.txt"
    export QUC_FILE_PAUSE=10
    run_start "$src_a" "$dst_a"
    if [ "$quc_ec" -ne 0 ]; then
        bad=1
    fi
    run_start "$src_b" "$dst_b"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "second start ec=$quc_ec"
        bad=1
    fi
    if [ -e "$dst_b/b.txt" ]; then
        bad=1
    fi
    if [ "$(job_field copy_status)" != RUNNING ]; then
        echo "first job $(job_field copy_status)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ] && [ "$st" != INTERRUPTED ]; then
        echo "after stop $st"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "parallel start"; fi
}

test_T15() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'alpha-one\n' > "$src/a.txt"
    printf 'bravo-two\n' > "$src/b.txt"
    printf 'charlie-three\n' > "$src/c.txt"
    save_src
    export QUC_FILE_PAUSE=2
    run_start "$src" "$dst"
    i=0
    saw=0
    while [ "$i" -lt 40 ]; do
        n=$(job_field files_done || true)
        case $n in
            ''|0) ;;
            *) saw=1; break ;;
        esac
        st=$(job_field copy_status || true)
        case $st in
            SUCCESS|PARTIAL|FAILED|UNCERTAIN) break ;;
        esac
        sleep 0.2
        i=$((i + 1))
    done
    if [ "$saw" -ne 1 ]; then
        echo "did not observe partial progress status=$(job_field copy_status) done=$(job_field files_done)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    if [ "$st" = SUCCESS ]; then
        bad=1
    fi
    copied=''
    for name in a.txt b.txt c.txt; do
        if [ -f "$dst/$name" ]; then
            copied=$name
            break
        fi
    done
    if [ -z "$copied" ]; then
        echo "nothing copied"
        bad=1
    else
        printf 'SHORT\n' > "$dst/$copied"
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec"
        bad=1
    fi
    st=$(wait_done 120)
    if [ "$st" != SUCCESS ]; then
        echo "resume status=$st"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "resume"; fi
}

test_T16() {
    bad=0
    make_pair || { fail "mount"; return; }
    outside=$WORK/t-$current/outside
    mkdir -p "$outside"
    printf 'SECRET\n' > "$outside/secret.txt"
    printf 'inside\n' > "$src/real.txt"
    ln -s real.txt "$src/inner"
    ln -s "$outside/secret.txt" "$src/escape"
    ln -s "$outside" "$src/dirlink"
    ln -s ../outside/secret.txt "$src/rel"
    save_src
    run_start "$src" "$dst"
    st=$(wait_done)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ ! -L "$dst/escape" ] || [ ! -L "$dst/dirlink" ] || [ ! -L "$dst/inner" ]; then
        bad=1
    fi
    if [ -f "$dst/dirlink" ] && [ ! -L "$dst/dirlink" ]; then
        bad=1
    fi
    if find "$dst" -xdev -type f -print | grep -q 'secret.txt$'; then
        echo "secret content was copied"
        bad=1
    fi
    if [ "$(readlink "$dst/escape")" != "$outside/secret.txt" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "symlinks status=$st"; fi
}

test_T17() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'stable-start\n' > "$src/live.txt"
    export QUC_POST_COPY_DELAY=4
    run_start "$src" "$dst"
    (
        i=0
        while [ "$i" -lt 200 ]; do
            ph=$(job_field phase || true)
            case $ph in
                confirming:*)
                    printf 'x\n' >> "$src/live.txt"
                    ;;
            esac
            st=$(job_field copy_status || true)
            case $st in
                SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) exit 0 ;;
            esac
            sleep 0.2
            i=$((i + 1))
        done
    ) &
    watcher=$!
    st=$(wait_done 200)
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    if [ "$st" != UNCERTAIN ]; then
        echo "status=$st phase=$(job_field phase) uncertain=$(job_field files_uncertain)"
        bad=1
    fi
    if [ "$(job_field files_uncertain)" = 0 ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "live change status=$st"; fi
}

test_T18() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'checksum-me\n' > "$src/a.txt"
    mkdir -p "$src/sub"
    printf 'more\n' > "$src/sub/b.txt"
    run_start "$src" "$dst"
    st=$(wait_done)
    if [ "$st" != SUCCESS ]; then
        echo "copy $st"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^verify_status=checksum$' "$quc_out"; then
        echo "clean verify failed"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$(job_field copy_status)" != SUCCESS ]; then
        bad=1
    fi
    printf 'Z' | dd of="$dst/a.txt" bs=1 count=1 conv=notrunc status=none
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -eq 0 ] || ! grep -q '^verify_status=failed$' "$quc_out"; then
        echo "corrupt verify"
        cat "$quc_out"
        bad=1
    fi
    if [ "$(job_field copy_status)" != SUCCESS ]; then
        echo "copy status rewritten: $(job_field copy_status)"
        bad=1
    fi
    if [ "$(job_field verify_status)" != failed ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "hash verify"; fi
}

test_T19() {
    bad=0
    lim=$WORK/t-$current/bin
    mkdir -p "$lim"
    for tool in find stat awk od tr mkdir rmdir rm mv ln chmod date readlink sleep cat cp grep dirname basename cmp; do
        srcbin=$(PATH=$ORIG_PATH command -v "$tool") || { echo "missing $tool"; bad=1; break; }
        ln -s "$srcbin" "$lim/$tool"
    done
    if env PATH="$lim" command -v sha256sum >/dev/null 2>&1 || env PATH="$lim" command -v flock >/dev/null 2>&1 || env PATH="$lim" command -v setsid >/dev/null 2>&1; then
        echo "optional tool leaked into PATH"
        bad=1
    fi
    make_pair || { fail "mount"; return; }
    printf 'fallback\n' > "$src/a.txt"
    mkdir -p "$src/empty"
    env PATH="$lim" "$SH" "$SCRIPT" check "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    if ! grep -q '^check_result=OK$' "$WORK/last.out"; then
        echo "limited check failed"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    env PATH="$lim" "$SH" "$SCRIPT" start "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    quc_ec=$?
    if [ "$quc_ec" -ne 0 ] || [ -s "$WORK/last.out" ] || [ -s "$WORK/last.err" ]; then
        echo "limited start ec=$quc_ec"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    st=$(wait_done 120)
    if [ "$st" != SUCCESS ]; then
        echo "limited status=$st"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$(job_field metadata_gaps)" != 1 ]; then
        echo "expected metadata fallback"
        bad=1
    fi
    if [ "$(job_field sync_status)" != unconfirmed ]; then
        echo "sync $(job_field sync_status)"
        bad=1
    fi
    if [ -n "$(job_field error)" ]; then
        echo "sync leaked into error: $(job_field error)"
        bad=1
    fi
    env PATH="$lim" "$SH" "$SCRIPT" status >"$WORK/last.out" 2>"$WORK/last.err"
    if ! grep -q '^copy_status=SUCCESS$' "$WORK/last.out" || ! grep -q '^sync_status=unconfirmed$' "$WORK/last.out" || ! grep -q 'Извлечение:' "$WORK/last.out"; then
        echo "limited status axes"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    if grep -q 'данные назначения не подтверждены синхронизацией' "$WORK/last.out"; then
        echo "sync failure stored as copy error"
        bad=1
    fi
    env PATH="$lim" "$SH" "$SCRIPT" verify >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ] || ! grep -q '^verify_status=byte$' "$WORK/last.out"; then
        echo "expected byte compare"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    if grep -q 'verify_status=checksum' "$WORK/last.out"; then
        bad=1
    fi
    src2=$WORK/t-$current/src2
    dst2=$WORK/t-$current/dst2
    src3=$WORK/t-$current/src3
    dst3=$WORK/t-$current/dst3
    mkdir -p "$src2" "$dst2" "$src3" "$dst3"
    mount -t tmpfs -o size=8m tmpfs "$src2" || bad=1
    mount -t tmpfs -o size=8m tmpfs "$dst2" || bad=1
    mount -t tmpfs -o size=8m tmpfs "$src3" || bad=1
    mount -t tmpfs -o size=8m tmpfs "$dst3" || bad=1
    echo p > "$src2/p.txt"
    echo q > "$src3/q.txt"
    env PATH="$lim" QUC_FILE_PAUSE=8 "$SH" "$SCRIPT" start "$src2" "$dst2" >"$WORK/last.out" 2>"$WORK/last.err"
    env PATH="$lim" "$SH" "$SCRIPT" start "$src3" "$dst3" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -eq 0 ] || [ -e "$dst3/q.txt" ]; then
        echo "mkdir lock did not block the second start"
        bad=1
    fi
    env PATH="$lim" "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "optional tools fallback"; fi
}

test_T20() {
    bad=0
    xdg=$WORK/t-$current/xdg-link
    mkdir -p "$xdg" "$WORK/t-$current/real-state"
    ln -s "$WORK/t-$current/real-state" "$xdg/quiet-usb-copy"
    src=$WORK/t-$current/src
    dst=$WORK/t-$current/dst
    mkdir -p "$src" "$dst"
    mount -t tmpfs -o size=8m tmpfs "$src" || { fail "mount"; return; }
    mount -t tmpfs -o size=8m tmpfs "$dst" || { fail "mount"; return; }
    echo a > "$src/a.txt"
    run_quiet env XDG_STATE_HOME="$xdg" HOME="$HOME" "$SH" "$SCRIPT" start "$src" "$dst"
    if [ "$quc_ec" -ne 70 ] || [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        echo "symlink state ec=$quc_ec out=$quc_out_n err=$quc_err_n"
        bad=1
    fi
    if [ "$(count_live "$xdg")" != 0 ]; then
        bad=1
    fi
    if [ -e "$dst/a.txt" ]; then
        bad=1
    fi
    ro=$WORK/t-$current/ro
    mkdir -p "$ro"
    if mount -t tmpfs -o size=1m,ro tmpfs "$ro"; then
        run_quiet env XDG_STATE_HOME="$ro/state" HOME="$HOME" "$SH" "$SCRIPT" start "$src" "$dst"
        if [ "$quc_ec" -ne 70 ] || [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
            echo "ro state ec=$quc_ec"
            bad=1
        fi
        if [ -e "$dst/a.txt" ]; then
            bad=1
        fi
    else
        echo "read-only remount unavailable"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "unwritable journal"; fi
}

test_T21() {
    bad=0
    make_pair || { fail "mount"; return; }
    echo slow > "$src/a.txt"
    export QUC_FILE_PAUSE=30
    t0=$(date +%s)
    run_start "$src" "$dst"
    t1=$(date +%s)
    elapsed=$((t1 - t0))
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    if [ "$elapsed" -ge 12 ]; then
        echo "start blocked for ${elapsed}s"
        bad=1
    fi
    if [ "$(job_field copy_status)" != RUNNING ]; then
        echo "expected RUNNING got $(job_field copy_status) after ${elapsed}s"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "quiet start"; fi
}

test_T22() {
    bad=0
    make_pair || { fail "mount"; return; }
    echo a > "$src/a.txt"
    echo b > "$src/b.txt"
    export QUC_FILE_PAUSE=8
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" stop
    if [ "$quc_ec" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ]; then
        echo "status=$st"
        bad=1
    fi
    sleep 0.3
    left=$(count_live "$XDG_STATE_HOME/quiet-usb-copy")
    if [ "$left" != 0 ]; then
        echo "still running: $left"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "stop"; fi
}

test_T23() {
    bad=0
    sleep 120 &
    foreign=$!
    quc_resolve_tools || bad=1
    start=$(quc_proc_starttime "$foreign" || true)
    if [ -z "$start" ]; then
        bad=1
    fi
    base=$XDG_STATE_HOME/quiet-usb-copy
    mkdir -p "$base/jobs"
    chmod 700 "$base"
    cat > "$base/owner" <<EOF
pid=$foreign
starttime=$start
token=not-this-program
job=not-a-job
EOF
    printf '%s\n' "$$" > "$base/lock.d-not-used"
    run_quiet "$SH" "$SCRIPT" stop
    if ! grep -q 'Чужой процесс не затронут' "$quc_out"; then
        echo "stop output:"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if ! kill -0 "$foreign" 2>/dev/null; then
        echo "foreign sleep was signalled"
        bad=1
    fi
    kill "$foreign" 2>/dev/null || true
    wait "$foreign" 2>/dev/null || true
    # Stale pid must be cleared and must not be signalled.
    cat > "$base/owner" <<EOF
pid=999999
starttime=1
token=stale
job=missing
EOF
    mkdir -p "$base/lock.d"
    printf '999999\n' > "$base/lock.d/pid"
    run_quiet "$SH" "$SCRIPT" stop
    if ! grep -q 'устаревшая блокировка' "$quc_out"; then
        echo "stale output:"
        cat "$quc_out"
        bad=1
    fi
    if [ -f "$base/owner" ]; then
        echo "stale owner remains"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "pid reuse"; fi
}

test_T24() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || { fail "tools"; return; }
    quc_prepare_state || { fail "state"; return; }
    quc_source=$src
    quc_target=$dst
    quc_source_dev=$(quc_dev_of "$src")
    quc_target_dev=$(quc_dev_of "$dst")
    quc_source_fs=tmpfs
    quc_target_fs=vfat
    quc_source_uuid=$(quc_uuid_of "$src" || true)
    quc_target_uuid=$(quc_uuid_of "$dst" || true)
    quc_source_spec=tmpfs
    quc_target_spec=tmpfs
    quc_job_dir=$quc_jobs_dir/unit-fat
    mkdir -p "$quc_job_dir"
    quc_log_file=$quc_job_dir/log
    quc_meta_file=$quc_job_dir/done.meta
    : > "$quc_log_file"
    : > "$quc_meta_file"
    quc_verify_during=0
    quc_bytes_done=0
    quc_metadata_gaps=0
    quc_cp_sparse=0
    quc_sync_mode=none
    quc_sync_status=unconfirmed
    quc_run_mode=fresh
    printf 'small\n' > "$src/small.txt"
    quc_copy_regular "$src/small.txt" "$dst/small.txt" small.txt "$(quc_hex_encode "$src/small.txt")"
    small_rc=$?
    if [ "$small_rc" -ne 0 ] || ! cmp -s "$src/small.txt" "$dst/small.txt"; then
        echo "small vfat-labelled copy rc=$small_rc"
        bad=1
    fi
    truncate -s 4294967296 "$src/big.bin" || bad=1
    quc_copy_regular "$src/big.bin" "$dst/big.bin" big.bin "$(quc_hex_encode "$src/big.bin")"
    big_rc=$?
    if [ "$big_rc" -ne 4 ]; then
        echo "big file rc=$big_rc"
        bad=1
    fi
    if [ -e "$dst/big.bin" ]; then
        bad=1
    fi
    if ! grep -q 'FAT32' "$quc_log_file"; then
        echo "log missed FAT32"
        cat "$quc_log_file"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "FAT32 limit"; fi
}

test_T25() {
    bad=0
    quc_fat_name_bad vfat 'COM1' || bad=1
    quc_fat_name_bad vfat 'dir/foo:bar' || bad=1
    quc_fat_name_bad ext4 'foo:bar' && bad=1
    src=$WORK/t-$current/src
    dst=$WORK/t-$current/dst-quc-nosymlink
    mkdir -p "$src" "$dst"
    mount -t tmpfs -o size=16m tmpfs "$src" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$dst" || { fail "mount"; return; }
    printf 'ok\n' > "$src/ok.txt"
    ln -s ok.txt "$src/link"
    mkfifo "$src/pipe" || bad=1
    wrap=$WORK/t-$current/bin
    mkdir -p "$wrap"
    real_ln=$(PATH=$ORIG_PATH command -v ln)
    cat > "$wrap/ln" <<EOF
#!/bin/sh
for a in "\$@"; do
    case \$a in
        *quc-nosymlink*)
            echo "Operation not permitted" >&2
            exit 1
            ;;
    esac
done
exec $real_ln "\$@"
EOF
    chmod 755 "$wrap/ln"
    env PATH="$wrap:$ORIG_PATH" "$SH" "$SCRIPT" start "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ] || [ -s "$WORK/last.out" ] || [ -s "$WORK/last.err" ]; then
        bad=1
    fi
    st=$(wait_done 120)
    if [ "$st" != PARTIAL ]; then
        echo "status=$st"
        bad=1
    fi
    cmp -s "$src/ok.txt" "$dst/ok.txt" || bad=1
    if [ -e "$dst/pipe" ] || [ -L "$dst/link" ] || [ -e "$dst/link" ]; then
        echo "special or link was created"
        bad=1
    fi
    log=$(find "$XDG_STATE_HOME/quiet-usb-copy/jobs" -name log -type f | head -n 1)
    if [ -z "$log" ] || ! grep -q 'специальный файл' "$log" || ! grep -q 'символьные ссылки' "$log"; then
        echo "policy log missing"
        cat "$log"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "special files and metadata policy"; fi
}

test_T26() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'keep\n' > "$src/keep.txt"
    mkdir -p "$src/nested"
    mount -t tmpfs -o size=4m tmpfs "$src/nested" || { fail "nested mount"; return; }
    printf 'SECRET\n' > "$src/nested/secret.txt"
    run_start "$src" "$dst"
    st=$(wait_done)
    if [ "$st" != PARTIAL ]; then
        echo "status=$st"
        bad=1
    fi
    cmp -s "$src/keep.txt" "$dst/keep.txt" || bad=1
    if [ -e "$dst/nested/secret.txt" ] || find "$dst" -xdev -type f -print | grep -q secret.txt; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "nested mount status=$st"; fi
}

test_T27() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    printf 'three\n' > "$src/c.txt"
    export QUC_FILE_PAUSE=3
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    if ! umount "$dst"; then
        echo "umount failed"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != FAILED ]; then
        echo "status=$st"
        bad=1
    fi
    left=$(find "$dst" -mindepth 1 -print 2>/dev/null)
    if [ -n "$left" ]; then
        echo "files landed on the underlying directory:"
        printf '%s\n' "$left"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "unplug status=$st"; fi
}

test_dx() {
    bad=0
    run_quiet "$SH" "$SCRIPT" version
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^quiet-usb-copy 0.3.0$' "$quc_out" || ! grep -q '^build 20261029.2$' "$quc_out"; then
        echo "version"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" help
    if [ "$quc_ec" -ne 0 ] || ! grep -q 'doctor' "$quc_out" || ! grep -q 'selftest' "$quc_out" || ! grep -q 'gentle' "$quc_out"; then
        echo "help"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT"
    if [ "$quc_ec" -ne 2 ] || ! grep -q 'error_code=E_USAGE' "$quc_err" || ! grep -q 'только в терминале' "$quc_err"; then
        echo "no-args ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ -d "$XDG_STATE_HOME/quiet-usb-copy" ]; then
        echo "no-args created state"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" selftest
    if [ "$quc_ec" -ne 0 ] || [ "$quc_err_n" != 0 ] || ! grep -q '^selftest: готово$' "$quc_out" || ! grep -q '^error_code=E_OK$' "$quc_out"; then
        echo "selftest ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" selftest extra
    if [ "$quc_ec" -ne 2 ] || ! grep -q 'error_code=E_USAGE' "$quc_err"; then
        echo "selftest args"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" doctor
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^error_code=E_OK$' "$quc_out" || ! grep -q 'find -print0: да' "$quc_out" || ! grep -q '^sync-проба: data$' "$quc_out" || ! grep -q 'Pop!_OS 24.04' "$quc_out" || ! grep -q 'не отмечены как проверенные' "$quc_out"; then
        echo "doctor"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" doctor extra
    if [ "$quc_ec" -ne 2 ] || ! grep -q 'error_code=E_USAGE' "$quc_err"; then
        echo "doctor args"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" start --profile fast
    if [ "$quc_ec" -ne 2 ] || [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        echo "fast profile noisy ec=$quc_ec out=$quc_out_n err=$quc_err_n"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ] || [ -n "$(find "$XDG_STATE_HOME/quiet-usb-copy/jobs" -mindepth 1 -print 2>/dev/null)" ]; then
        echo "fast profile created a job"
        bad=1
    fi
    if ! grep -q 'неизвестный профиль' "$XDG_STATE_HOME/quiet-usb-copy/last-error"; then
        echo "fast profile last-error"
        cat "$XDG_STATE_HOME/quiet-usb-copy/last-error" 2>/dev/null
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" cleanup extra
    if [ "$quc_ec" -ne 2 ] || ! grep -q 'error_code=E_USAGE' "$quc_err"; then
        echo "cleanup args"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if [ "$quc_ec" -ne 1 ] || ! grep -q 'error_code=E_NOJOB' "$quc_out"; then
        echo "missing job"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "dx commands"; fi
}

test_legacy() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'legacy\n' > "$src/a.txt"
    run_quiet "$SH" "$SCRIPT" "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        bad=1
    fi
    st=$(wait_done)
    [ "$st" = SUCCESS ] || bad=1
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "legacy two-argument start"; fi
}

pty_run() {
    pin=$1
    shift
    quc_out=$WORK/last.out
    quc_meta=$WORK/last.pty
    : > "$quc_out"
    : > "$quc_meta"
    python3 "$ROOT/tests/pty_menu.py" --timeout "${QUC_PTY_TIMEOUT:-30}" --input "$pin" --output "$quc_out" -- "$@" >"$quc_meta" 2>"$WORK/last.err"
    quc_pty_rc=$?
    quc_ec=$(awk -F= '$1 == "PTY_EXIT" { print $2; exit }' "$quc_meta")
    quc_pty_first=$(awk -F= '$1 == "PTY_FIRST" { print $2; exit }' "$quc_meta")
    quc_pty_esc=$(awk -F= '$1 == "PTY_ESC" { print $2; exit }' "$quc_meta")
}

no_esc() {
    python3 -c 'import sys; data=open(sys.argv[1],"rb").read(); raise SystemExit(0 if b"\x1b" not in data else 1)' "$1"
}

fake_row() {
    printf '%s\t%s\t%s\t%s\t%s\tyes\t%s\n' \
        "$(quc_hex_encode "$1")" "$2" "$(quc_hex_encode "$3")" "$(quc_hex_encode "$4")" "${5:-0}" "${6:-}"
}

test_UX01() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'slide\n' > "$src/deck.txt"
    fake=$WORK/t-$current/fake.tsv
    fake_row "$src" ext4 tmpfs PRESENTATION 33554432 30000000 > "$fake"
    fake_row "$dst" ext4 tmpfs BACKUP 67108864 65000000 >> "$fake"
    export QUC_FAKE_VOLUMES=$fake
    printf '1\n2\n1\n' > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_pty_rc" -ne 0 ] || [ "$quc_ec" != 0 ]; then
        echo "pty ec=$quc_ec driver=$quc_pty_rc"
        cat "$quc_out" "$quc_meta" "$WORK/last.err"
        bad=1
    fi
    if ! awk -v t="${quc_pty_first:-99}" 'BEGIN { exit !(t+0 >= 0 && t+0 < 3) }'; then
        echo "menu slow first=$quc_pty_first"
        bad=1
    fi
    if ! grep -q 'Quiet USB Copy' "$quc_out" || ! grep -q 'PRESENTATION' "$quc_out" || ! grep -q 'BACKUP' "$quc_out" || ! grep -q 'Проверка: готово' "$quc_out" || ! grep -q 'Копирование запущено в фоне' "$quc_out"; then
        echo "menu text"
        cat "$quc_out"
        bad=1
    fi
    if ! awk 'index($0, "Проверка: готово") { seen=1 } index($0, "Копирование запущено") { if (!seen) bad=1 } END { exit bad+0 }' "$quc_out"; then
        echo "launch before preflight"
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Копирование завершено.' "$quc_out" || grep -q 'copy_status=' "$quc_out" || grep -q 'можно извлекать' "$quc_out"; then
        echo "calm status"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "interactive start"; fi
}

test_UX02() {
    bad=0
    printf '0\n' > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || ! grep -q 'Копирование не запущено.' "$quc_out" || ! grep -q 'error_code=E_OK' "$quc_out" || grep -q 'Копирование запущено' "$quc_out"; then
        echo "cancel"
        cat "$quc_out" "$quc_meta"
        bad=1
    fi
    if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ]; then
        echo "cancel created a job"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "cancel"; fi
}

test_UX03() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf '%s\n%s\n1\n0\n' "$src" "$src" > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || ! grep -q 'один и тот же' "$quc_out" || ! grep -q 'запускать нельзя' "$quc_out" || ! grep -q 'Запуск запрещён.' "$quc_out" || grep -q 'Копирование запущено' "$quc_out"; then
        echo "same device"
        cat "$quc_out"
        bad=1
    fi
    if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ]; then
        echo "reject created a job"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "same device"; fi
}

test_UX04() {
    bad=0
    run_quiet "$SH" "$SCRIPT" </dev/null
    if [ "$quc_ec" -ne 2 ] || ! grep -q 'только в терминале' "$quc_err" || ! grep -q 'error_code=E_USAGE' "$quc_err"; then
        echo "no tty ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ -d "$XDG_STATE_HOME/quiet-usb-copy" ]; then
        echo "no tty created state"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "no tty"; fi
}

test_UX05() {
    bad=0
    printf '0\n' > "$WORK/t-$current/in"
    TERM=dumb NO_COLOR=1 pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || [ "$quc_pty_esc" != 0 ] || ! grep -q 'Quiet USB Copy' "$quc_out" || ! no_esc "$quc_out"; then
        echo "color esc=$quc_pty_esc"
        cat "$quc_out" "$quc_meta"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "no color"; fi
}

test_UX06() {
    bad=0
    make_pair || { fail "mount"; return; }
    third=$WORK/t-$current/third
    mkdir -p "$third"
    mount -t tmpfs -o size=8m tmpfs "$third" || { fail "mount"; return; }
    fake=$WORK/t-$current/fake.tsv
    fake_row "$src" ext4 tmpfs ONE 1000 1000 > "$fake"
    fake_row "$dst" ext4 tmpfs TWO 2000 2000 >> "$fake"
    fake_row "$third" ext4 tmpfs THREE 3000 3000 >> "$fake"
    export QUC_FAKE_VOLUMES=$fake
    printf '1\n2\n0\n' > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || ! grep -q 'ONE' "$quc_out" || ! grep -q 'TWO' "$quc_out" || ! grep -q 'THREE' "$quc_out" || ! grep -q 'ONE → TWO' "$quc_out" || ! grep -q 'Проверка: готово' "$quc_out" || grep -q 'Копирование запущено' "$quc_out"; then
        echo "several"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "several volumes"; fi
}

test_UX07() {
    bad=0
    make_pair || { fail "mount"; return; }
    fake=$WORK/t-$current/fake.tsv
    printf '%s\text4\t%s\t\t1000\tyes\t1000\n' "$(quc_hex_encode "$src")" "$(quc_hex_encode tmpfs)" > "$fake"
    esc_label=$(printf 'A\033B')
    fake_row "$dst" ext4 tmpfs "$esc_label" 2000 2000 >> "$fake"
    export QUC_FAKE_VOLUMES=$fake
    printf '1\n2\n0\n' > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || ! grep -q 'без метки' "$quc_out" || ! grep -q 'Проверка: готово' "$quc_out" || ! no_esc "$quc_out"; then
        echo "unlabeled"
        cat "$quc_out"
        bad=1
    fi
    if ! grep -q 'без метки →' "$quc_out"; then
        echo "direction label"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "unlabeled volume"; fi
}

test_UX08() {
    bad=0
    lim=$WORK/t-$current/bin
    mkdir -p "$lim"
    for tool in find stat awk od tr mkdir rmdir rm mv ln chmod date readlink sleep cat cp grep dirname basename; do
        srcbin=$(PATH=$ORIG_PATH command -v "$tool") || { echo "missing $tool"; bad=1; break; }
        ln -s "$srcbin" "$lim/$tool"
    done
    make_pair || { fail "mount"; return; }
    printf 'x\n' > "$src/a.txt"
    printf '%s\n%s\n0\n' "$src" "$dst" > "$WORK/t-$current/in"
    py=$(PATH=$ORIG_PATH command -v python3)
    env PATH="$lim" "$py" "$ROOT/tests/pty_menu.py" --timeout 30 --input "$WORK/t-$current/in" --output "$WORK/last.out" -- /bin/sh "$SCRIPT" >"$WORK/last.pty" 2>"$WORK/last.err"
    quc_ec=$(awk -F= '$1 == "PTY_EXIT" { print $2; exit }' "$WORK/last.pty")
    if [ "$quc_ec" != 0 ] || ! grep -q 'Проверка: готово' "$WORK/last.out" || grep -q 'Копирование запущено' "$WORK/last.out"; then
        echo "optional tools ec=$quc_ec"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    if env PATH="$lim" command -v findmnt >/dev/null 2>&1; then
        echo "findmnt still visible"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "missing optional tools"; fi
}

test_UX09() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'x\n' > "$src/a.txt"
    run_start "$src" "$src"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "noisy failure ec=$quc_ec"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Копирование не выполнено.' "$quc_out" || ! grep -q 'Причина:' "$quc_out" || ! grep -q 'Подробнее: report' "$quc_out" || grep -q 'copy_status=' "$quc_out"; then
        echo "calm failure"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if grep -q 'notify-send' "$quc_out" || grep -q 'zenity' "$quc_out"; then
        echo "notification text"
        bad=1
    fi
    # A desktop notifier already running is not this program. Ours would
    # inherit the test's XDG_STATE_HOME. cat hides processes we cannot read.
    for cmdf in /proc/[0-9]*/cmdline; do
        data=$(tr '\0' ' ' < "$cmdf" 2>/dev/null || true)
        case $data in
            *notify-send*|*zenity*) ;;
            *) continue ;;
        esac
        npid=${cmdf#/proc/}
        npid=${npid%/cmdline}
        envs=$(cat "/proc/$npid/environ" 2>/dev/null | tr '\0' '\n' || true)
        case $envs in
            *"XDG_STATE_HOME=$XDG_STATE_HOME"*)
                echo "notification process $npid"
                bad=1
                ;;
        esac
    done
    if [ "$bad" -eq 0 ]; then pass; else fail "silent failure"; fi
}

test_UX10() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'plain\n' > "$src/note.txt"
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Копирование завершено.' "$quc_out" || ! grep -q 'Проверка содержимого:' "$quc_out" || ! grep -q 'Для извлечения используйте средства ОС.' "$quc_out" || grep -q 'copy_status=' "$quc_out" || grep -q 'можно извлекать' "$quc_out"; then
        echo "human success"
        cat "$quc_out"
        bad=1
    fi
    quc_default_job_vars
    quc_copy_status=PARTIAL
    quc_error='ошибка чтения'
    quc_verify_status=none
    quc_sync_status=unconfirmed
    quc_profile=gentle
    text=$(quc_print_human)
    case $text in
        *'Копирование завершено частично.'*) ;;
        *) echo "partial phrase"; bad=1 ;;
    esac
    case $text in
        *'Причина: ошибка чтения'*) ;;
        *) echo "partial reason"; bad=1 ;;
    esac
    case $text in
        *'Подробнее: report'*) ;;
        *) echo "partial more"; bad=1 ;;
    esac
    case $text in
        *'Копирование завершено.'*) echo "partial called done"; bad=1 ;;
    esac
    quc_copy_status=RUNNING
    quc_error=
    text=$(quc_print_human)
    case $text in
        *'Копирование выполняется.'*) ;;
        *) echo "running phrase"; bad=1 ;;
    esac
    if [ "$bad" -eq 0 ]; then pass; else fail "plain status"; fi
}

test_UX11() {
    bad=0
    quc_resolve_tools || bad=1
    if ! quc_prepare_state; then
        fail "state"
        return
    fi
    keep=$WORK/t-$current/user-data
    mkdir -p "$keep"
    printf 'keep\n' > "$keep/file.txt"
    plant_one() {
        pj_id=$1
        pj_status=$2
        quc_default_job_vars
        quc_job_id=$pj_id
        quc_source=$keep
        quc_target=$keep-dst
        mkdir -p "$quc_target"
        quc_source_spec=tmpfs
        quc_target_spec=tmpfs
        quc_copy_status=$pj_status
        quc_profile=gentle
        quc_job_dir=$quc_jobs_dir/$pj_id
        mkdir -p "$quc_job_dir"
        quc_log_file=$quc_job_dir/log
        printf 'log\n' > "$quc_log_file"
        quc_save_state
    }
    plant_one ux-success SUCCESS || bad=1
    plant_one ux-running RUNNING || bad=1
    printf '%s\n' ux-success > "$quc_current"
    run_quiet "$SH" "$SCRIPT" cleanup --dry-run
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^Удаление не выполнялось.$' "$quc_out" || ! grep -q '^Можно удалить: ux-success$' "$quc_out" || ! grep -q 'ux-running' "$quc_out" || ! grep -q '^Будет удалено служебных заданий: 1$' "$quc_out"; then
        echo "dry-run"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ ! -d "$quc_jobs_dir/ux-success" ] || [ ! -d "$quc_jobs_dir/ux-running" ] || [ ! -f "$keep/file.txt" ]; then
        echo "dry-run deleted data"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" cleanup
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^Удалено служебных заданий: 1$' "$quc_out" || ! grep -q '^Оставлено незавершённых: 1$' "$quc_out"; then
        echo "cleanup"
        cat "$quc_out"
        bad=1
    fi
    if [ -d "$quc_jobs_dir/ux-success" ] || [ ! -d "$quc_jobs_dir/ux-running" ] || [ ! -f "$keep/file.txt" ]; then
        echo "cleanup touched the wrong data"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "cleanup preview"; fi
}

test_UX12() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'done\n' > "$src/a.txt"
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    sleep 0.3
    if [ "$(count_live "$XDG_STATE_HOME/quiet-usb-copy")" != 0 ]; then
        echo "workers left"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "leftover workers"; fi
}

test_UX13() {
    bad=0
    quc_resolve_tools || bad=1
    text=$(quc_fs_caution mysteryfs)
    case $text in
        *'непроверен'*) ;;
        *) echo "unknown fs: $text"; bad=1 ;;
    esac
    case $text in
        *'запускать нельзя'*) echo "unknown fs blocks"; bad=1 ;;
    esac
    text=$(quc_fs_caution ext4)
    if [ -n "$text" ]; then
        echo "ext4 caution: $text"
        bad=1
    fi
    text=$(quc_fs_caution vfat)
    case $text in
        *'FAT:'*) ;;
        *) echo "fat caution"; bad=1 ;;
    esac
    make_pair || { fail "mount"; return; }
    printf '%s\n%s\n0\n' "$src" "$dst" > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || ! grep -q 'Проверка: готово' "$quc_out" || grep -q 'запускать нельзя' "$quc_out"; then
        echo "known fs preflight"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "unknown filesystem"; fi
}

test_UX14() {
    bad=0
    src_a=$WORK/t-$current/src-a
    dst_a=$WORK/t-$current/dst-a
    src_b=$WORK/t-$current/src-b
    dst_b=$WORK/t-$current/dst-b
    mkdir -p "$src_a" "$dst_a" "$src_b" "$dst_b"
    mount -t tmpfs -o size=16m tmpfs "$src_a" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$dst_a" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$src_b" || { fail "mount"; return; }
    mount -t tmpfs -o size=16m tmpfs "$dst_b" || { fail "mount"; return; }
    printf 'a\n' > "$src_a/a.txt"
    printf 'b\n' > "$src_a/b.txt"
    printf 'c\n' > "$src_b/c.txt"
    export QUC_FILE_PAUSE=8
    run_start "$src_a" "$dst_a"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    run_start "$src_b" "$dst_b"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "second start ec=$quc_ec"
        bad=1
    fi
    if [ -e "$dst_b/c.txt" ]; then
        echo "second copy wrote"
        bad=1
    fi
    if [ "$(job_field copy_status)" != RUNNING ]; then
        echo "first job $(job_field copy_status)"
        bad=1
    fi
    if ! grep -q 'уже выполняется другое задание' "$XDG_STATE_HOME/quiet-usb-copy/last-error"; then
        echo "conflict message"
        cat "$XDG_STATE_HOME/quiet-usb-copy/last-error" 2>/dev/null
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ] && [ "$st" != INTERRUPTED ]; then
        echo "after stop $st"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "conflicting start"; fi
}

test_UX15() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=6
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" stop
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ] && [ "$st" != INTERRUPTED ]; then
        echo "stopped $st"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Копирование остановлено.' "$quc_out" || grep -q 'copy_status=' "$quc_out"; then
        echo "stopped text"
        cat "$quc_out"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume noisy ec=$quc_ec"
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ]; then
        echo "resumed $st"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "resume after stop"; fi
}

if [ "$(id -u)" != 0 ]; then
    echo "FAIL setup: user namespace did not map root"
    exit 1
fi

QUC_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"
unset QUC_SOURCE_ONLY

run_case U-static test_static
run_case U-dx test_dx
run_case U-units test_units
run_case T01 test_T01
run_case T02 test_T02
run_case T03 test_T03
run_case T04 test_T04
run_case T05 test_T05
run_case T06 test_T06
run_case T07 test_T07
run_case T08 test_T08
run_case T09 test_T09
run_case T10 test_T10
run_case T11 test_T11
run_case T12 test_T12
run_case T13 test_T13
run_case T14 test_T14
run_case T15 test_T15
run_case T16 test_T16
run_case T17 test_T17
run_case T18 test_T18
run_case T19 test_T19
run_case T20 test_T20
run_case T21 test_T21
run_case T22 test_T22
run_case T23 test_T23
run_case T24 test_T24
run_case T25 test_T25
run_case T26 test_T26
run_case T27 test_T27
run_case U-legacy test_legacy
run_case UX01 test_UX01
run_case UX02 test_UX02
run_case UX03 test_UX03
run_case UX04 test_UX04
run_case UX05 test_UX05
run_case UX06 test_UX06
run_case UX07 test_UX07
run_case UX08 test_UX08
run_case UX09 test_UX09
run_case UX10 test_UX10
run_case UX11 test_UX11
run_case UX12 test_UX12
run_case UX13 test_UX13
run_case UX14 test_UX14
run_case UX15 test_UX15

leaked=$(count_live "$WORK")
if [ "$leaked" != 0 ]; then
    current=cleanup
    fail "leftover processes: $leaked"
fi

printf 'RESULT passes=%s fails=%s\n' "$passes" "$fails"
if [ "$fails" -ne 0 ]; then
    exit 1
fi
exit 0

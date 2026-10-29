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
    unset LD_PRELOAD
    export HOME=$WORK/home
    export XDG_STATE_HOME=$WORK/xdg-$current
    export LC_ALL=C
    mkdir -p "$HOME" "$XDG_STATE_HOME" "$WORK/t-$current"
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
    if ! grep -q 'start' "$quc_out"; then
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

if [ "$(id -u)" != 0 ]; then
    echo "FAIL setup: user namespace did not map root"
    exit 1
fi

QUC_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$SCRIPT"
unset QUC_SOURCE_ONLY

run_case U-static test_static
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

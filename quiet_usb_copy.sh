#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC2016
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AdmiralGDR
#
# Quiet USB Copy — тихое копирование одного смонтированного накопителя на другой.
# Запуск без аргументов в терминале показывает один экран выбора съёмных накопителей.
# Запуск: sh quiet_usb_copy.sh start ИСТОЧНИК НАЗНАЧЕНИЕ
# Права только текущего пользователя. Пароль не запрашивается.
# Обычный запуск start ничего не печатает и не открывает окон.
# Итог смотрите командами status и report. Описание: README.md
#
# Успех (SUCCESS) означает, что все обычные файлы, каталоги и ссылки перенесены,
# размеры сошлись, а файлы не менялись во время записи. Это не атомарный снимок
# живой файловой системы. Контрольная сумма — отдельный verify_status.
# Сброс на носитель — отдельный sync_status. Даже command_ok не разрешает
# физически извлекать накопитель: нужна штатная процедура безопасного извлечения ОС.

umask 077

QUC_VERSION=0.3.0
QUC_BUILD=20261029.2
QUC_PARTIAL_PREFIX=.quc-partial.
QUC_MAX_ATTEMPTS=3
QUC_FAT_MAX=4294967295

if [ "${QUC_SOURCE_ONLY:-}" != 1 ]; then
    IFS=' 	
'
fi

quc_norm_uint() {
    n=$1
    case $n in
        ''|*[!0-9]*)
            printf '0\n'
            return
            ;;
    esac
    while :; do
        case $n in
            0?*) n=${n#0} ;;
            *) break ;;
        esac
    done
    if [ -z "$n" ]; then
        n=0
    fi
    printf '%s\n' "$n"
}

quc_is_uint() {
    case ${1:-} in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

quc_hex_encode() {
    printf '%s' "$1" | LC_ALL=C od -An -tx1 | LC_ALL=C tr -d '[:space:]' | LC_ALL=C tr 'A-F' 'a-f'
}

quc_hex_decode() {
    LC_ALL=C awk -v s="$1" 'BEGIN {
        n = length(s)
        if (n == 0 || n % 2 != 0) exit 2
        hex = "0123456789abcdef"
        for (i = 1; i <= n; i += 2) {
            h = index(hex, substr(s, i, 1)) - 1
            l = index(hex, substr(s, i + 1, 1)) - 1
            if (h < 0 || l < 0) exit 2
            printf "%c", h * 16 + l
        }
    }'
}

quc_decode_hex_var() {
    quc_decoded=$(quc_hex_decode "$1" && printf X) || return 1
    quc_decoded=${quc_decoded%X}
}

quc_display_path() {
    printf '%s\0' "$1" | LC_ALL=C awk 'BEGIN {
        RS = "\0"
        for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
    }
    NR == 1 {
        s = $0
        out = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            v = ord[c]
            if (v == "") v = 0
            if (v < 32 || v == 127 || v == 92) out = out sprintf("\\x%02x", v + 0)
            else out = out c
        }
        printf "%s", out
        exit
    }'
}

quc_one_line() {
    printf '%s' "$1" | LC_ALL=C tr '\n\r' '  '
}

quc_now() {
    date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date
}

quc_epoch() {
    date '+%s' 2>/dev/null || printf '0\n'
}

quc_human_bytes() {
    LC_ALL=C awk -v b="${1:-0}" 'BEGIN {
        if (b == "" || b + 0 < 0) b = 0
        b = b + 0
        split("B KiB MiB GiB TiB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b = b / 1024; i++ }
        if (i == 1) printf "%.0f %s", b, u[i]
        else printf "%.1f %s", b, u[i]
    }'
}

quc_add_bytes() {
    LC_ALL=C awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.0f", (a + 0) + (b + 0) }'
}

quc_cmp_num() {
    LC_ALL=C awk -v a="${1:-0}" -v b="${2:-0}" -v op="$3" 'BEGIN {
        a = a + 0; b = b + 0
        if (op == "ge") exit !(a >= b)
        if (op == "gt") exit !(a > b)
        if (op == "lt") exit !(a < b)
        if (op == "le") exit !(a <= b)
        if (op == "eq") exit !(a == b)
        exit 2
    }'
}

quc_proc_starttime() {
    pid=$1
    if ! quc_is_uint "$pid"; then
        return 1
    fi
    if [ ! -r "/proc/$pid/stat" ]; then
        return 1
    fi
    LC_ALL=C awk '{
        s = $0
        sub(/^[^)]*\) /, "", s)
        n = split(s, a, " ")
        if (n >= 20 && a[20] ~ /^[0-9]+$/) { print a[20]; exit 0 }
        exit 1
    }' "/proc/$pid/stat"
}

quc_proc_ppid() {
    pid=$1
    if ! quc_is_uint "$pid"; then
        return 1
    fi
    if [ ! -r "/proc/$pid/status" ]; then
        return 1
    fi
    LC_ALL=C awk '/^PPid:/ { print $2; found = 1; exit } END { exit !found }' "/proc/$pid/status"
}

quc_cmdline_has_exact() {
    pid=$1
    needle=$2
    if [ ! -r "/proc/$pid/cmdline" ]; then
        return 1
    fi
    LC_ALL=C tr '\0' '\n' < "/proc/$pid/cmdline" | LC_ALL=C awk -v n="$needle" '
        $0 == n { found = 1; exit }
        END { exit !found }
    '
}

quc_cmdline_contains() {
    pid=$1
    needle=$2
    if [ ! -r "/proc/$pid/cmdline" ]; then
        return 1
    fi
    LC_ALL=C tr '\0' '\n' < "/proc/$pid/cmdline" | LC_ALL=C awk -v n="$needle" '
        index($0, n) { found = 1; exit }
        END { exit !found }
    '
}

quc_pid_is_worker() {
    pid=$1
    expect_start=$2
    job_dir=$3
    if ! quc_is_uint "$pid" || ! quc_is_uint "$expect_start"; then
        return 1
    fi
    case $pid in
        0|1) return 1 ;;
    esac
    got=$(quc_proc_starttime "$pid") || return 1
    if [ "$got" != "$expect_start" ]; then
        return 1
    fi
    quc_cmdline_has_exact "$pid" _worker || return 1
    quc_cmdline_contains "$pid" quiet_usb_copy.sh || return 1
    quc_cmdline_has_exact "$pid" "$job_dir" || return 1
    return 0
}

quc_job_id_safe() {
    case ${1:-} in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

quc_self_path() {
    case $0 in
        /*) printf '%s\n' "$0" ;;
        *)
            dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P) || return 1
            printf '%s\n' "$dir/$(basename -- "$0")"
            ;;
    esac
}

quc_resolve_tools() {
    quc_missing=''
    quc_bin_find=$(command -v find 2>/dev/null || true)
    quc_bin_stat=$(command -v stat 2>/dev/null || true)
    quc_bin_awk=$(command -v awk 2>/dev/null || true)
    quc_bin_od=$(command -v od 2>/dev/null || true)
    quc_bin_tr=$(command -v tr 2>/dev/null || true)
    quc_bin_mkdir=$(command -v mkdir 2>/dev/null || true)
    quc_bin_rm=$(command -v rm 2>/dev/null || true)
    quc_bin_rmdir=$(command -v rmdir 2>/dev/null || true)
    quc_bin_mv=$(command -v mv 2>/dev/null || true)
    quc_bin_ln=$(command -v ln 2>/dev/null || true)
    quc_bin_chmod=$(command -v chmod 2>/dev/null || true)
    quc_bin_date=$(command -v date 2>/dev/null || true)
    quc_bin_readlink=$(command -v readlink 2>/dev/null || true)
    quc_bin_sleep=$(command -v sleep 2>/dev/null || true)
    quc_bin_cat=$(command -v cat 2>/dev/null || true)
    quc_bin_cp=$(command -v cp 2>/dev/null || true)
    quc_bin_grep=$(command -v grep 2>/dev/null || true)
    quc_bin_dirname=$(command -v dirname 2>/dev/null || true)
    quc_bin_basename=$(command -v basename 2>/dev/null || true)
    quc_missing=''
    if [ -z "$quc_bin_find" ]; then quc_missing="$quc_missing find"; fi
    if [ -z "$quc_bin_stat" ]; then quc_missing="$quc_missing stat"; fi
    if [ -z "$quc_bin_awk" ]; then quc_missing="$quc_missing awk"; fi
    if [ -z "$quc_bin_od" ]; then quc_missing="$quc_missing od"; fi
    if [ -z "$quc_bin_tr" ]; then quc_missing="$quc_missing tr"; fi
    if [ -z "$quc_bin_mkdir" ]; then quc_missing="$quc_missing mkdir"; fi
    if [ -z "$quc_bin_rm" ]; then quc_missing="$quc_missing rm"; fi
    if [ -z "$quc_bin_rmdir" ]; then quc_missing="$quc_missing rmdir"; fi
    if [ -z "$quc_bin_mv" ]; then quc_missing="$quc_missing mv"; fi
    if [ -z "$quc_bin_ln" ]; then quc_missing="$quc_missing ln"; fi
    if [ -z "$quc_bin_chmod" ]; then quc_missing="$quc_missing chmod"; fi
    if [ -z "$quc_bin_date" ]; then quc_missing="$quc_missing date"; fi
    if [ -z "$quc_bin_readlink" ]; then quc_missing="$quc_missing readlink"; fi
    if [ -z "$quc_bin_sleep" ]; then quc_missing="$quc_missing sleep"; fi
    if [ -z "$quc_bin_cat" ]; then quc_missing="$quc_missing cat"; fi
    if [ -z "$quc_bin_cp" ]; then quc_missing="$quc_missing cp"; fi
    if [ -z "$quc_bin_grep" ]; then quc_missing="$quc_missing grep"; fi
    if [ -z "$quc_bin_dirname" ]; then quc_missing="$quc_missing dirname"; fi
    if [ -z "$quc_bin_basename" ]; then quc_missing="$quc_missing basename"; fi
    quc_bin_flock=$(command -v flock 2>/dev/null || true)
    quc_bin_findmnt=$(command -v findmnt 2>/dev/null || true)
    quc_bin_setsid=$(command -v setsid 2>/dev/null || true)
    quc_bin_nohup=$(command -v nohup 2>/dev/null || true)
    quc_bin_nice=$(command -v nice 2>/dev/null || true)
    quc_bin_renice=$(command -v renice 2>/dev/null || true)
    quc_bin_ionice=$(command -v ionice 2>/dev/null || true)
    quc_bin_sync=$(command -v sync 2>/dev/null || true)
    quc_bin_touch=$(command -v touch 2>/dev/null || true)
    quc_bin_sha256=$(command -v sha256sum 2>/dev/null || true)
    quc_bin_sha1=$(command -v sha1sum 2>/dev/null || true)
    quc_bin_md5=$(command -v md5sum 2>/dev/null || true)
    quc_bin_cksum=$(command -v cksum 2>/dev/null || true)
    quc_bin_cmp=$(command -v cmp 2>/dev/null || true)
    if [ -n "$quc_missing" ]; then
        return 1
    fi
    if ! printf 'x' | "$quc_bin_od" -An -tx1 >/dev/null 2>&1; then
        quc_missing=" od -An"
        return 1
    fi
    if ! "$quc_bin_stat" -c '%s' / >/dev/null 2>&1; then
        quc_missing=" stat -c"
        return 1
    fi
    return 0
}

quc_state_base() {
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        printf '%s\n' "$XDG_STATE_HOME/quiet-usb-copy"
    elif [ -n "${HOME:-}" ]; then
        printf '%s\n' "$HOME/.local/state/quiet-usb-copy"
    else
        return 1
    fi
}

quc_prepare_state() {
    base=$(quc_state_base) || return 70
    case $base in
        /*) ;;
        *) base=$(pwd)/$base ;;
    esac
    if [ -L "$base" ]; then
        return 70
    fi
    if [ ! -d "$base" ]; then
        if ! "$quc_bin_mkdir" -p -- "$base" 2>/dev/null; then
            return 70
        fi
    fi
    if [ -L "$base" ] || [ ! -d "$base" ]; then
        return 70
    fi
    if ! "$quc_bin_chmod" 700 -- "$base" 2>/dev/null; then
        return 70
    fi
    probe=$base/.write-probe.$$
    if ! : > "$probe" 2>/dev/null; then
        return 70
    fi
    "$quc_bin_rm" -f -- "$probe" 2>/dev/null || return 70
    quc_state_dir=$base
    quc_lockfile=$base/lockfile
    quc_owner=$base/owner
    quc_current=$base/current
    quc_last_error=$base/last-error
    quc_jobs_dir=$base/jobs
    "$quc_bin_mkdir" -p -- "$quc_jobs_dir" || return 70
    "$quc_bin_chmod" 700 -- "$quc_jobs_dir" || return 70
    return 0
}

quc_runtime_prepare() {
    quc_runtime_base=
    raw=${XDG_RUNTIME_DIR:-}
    [ -n "$raw" ] || return 1
    case $raw in
        /*) ;;
        *) return 1 ;;
    esac
    if [ ! -d "$raw" ] || [ -L "$raw" ]; then
        return 1
    fi
    base=$raw/quiet-usb-copy
    if [ -L "$base" ]; then
        return 1
    fi
    if [ ! -d "$base" ]; then
        "$quc_bin_mkdir" -p -- "$base" 2>/dev/null || return 1
    fi
    if [ -L "$base" ] || [ ! -d "$base" ]; then
        return 1
    fi
    "$quc_bin_chmod" 700 -- "$base" 2>/dev/null || return 1
    quc_runtime_base=$base
    return 0
}

quc_open_run_dir() {
    quc_run_dir=${quc_job_dir:-}
    quc_job_id_safe "${quc_job_id:-}" || return 0
    parent=
    if quc_runtime_prepare; then
        parent=$quc_runtime_base/jobs
    elif [ -n "${quc_state_dir:-}" ] && [ ! -L "$quc_state_dir" ] && [ -d "$quc_state_dir" ]; then
        parent=$quc_state_dir/run/jobs
    else
        return 0
    fi
    if [ -L "$parent" ]; then
        return 0
    fi
    "$quc_bin_mkdir" -p -- "$parent" 2>/dev/null || return 0
    "$quc_bin_chmod" 700 -- "$parent" 2>/dev/null || return 0
    dest=$parent/$quc_job_id
    if [ -L "$dest" ]; then
        return 0
    fi
    "$quc_bin_mkdir" -p -- "$dest" 2>/dev/null || return 0
    "$quc_bin_chmod" 700 -- "$dest" 2>/dev/null || return 0
    if [ -L "$dest" ] || [ ! -d "$dest" ]; then
        return 0
    fi
    quc_run_dir=$dest
    return 0
}

quc_scratch_file() {
    sc_base=${quc_run_dir:-$quc_job_dir}
    printf '%s\n' "$sc_base/$1"
}

quc_rm_owned_dir() {
    target=$1
    [ -n "$target" ] || return 1
    if [ -L "$target" ]; then
        return 1
    fi
    if [ ! -d "$target" ]; then
        return 0
    fi
    ok=0
    if [ -n "${quc_runtime_base:-}" ]; then
        case $target in
            "$quc_runtime_base"/jobs/*) ok=1 ;;
        esac
    fi
    if [ -n "${quc_state_dir:-}" ]; then
        case $target in
            "$quc_state_dir"/run/jobs/*) ok=1 ;;
        esac
    fi
    if [ "$ok" != 1 ]; then
        return 1
    fi
    owned_id=$("$quc_bin_basename" -- "$target")
    quc_job_id_safe "$owned_id" || return 1
    "$quc_bin_rm" -rf -- "$target"
}

quc_drop_scratch() {
    if [ -n "${quc_run_dir:-}" ] && [ -n "${quc_job_dir:-}" ] && [ "$quc_run_dir" != "$quc_job_dir" ]; then
        quc_rm_owned_dir "$quc_run_dir" || true
    fi
    base=${quc_job_dir:-}
    if [ -z "$base" ] || [ ! -d "$base" ] || [ -L "$base" ]; then
        return 0
    fi
    for sc_name in plan.0 plan.hex plan2.hex extra.hex now.hex new.hex gone.hex dest-scan.hex nested.seen probe-in probe-out sync-probe.err transfer.err verify.hex last-error-line childpid spawn.pid ready; do
        "$quc_bin_rm" -f -- "$base/$sc_name" 2>/dev/null || true
    done
    return 0
}

quc_note_error() {
    if [ -n "${quc_state_dir:-}" ] && [ -n "${quc_last_error:-}" ]; then
        printf '%s\n' "$(quc_one_line "$1")" > "$quc_last_error" 2>/dev/null || true
    fi
}

quc_clear_error() {
    if [ -n "${quc_last_error:-}" ]; then
        "$quc_bin_rm" -f -- "$quc_last_error" 2>/dev/null || true
    fi
}

quc_default_job_vars() {
    quc_version=$QUC_VERSION
    quc_job_id=''
    quc_source=''
    quc_target=''
    quc_source_dev=''
    quc_target_dev=''
    quc_source_fs=''
    quc_target_fs=''
    quc_source_uuid=''
    quc_target_uuid=''
    quc_source_spec=''
    quc_target_spec=''
    quc_source_fssize=0
    quc_target_fssize=0
    quc_source_disk=''
    quc_target_disk=''
    quc_token=''
    quc_pid=''
    quc_starttime=''
    quc_run_mode=fresh
    quc_verify_during=0
    quc_copy_status=STARTING
    quc_verify_status=none
    quc_verify_tool=''
    quc_files_total=0
    quc_files_done=0
    quc_files_failed=0
    quc_files_uncertain=0
    quc_files_skipped=0
    quc_bytes_done=0
    quc_started=''
    quc_ended=''
    quc_started_epoch=0
    quc_ended_epoch=0
    quc_phase=init
    quc_phase_path=''
    quc_error=''
    quc_tree_changed=0
    quc_metadata_gaps=0
    quc_sync_unconfirmed=0
    quc_sync_status=unconfirmed
    quc_sync_mode=
    quc_profile=gentle
    quc_fatal_kind=''
}

# Повторное кодирование одних и тех же путей на каждом файле плодит процессы od.
# Кэш живёт в этой оболочке: подстановка $(...) сбросила бы его в подоболочке.
quc_encode_cached() {
    ec_slot=$1
    ec_val=$2
    case $ec_slot in
        source)
            if [ "${quc_hx_source_set:-}" = 1 ] && [ "$quc_hx_source_raw" = "$ec_val" ]; then
                quc_hex_out=$quc_hx_source
                return 0
            fi
            quc_hx_source=$(quc_hex_encode "$ec_val")
            quc_hx_source_raw=$ec_val
            quc_hx_source_set=1
            quc_hex_out=$quc_hx_source
            ;;
        target)
            if [ "${quc_hx_target_set:-}" = 1 ] && [ "$quc_hx_target_raw" = "$ec_val" ]; then
                quc_hex_out=$quc_hx_target
                return 0
            fi
            quc_hx_target=$(quc_hex_encode "$ec_val")
            quc_hx_target_raw=$ec_val
            quc_hx_target_set=1
            quc_hex_out=$quc_hx_target
            ;;
        source_spec)
            if [ "${quc_hx_ssp_set:-}" = 1 ] && [ "$quc_hx_ssp_raw" = "$ec_val" ]; then
                quc_hex_out=$quc_hx_ssp
                return 0
            fi
            quc_hx_ssp=$(quc_hex_encode "$ec_val")
            quc_hx_ssp_raw=$ec_val
            quc_hx_ssp_set=1
            quc_hex_out=$quc_hx_ssp
            ;;
        target_spec)
            if [ "${quc_hx_tsp_set:-}" = 1 ] && [ "$quc_hx_tsp_raw" = "$ec_val" ]; then
                quc_hex_out=$quc_hx_tsp
                return 0
            fi
            quc_hx_tsp=$(quc_hex_encode "$ec_val")
            quc_hx_tsp_raw=$ec_val
            quc_hx_tsp_set=1
            quc_hex_out=$quc_hx_tsp
            ;;
        phase)
            if [ "${quc_hx_phase_set:-}" = 1 ] && [ "$quc_hx_phase_raw" = "$ec_val" ]; then
                quc_hex_out=$quc_hx_phase
                return 0
            fi
            quc_hx_phase=$(quc_hex_encode "$ec_val")
            quc_hx_phase_raw=$ec_val
            quc_hx_phase_set=1
            quc_hex_out=$quc_hx_phase
            ;;
        *)
            quc_hex_out=$(quc_hex_encode "$ec_val")
            ;;
    esac
}

quc_save_state() {
    st_file=$quc_job_dir/state
    st_tmp=$quc_job_dir/state.tmp.$$
    quc_encode_cached source "$quc_source"
    src_hex=$quc_hex_out
    quc_encode_cached target "$quc_target"
    tgt_hex=$quc_hex_out
    quc_encode_cached source_spec "$quc_source_spec"
    ssp_hex=$quc_hex_out
    quc_encode_cached target_spec "$quc_target_spec"
    tsp_hex=$quc_hex_out
    quc_encode_cached phase "$quc_phase_path"
    php_hex=$quc_hex_out
    {
        printf 'version=%s\n' "$quc_version"
        printf 'job_id=%s\n' "$quc_job_id"
        printf 'source_hex=%s\n' "$src_hex"
        printf 'target_hex=%s\n' "$tgt_hex"
        printf 'source_dev=%s\n' "$quc_source_dev"
        printf 'target_dev=%s\n' "$quc_target_dev"
        printf 'source_fs=%s\n' "$quc_source_fs"
        printf 'target_fs=%s\n' "$quc_target_fs"
        printf 'source_uuid=%s\n' "$quc_source_uuid"
        printf 'target_uuid=%s\n' "$quc_target_uuid"
        printf 'source_spec_hex=%s\n' "$ssp_hex"
        printf 'target_spec_hex=%s\n' "$tsp_hex"
        printf 'source_fssize=%s\n' "$quc_source_fssize"
        printf 'target_fssize=%s\n' "$quc_target_fssize"
        printf 'source_disk=%s\n' "$quc_source_disk"
        printf 'target_disk=%s\n' "$quc_target_disk"
        printf 'token=%s\n' "$quc_token"
        printf 'pid=%s\n' "$quc_pid"
        printf 'starttime=%s\n' "$quc_starttime"
        printf 'run_mode=%s\n' "$quc_run_mode"
        printf 'verify_during=%s\n' "$quc_verify_during"
        printf 'copy_status=%s\n' "$quc_copy_status"
        printf 'verify_status=%s\n' "$quc_verify_status"
        printf 'verify_tool=%s\n' "$quc_verify_tool"
        printf 'files_total=%s\n' "$quc_files_total"
        printf 'files_done=%s\n' "$quc_files_done"
        printf 'files_failed=%s\n' "$quc_files_failed"
        printf 'files_uncertain=%s\n' "$quc_files_uncertain"
        printf 'files_skipped=%s\n' "$quc_files_skipped"
        printf 'bytes_done=%s\n' "$quc_bytes_done"
        printf 'started=%s\n' "$quc_started"
        printf 'ended=%s\n' "$quc_ended"
        printf 'started_epoch=%s\n' "$quc_started_epoch"
        printf 'ended_epoch=%s\n' "$quc_ended_epoch"
        printf 'phase=%s\n' "$quc_phase"
        printf 'phase_path_hex=%s\n' "$php_hex"
        printf 'error=%s\n' "$(quc_one_line "$quc_error")"
        printf 'tree_changed=%s\n' "$quc_tree_changed"
        printf 'metadata_gaps=%s\n' "$quc_metadata_gaps"
        printf 'sync_unconfirmed=%s\n' "$quc_sync_unconfirmed"
        printf 'sync_status=%s\n' "$quc_sync_status"
        printf 'sync_mode=%s\n' "$quc_sync_mode"
        printf 'profile=%s\n' "${quc_profile:-gentle}"
        printf 'fatal_kind=%s\n' "$quc_fatal_kind"
    } > "$st_tmp" || return 1
    "$quc_bin_mv" -f -- "$st_tmp" "$st_file"
}

quc_load_state() {
    file=$1
    quc_default_job_vars
    if [ ! -f "$file" ]; then
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%=*}
        val=${line#*=}
        case $key in
            *[!a-z0-9_]*) continue ;;
        esac
        case $key in
            version) quc_version=$val ;;
            job_id) quc_job_id=$val ;;
            source_hex)
                quc_decode_hex_var "$val" || return 1
                quc_source=$quc_decoded
                ;;
            target_hex)
                quc_decode_hex_var "$val" || return 1
                quc_target=$quc_decoded
                ;;
            source_dev) quc_source_dev=$val ;;
            target_dev) quc_target_dev=$val ;;
            source_fs) quc_source_fs=$val ;;
            target_fs) quc_target_fs=$val ;;
            source_uuid) quc_source_uuid=$val ;;
            target_uuid) quc_target_uuid=$val ;;
            source_spec_hex)
                if [ -n "$val" ]; then
                    quc_decode_hex_var "$val" || return 1
                    quc_source_spec=$quc_decoded
                fi
                ;;
            target_spec_hex)
                if [ -n "$val" ]; then
                    quc_decode_hex_var "$val" || return 1
                    quc_target_spec=$quc_decoded
                fi
                ;;
            source_fssize) quc_source_fssize=$(quc_norm_uint "$val") ;;
            target_fssize) quc_target_fssize=$(quc_norm_uint "$val") ;;
            source_disk) quc_source_disk=$val ;;
            target_disk) quc_target_disk=$val ;;
            token) quc_token=$val ;;
            pid) quc_pid=$val ;;
            starttime) quc_starttime=$val ;;
            run_mode) quc_run_mode=$val ;;
            verify_during) quc_verify_during=$(quc_norm_uint "$val") ;;
            copy_status) quc_copy_status=$val ;;
            verify_status) quc_verify_status=$val ;;
            verify_tool) quc_verify_tool=$val ;;
            files_total) quc_files_total=$(quc_norm_uint "$val") ;;
            files_done) quc_files_done=$(quc_norm_uint "$val") ;;
            files_failed) quc_files_failed=$(quc_norm_uint "$val") ;;
            files_uncertain) quc_files_uncertain=$(quc_norm_uint "$val") ;;
            files_skipped) quc_files_skipped=$(quc_norm_uint "$val") ;;
            bytes_done) quc_bytes_done=$(quc_norm_uint "$val") ;;
            started) quc_started=$val ;;
            ended) quc_ended=$val ;;
            started_epoch) quc_started_epoch=$(quc_norm_uint "$val") ;;
            ended_epoch) quc_ended_epoch=$(quc_norm_uint "$val") ;;
            phase) quc_phase=$val ;;
            phase_path_hex)
                if [ -n "$val" ]; then
                    quc_decode_hex_var "$val" || quc_phase_path=''
                    quc_phase_path=$quc_decoded
                fi
                ;;
            error) quc_error=$val ;;
            tree_changed) quc_tree_changed=$(quc_norm_uint "$val") ;;
            metadata_gaps) quc_metadata_gaps=$(quc_norm_uint "$val") ;;
            sync_unconfirmed) quc_sync_unconfirmed=$(quc_norm_uint "$val") ;;
            sync_status) quc_sync_status=$val ;;
            sync_mode) quc_sync_mode=$val ;;
            profile) quc_profile=$val ;;
            fatal_kind) quc_fatal_kind=$val ;;
        esac
    done < "$file"
    case $quc_sync_status in
        command_ok|unconfirmed) ;;
        *) quc_sync_status=unconfirmed ;;
    esac
    case $quc_sync_mode in
        data|file|none) ;;
        *) quc_sync_mode= ;;
    esac
    case $quc_profile in
        gentle) ;;
        *) quc_profile=gentle ;;
    esac
    if [ "$quc_sync_unconfirmed" = 1 ]; then
        quc_sync_status=unconfirmed
    fi
    if [ -z "$quc_job_id" ] || [ -z "$quc_source" ] || [ -z "$quc_target" ]; then
        return 1
    fi
    return 0
}

quc_log() {
    level=$1
    shift
    if [ -z "${quc_log_file:-}" ]; then
        return 0
    fi
    msg=$(quc_one_line "$*")
    printf '%s %s %s\n' "$(quc_now)" "$level" "$msg" >> "$quc_log_file" 2>/dev/null || true
}

quc_unescape_field() {
    printf '%s' "$1" | LC_ALL=C awk '{
        s = $0
        out = ""
        i = 1
        n = length(s)
        while (i <= n) {
            c = substr(s, i, 1)
            if (c == "\\" && i + 3 <= n && substr(s, i + 1, 3) ~ /^[0-7][0-7][0-7]$/) {
                o = substr(s, i + 1, 3)
                v = (substr(o, 1, 1) + 0) * 64 + (substr(o, 2, 1) + 0) * 8 + (substr(o, 3, 1) + 0)
                out = out sprintf("%c", v)
                i += 4
            } else {
                out = out c
                i++
            }
        }
        printf "%s", out
    }'
}

quc_mountinfo_lookup() {
    mi_path=$1
    quc_mi_fstype=''
    quc_mi_source=''
    if [ ! -r /proc/self/mountinfo ]; then
        return 1
    fi
    mi_found=0
    while IFS= read -r mi_line || [ -n "$mi_line" ]; do
        mi_f5=$(printf '%s\n' "$mi_line" | "$quc_bin_awk" '{ print $5 }')
        mi_mp=$(quc_unescape_field "$mi_f5" && printf X)
        mi_mp=${mi_mp%X}
        if [ "$mi_mp" != "$mi_path" ]; then
            continue
        fi
        mi_parsed=$(printf '%s\n' "$mi_line" | "$quc_bin_awk" '{
            maj = $3
            fst = ""
            src = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "-") {
                    fst = $(i + 1)
                    src = $(i + 2)
                    break
                }
            }
            printf "%s\t%s\t%s", fst, src, maj
        }')
        quc_mi_fstype=${mi_parsed%%	*}
        mi_rest=${mi_parsed#*	}
        quc_mi_source_raw=${mi_rest%%	*}
        quc_mi_source=$(quc_unescape_field "$quc_mi_source_raw" && printf X)
        quc_mi_source=${quc_mi_source%X}
        mi_found=1
    done < /proc/self/mountinfo
    [ "$mi_found" -eq 1 ]
}

quc_uuid_of() {
    if [ -z "${quc_bin_findmnt:-}" ]; then
        printf '\n'
        return 0
    fi
    "$quc_bin_findmnt" -n -T "$1" -o UUID 2>/dev/null | "$quc_bin_awk" 'NR == 1 { print; exit }'
}

quc_dev_of() {
    "$quc_bin_stat" -c '%d' -- "$1" 2>/dev/null
}

quc_fs_bytes() {
    stats=$("$quc_bin_stat" -f -c '%b %S' -- "$1" 2>/dev/null) || return 1
    printf '%s\n' "$stats" | "$quc_bin_awk" '{ printf "%.0f", ($1 + 0) * ($2 + 0) }'
}

quc_free_bytes() {
    stats=$("$quc_bin_stat" -f -c '%a %S' -- "$1" 2>/dev/null) || return 1
    printf '%s\n' "$stats" | "$quc_bin_awk" '{ printf "%.0f", ($1 + 0) * ($2 + 0) }'
}

quc_disk_name() {
    dn_spec=$1
    dn_depth=${2:-0}
    case $dn_spec in
        /dev/*) ;;
        *) return 1 ;;
    esac
    case $dn_depth in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$dn_depth" -gt 8 ]; then
        return 1
    fi
    dn_real=$("$quc_bin_readlink" -f -- "$dn_spec" 2>/dev/null) || true
    case $dn_real in
        /dev/*) ;;
        *) return 1 ;;
    esac
    dn_base=$("$quc_bin_basename" -- "$dn_real")
    if [ ! -e "/sys/class/block/$dn_base" ]; then
        return 1
    fi
    if [ -f "/sys/class/block/$dn_base/partition" ]; then
        dn_sys=$("$quc_bin_readlink" -f -- "/sys/class/block/$dn_base") || return 1
        dn_parent=$("$quc_bin_basename" -- "$("$quc_bin_dirname" -- "$dn_sys")")
        quc_disk_name "/dev/$dn_parent" $((dn_depth + 1))
        return $?
    fi
    dn_slave_dir=/sys/class/block/$dn_base/slaves
    if [ -d "$dn_slave_dir" ]; then
        dn_slave=$("$quc_bin_find" "$dn_slave_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null | LC_ALL=C "$quc_bin_awk" '
            NF { c++; name = $0 }
            END {
                if (c + 0 > 1) { printf "MANY"; exit }
                if (c + 0 == 1) printf "%s", name
            }') || dn_slave=
        case $dn_slave in
            MANY) return 1 ;;
            '') ;;
            *)
                dn_slave_base=$("$quc_bin_basename" -- "$dn_slave")
                quc_disk_name "/dev/$dn_slave_base" $((dn_depth + 1))
                return $?
                ;;
        esac
    fi
    if [ -e "/sys/class/block/$dn_base/dm/name" ]; then
        return 1
    fi
    printf '%s\n' "$dn_base"
    return 0
}

quc_disk_pair_problem() {
    dp_a=$1
    dp_b=$2
    case $dp_a in
        /dev/*) ;;
        *) return 0 ;;
    esac
    case $dp_b in
        /dev/*) ;;
        *) return 0 ;;
    esac
    dp_da=$(quc_disk_name "$dp_a" 0) || dp_da=
    dp_db=$(quc_disk_name "$dp_b" 0) || dp_db=
    if [ -n "$dp_da" ] && [ -n "$dp_db" ] && [ "$dp_da" != "$dp_db" ]; then
        return 0
    fi
    if [ -n "$dp_da" ] && [ "$dp_da" = "$dp_db" ]; then
        printf '%s\n' "источник и назначение — разделы одного физического диска"
        return 1
    fi
    printf '%s\n' "физический диск источника или назначения не определён; нельзя исключить совпадение носителей"
    return 1
}

quc_kind_of() {
    mode=$("$quc_bin_stat" -c '%f' -- "$1" 2>/dev/null) || return 1
    "$quc_bin_awk" -v m="$mode" 'function hexval(s,    i, c, v, d) {
        v = 0
        s = tolower(s)
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            d = index("0123456789abcdef", c) - 1
            if (d < 0) return -1
            v = v * 16 + d
        }
        return v
    }
    BEGIN {
        v = hexval(m)
        if (v < 0) exit 1
        type = int(v / 4096) % 16
        if (type == 8) print "regular"
        else if (type == 4) print "dir"
        else if (type == 10) print "link"
        else if (type == 1) print "fifo"
        else if (type == 12) print "socket"
        else if (type == 2) print "char"
        else if (type == 6) print "block"
        else print "other"
    }'
}

quc_fingerprint() {
    "$quc_bin_stat" -c '%s %y' -- "$1" 2>/dev/null
}

quc_file_size() {
    "$quc_bin_stat" -c '%s' -- "$1" 2>/dev/null
}

quc_is_system_path() {
    case $1 in
        /|/bin|/boot|/boot/efi|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/sys|/tmp|/usr|/usr/local|/var|/var/log|/var/tmp|/var/lib)
            return 0
            ;;
    esac
    return 1
}

quc_paths_nested() {
    a=$1
    b=$2
    case $a in
        */) ;;
        *) a=$a/ ;;
    esac
    case $b in
        */) ;;
        *) b=$b/ ;;
    esac
    if [ "$a" = "$b" ]; then
        return 0
    fi
    case $a in
        "$b"*) return 0 ;;
    esac
    case $b in
        "$a"*) return 0 ;;
    esac
    return 1
}

quc_realpath_dir() {
    if [ ! -d "$1" ]; then
        return 1
    fi
    (CDPATH='' cd -P -- "$1" && pwd -P)
}

quc_dir_nonempty() {
    found=$(CDPATH='' cd -P -- "$1" 2>/dev/null && "$quc_bin_find" . ! -name . -prune -print 2>/dev/null | "$quc_bin_awk" 'NR == 1 { print; exit }') || return 1
    if [ -n "$found" ]; then
        return 0
    fi
    return 1
}

quc_tree_bytes() {
    "$quc_bin_find" "$1" -xdev -type f -exec "$quc_bin_stat" -c '%s' {} + 2>/dev/null | "$quc_bin_awk" '{ s += $1 } END { printf "%.0f", s + 0 }'
}

quc_fat_limit() {
    case $1 in
        vfat|msdos|fat|msdosfs) printf '%s\n' "$QUC_FAT_MAX" ;;
        *) printf '\n' ;;
    esac
}

quc_fat_component_bad() {
    case $1 in
        *'
'*) return 0 ;;
    esac
    printf '%s\n' "$1" | LC_ALL=C awk '{
        s = $0
        n = length(s)
        if (n == 0 || n > 255) exit 0
        last = substr(s, n, 1)
        if (last == " " || last == ".") exit 0
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c ~ /[<>:"\\|?*]/) exit 0
            o = index("\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177", c)
            if (o > 0) exit 0
        }
        u = toupper(s)
        sub(/\..*$/, "", u)
        if (u ~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/) exit 0
        exit 1
    }'
}

quc_fat_name_bad() {
    fn_fs=$1
    fn_name=$2
    case $fn_fs in
        vfat|msdos|fat|msdosfs) ;;
        *) return 1 ;;
    esac
    fn_rest=$fn_name
    while [ -n "$fn_rest" ]; do
        fn_part=${fn_rest%%/*}
        case $fn_rest in
            */*) fn_rest=${fn_rest#*/} ;;
            *) fn_rest='' ;;
        esac
        if [ -z "$fn_part" ] || [ "$fn_part" = . ]; then
            continue
        fi
        if quc_fat_component_bad "$fn_part"; then
            return 0
        fi
    done
    return 1
}

quc_hash_tool() {
    if [ -n "${quc_bin_sha256:-}" ]; then
        quc_hash_name='sha256'
        quc_hash_bin=$quc_bin_sha256
        return 0
    fi
    if [ -n "${quc_bin_sha1:-}" ]; then
        quc_hash_name='sha1'
        quc_hash_bin=$quc_bin_sha1
        return 0
    fi
    if [ -n "${quc_bin_md5:-}" ]; then
        quc_hash_name='md5'
        quc_hash_bin=$quc_bin_md5
        return 0
    fi
    if [ -n "${quc_bin_cksum:-}" ]; then
        quc_hash_name='cksum'
        quc_hash_bin=$quc_bin_cksum
        return 0
    fi
    return 1
}

quc_hash_file() {
    if ! quc_hash_tool; then
        return 1
    fi
    "$quc_hash_bin" -- "$1" 2>/dev/null | "$quc_bin_awk" 'NR == 1 { print $1; exit }'
}

quc_decide_copy_status() {
    fatal_kind=$1
    done=$2
    failed=$3
    uncertain=$4
    skipped=$5
    tree_changed=$6
    if [ -n "$fatal_kind" ]; then
        printf '%s\n' "$fatal_kind"
        return 0
    fi
    if quc_cmp_num "$uncertain" 0 gt || [ "$tree_changed" = 1 ]; then
        printf '%s\n' UNCERTAIN
        return 0
    fi
    if quc_cmp_num "$failed" 0 gt || quc_cmp_num "$skipped" 0 gt; then
        if quc_cmp_num "$done" 0 eq && quc_cmp_num "$skipped" 0 eq; then
            printf '%s\n' FAILED
        else
            printf '%s\n' PARTIAL
        fi
        return 0
    fi
    printf '%s\n' SUCCESS
}

quc_add_problem() {
    if [ -z "$quc_problems" ]; then
        quc_problems=$1
    else
        quc_problems="$quc_problems
$1"
    fi
}

quc_add_note() {
    if [ -z "$quc_notes" ]; then
        quc_notes=$1
    else
        quc_notes="$quc_notes
$1"
    fi
}

quc_describe_mount() {
    path=$1
    role=$2
    if ! quc_mountinfo_lookup "$path"; then
        quc_add_problem "$role не является точкой монтирования"
        return 1
    fi
    if [ "$role" = "Источник" ]; then
        quc_source_fs=$quc_mi_fstype
        quc_source_spec=$quc_mi_source
        quc_source_dev=$(quc_dev_of "$path") || quc_source_dev=''
        quc_source_uuid=$(quc_uuid_of "$path" || true)
        quc_source_fssize=$(quc_fs_bytes "$path" || printf '0')
        quc_source_disk=$(quc_disk_name "$quc_source_spec" 0) || quc_source_disk=
    else
        quc_target_fs=$quc_mi_fstype
        quc_target_spec=$quc_mi_source
        quc_target_dev=$(quc_dev_of "$path") || quc_target_dev=''
        quc_target_uuid=$(quc_uuid_of "$path" || true)
        quc_target_fssize=$(quc_fs_bytes "$path" || printf '0')
        quc_target_disk=$(quc_disk_name "$quc_target_spec" 0) || quc_target_disk=
    fi
    return 0
}

quc_validate_pair() {
    raw_src=$1
    raw_dst=$2
    mode=$3
    quc_problems=''
    quc_notes=''
    quc_source=''
    quc_target=''
    if [ ! -e "$raw_src" ] && [ ! -L "$raw_src" ]; then
        quc_add_problem "источник не существует"
    fi
    if [ ! -e "$raw_dst" ] && [ ! -L "$raw_dst" ]; then
        quc_add_problem "назначение не существует"
    fi
    if [ -n "$quc_problems" ]; then
        return 1
    fi
    if [ ! -d "$raw_src" ]; then
        quc_add_problem "источник не каталог"
    fi
    if [ ! -d "$raw_dst" ]; then
        quc_add_problem "назначение не каталог"
    fi
    if [ -n "$quc_problems" ]; then
        return 1
    fi
    quc_source=$(quc_realpath_dir "$raw_src") || quc_add_problem "источник недоступен"
    quc_target=$(quc_realpath_dir "$raw_dst") || quc_add_problem "назначение недоступно"
    if [ -z "$quc_source" ] || [ -z "$quc_target" ]; then
        return 1
    fi
    if [ "$quc_source" = "$quc_target" ]; then
        quc_add_problem "источник и назначение — один и тот же каталог"
    elif quc_paths_nested "$quc_source" "$quc_target"; then
        quc_add_problem "один каталог находится внутри другого"
    fi
    if quc_is_system_path "$quc_source"; then
        quc_add_problem "нельзя копировать системный каталог: $quc_source"
    fi
    if quc_is_system_path "$quc_target"; then
        quc_add_problem "нельзя копировать в системный каталог: $quc_target"
    fi
    if [ ! -r "$quc_source" ] || [ ! -x "$quc_source" ]; then
        quc_add_problem "нет права чтения источника"
    fi
    if [ ! -w "$quc_target" ] || [ ! -x "$quc_target" ]; then
        quc_add_problem "нет права записи в назначение"
    fi
    quc_describe_mount "$quc_source" "Источник" || true
    quc_describe_mount "$quc_target" "Назначение" || true
    root_dev=$(quc_dev_of / || true)
    if [ -n "$root_dev" ] && [ -n "$quc_source_dev" ] && [ "$quc_source_dev" = "$root_dev" ]; then
        quc_add_problem "источник находится на корневой файловой системе"
    fi
    if [ -n "$root_dev" ] && [ -n "$quc_target_dev" ] && [ "$quc_target_dev" = "$root_dev" ]; then
        quc_add_problem "назначение находится на корневой файловой системе"
    fi
    if [ -n "$quc_source_dev" ] && [ -n "$quc_target_dev" ] && [ "$quc_source_dev" = "$quc_target_dev" ]; then
        quc_add_problem "источник и назначение на одной файловой системе"
    fi
    dp_msg=$(quc_disk_pair_problem "$quc_source_spec" "$quc_target_spec") || true
    if [ -n "$dp_msg" ]; then
        quc_add_problem "$dp_msg"
    else
        dp_src_block=0
        dp_dst_block=0
        case $quc_source_spec in
            /dev/*) dp_src_block=1 ;;
        esac
        case $quc_target_spec in
            /dev/*) dp_dst_block=1 ;;
        esac
        if [ "$dp_src_block" != 1 ] || [ "$dp_dst_block" != 1 ]; then
            quc_add_note "физический диск однозначно не определён; совпадение разделов не проверялось"
        fi
    fi
    if [ -n "${quc_state_dir:-}" ]; then
        if quc_paths_nested "$quc_state_dir" "$quc_source" || quc_paths_nested "$quc_state_dir" "$quc_target"; then
            quc_add_problem "служебный каталог программы пересекается с источником или назначением"
        fi
    fi
    if [ "$mode" = fresh ]; then
        if quc_dir_nonempty "$quc_target"; then
            quc_add_problem "назначение не пустое; существующие данные не перезаписываются"
        fi
        need=$(quc_tree_bytes "$quc_source" || printf '0')
        have=$(quc_free_bytes "$quc_target" || printf '')
        if [ -z "$have" ]; then
            quc_add_problem "не удалось определить свободное место"
        else
            quc_need_bytes=$need
            quc_free_have=$have
            ok=$(LC_ALL=C awk -v need="$need" -v have="$have" 'BEGIN {
                need = need + 0; have = have + 0
                extra = 0
                if (need > 0) {
                    extra = need * 0.1
                    if (extra < 1048576) extra = 1048576
                }
                if (have >= need + extra) print "yes"; else print "no"
            }')
            if [ "$ok" != yes ]; then
                quc_add_problem "недостаточно свободного места (нужно около $(quc_human_bytes "$need"), доступно $(quc_human_bytes "$have"))"
            fi
        fi
        lim=$(quc_fat_limit "$quc_target_fs")
        if [ -n "$lim" ]; then
            too=$("$quc_bin_find" "$quc_source" -xdev -type f -exec "$quc_bin_stat" -c '%s' {} + 2>/dev/null | "$quc_bin_awk" -v lim="$lim" 'BEGIN { n = 0 } ($1 + 0) > (lim + 0) { n++ } END { print n + 0 }')
            if quc_cmp_num "$too" 0 gt; then
                quc_add_note "файлов больше предела FAT32 ($too): они не будут скопированы, итог не будет SUCCESS"
            fi
        fi
    fi
    if [ "$mode" = fresh ]; then
        probe=$quc_target/$QUC_PARTIAL_PREFIX"write-probe.$$"
        if [ -z "$quc_problems" ]; then
            if ! : > "$probe" 2>/dev/null; then
                quc_add_problem "пробная запись в назначение не удалась"
            else
                "$quc_bin_rm" -f -- "$probe" 2>/dev/null || quc_add_problem "не удалось убрать пробный файл назначения"
            fi
        fi
    fi
    if [ -n "$quc_problems" ]; then
        return 1
    fi
    return 0
}

quc_identity_still() {
    if ! quc_mountinfo_lookup "$quc_source"; then
        quc_error="источник больше не смонтирован"
        return 1
    fi
    if ! quc_mountinfo_lookup "$quc_target"; then
        quc_error="назначение больше не смонтировано"
        return 1
    fi
    now_s=$(quc_dev_of "$quc_source" || true)
    now_t=$(quc_dev_of "$quc_target" || true)
    if [ -z "$now_s" ] || [ "$now_s" != "$quc_source_dev" ]; then
        quc_error="устройство источника изменилось во время работы"
        return 1
    fi
    if [ -z "$now_t" ] || [ "$now_t" != "$quc_target_dev" ]; then
        quc_error="устройство назначения изменилось во время работы"
        return 1
    fi
    if [ -n "$quc_source_uuid" ]; then
        u=$(quc_uuid_of "$quc_source" || true)
        if [ "$u" != "$quc_source_uuid" ]; then
            quc_error="UUID источника не совпал"
            return 1
        fi
    fi
    if [ -n "$quc_target_uuid" ]; then
        u=$(quc_uuid_of "$quc_target" || true)
        if [ "$u" != "$quc_target_uuid" ]; then
            quc_error="UUID назначения не совпал"
            return 1
        fi
    fi
    return 0
}

quc_resume_identity() {
    if ! quc_mountinfo_lookup "$quc_source"; then
        quc_error="источник не смонтирован"
        return 1
    fi
    if ! quc_mountinfo_lookup "$quc_target"; then
        quc_error="назначение не смонтировано"
        return 1
    fi
    if ! quc_mountinfo_lookup "$quc_source"; then
        return 1
    fi
    src_fs=$quc_mi_fstype
    src_spec=$quc_mi_source
    if ! quc_mountinfo_lookup "$quc_target"; then
        return 1
    fi
    dst_fs=$quc_mi_fstype
    dst_spec=$quc_mi_source
    src_uuid=$(quc_uuid_of "$quc_source" || true)
    dst_uuid=$(quc_uuid_of "$quc_target" || true)
    src_size=$(quc_fs_bytes "$quc_source" || printf '0')
    dst_size=$(quc_fs_bytes "$quc_target" || printf '0')
    if [ -n "$quc_source_uuid" ]; then
        if [ "$src_uuid" != "$quc_source_uuid" ]; then
            quc_error="UUID источника не совпадает с прерванным заданием"
            return 1
        fi
    else
        if [ "$src_spec" != "$quc_source_spec" ] || [ "$src_fs" != "$quc_source_fs" ] || [ "$src_size" != "$quc_source_fssize" ]; then
            quc_error="нельзя подтвердить, что источник тот же самый"
            return 1
        fi
        now_dev=$(quc_dev_of "$quc_source" || true)
        if [ "$now_dev" != "$quc_source_dev" ]; then
            quc_error="без UUID источник после переподключения не подтверждён"
            return 1
        fi
    fi
    if [ -n "$quc_target_uuid" ]; then
        if [ "$dst_uuid" != "$quc_target_uuid" ]; then
            quc_error="UUID назначения не совпадает с прерванным заданием"
            return 1
        fi
    else
        if [ "$dst_spec" != "$quc_target_spec" ] || [ "$dst_fs" != "$quc_target_fs" ] || [ "$dst_size" != "$quc_target_fssize" ]; then
            quc_error="нельзя подтвердить, что назначение то же самое"
            return 1
        fi
        now_dev=$(quc_dev_of "$quc_target" || true)
        if [ "$now_dev" != "$quc_target_dev" ]; then
            quc_error="без UUID назначение после переподключения не подтверждено"
            return 1
        fi
    fi
    quc_source_dev=$(quc_dev_of "$quc_source") || return 1
    quc_target_dev=$(quc_dev_of "$quc_target") || return 1
    quc_source_fs=$src_fs
    quc_target_fs=$dst_fs
    quc_source_spec=$src_spec
    quc_target_spec=$dst_spec
    quc_source_uuid=$src_uuid
    quc_target_uuid=$dst_uuid
    return 0
}

quc_read_owner() {
    quc_owner_pid=''
    quc_owner_start=''
    quc_owner_token=''
    quc_owner_job=''
    if [ ! -f "$quc_owner" ]; then
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%=*}
        val=${line#*=}
        case $key in
            pid) quc_owner_pid=$val ;;
            starttime) quc_owner_start=$val ;;
            token) quc_owner_token=$val ;;
            job) quc_owner_job=$val ;;
        esac
    done < "$quc_owner"
    return 0
}

quc_write_owner() {
    ow_tmp=$quc_state_dir/owner.tmp.$$
    {
        printf 'pid=%s\n' "$1"
        printf 'starttime=%s\n' "$2"
        printf 'token=%s\n' "$3"
        printf 'job=%s\n' "$4"
    } > "$ow_tmp" || return 1
    "$quc_bin_mv" -f -- "$ow_tmp" "$quc_owner"
}

quc_acquire_lock() {
    quc_lock_mode=''
    if [ -n "${quc_bin_flock:-}" ]; then
        exec 9>>"$quc_lockfile" || return 1
        err=$quc_state_dir/flock.err
        if "$quc_bin_flock" -n 9 2>"$err"; then
            "$quc_bin_rm" -f -- "$err" 2>/dev/null || true
            quc_lock_mode='flock'
            return 0
        fi
        exec 9>&-
        if [ -s "$err" ] && "$quc_bin_grep" -q -e 'not support' -e 'Invalid argument' "$err"; then
            quc_bin_flock=''
        else
            return 1
        fi
    fi
    if "$quc_bin_mkdir" "$quc_state_dir/lock.d" 2>/dev/null; then
        quc_lock_mode='mkdir'
        printf '%s\n' "$$" > "$quc_state_dir/lock.d/pid" || return 1
        return 0
    fi
    oldpid=''
    if [ -f "$quc_state_dir/lock.d/pid" ]; then
        oldpid=$("$quc_bin_cat" "$quc_state_dir/lock.d/pid" 2>/dev/null || true)
    fi
    stale=0
    if [ -z "$oldpid" ] || ! quc_is_uint "$oldpid"; then
        stale=1
    elif [ ! -d "/proc/$oldpid" ]; then
        stale=1
    elif ! quc_cmdline_contains "$oldpid" quiet_usb_copy.sh; then
        stale=1
    fi
    if [ "$stale" -eq 1 ]; then
        "$quc_bin_rm" -rf -- "$quc_state_dir/lock.d" || return 1
        if "$quc_bin_mkdir" "$quc_state_dir/lock.d" 2>/dev/null; then
            quc_lock_mode='mkdir'
            printf '%s\n' "$$" > "$quc_state_dir/lock.d/pid" || return 1
            return 0
        fi
    fi
    return 1
}

quc_release_lock() {
    if [ "${quc_lock_mode:-}" = mkdir ] && [ -d "$quc_state_dir/lock.d" ]; then
        "$quc_bin_rm" -rf -- "$quc_state_dir/lock.d" 2>/dev/null || true
    fi
    "$quc_bin_rm" -f -- "$quc_owner" 2>/dev/null || true
}

quc_new_token() {
    if [ -r /dev/urandom ]; then
        token=$(LC_ALL=C "$quc_bin_od" -An -N16 -tx1 /dev/urandom 2>/dev/null | LC_ALL=C "$quc_bin_tr" -d '[:space:]')
        if [ -n "$token" ]; then
            printf '%s\n' "$token"
            return 0
        fi
    fi
    printf '%s-%s\n' "$$" "$(quc_epoch)"
}

quc_new_job_id() {
    ts=$("$quc_bin_date" '+%Y%m%dT%H%M%S')
    rand=$(quc_new_token | "$quc_bin_awk" '{ print substr($0, 1, 8); exit }')
    printf '%s-%s-%s\n' "$ts" "$$" "$rand"
}

quc_pause_seconds() {
    name=$1
    def=$2
    cap=$3
    raw=$def
    case $name in
        QUC_POST_COPY_DELAY) raw=${QUC_POST_COPY_DELAY:-$def} ;;
        QUC_FILE_PAUSE) raw=${QUC_FILE_PAUSE:-$def} ;;
    esac
    n=$(quc_norm_uint "$raw")
    if quc_cmp_num "$n" "$cap" gt; then
        n=$cap
    fi
    printf '%s\n' "$n"
}

quc_on_term() {
    quc_stop_requested=1
    sig_pid=${quc_child_pid:-}
    if [ -z "$sig_pid" ] && [ -n "${quc_job_dir:-}" ] && [ -f "$quc_job_dir/childpid" ]; then
        sig_pid=$("${quc_bin_cat:-cat}" "$quc_job_dir/childpid" 2>/dev/null || true)
    fi
    if [ -n "$sig_pid" ]; then
        kill -TERM "$sig_pid" 2>/dev/null || true
    fi
}

quc_wait_pid() {
    quc_child_pid=$1
    if [ -n "${quc_job_dir:-}" ]; then
        printf '%s\n' "$quc_child_pid" > "$quc_job_dir/childpid" 2>/dev/null || true
    fi
    quc_wait_rc=0
    wait "$quc_child_pid" || quc_wait_rc=$?
    quc_child_pid=''
    if [ -n "${quc_job_dir:-}" ]; then
        "$quc_bin_rm" -f -- "$quc_job_dir/childpid" 2>/dev/null || true
    fi
    if [ "${quc_stop_requested:-0}" = 1 ] || [ -f "${quc_job_dir:-/nonexistent}/stop-requested" ]; then
        quc_stop_requested=1
        return 20
    fi
    return "$quc_wait_rc"
}

quc_sleep_interruptible() {
    n=$(quc_norm_uint "$1")
    if [ "$n" = 0 ]; then
        return 0
    fi
    while quc_cmp_num "$n" 0 gt; do
        if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
            quc_stop_requested=1
            return 20
        fi
        "$quc_bin_sleep" 1 &
        # Нельзя писать `if ! cmd; then rc=$?`: `!` обнуляет $?.
        quc_wait_pid "$!"
        sl_rc=$?
        if [ "$sl_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ] || [ -f "$quc_job_dir/stop-requested" ]; then
            quc_stop_requested=1
            return 20
        fi
        n=$(quc_add_bytes "$n" -1)
    done
    return 0
}

quc_apply_niceness() {
    if [ -n "${quc_bin_renice:-}" ]; then
        "$quc_bin_renice" -n 19 -p $$ >/dev/null 2>&1 || true
    fi
    if [ -n "${quc_bin_ionice:-}" ]; then
        # Класс idle (3) на занятом диске может не получать ввод-вывод вовсе.
        # Best-effort с низким приоритетом уступает пользовательским чтениям,
        # но копирование всё равно продвигается.
        "$quc_bin_ionice" -c 2 -n 7 -p $$ >/dev/null 2>&1 || true
    fi
}

quc_sync_stderr_bad() {
    [ -s "$1" ] || return 1
    LC_ALL=C "$quc_bin_awk" '
        BEGIN { found = 0 }
        {
            line = tolower($0)
            if (index(line, "unrecognized") > 0 || index(line, "unrecognised") > 0 || index(line, "invalid option") > 0 || index(line, "illegal option") > 0 || index(line, "unknown option") > 0 || index(line, "extra operand") > 0)
                found = 1
        }
        END { if (found) exit 0; exit 1 }
    ' "$1"
}

quc_sync_cmd() {
    case $quc_sync_mode in
        data) "$quc_bin_sync" -d -- "$1" ;;
        file) "$quc_bin_sync" -- "$1" ;;
        *) return 1 ;;
    esac
}

quc_probe_copy_tools() {
    quc_cp_sparse=0
    quc_sync_mode=none
    in=$(quc_scratch_file probe-in)
    out=$(quc_scratch_file probe-out)
    sp_err=$(quc_scratch_file sync-probe.err)
    printf 'x' > "$in" || return 1
    if "$quc_bin_cp" --sparse=auto -- "$in" "$out" >/dev/null 2>&1; then
        quc_cp_sparse=1
    else
        "$quc_bin_cp" -- "$in" "$out" >/dev/null 2>&1 || true
    fi
    if [ -n "${quc_bin_sync:-}" ] && [ -f "$out" ]; then
        if "$quc_bin_sync" -d -- "$out" >/dev/null 2>"$sp_err"; then
            if ! quc_sync_stderr_bad "$sp_err"; then
                quc_sync_mode=data
            fi
        fi
        if [ "$quc_sync_mode" = none ]; then
            if "$quc_bin_sync" -- "$out" >/dev/null 2>"$sp_err"; then
                if ! quc_sync_stderr_bad "$sp_err"; then
                    quc_sync_mode="file"
                fi
            fi
        fi
    fi
    "$quc_bin_rm" -f -- "$in" "$out" "$sp_err"
}

quc_set_phase() {
    quc_phase=$1
    quc_phase_path=$2
    quc_save_state || true
}

quc_transfer_file() {
    tf_src=$1
    tf_dst=$2
    tf_err=$(quc_scratch_file transfer.err)
    : > "$tf_err"
    if [ "$quc_cp_sparse" = 1 ]; then
        "$quc_bin_cp" --sparse=auto -- "$tf_src" "$tf_dst" 2>"$tf_err" &
    else
        "$quc_bin_cp" -- "$tf_src" "$tf_dst" 2>"$tf_err" &
    fi
    quc_wait_pid "$!"
    tf_rc=$?
    if [ "$tf_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ] || [ -f "$quc_job_dir/stop-requested" ]; then
        return 20
    fi
    if [ "$tf_rc" -ne 0 ]; then
        return "$tf_rc"
    fi
    if [ "$quc_sync_mode" = data ] || [ "$quc_sync_mode" = file ]; then
        quc_sync_cmd "$tf_dst" 2>>"$tf_err" &
        quc_wait_pid "$!"
        tf_rc=$?
        if [ "$tf_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ] || [ -f "$quc_job_dir/stop-requested" ]; then
            return 20
        fi
        if [ "$tf_rc" -ne 0 ]; then
            quc_sync_unconfirmed=1
            quc_sync_status=unconfirmed
            quc_log INFO "не удалось синхронизировать данные файла"
        fi
    fi
    return 0
}

quc_ensure_dir() {
    ed_rel=$1
    ed_dest=$quc_target
    ed_rest=$ed_rel
    ed_n=0
    while [ -n "$ed_rest" ]; do
        ed_n=$((ed_n + 1))
        if [ "$ed_n" -gt 512 ]; then
            quc_error="слишком глубокий путь каталога"
            return 2
        fi
        ed_part=${ed_rest%%/*}
        case $ed_rest in
            */*) ed_rest=${ed_rest#*/} ;;
            *) ed_rest='' ;;
        esac
        if [ -z "$ed_part" ] || [ "$ed_part" = . ]; then
            continue
        fi
        ed_dest=$ed_dest/$ed_part
        if ! quc_identity_still; then
            return 10
        fi
        if [ -d "$ed_dest" ] && [ ! -L "$ed_dest" ]; then
            ed_dev=$(quc_dev_of "$ed_dest" || true)
            if [ "$ed_dev" != "$quc_target_dev" ]; then
                quc_error="каталог назначения сменил файловую систему"
                return 10
            fi
            continue
        fi
        if [ -e "$ed_dest" ] || [ -L "$ed_dest" ]; then
            quc_error="на пути каталога уже есть файл: $(quc_display_path "$ed_dest")"
            return 2
        fi
        if ! "$quc_bin_mkdir" -- "$ed_dest" 2>>"$(quc_scratch_file transfer.err)"; then
            if ! quc_identity_still; then
                return 10
            fi
            return 2
        fi
        ed_dev=$(quc_dev_of "$ed_dest" || true)
        if [ "$ed_dev" != "$quc_target_dev" ]; then
            "$quc_bin_rm" -f -- "$ed_dest" 2>/dev/null || "$quc_bin_rmdir" "$ed_dest" 2>/dev/null || true
            quc_error="назначение отключилось в момент создания каталога"
            return 10
        fi
    done
    return 0
}

quc_append_meta() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$quc_meta_file" || return 1
}

quc_meta_line() {
    [ -f "$quc_meta_file" ] || return 1
    "$quc_bin_awk" -F '\t' -v p="$1" '$2 == p { line = $0; found = 1 } END { if (found) print line; exit found ? 0 : 1 }' "$quc_meta_file"
}

quc_apply_metadata() {
    am_src=$1
    am_dst=$2
    am_mode=$("$quc_bin_stat" -c '%a' -- "$am_src" 2>/dev/null || true)
    if [ -n "$am_mode" ]; then
        if ! "$quc_bin_chmod" "$am_mode" -- "$am_dst" 2>/dev/null; then
            quc_metadata_gaps=1
        fi
    fi
    if [ -n "${quc_bin_touch:-}" ]; then
        if ! "$quc_bin_touch" -r "$am_src" -- "$am_dst" 2>/dev/null; then
            quc_metadata_gaps=1
        fi
    else
        quc_metadata_gaps=1
    fi
}

quc_copy_regular() {
    cr_src=$1
    cr_dst=$2
    cr_rel=$3
    cr_hex=$4
    cr_attempt=1
    cr_unstable=0
    while quc_cmp_num "$cr_attempt" "$QUC_MAX_ATTEMPTS" le; do
        if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
            quc_stop_requested=1
            return 20
        fi
        if ! quc_identity_still; then
            return 10
        fi
        cr_fp1=$(quc_fingerprint "$cr_src" || true)
        if [ -z "$cr_fp1" ]; then
            quc_error="не удалось прочитать сведения о файле"
            return 2
        fi
        cr_size=${cr_fp1%% *}
        cr_lim=$(quc_fat_limit "$quc_target_fs")
        if [ -n "$cr_lim" ] && quc_cmp_num "$cr_size" "$cr_lim" gt; then
            quc_error="файл больше предела FAT32 ($(quc_human_bytes "$cr_size"))"
            quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
            return 4
        fi
        cr_parent=$("$quc_bin_dirname" -- "$cr_rel")
        case $cr_parent in
            .|'') ;;
            *)
                quc_ensure_dir "$cr_parent"
                cr_rc=$?
                if [ "$cr_rc" -ne 0 ]; then
                    return "$cr_rc"
                fi
                ;;
        esac
        if quc_fat_name_bad "$quc_target_fs" "$cr_rel"; then
            quc_error="имя несовместимо с FAT"
            quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
            return 4
        fi
        cr_tmp=$("$quc_bin_dirname" -- "$cr_dst")/$QUC_PARTIAL_PREFIX$$.$cr_attempt
        "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
        quc_set_phase "copying:$cr_attempt" "$cr_rel"
        quc_transfer_file "$cr_src" "$cr_tmp"
        cr_rc=$?
        if [ "$cr_rc" -ne 0 ]; then
            "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
            if [ "$cr_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ]; then
                return 20
            fi
            if [ -f "$(quc_scratch_file transfer.err)" ] && "$quc_bin_grep" -q -e 'No space left' -e 'Disk quota exceeded' "$(quc_scratch_file transfer.err)"; then
                quc_error="на назначении закончилось место"
                return 10
            fi
            if ! quc_identity_still; then
                return 10
            fi
            if [ -f "$(quc_scratch_file transfer.err)" ] && "$quc_bin_grep" -q -e 'Permission denied' -e 'Operation not permitted' -e 'No such file' "$(quc_scratch_file transfer.err)"; then
                quc_error="не удалось прочитать или записать файл"
                return 2
            fi
            cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
            continue
        fi
        cr_delay=$(quc_pause_seconds QUC_POST_COPY_DELAY 0 30)
        if [ "$cr_delay" != 0 ]; then
            quc_set_phase "confirming:$cr_attempt" "$cr_rel"
            if ! quc_sleep_interruptible "$cr_delay"; then
                "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
                return 20
            fi
        fi
        cr_fp2=$(quc_fingerprint "$cr_src" || true)
        cr_dsize=$(quc_file_size "$cr_tmp" || true)
        if [ -z "$cr_fp2" ] || [ "$cr_fp1" != "$cr_fp2" ] || [ "$cr_dsize" != "$cr_size" ]; then
            "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
            cr_unstable=1
            quc_log INFO "path=$(quc_display_path "$cr_rel") файл изменился во время копирования, повтор $cr_attempt"
            cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
            continue
        fi
        cr_hash='-'
        if [ "$quc_verify_during" = 1 ]; then
            if ! quc_hash_tool; then
                quc_verify_tool=unavailable
            else
                quc_verify_tool=$quc_hash_name
                cr_h1=$(quc_hash_file "$cr_src" || true)
                cr_h2=$(quc_hash_file "$cr_tmp" || true)
                cr_h3=$(quc_hash_file "$cr_src" || true)
                if [ -z "$cr_h1" ] || [ -z "$cr_h2" ] || [ -z "$cr_h3" ] || [ "$cr_h1" != "$cr_h3" ]; then
                    "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
                    cr_unstable=1
                    quc_log INFO "path=$(quc_display_path "$cr_rel") содержимое изменилось во время проверки"
                    cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
                    continue
                fi
                if [ "$cr_h1" != "$cr_h2" ]; then
                    "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
                    quc_log ERROR "path=$(quc_display_path "$cr_rel") контрольная сумма копии не совпала"
                    cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
                    continue
                fi
                cr_hash=$cr_h1
            fi
        fi
        if ! quc_identity_still; then
            "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
            return 10
        fi
        if ! "$quc_bin_mv" -f -- "$cr_tmp" "$cr_dst"; then
            "$quc_bin_rm" -f -- "$cr_tmp" 2>/dev/null || true
            if ! quc_identity_still; then
                return 10
            fi
            return 2
        fi
        cr_dev=$(quc_dev_of "$cr_dst" || true)
        if [ "$cr_dev" != "$quc_target_dev" ]; then
            quc_error="файл оказался не на файловой системе назначения и не удалён автоматически"
            quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
            return 10
        fi
        cr_final=$(quc_file_size "$cr_dst" || true)
        if [ "$cr_final" != "$cr_size" ]; then
            quc_error="размер после переноса не совпал"
            return 2
        fi
        quc_apply_metadata "$cr_src" "$cr_dst"
        cr_fp_hex=$(quc_hex_encode "$cr_fp1")
        quc_append_meta F "$cr_hex" "$cr_size" "$cr_fp_hex" "$cr_hash" || return 2
        quc_bytes_done=$(quc_add_bytes "$quc_bytes_done" "$cr_size")
        return 0
    done
    if [ "$cr_unstable" = 1 ]; then
        quc_error="файл менялся во время копирования, согласованная копия не получена"
        quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
        return 3
    fi
    quc_error="не удалось скопировать файл"
    quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
    return 2
}

quc_copy_link() {
    src=$1
    dst=$2
    rel=$3
    path_hex=$4
    target=$("$quc_bin_readlink" -- "$src" 2>/dev/null || true)
    if [ -z "$target" ] && [ ! -L "$src" ]; then
        return 2
    fi
    parent=$("$quc_bin_dirname" -- "$rel")
    case $parent in
        .|'') ;;
        *)
            quc_ensure_dir "$parent"
            cl_rc=$?
            if [ "$cl_rc" -ne 0 ]; then
                return "$cl_rc"
            fi
            ;;
    esac
    tmp=$("$quc_bin_dirname" -- "$dst")/$QUC_PARTIAL_PREFIX$$.link
    "$quc_bin_rm" -f -- "$tmp" 2>/dev/null || true
    if ! "$quc_bin_ln" -s -- "$target" "$tmp" 2>"$(quc_scratch_file transfer.err)"; then
        quc_error="файловая система назначения не поддерживает символьные ссылки"
        quc_log ERROR "path=$(quc_display_path "$rel") $quc_error"
        return 4
    fi
    if ! "$quc_bin_mv" -f -- "$tmp" "$dst"; then
        "$quc_bin_rm" -f -- "$tmp" 2>/dev/null || true
        return 2
    fi
    got=$("$quc_bin_readlink" -- "$dst" 2>/dev/null || true)
    if [ "$got" != "$target" ]; then
        quc_error="символьная ссылка записана неверно"
        return 2
    fi
    th=$(quc_hex_encode "$target")
    quc_append_meta L "$path_hex" 0 "$th" - || return 2
    return 0
}

quc_copy_dir() {
    rel=$1
    path_hex=$2
    quc_ensure_dir "$rel"
    cd_rc=$?
    if [ "$cd_rc" -ne 0 ]; then
        return "$cd_rc"
    fi
    quc_append_meta D "$path_hex" 0 - - || return 2
    return 0
}

quc_should_skip_done() {
    path=$1
    dst=$2
    path_hex=$3
    line=$(quc_meta_line "$path_hex" || true)
    if [ -z "$line" ]; then
        return 1
    fi
    kind=$(printf '%s\n' "$line" | "$quc_bin_awk" -F '\t' '{ print $1; exit }')
    size=$(printf '%s\n' "$line" | "$quc_bin_awk" -F '\t' '{ print $3; exit }')
    fp_hex=$(printf '%s\n' "$line" | "$quc_bin_awk" -F '\t' '{ print $4; exit }')
    hash=$(printf '%s\n' "$line" | "$quc_bin_awk" -F '\t' '{ print $5; exit }')
    case $kind in
        D)
            [ -d "$dst" ] && [ ! -L "$dst" ]
            return
            ;;
        L)
            [ -L "$dst" ] || return 1
            quc_decode_hex_var "$fp_hex" || return 1
            now=$("$quc_bin_readlink" -- "$path" 2>/dev/null || true)
            got=$("$quc_bin_readlink" -- "$dst" 2>/dev/null || true)
            [ "$now" = "$quc_decoded" ] && [ "$got" = "$quc_decoded" ]
            return
            ;;
        F)
            fp=$(quc_fingerprint "$path" || true)
            [ -n "$fp" ] || return 1
            quc_decode_hex_var "$fp_hex" || return 1
            [ "$fp" = "$quc_decoded" ] || return 1
            [ -f "$dst" ] && [ ! -L "$dst" ] || return 1
            dsize=$(quc_file_size "$dst" || true)
            [ "$dsize" = "$size" ] || return 1
            if [ "$hash" != - ] && [ -n "$hash" ]; then
                nowh=$(quc_hash_file "$dst" || true)
                [ "$nowh" = "$hash" ] || return 1
            fi
            return 0
            ;;
        *) return 1 ;;
    esac
}

quc_record_result() {
    rc=$1
    rel=$2
    case $rc in
        0)
            quc_files_done=$(quc_add_bytes "$quc_files_done" 1)
            ;;
        2)
            quc_files_failed=$(quc_add_bytes "$quc_files_failed" 1)
            quc_log ERROR "path=$(quc_display_path "$rel") ${quc_error:-ошибка копирования}"
            ;;
        3)
            quc_files_uncertain=$(quc_add_bytes "$quc_files_uncertain" 1)
            ;;
        4)
            quc_files_skipped=$(quc_add_bytes "$quc_files_skipped" 1)
            ;;
        10|20) return "$rc" ;;
        *)
            quc_files_failed=$(quc_add_bytes "$quc_files_failed" 1)
            ;;
    esac
    return 0
}

quc_handle_path() {
    path=$1
    case $path in
        "$quc_source") return 0 ;;
        "$quc_source"/*) ;;
        *)
            quc_log ERROR "пропущен неожиданный путь"
            return 0
            ;;
    esac
    prefix=$quc_source/
    rel=${path#"$prefix"}
    if [ -z "$rel" ]; then
        return 0
    fi
    dst=$quc_target/$rel
    path_hex=$(quc_hex_encode "$path")
    if [ "$quc_run_mode" = resume ] && quc_should_skip_done "$path" "$dst" "$path_hex"; then
        quc_files_done=$(quc_add_bytes "$quc_files_done" 1)
        sz=$(quc_file_size "$path" 2>/dev/null || printf '0')
        kind=$(quc_kind_of "$path" || true)
        if [ "$kind" = regular ]; then
            quc_bytes_done=$(quc_add_bytes "$quc_bytes_done" "$sz")
        fi
        return 0
    fi
    kind=$(quc_kind_of "$path" || true)
    case $kind in
        dir) quc_copy_dir "$rel" "$path_hex" ;;
        regular) quc_copy_regular "$path" "$dst" "$rel" "$path_hex" ;;
        link) quc_copy_link "$path" "$dst" "$rel" "$path_hex" ;;
        fifo|socket|char|block|other)
            quc_error="специальный файл не копируется ($kind)"
            quc_log ERROR "path=$(quc_display_path "$rel") $quc_error"
            quc_record_result 4 "$rel" || return $?
            return 0
            ;;
        '')
            quc_error="не удалось определить тип файла"
            quc_log ERROR "path=$(quc_display_path "$rel") $quc_error"
            quc_record_result 2 "$rel" || return $?
            return 0
            ;;
    esac
    quc_copy_rc=$?
    if [ "$quc_copy_rc" -eq 10 ] || [ "$quc_copy_rc" -eq 20 ]; then
        return "$quc_copy_rc"
    fi
    quc_record_result "$quc_copy_rc" "$rel" || return $?
    pause=$(quc_pause_seconds QUC_FILE_PAUSE 0 60)
    if [ "$pause" != 0 ]; then
        quc_set_phase "pause" "$rel"
        if ! quc_sleep_interruptible "$pause"; then
            return 20
        fi
    fi
    quc_save_state || true
    return 0
}

quc_write_plan() {
    out=$1
    root=$2
    nul=$(quc_scratch_file plan.0)
    if "$quc_bin_find" "$root" -xdev -print0 -quit >/dev/null 2>&1; then
        "$quc_bin_find" "$root" -xdev -print0 > "$nul" 2>"$(quc_scratch_file transfer.err)" &
        quc_wait_pid "$!"
        wp_rc=$?
        if [ "$wp_rc" -ne 0 ]; then
            return "$wp_rc"
        fi
        wp_awk_failed=0
        LC_ALL=C "$quc_bin_awk" 'BEGIN { RS = "\0" }
            function hexof(s,    i, c, v, out, n) {
                out = ""
                n = length(s)
                for (i = 1; i <= n; i++) {
                    c = substr(s, i, 1)
                    v = ord[c]
                    if (v == "") v = 0
                    out = out sprintf("%02x", v + 0)
                }
                return out
            }
            NR == 1 {
                for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
            }
            {
                if (length($0) == 0) next
                print hexof($0)
            }' "$nul" > "$out" || {
            if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
                "$quc_bin_rm" -f -- "$nul"
                return 20
            fi
            wp_awk_failed=1
        }
        # Короткий разбор awk (старый mawk режет запись на первом NUL) не должен
        # обрывать копирование. Число NUL считается через od. При расхождении
        # имена кодируются по одному пути, без разбора NUL-записей awk.
        if [ "$wp_awk_failed" != 1 ]; then
            wp_nuls=$(LC_ALL=C "$quc_bin_od" -An -tx1 "$nul" | LC_ALL=C tr 'A-F' 'a-f' | LC_ALL=C "$quc_bin_awk" '{ for (i = 1; i <= NF; i++) if ($i == "00") c++ } END { printf "%.0f", c + 0 }')
            wp_lines=$(LC_ALL=C "$quc_bin_awk" 'NF { c++ } END { printf "%.0f", c + 0 }' "$out")
            if quc_cmp_num "$wp_nuls" "$wp_lines" eq; then
                "$quc_bin_rm" -f -- "$nul"
                return 0
            fi
            quc_log INFO "список файлов разобран не полностью, используется запасной разбор"
        else
            quc_log INFO "разбор списка через awk не удался, используется запасной разбор"
        fi
        "$quc_bin_rm" -f -- "$nul" "$out"
    fi
    printf 'x' | LC_ALL=C "$quc_bin_od" -An -tx1 >/dev/null 2>&1 || return 1
    : > "$out"
    "$quc_bin_find" "$root" -xdev -exec sh -c 'for p do printf "%s" "$p" | LC_ALL=C od -An -tx1 | LC_ALL=C tr -d "[:space:]" | LC_ALL=C tr "A-F" "a-f"; printf "\n"; done' sh {} + > "$out"
}

quc_count_plan() {
    "$quc_bin_awk" -v root="$1" 'BEGIN { c = 0 }
        NF {
            c++
        }
        END { printf "%.0f", c + 0 }' "$2"
}

quc_copy_list() {
    list=$1
    while IFS= read -r hex || [ -n "$hex" ]; do
        if [ -z "$hex" ]; then
            continue
        fi
        if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
            quc_stop_requested=1
            return 20
        fi
        if ! quc_decode_hex_var "$hex"; then
            quc_files_failed=$(quc_add_bytes "$quc_files_failed" 1)
            continue
        fi
        quc_handle_path "$quc_decoded"
        cl_rc=$?
        if [ "$cl_rc" -ne 0 ]; then
            return "$cl_rc"
        fi
    done < "$list"
    return 0
}

quc_reconcile_stopped() {
    if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
        quc_stop_requested=1
        return 0
    fi
    return 1
}

quc_reconcile_tree() {
    now=$(quc_scratch_file now.hex)
    quc_write_plan "$now" "$quc_source"
    rr_rc=$?
    if [ "$rr_rc" -ne 0 ]; then
        if [ "$rr_rc" -eq 20 ] || quc_reconcile_stopped; then
            return 20
        fi
        quc_error="не удалось повторно прочитать источник"
        return 10
    fi
    new=$(quc_scratch_file new.hex)
    gone=$(quc_scratch_file gone.hex)
    if ! "$quc_bin_awk" 'NR == FNR { a[$0] = 1; next } !($0 in a) && NF { print }' "$(quc_scratch_file plan.hex)" "$now" > "$new"; then
        if quc_reconcile_stopped; then
            return 20
        fi
        quc_error="не удалось сравнить список файлов"
        return 1
    fi
    if ! "$quc_bin_awk" 'NR == FNR { a[$0] = 1; next } !($0 in a) && NF { print }' "$now" "$(quc_scratch_file plan.hex)" > "$gone"; then
        if quc_reconcile_stopped; then
            return 20
        fi
        quc_error="не удалось сравнить список файлов"
        return 1
    fi
    if [ -s "$new" ]; then
        quc_log INFO "во время копирования появились новые объекты, выполняется один дополнительный проход"
        quc_copy_list "$new"
        rr_rc=$?
        if [ "$rr_rc" -ne 0 ]; then
            return "$rr_rc"
        fi
        quc_write_plan "$now" "$quc_source"
        rr_rc=$?
        if [ "$rr_rc" -ne 0 ]; then
            if [ "$rr_rc" -eq 20 ] || quc_reconcile_stopped; then
                return 20
            fi
            return 10
        fi
        if ! "$quc_bin_awk" 'NR == FNR { a[$0] = 1; next } !($0 in a) && NF { print }' "$(quc_scratch_file plan.hex)" "$now" > "$new"; then
            if quc_reconcile_stopped; then
                return 20
            fi
            quc_error="не удалось сравнить список файлов"
            return 1
        fi
        cat "$(quc_scratch_file plan.hex)" "$(quc_scratch_file extra.hex)" 2>/dev/null > "$(quc_scratch_file plan2.hex)" || true
    fi
    if [ -s "$new" ] || [ -s "$gone" ]; then
        quc_tree_changed=1
        quc_log INFO "набор файлов источника изменился; снимок не атомарен"
    fi
    return 0
}

quc_cleanup_partials() {
    if ! quc_identity_still; then
        return 0
    fi
    "$quc_bin_find" "$quc_target" -xdev -type f -name "${QUC_PARTIAL_PREFIX}*" -print 2>/dev/null | while IFS= read -r p; do
        rel=${p#"$quc_target"/}
        base=$(basename -- "$rel")
        case $base in
            ${QUC_PARTIAL_PREFIX}*)
                src_same=$quc_source/$rel
                if [ -e "$src_same" ] || [ -L "$src_same" ]; then
                    continue
                fi
                "$quc_bin_rm" -f -- "$p" 2>/dev/null || true
                ;;
        esac
    done
    return 0
}

quc_dest_unexpected() {
    du_list=$(quc_scratch_file dest-scan.hex)
    quc_write_plan "$du_list" "$quc_target"
    du_rc=$?
    if [ "$du_rc" -ne 0 ]; then
        return "$du_rc"
    fi
    while IFS= read -r du_hex || [ -n "$du_hex" ]; do
        if [ -z "$du_hex" ]; then
            continue
        fi
        if ! quc_decode_hex_var "$du_hex"; then
            return 1
        fi
        du_path=$quc_decoded
        if [ "$du_path" = "$quc_target" ]; then
            continue
        fi
        du_rel=${du_path#"$quc_target"/}
        du_base=$(basename -- "$du_rel")
        case $du_base in
            ${QUC_PARTIAL_PREFIX}*) continue ;;
        esac
        du_src=$quc_source/$du_rel
        if [ -e "$du_src" ] || [ -L "$du_src" ]; then
            continue
        fi
        quc_hex_encode "$du_path"
        printf '\n'
        return 0
    done < "$du_list"
    return 0
}

quc_finalize() {
    kind=$1
    msg=$2
    if [ "${quc_finalized:-0}" = 1 ]; then
        return 0
    fi
    quc_finalized=1
    if [ -n "$kind" ]; then
        quc_fatal_kind=$kind
    fi
    if [ -n "$msg" ]; then
        quc_error=$msg
    fi
    if [ "$quc_verify_during" = 1 ] && [ -n "${quc_verify_tool:-}" ] && [ "$quc_verify_tool" != unavailable ]; then
        if quc_cmp_num "$quc_files_uncertain" 0 gt || [ "$quc_tree_changed" = 1 ]; then
            quc_verify_status=uncertain
        elif quc_cmp_num "$quc_files_failed" 0 gt || quc_cmp_num "$quc_files_skipped" 0 gt; then
            quc_verify_status=failed
        elif [ -z "$quc_fatal_kind" ]; then
            quc_verify_status=checksum
        fi
    elif [ "${quc_verify_status:-none}" = none ]; then
        quc_verify_status=size
    fi
    quc_copy_status=$(quc_decide_copy_status "$quc_fatal_kind" "$quc_files_done" "$quc_files_failed" "$quc_files_uncertain" "$quc_files_skipped" "$quc_tree_changed")
    quc_ended=$(quc_now)
    quc_ended_epoch=$(quc_epoch)
    quc_phase='done'
    quc_save_state || true
    quc_log INFO "result copy_status=$quc_copy_status verify_status=$quc_verify_status sync_status=${quc_sync_status:-unconfirmed} done=$quc_files_done failed=$quc_files_failed uncertain=$quc_files_uncertain skipped=$quc_files_skipped"
    if [ -n "$quc_error" ]; then
        quc_log INFO "error=$(quc_one_line "$quc_error")"
    fi
    quc_release_lock
    quc_drop_scratch
}

quc_on_exit() {
    if [ "${quc_finalized:-0}" != 1 ]; then
        if [ -f "${quc_job_dir:-}/stop-requested" ]; then
            quc_finalize CANCELLED "остановлено по запросу"
        else
            quc_finalize INTERRUPTED "процесс завершился до установки итогового статуса"
        fi
    fi
    if [ -n "${quc_child_pid:-}" ]; then
        kill -TERM "$quc_child_pid" 2>/dev/null || true
    fi
}

quc_flag_nested_mounts() {
    root=$1
    role=$2
    seen=$(quc_scratch_file nested.seen)
    : > "$seen" || return 0
    if [ ! -r /proc/self/mountinfo ]; then
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        f5=$(printf '%s\n' "$line" | "$quc_bin_awk" '{ print $5 }')
        mp=$(quc_unescape_field "$f5" && printf X)
        mp=${mp%X}
        case $mp in
            "$root"/*) ;;
            *) continue ;;
        esac
        if "$quc_bin_grep" -F -x -e "$mp" "$seen" >/dev/null 2>&1; then
            continue
        fi
        printf '%s\n' "$mp" >> "$seen" || true
        quc_log ERROR "вложенная точка монтирования не копируется ($role): $(quc_display_path "$mp")"
        quc_files_skipped=$(quc_add_bytes "$quc_files_skipped" 1)
        quc_error="внутри накопителя есть вложенная точка монтирования; её содержимое не копировалось"
    done < /proc/self/mountinfo
    return 0
}

quc_finalize_rc() {
    fr_rc=$1
    fr_msg=$2
    if [ -f "${quc_job_dir:-}/stop-requested" ]; then
        quc_finalize CANCELLED "остановлено по запросу"
        return 0
    fi
    if [ "$fr_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ]; then
        quc_finalize INTERRUPTED "прервано сигналом"
        return 0
    fi
    quc_finalize FAILED "$fr_msg"
}

quc_worker_main() {
    quc_job_dir=$1
    quc_log_file=$quc_job_dir/log
    quc_meta_file=$quc_job_dir/done.meta
    quc_stop_requested=0
    quc_child_pid=''
    quc_finalized=0
    trap 'quc_on_term' TERM INT
    trap '' HUP
    trap 'quc_on_exit' EXIT
    if ! CDPATH='' cd -P -- "$quc_state_dir" 2>/dev/null; then
        CDPATH='' cd -P -- / 2>/dev/null || true
    fi
    if [ -d "$quc_state_dir/lock.d" ]; then
        printf '%s\n' "$$" > "$quc_state_dir/lock.d/pid" 2>/dev/null || true
    fi
    if ! quc_load_state "$quc_job_dir/state"; then
        quc_finalized=1
        exit 1
    fi
    quc_open_run_dir
    if ! quc_read_owner; then
        quc_error="нет блокировки задания"
        quc_finalize FAILED "$quc_error"
        exit 1
    fi
    if [ "$quc_owner_token" != "$quc_token" ] || [ "$quc_owner_job" != "$quc_job_id" ]; then
        quc_error="блокировка не соответствует заданию"
        quc_finalize FAILED "$quc_error"
        exit 1
    fi
    quc_pid=$$
    quc_starttime=$(quc_proc_starttime $$ || true)
    quc_write_owner "$quc_pid" "$quc_starttime" "$quc_token" "$quc_job_id" || exit 1
    if [ "${quc_lock_mode_worker:-}" = mkdir ]; then
        printf '%s\n' "$$" > "$quc_state_dir/lock.d/pid" 2>/dev/null || true
    fi
    quc_copy_status=RUNNING
    quc_phase=running
    quc_started=${quc_started:-$(quc_now)}
    quc_started_epoch=${quc_started_epoch:-$(quc_epoch)}
    quc_save_state || exit 1
    printf '%s\n' "$$" > "$quc_job_dir/ready"
    quc_apply_niceness
    quc_probe_copy_tools || true
    quc_log INFO "worker pid=$$ mode=$quc_run_mode sparse=$quc_cp_sparse sync_mode=$quc_sync_mode profile=${quc_profile:-gentle}"
    if [ "$quc_run_mode" = fresh ]; then
        if ! quc_validate_pair "$quc_source" "$quc_target" fresh; then
            quc_error=$(printf '%s\n' "$quc_problems" | "$quc_bin_awk" 'NR == 1 { print; exit }')
            quc_finalize FAILED "${quc_error:-проверка перед копированием не пройдена}"
            exit 1
        fi
    else
        if ! quc_resume_identity; then
            quc_finalize FAILED "${quc_error:-носитель не подтверждён}"
            exit 1
        fi
        "$quc_bin_rm" -f -- "$quc_job_dir/stop-requested" 2>/dev/null || true
        quc_stop_requested=0
        bad=$(quc_dest_unexpected)
        du_rc=$?
        if [ "$du_rc" -eq 20 ]; then
            quc_finalize_rc 20 "прервано сигналом"
            exit 1
        fi
        if [ "$du_rc" -ne 0 ]; then
            quc_finalize FAILED "не удалось проверить посторонние объекты назначения"
            exit 1
        fi
        if [ -n "$bad" ]; then
            if quc_decode_hex_var "$bad"; then
                quc_finalize FAILED "в назначении есть посторонний объект: $(quc_display_path "$quc_decoded")"
            else
                quc_finalize FAILED "в назначении есть посторонний объект"
            fi
            exit 1
        fi
        quc_cleanup_partials || true
    fi
    if ! quc_identity_still; then
        quc_finalize FAILED "${quc_error:-носитель недоступен}"
        exit 1
    fi
    quc_set_phase planning ''
    quc_write_plan "$(quc_scratch_file plan.hex)" "$quc_source"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        quc_finalize_rc "$rc" "не удалось составить список файлов источника"
        exit 1
    fi
    total=$("$quc_bin_awk" 'NF { c++ } END { printf "%.0f", c + 0 }' "$(quc_scratch_file plan.hex)")
    if quc_cmp_num "$total" 0 gt; then
        total=$(quc_add_bytes "$total" -1)
    fi
    quc_files_total=$total
    quc_files_done=0
    quc_files_failed=0
    quc_files_uncertain=0
    quc_files_skipped=0
    quc_bytes_done=0
    quc_flag_nested_mounts "$quc_source" "источник" || true
    quc_save_state || true
    quc_copy_list "$(quc_scratch_file plan.hex)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        quc_finalize_rc "$rc" "${quc_error:-копирование прервано ошибкой}"
        exit 1
    fi
    quc_reconcile_tree
    rc=$?
    if [ "$rc" -ne 0 ]; then
        quc_finalize_rc "$rc" "${quc_error:-ошибка повторной проверки дерева}"
        exit 1
    fi
    if ! quc_identity_still; then
        quc_finalize FAILED "${quc_error:-носитель недоступен перед завершением}"
        exit 1
    fi
    if [ "$quc_sync_mode" != data ] && [ "$quc_sync_mode" != file ]; then
        quc_sync_unconfirmed=1
        quc_sync_status=unconfirmed
        quc_log INFO "команда sync с файловым аргументом недоступна; сброс на носитель не подтверждён"
    elif [ "${quc_sync_unconfirmed:-0}" = 1 ]; then
        quc_sync_status=unconfirmed
        quc_log INFO "сброс данных на носитель не подтверждён"
    elif quc_sync_cmd "$quc_target" >/dev/null 2>&1; then
        quc_sync_unconfirmed=0
        quc_sync_status=command_ok
        quc_log INFO "sync mode=$quc_sync_mode status=command_ok"
    else
        quc_sync_unconfirmed=1
        quc_sync_status=unconfirmed
        quc_log INFO "не удалось синхронизировать каталог назначения"
    fi
    quc_finalize '' ''
    exit 0
}

quc_spawn_worker() {
    # /bin/sh, а не прямой запуск файла: скрипт может быть без бита исполнения.
    if [ -n "$quc_bin_setsid" ] && [ -n "$quc_bin_nice" ]; then
        "$quc_bin_setsid" "$quc_bin_nice" -n 19 /bin/sh "$quc_self" _worker "$quc_job_dir" </dev/null >/dev/null 2>&1 &
    elif [ -n "$quc_bin_setsid" ]; then
        "$quc_bin_setsid" /bin/sh "$quc_self" _worker "$quc_job_dir" </dev/null >/dev/null 2>&1 &
    elif [ -n "$quc_bin_nohup" ] && [ -n "$quc_bin_nice" ]; then
        "$quc_bin_nohup" "$quc_bin_nice" -n 19 /bin/sh "$quc_self" _worker "$quc_job_dir" </dev/null >/dev/null 2>&1 &
    elif [ -n "$quc_bin_nohup" ]; then
        "$quc_bin_nohup" /bin/sh "$quc_self" _worker "$quc_job_dir" </dev/null >/dev/null 2>&1 &
    else
        /bin/sh "$quc_self" _worker "$quc_job_dir" </dev/null >/dev/null 2>&1 &
    fi
    quc_spawn_pid=$!
    printf '%s\n' "$quc_spawn_pid" > "$quc_job_dir/spawn.pid" 2>/dev/null || true
}

quc_wait_ready() {
    i=0
    while quc_cmp_num "$i" 15 lt; do
        if [ -f "$quc_job_dir/ready" ]; then
            return 0
        fi
        if [ -f "$quc_job_dir/state" ]; then
            st=$("$quc_bin_awk" -F= '$1 == "copy_status" { print $2; exit }' "$quc_job_dir/state" 2>/dev/null || true)
            case $st in
                FAILED|CANCELLED|INTERRUPTED) return 1 ;;
            esac
        fi
        "$quc_bin_sleep" 1
        i=$(quc_add_bytes "$i" 1)
    done
    if [ -f "$quc_job_dir/ready" ]; then
        return 0
    fi
    return 1
}

quc_open_job() {
    id=$1
    if ! quc_job_id_safe "$id"; then
        return 1
    fi
    quc_job_dir=$quc_jobs_dir/$id
    if [ ! -d "$quc_job_dir" ] || [ -L "$quc_job_dir" ]; then
        return 1
    fi
    quc_log_file=$quc_job_dir/log
    quc_load_state "$quc_job_dir/state"
}

quc_current_id() {
    if [ ! -f "$quc_current" ]; then
        return 1
    fi
    id=$("$quc_bin_cat" "$quc_current" 2>/dev/null || true)
    quc_job_id_safe "$id" || return 1
    printf '%s\n' "$id"
}

quc_cmd_help() {
    cat <<'EOF'
Quiet USB Copy копирует один уже смонтированный накопитель на другой.
Пароль не нужен. Окна, звук и уведомления программа не создаёт.

В терминале

  sh quiet_usb_copy.sh

Один экран: источник, назначение, проверка, затем 1, 2 или 0.
Направление само не угадывается. После 1 терминал свободен.
Вопрос во время копирования не задаётся. Если списка нет, введите
два абсолютных пути. Вне терминала меню не открывается.

  sh quiet_usb_copy.sh status
  sh quiet_usb_copy.sh stop
  sh quiet_usb_copy.sh resume
  sh quiet_usb_copy.sh help

Для автоматизации

  sh quiet_usb_copy.sh start ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh start --profile gentle --verify ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh check ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh status --machine
  sh quiet_usb_copy.sh report
  sh quiet_usb_copy.sh report --verbose
  sh quiet_usb_copy.sh verify
  sh quiet_usb_copy.sh doctor
  sh quiet_usb_copy.sh selftest
  sh quiet_usb_copy.sh cleanup
  sh quiet_usb_copy.sh cleanup --dry-run
  sh quiet_usb_copy.sh version

status в терминале — короткий русский итог. Для программ: --machine.
Диагностика: report --verbose. Профиль gentle снижает приоритет только
этого копирования и не обещает отсутствия задержек флешки.

Назначение при обычном запуске должно быть пустым. resume продолжает
прерванное задание. Успешные копирование, контрольная сумма и sync не
заменяют штатное безопасное извлечение средствами операционной системы.

Пути с дефисом в начале указывайте после -- :
  sh quiet_usb_copy.sh start -- --источник --назначение

Коды выхода: 0 команда принята, 1 отказ или сбой операции,
2 неверные аргументы, 70 нет программ или служебного каталога.
Строки error_code=: E_OK, E_FAIL, E_USAGE, E_ENV, E_REJECT, E_NOJOB.

Постоянные данные восстановления:
  ${XDG_STATE_HOME:-$HOME/.local/state}/quiet-usb-copy/
Временные списки, если каталог доступен:
  ${XDG_RUNTIME_DIR}/quiet-usb-copy/
На флешках файлы программы не создаются. cleanup удаляет только свои
завершённые служебные данные. --dry-run только показывает список.
Выполняющееся задание не удаляется.
EOF
}

quc_cmd_version() {
    printf 'quiet-usb-copy %s\n' "$QUC_VERSION"
    printf 'build %s\n' "$QUC_BUILD"
}

quc_cmd_check() {
    if [ "$#" -ne 2 ]; then
        printf '%s\n' "Нужны два каталога: источник и назначение." >&2
        return 2
    fi
    quc_prepare_state || true
    if ! quc_validate_pair "$1" "$2" fresh; then
        printf '%s\n' "Проверка: копировать нельзя."
        printf '%s\n' "$quc_problems" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf 'Причина: %s\n' "$line"
        done
        if [ -n "$quc_notes" ]; then
            printf '%s\n' "$quc_notes" | while IFS= read -r line; do
                [ -n "$line" ] || continue
                printf 'Замечание: %s\n' "$line"
            done
        fi
        printf '%s\n' "check_result=REJECT"
        printf '%s\n' "error_code=E_REJECT"
        return 1
    fi
    printf '%s\n' "Проверка: можно запускать копирование."
    printf 'Источник: %s\n' "$(quc_display_path "$quc_source")"
    printf 'Назначение: %s\n' "$(quc_display_path "$quc_target")"
    printf 'Файловые системы: %s -> %s\n' "$quc_source_fs" "$quc_target_fs"
    if [ -n "${quc_need_bytes:-}" ]; then
        printf 'Объём данных: %s, свободно: %s\n' "$(quc_human_bytes "$quc_need_bytes")" "$(quc_human_bytes "${quc_free_have:-0}")"
    fi
    if [ -n "$quc_notes" ]; then
        printf '%s\n' "$quc_notes" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf 'Замечание: %s\n' "$line"
        done
    fi
    printf '%s\n' "check_result=OK"
    printf '%s\n' "error_code=E_OK"
    return 0
}

quc_begin_job() {
    mode=$1
    publish=${2:-yes}
    quc_job_id=$(quc_new_job_id)
    quc_job_dir=$quc_jobs_dir/$quc_job_id
    "$quc_bin_mkdir" -p -- "$quc_job_dir" || return 70
    "$quc_bin_chmod" 700 -- "$quc_job_dir" || return 70
    quc_log_file=$quc_job_dir/log
    : > "$quc_log_file" || return 70
    quc_meta_file=$quc_job_dir/done.meta
    : > "$quc_meta_file" || return 70
    quc_token=$(quc_new_token)
    quc_version=$QUC_VERSION
    quc_started=$(quc_now)
    quc_started_epoch=$(quc_epoch)
    quc_copy_status=STARTING
    quc_run_mode=$mode
    quc_files_total=${quc_files_total:-0}
    quc_files_done=${quc_files_done:-0}
    quc_files_failed=${quc_files_failed:-0}
    quc_files_uncertain=${quc_files_uncertain:-0}
    quc_files_skipped=${quc_files_skipped:-0}
    quc_bytes_done=${quc_bytes_done:-0}
    quc_tree_changed=${quc_tree_changed:-0}
    quc_metadata_gaps=${quc_metadata_gaps:-0}
    quc_verify_status=${quc_verify_status:-none}
    quc_sync_unconfirmed=0
    quc_sync_status=unconfirmed
    quc_sync_mode=
    case ${quc_profile:-} in
        gentle) ;;
        *) quc_profile=gentle ;;
    esac
    quc_save_state || return 1
    if [ "$publish" = yes ]; then
        printf '%s\n' "$quc_job_id" > "$quc_current" || return 1
    fi
    return 0
}

quc_cmd_start() {
    exec </dev/null >/dev/null 2>&1
    if ! quc_prepare_state; then
        exit 70
    fi
    verify=0
    quc_profile=gentle
    while [ "$#" -gt 0 ]; do
        case $1 in
            --verify) verify=1; shift ;;
            --profile)
                shift
                case ${1:-} in
                    gentle) quc_profile=gentle; shift ;;
                    *)
                        quc_note_error "неизвестный профиль; доступен только gentle"
                        exit 2
                        ;;
                esac
                ;;
            --) shift; break ;;
            -*)
                quc_note_error "неизвестный параметр запуска"
                exit 2
                ;;
            *) break ;;
        esac
    done
    if [ "$#" -ne 2 ]; then
        quc_note_error "нужны ровно два пути: источник и назначение"
        exit 2
    fi
    if ! quc_validate_pair "$1" "$2" fresh; then
        quc_verify_during=$verify
        if [ -z "$quc_source" ]; then
            quc_source=$1
        fi
        if [ -z "$quc_target" ]; then
            quc_target=$2
        fi
        quc_error=$(printf '%s\n' "$quc_problems" | "$quc_bin_awk" 'NR == 1 { print; exit }')
        quc_verify_status=none
        publish=yes
        if quc_read_owner && quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$quc_jobs_dir/$quc_owner_job"; then
            publish=no
        fi
        quc_begin_job fresh "$publish" || exit 70
        quc_copy_status=FAILED
        quc_fatal_kind=FAILED
        quc_ended=$(quc_now)
        quc_ended_epoch=$(quc_epoch)
        quc_phase='done'
        quc_save_state || exit 1
        printf '%s\n' "$quc_problems" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            quc_log ERROR "$line"
        done
        if [ "$publish" = yes ]; then
            quc_note_error "$quc_error"
        fi
        exit 1
    fi
    quc_verify_during=$verify
    quc_launch_prepared
}

quc_launch_prepared() {
    exec </dev/null >/dev/null 2>&1
    if ! quc_acquire_lock; then
        quc_note_error "уже выполняется другое задание"
        exit 1
    fi
    # flock is held on fd 9 when available; the worker inherits it.
    if ! quc_begin_job fresh; then
        quc_release_lock
        exit 70
    fi
    quc_write_owner "$$" "$(quc_proc_starttime $$ || printf 0)" "$quc_token" "$quc_job_id" || {
        quc_release_lock
        exit 1
    }
    quc_clear_error
    quc_log INFO "start source=$(quc_display_path "$quc_source") target=$(quc_display_path "$quc_target") verify=$quc_verify_during"
    quc_spawn_worker
    if ! quc_wait_ready; then
        exit 1
    fi
    exit 0
}

quc_status_text() {
    case $1 in
        RUNNING) printf '%s\n' "выполняется" ;;
        SUCCESS) printf '%s\n' "копирование завершено" ;;
        PARTIAL) printf '%s\n' "копирование неполное" ;;
        FAILED) printf '%s\n' "ошибка" ;;
        CANCELLED) printf '%s\n' "остановлено" ;;
        INTERRUPTED) printf '%s\n' "прервано" ;;
        UNCERTAIN) printf '%s\n' "результат не подтверждён" ;;
        STARTING) printf '%s\n' "запуск" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

quc_print_media_lines() {
    case ${quc_sync_status:-unconfirmed} in
        command_ok)
            printf 'sync_status=%s\n' command_ok
            printf '%s\n' "Синхронизация: команда sync завершилась без ошибки. Это не подтверждение, что кэш накопителя записан, и не разрешение его извлекать."
            ;;
        *)
            printf 'sync_status=%s\n' unconfirmed
            printf '%s\n' "Синхронизация: сброс данных на носитель не подтверждён."
            ;;
    esac
    printf '%s\n' "Извлечение: перед физическим извлечением выполните штатную процедуру безопасного извлечения операционной системы. Успешные копирование, контрольная сумма и sync сами по себе этого не разрешают."
}

quc_print_job() {
    brief=$1
    printf 'Задание: %s\n' "$quc_job_id"
    printf 'Состояние: %s\n' "$(quc_status_text "$quc_copy_status")"
    printf 'copy_status=%s\n' "$quc_copy_status"
    printf 'verify_status=%s\n' "$quc_verify_status"
    if [ -n "$quc_verify_tool" ]; then
        printf 'verify_tool=%s\n' "$quc_verify_tool"
    fi
    case $quc_verify_status in
        checksum) printf '%s\n' "Целостность: подтверждена контрольной суммой ($quc_verify_tool)." ;;
        size) printf '%s\n' "Целостность: при копировании сравнивались размеры. Контрольная сумма не считалась." ;;
        failed) printf '%s\n' "Целостность: ОТЛИЧИЯ НАЙДЕНЫ." ;;
        uncertain) printf '%s\n' "Целостность: источник менялся во время проверки." ;;
        byte) printf '%s\n' "Целостность: побайтовое сравнение без отдельной контрольной суммы." ;;
        *) printf '%s\n' "Целостность: не проверялась." ;;
    esac
    quc_print_media_lines
    printf 'Источник: %s\n' "$(quc_display_path "$quc_source")"
    printf 'Назначение: %s\n' "$(quc_display_path "$quc_target")"
    printf 'Объектов: %s из %s\n' "$quc_files_done" "$quc_files_total"
    printf 'files_done=%s\n' "$quc_files_done"
    printf 'files_total=%s\n' "$quc_files_total"
    printf 'files_failed=%s\n' "$quc_files_failed"
    printf 'files_uncertain=%s\n' "$quc_files_uncertain"
    printf 'files_skipped=%s\n' "$quc_files_skipped"
    printf 'bytes_done=%s\n' "$quc_bytes_done"
    printf 'Объём: %s\n' "$(quc_human_bytes "$quc_bytes_done")"
    if [ "$quc_metadata_gaps" = 1 ]; then
        printf '%s\n' "Метаданные: часть прав или времени файлов не сохранилась. Содержимое от этого не становится успешным или неуспешным."
    fi
    if [ "$quc_tree_changed" = 1 ]; then
        printf '%s\n' "Дерево источника изменилось во время работы. Это не атомарный снимок."
    fi
    if [ -n "$quc_error" ]; then
        printf 'Сообщение: %s\n' "$quc_error"
    fi
    if [ "$brief" -eq 0 ] && [ -f "$quc_log_file" ]; then
        printf '%s\n' "Журнал: $quc_log_file"
        printf '%s\n' "Последние ошибки:"
        "$quc_bin_awk" '/ ERROR / { n = NR; lines[NR] = $0 } END { start = NR - 19; if (start < 1) start = 1; for (i = start; i <= NR; i++) if (lines[i] != "") print lines[i] }' "$quc_log_file" 2>/dev/null || true
    fi
}

quc_print_human() {
    case $quc_copy_status in
        RUNNING|STARTING) printf '%s\n' "Копирование выполняется." ;;
        SUCCESS) printf '%s\n' "Копирование завершено." ;;
        CANCELLED|INTERRUPTED) printf '%s\n' "Копирование остановлено." ;;
        FAILED) printf '%s\n' "Копирование не выполнено." ;;
        PARTIAL) printf '%s\n' "Копирование завершено частично." ;;
        UNCERTAIN) printf '%s\n' "Результат копирования не подтверждён." ;;
        *) printf 'Копирование: %s\n' "$(quc_status_text "$quc_copy_status")" ;;
    esac
    printf 'Файлы: %s из %s\n' "${quc_files_done:-0}" "${quc_files_total:-0}"
    case ${quc_verify_status:-none} in
        checksum|byte) printf '%s\n' "Проверка содержимого: завершена" ;;
        size) printf '%s\n' "Проверка содержимого: сравнивались только размеры" ;;
        failed) printf '%s\n' "Проверка содержимого: найдены отличия" ;;
        uncertain) printf '%s\n' "Проверка содержимого: источник менялся" ;;
        *) printf '%s\n' "Проверка содержимого: не выполнялась" ;;
    esac
    case ${quc_sync_status:-unconfirmed} in
        command_ok)
            printf '%s\n' "Синхронизация: команда sync завершилась без ошибки. Это не разрешение извлекать накопитель."
            ;;
        *)
            printf '%s\n' "Синхронизация: сброс данных на носитель не подтверждён."
            ;;
    esac
    printf '%s\n' "Для извлечения используйте средства ОС."
    case ${quc_profile:-gentle} in
        gentle)
            printf '%s\n' "Режим: бережный. Задержки самой флешки возможны."
            ;;
        *)
            printf 'Режим: %s\n' "$quc_profile"
            ;;
    esac
    case $quc_copy_status in
        PARTIAL|FAILED|UNCERTAIN)
            if [ -n "${quc_error:-}" ]; then
                printf 'Причина: %s\n' "$(quc_one_line "$quc_error")"
            else
                case $quc_copy_status in
                    PARTIAL) printf '%s\n' "Причина: часть объектов не скопирована." ;;
                    FAILED) printf '%s\n' "Причина: копирование не удалось." ;;
                    *) printf '%s\n' "Причина: результат не подтверждён." ;;
                esac
            fi
            printf '%s\n' "Подробнее: report"
            ;;
    esac
}

quc_parse_view_args() {
    quc_view_mode=
    quc_view_verbose=0
    quc_view_id=
    while [ "$#" -gt 0 ]; do
        case $1 in
            --machine) quc_view_mode=machine ;;
            --human) quc_view_mode=human ;;
            --verbose) quc_view_verbose=1 ;;
            --)
                shift
                break
                ;;
            -*)
                return 2
                ;;
            *)
                if [ -n "$quc_view_id" ]; then
                    return 2
                fi
                quc_view_id=$1
                ;;
        esac
        shift
    done
    while [ "$#" -gt 0 ]; do
        case $1 in
            -*) return 2 ;;
            *)
                if [ -n "$quc_view_id" ]; then
                    return 2
                fi
                quc_view_id=$1
                ;;
        esac
        shift
    done
    if [ -z "$quc_view_mode" ]; then
        if [ -t 1 ]; then
            quc_view_mode=human
        else
            quc_view_mode=machine
        fi
    fi
    return 0
}

quc_print_report_extra() {
    if [ -n "$quc_started" ]; then
        printf 'Начало: %s\n' "$quc_started"
    fi
    if [ -n "$quc_ended" ]; then
        printf 'Конец: %s\n' "$quc_ended"
    fi
    if quc_cmp_num "$quc_started_epoch" 0 gt && quc_cmp_num "$quc_ended_epoch" 0 gt; then
        dur=$(quc_add_bytes "$quc_ended_epoch" "-$quc_started_epoch")
        printf 'Длительность: %s с\n' "$dur"
    fi
    printf '%s\n' "Файловые системы: ${quc_source_fs:-?} -> ${quc_target_fs:-?}"
    printf 'profile=%s\n' "${quc_profile:-gentle}"
}

quc_render_view() {
    brief=$1
    if [ "$quc_view_mode" = human ] && [ "$quc_view_verbose" = 1 ]; then
        quc_print_human
        printf '\n%s\n' "Диагностика:"
        quc_print_job 0
        quc_print_report_extra
        return 0
    fi
    if [ "$quc_view_mode" = human ]; then
        quc_print_human
        return 0
    fi
    if [ "$quc_view_verbose" = 1 ] || [ "$brief" -eq 0 ]; then
        quc_print_job 0
        quc_print_report_extra
        return 0
    fi
    quc_print_job 1
}

quc_cmd_status() {
    if ! quc_prepare_state; then
        printf '%s\n' "Служебный каталог недоступен." >&2
        printf '%s\n' "error_code=E_ENV" >&2
        return 70
    fi
    if ! quc_parse_view_args "$@"; then
        printf '%s\n' "Непонятные аргументы status. См. help." >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    id=$quc_view_id
    if [ -z "$id" ]; then
        id=$(quc_current_id || true)
    fi
    if [ -z "$id" ]; then
        printf '%s\n' "Заданий пока нет."
        if [ -f "$quc_last_error" ]; then
            printf 'Последнее сообщение: %s\n' "$("$quc_bin_cat" "$quc_last_error")"
        fi
        printf '%s\n' "error_code=E_NOJOB"
        return 1
    fi
    if ! quc_open_job "$id"; then
        printf '%s\n' "Задание не найдено." >&2
        printf '%s\n' "error_code=E_NOJOB" >&2
        return 1
    fi
    quc_render_view 1
    if [ -f "$quc_last_error" ] && [ "$quc_copy_status" = RUNNING ]; then
        printf 'Последнее сообщение: %s\n' "$("$quc_bin_cat" "$quc_last_error")"
    fi
    return 0
}

quc_cmd_report() {
    if ! quc_prepare_state; then
        printf '%s\n' "Служебный каталог недоступен." >&2
        printf '%s\n' "error_code=E_ENV" >&2
        return 70
    fi
    if ! quc_parse_view_args "$@"; then
        printf '%s\n' "Непонятные аргументы report. См. help." >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    id=$quc_view_id
    if [ -z "$id" ]; then
        id=$(quc_current_id || true)
    fi
    if [ -z "$id" ] || ! quc_open_job "$id"; then
        printf '%s\n' "Отчёта нет: задание не найдено."
        if [ -f "$quc_last_error" ]; then
            printf 'Последнее сообщение: %s\n' "$("$quc_bin_cat" "$quc_last_error")"
        fi
        printf '%s\n' "error_code=E_NOJOB"
        return 1
    fi
    quc_render_view 0
    return 0
}

quc_mark_stopped() {
    if ! quc_open_job "$1"; then
        return 1
    fi
    case $quc_copy_status in
        RUNNING|STARTING)
            quc_copy_status=CANCELLED
            quc_fatal_kind=CANCELLED
            quc_error="остановлено командой stop"
            quc_ended=$(quc_now)
            quc_ended_epoch=$(quc_epoch)
            quc_phase='done'
            quc_save_state || true
            quc_log INFO "result copy_status=CANCELLED"
            ;;
    esac
    quc_release_lock
}

quc_cmd_stop() {
    if ! quc_prepare_state; then
        printf '%s\n' "Служебный каталог недоступен." >&2
        return 70
    fi
    if ! quc_read_owner; then
        printf '%s\n' "Выполняющегося задания нет."
        return 0
    fi
    job_dir=$quc_jobs_dir/$quc_owner_job
    if quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$job_dir"; then
        printf '%s\n' 1 > "$job_dir/stop-requested"
        child=''
        if [ -f "$job_dir/childpid" ]; then
            child=$("$quc_bin_cat" "$job_dir/childpid" 2>/dev/null || true)
        fi
        if quc_is_uint "$child"; then
            ppid=$(quc_proc_ppid "$child" || true)
            if [ "$ppid" = "$quc_owner_pid" ]; then
                kill -TERM "$child" 2>/dev/null || true
            fi
        fi
        kill -TERM "$quc_owner_pid" 2>/dev/null || true
        i=0
        while quc_cmp_num "$i" 10 lt; do
            if ! kill -0 "$quc_owner_pid" 2>/dev/null; then
                break
            fi
            if ! quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$job_dir"; then
                break
            fi
            "$quc_bin_sleep" 1
            i=$(quc_add_bytes "$i" 1)
        done
        if kill -0 "$quc_owner_pid" 2>/dev/null && quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$job_dir"; then
            kill -KILL "$quc_owner_pid" 2>/dev/null || true
        fi
        quc_mark_stopped "$quc_owner_job" || true
        printf '%s\n' "Задание остановлено."
        return 0
    fi
    printf '%s\n' "Указанный процесс не принадлежит Quiet USB Copy. Сигнал не отправлен."
    if quc_is_uint "$quc_owner_pid" && [ -d "/proc/$quc_owner_pid" ]; then
        printf '%s\n' "Чужой процесс не затронут."
        return 1
    fi
    "$quc_bin_rm" -f -- "$quc_owner" 2>/dev/null || true
    "$quc_bin_rm" -rf -- "$quc_state_dir/lock.d" 2>/dev/null || true
    printf '%s\n' "Снята устаревшая блокировка."
    return 0
}

quc_cmd_resume() {
    exec </dev/null >/dev/null 2>&1
    if ! quc_prepare_state; then
        exit 70
    fi
    id=''
    if [ "$#" -eq 1 ]; then
        id=$1
    else
        id=$(quc_current_id || true)
    fi
    if [ -z "$id" ] || ! quc_open_job "$id"; then
        quc_note_error "нет прерванного задания для продолжения"
        exit 1
    fi
    case $quc_copy_status in
        INTERRUPTED|CANCELLED|PARTIAL|FAILED|UNCERTAIN) ;;
        RUNNING|STARTING)
            quc_note_error "задание ещё выполняется"
            exit 1
            ;;
        SUCCESS)
            quc_note_error "задание уже завершено успешно, resume не нужен"
            exit 1
            ;;
        *)
            quc_note_error "это задание нельзя продолжить"
            exit 1
            ;;
    esac
    if ! quc_resume_identity; then
        quc_note_error "${quc_error:-носитель не подтверждён}"
        quc_log ERROR "${quc_error:-resume rejected}"
        exit 1
    fi
    # Старый stop-requested не должен обрывать новую проверку назначения.
    "$quc_bin_rm" -f -- "$quc_job_dir/stop-requested" 2>/dev/null || true
    quc_open_run_dir
    bad=$(quc_dest_unexpected)
    du_rc=$?
    quc_drop_scratch
    if [ "$du_rc" -ne 0 ]; then
        quc_error="не удалось проверить посторонние объекты назначения"
        quc_note_error "$quc_error"
        quc_log ERROR "$quc_error"
        exit 1
    fi
    if [ -n "$bad" ]; then
        if quc_decode_hex_var "$bad"; then
            quc_error="в назначении есть посторонний объект: $(quc_display_path "$quc_decoded")"
        else
            quc_error="в назначении есть посторонний объект"
        fi
        quc_note_error "$quc_error"
        quc_log ERROR "$quc_error"
        exit 1
    fi
    if ! quc_acquire_lock; then
        quc_note_error "уже выполняется другое задание"
        exit 1
    fi
    quc_run_mode=resume
    quc_copy_status=STARTING
    quc_fatal_kind=''
    quc_error=''
    quc_ended=''
    quc_phase=resume
    quc_token=$(quc_new_token)
    "$quc_bin_rm" -f -- "$quc_job_dir/ready" "$quc_job_dir/stop-requested" 2>/dev/null || true
    quc_save_state || exit 1
    quc_write_owner "$$" "$(quc_proc_starttime $$ || printf 0)" "$quc_token" "$quc_job_id" || exit 1
    quc_clear_error
    quc_log INFO "resume job=$quc_job_id"
    quc_spawn_worker
    if ! quc_wait_ready; then
        exit 1
    fi
    exit 0
}

quc_cmd_verify() {
    if ! quc_prepare_state; then
        printf '%s\n' "Служебный каталог недоступен." >&2
        return 70
    fi
    id=$(quc_current_id || true)
    if [ "$#" -eq 1 ]; then
        id=$1
    fi
    if [ -z "$id" ] || ! quc_open_job "$id"; then
        printf '%s\n' "Нет задания для проверки." >&2
        return 1
    fi
    case $quc_copy_status in
        RUNNING|STARTING)
            printf '%s\n' "Задание ещё выполняется. Проверка не начата."
            return 1
            ;;
    esac
    if ! quc_identity_still; then
        printf '%s\n' "Носитель недоступен, проверка не выполнена."
        quc_verify_status=failed
        quc_save_state || true
        return 1
    fi
    tool='size'
    if quc_hash_tool; then
        tool=$quc_hash_name
    elif [ -n "${quc_bin_cmp:-}" ]; then
        tool='cmp'
    fi
    quc_verify_tool=$tool
    bad=0
    uncertain=0
    quc_open_run_dir
    plan=$(quc_scratch_file verify.hex)
    if ! quc_write_plan "$plan" "$quc_source"; then
        quc_drop_scratch
        printf '%s\n' "Не удалось прочитать источник."
        return 1
    fi
    while IFS= read -r hex || [ -n "$hex" ]; do
        [ -n "$hex" ] || continue
        quc_decode_hex_var "$hex" || continue
        path=$quc_decoded
        if [ "$path" = "$quc_source" ]; then
            continue
        fi
        prefix=$quc_source/
        rel=${path#"$prefix"}
        dst=$quc_target/$rel
        kind=$(quc_kind_of "$path" || true)
        case $kind in
            dir)
                if [ ! -d "$dst" ] || [ -L "$dst" ]; then
                    bad=1
                    printf 'Нет каталога: %s\n' "$(quc_display_path "$rel")"
                fi
                ;;
            link)
                if [ ! -L "$dst" ]; then
                    bad=1
                    printf 'Нет ссылки: %s\n' "$(quc_display_path "$rel")"
                else
                    a=$("$quc_bin_readlink" -- "$path")
                    b=$("$quc_bin_readlink" -- "$dst")
                    if [ "$a" != "$b" ]; then
                        bad=1
                        printf 'Ссылка отличается: %s\n' "$(quc_display_path "$rel")"
                    fi
                fi
                ;;
            regular)
                fp1=$(quc_fingerprint "$path" || true)
                if [ ! -f "$dst" ] || [ -L "$dst" ]; then
                    bad=1
                    printf 'Нет файла: %s\n' "$(quc_display_path "$rel")"
                    continue
                fi
                s1=$(quc_file_size "$path" || printf '')
                s2=$(quc_file_size "$dst" || printf '')
                if [ "$s1" != "$s2" ]; then
                    bad=1
                    printf 'Размер отличается: %s\n' "$(quc_display_path "$rel")"
                    continue
                fi
                if [ "$tool" = cmp ]; then
                    if ! "$quc_bin_cmp" -s -- "$path" "$dst"; then
                        bad=1
                        printf 'Содержимое отличается: %s\n' "$(quc_display_path "$rel")"
                    fi
                elif [ "$tool" != size ]; then
                    h1=$(quc_hash_file "$path" || true)
                    h2=$(quc_hash_file "$dst" || true)
                    h3=$(quc_hash_file "$path" || true)
                    if [ -z "$h1" ] || [ "$h1" != "$h3" ] || [ "$fp1" != "$(quc_fingerprint "$path" || true)" ]; then
                        uncertain=1
                        printf 'Источник изменился во время проверки: %s\n' "$(quc_display_path "$rel")"
                    elif [ "$h1" != "$h2" ]; then
                        bad=1
                        printf 'Контрольная сумма отличается: %s\n' "$(quc_display_path "$rel")"
                    fi
                fi
                ;;
            *)
                printf 'Специальный файл не входит в проверку содержимого: %s\n' "$(quc_display_path "$rel")"
                bad=1
                ;;
        esac
    done < "$plan"
    quc_drop_scratch
    if [ "$uncertain" -eq 1 ]; then
        quc_verify_status=uncertain
        quc_save_state || true
        printf '%s\n' "Целостность: источник менялся во время проверки."
        printf '%s\n' "verify_status=uncertain"
        quc_print_media_lines
        return 1
    fi
    if [ "$bad" -eq 1 ]; then
        quc_verify_status=failed
        quc_save_state || true
        printf '%s\n' "Целостность: ОТЛИЧИЯ НАЙДЕНЫ."
        printf '%s\n' "verify_status=failed"
        quc_print_media_lines
        return 1
    fi
    if [ "$tool" = size ]; then
        quc_verify_status=size
        printf '%s\n' "Контрольная сумма недоступна. Совпали только размеры и наличие объектов."
    elif [ "$tool" = cmp ]; then
        quc_verify_status=byte
        printf '%s\n' "Целостность: побайтовое сравнение совпало. Отдельная контрольная сумма не считалась."
    else
        quc_verify_status=checksum
        printf '%s\n' "Целостность: подтверждена ($tool)."
    fi
    quc_save_state || true
    printf 'verify_status=%s\n' "$quc_verify_status"
    printf 'verify_tool=%s\n' "$tool"
    quc_print_media_lines
    return 0
}

quc_cmd_worker() {
    exec </dev/null >/dev/null 2>&1
    if [ "$#" -ne 1 ]; then
        exit 2
    fi
    if ! quc_prepare_state; then
        exit 70
    fi
    quc_worker_main "$1"
}

quc_answer_is_yes() {
    case ${1:-} in
        да) return 0 ;;
        *) return 1 ;;
    esac
}

quc_volume_candidate() {
    vc_src=$1
    vc_fs=$2
    vc_mp=$3
    vc_rem=$4
    case $vc_src in
        /dev/*) ;;
        *) return 1 ;;
    esac
    case $vc_mp in
        ''|/) return 1 ;;
    esac
    case $vc_fs in
        ''|autofs|proc|sysfs|tmpfs|devtmpfs|devpts|cgroup|cgroup2|overlay|squashfs|nfs|nfs4|cifs|smb3|fuse.portal|fusectl|debugfs|tracefs|securityfs|bpf|configfs|pstore|mqueue|hugetlbfs|ramfs|binfmt_misc|nsfs|rpc_pipefs)
            return 1
            ;;
        fuse.*) return 1 ;;
    esac
    if quc_is_system_path "$vc_mp"; then
        return 1
    fi
    case $vc_rem in
        yes) return 0 ;;
        *) return 1 ;;
    esac
}

quc_volume_label() {
    vl_spec=$1
    vl_mp=$2
    vl_label=
    if [ -n "${quc_bin_findmnt:-}" ]; then
        vl_label=$("$quc_bin_findmnt" -n -o LABEL -T "$vl_mp" 2>/dev/null | "$quc_bin_awk" 'NR == 1 { print; exit }') || vl_label=
    fi
    case $vl_label in
        */*) vl_label= ;;
    esac
    if [ -n "$vl_label" ]; then
        printf '%s\n' "$vl_label"
        return 0
    fi
    if [ -d /dev/disk/by-label ] && [ ! -L /dev/disk/by-label ]; then
        vl_want=$("$quc_bin_readlink" -f -- "$vl_spec" 2>/dev/null || true)
        if [ -n "$vl_want" ]; then
            vl_found=$("$quc_bin_find" /dev/disk/by-label -mindepth 1 -maxdepth 1 -print 2>/dev/null | while IFS= read -r vl_link || [ -n "$vl_link" ]; do
                [ -n "$vl_link" ] || continue
                vl_real=$("$quc_bin_readlink" -f -- "$vl_link" 2>/dev/null || true)
                if [ "$vl_real" = "$vl_want" ]; then
                    "$quc_bin_basename" -- "$vl_link"
                    break
                fi
            done)
            if [ -n "$vl_found" ]; then
                printf '%s\n' "$vl_found"
                return 0
            fi
        fi
    fi
    printf '\n'
}

quc_collect_volumes() {
    out=$1
    seen=$1.seen
    : > "$out" || return 1
    : > "$seen" || return 1
    quc_vol_shown=0
    quc_vol_skipped=0
    root_dev=$(quc_dev_of / || true)
    # Тестовый список заменяет живой обход: меню не должно выбрать настоящий носитель.
    if [ -z "${QUC_FAKE_VOLUMES:-}" ] && [ -r /proc/self/mountinfo ]; then
        while IFS= read -r cv_line || [ -n "$cv_line" ]; do
            [ -n "$cv_line" ] || continue
            cv_f5=$(printf '%s\n' "$cv_line" | "$quc_bin_awk" '{ print $5 }')
            cv_mp=$(quc_unescape_field "$cv_f5" && printf X) || continue
            cv_mp=${cv_mp%X}
            cv_parsed=$(printf '%s\n' "$cv_line" | "$quc_bin_awk" '{
                fst = ""
                src = ""
                for (i = 1; i <= NF; i++) {
                    if ($i == "-") {
                        fst = $(i + 1)
                        src = $(i + 2)
                        break
                    }
                }
                printf "%s\t%s", fst, src
            }')
            cv_fs=${cv_parsed%%	*}
            cv_raw=${cv_parsed#*	}
            cv_src=$(quc_unescape_field "$cv_raw" && printf X) || cv_src=
            cv_src=${cv_src%X}
            if "$quc_bin_grep" -F -x -e "$cv_mp" -- "$seen" >/dev/null 2>&1; then
                continue
            fi
            printf '%s\n' "$cv_mp" >> "$seen" || true
            cv_disk=$(quc_disk_name "$cv_src" 0) || cv_disk=
            cv_rem=unknown
            if [ -n "$cv_disk" ] && [ -f "/sys/class/block/$cv_disk/removable" ]; then
                cv_flag=$("$quc_bin_awk" 'NR == 1 { print; exit }' "/sys/class/block/$cv_disk/removable" 2>/dev/null || true)
                case $cv_flag in
                    1) cv_rem=yes ;;
                    0) cv_rem=no ;;
                esac
            fi
            if ! quc_volume_candidate "$cv_src" "$cv_fs" "$cv_mp" "$cv_rem"; then
                case $cv_src in
                    /dev/*) quc_vol_skipped=$(quc_add_bytes "$quc_vol_skipped" 1) ;;
                esac
                continue
            fi
            cv_dev=$(quc_dev_of "$cv_mp" || true)
            if [ -n "$root_dev" ] && [ -n "$cv_dev" ] && [ "$cv_dev" = "$root_dev" ]; then
                quc_vol_skipped=$(quc_add_bytes "$quc_vol_skipped" 1)
                continue
            fi
            cv_label=$(quc_volume_label "$cv_src" "$cv_mp" || true)
            cv_bytes=$(quc_fs_bytes "$cv_mp" || printf '0')
            cv_free=$(quc_free_bytes "$cv_mp" || printf '')
            printf '%s\t%s\t%s\t%s\t%s\tyes\t%s\n' \
                "$(quc_hex_encode "$cv_mp")" \
                "$cv_fs" \
                "$(quc_hex_encode "$cv_src")" \
                "$(quc_hex_encode "$cv_label")" \
                "$cv_bytes" \
                "$cv_free" >> "$out" || return 1
            quc_vol_shown=$(quc_add_bytes "$quc_vol_shown" 1)
        done < /proc/self/mountinfo
    fi
    if [ -n "${QUC_FAKE_VOLUMES:-}" ] && [ -f "$QUC_FAKE_VOLUMES" ] && [ ! -L "$QUC_FAKE_VOLUMES" ]; then
        while IFS= read -r fv_line || [ -n "$fv_line" ]; do
            [ -n "$fv_line" ] || continue
            fv_ok=$(printf '%s\n' "$fv_line" | "$quc_bin_awk" -F '\t' 'NF >= 6 && $6 == "yes" { print "yes"; exit }')
            [ "$fv_ok" = yes ] || continue
            printf '%s\n' "$fv_line" >> "$out" || return 1
            quc_vol_shown=$(quc_add_bytes "$quc_vol_shown" 1)
        done < "$QUC_FAKE_VOLUMES"
    fi
    "$quc_bin_rm" -f -- "$seen" 2>/dev/null || true
    return 0
}

quc_volume_fields() {
    vf_line=$1
    quc_vf_mp=
    quc_vf_fs=
    quc_vf_label=
    quc_vf_bytes=0
    quc_vf_free=
    vf_sep=$(printf '\036')
    vf_parsed=$(printf '%s\n' "$vf_line" | "$quc_bin_awk" -F '\t' -v sep="$vf_sep" 'NR == 1 {
        printf "%s%s%s%s%s%s%s%s%s", $1, sep, $2, sep, $4, sep, $5, sep, $7
        exit
    }')
    quc_vf_mp_hex=${vf_parsed%%"$vf_sep"*}
    vf_rest=${vf_parsed#*"$vf_sep"}
    quc_vf_fs=${vf_rest%%"$vf_sep"*}
    vf_rest=${vf_rest#*"$vf_sep"}
    quc_vf_label_hex=${vf_rest%%"$vf_sep"*}
    vf_rest=${vf_rest#*"$vf_sep"}
    quc_vf_bytes=${vf_rest%%"$vf_sep"*}
    quc_vf_free=${vf_rest#*"$vf_sep"}
    quc_decode_hex_var "$quc_vf_mp_hex" || return 1
    quc_vf_mp=$quc_decoded
    quc_vf_label=
    if [ -n "$quc_vf_label_hex" ] && quc_decode_hex_var "$quc_vf_label_hex"; then
        quc_vf_label=$quc_decoded
    fi
    if [ -z "$quc_vf_label" ]; then
        quc_vf_label='без метки'
    fi
    return 0
}

quc_print_volumes() {
    pv_file=$1
    pv_n=0
    while IFS= read -r pv_line || [ -n "$pv_line" ]; do
        [ -n "$pv_line" ] || continue
        pv_n=$(quc_add_bytes "$pv_n" 1)
        quc_volume_fields "$pv_line" || continue
        printf '%s. %s   USB · %s' "$pv_n" "$(quc_display_path "$quc_vf_label")" "$(quc_human_bytes "$quc_vf_bytes")"
        if [ -n "$quc_vf_free" ]; then
            printf ' · свободно %s' "$(quc_human_bytes "$quc_vf_free")"
        fi
        if [ -n "$quc_vf_fs" ]; then
            printf ' · %s' "$(quc_display_path "$quc_vf_fs")"
        fi
        printf '\n'
        printf '   %s\n' "$(quc_display_path "$quc_vf_mp")"
    done < "$pv_file"
}

quc_volume_pick() {
    vp_choice=$1
    vp_file=$2
    case $vp_choice in
        /*)
            printf '%s\n' "$vp_choice"
            return 0
            ;;
    esac
    quc_is_uint "$vp_choice" || return 1
    if [ "$vp_choice" = 0 ]; then
        return 1
    fi
    vp_hex=$("$quc_bin_awk" -F '\t' -v n="$vp_choice" 'NR == n { print $1; exit }' "$vp_file")
    [ -n "$vp_hex" ] || return 1
    quc_decode_hex_var "$vp_hex" || return 1
    printf '%s\n' "$quc_decoded"
}

quc_fs_caution() {
    case ${1:-} in
        ext2|ext3|ext4|btrfs|xfs|tmpfs|f2fs|'')
            return 0
            ;;
        vfat|msdos|fat|msdosfs)
            printf '%s\n' "FAT: имена и файлы больше 4 ГиБ могут быть пропущены. Полный обход имён до подтверждения запуска не делается."
            ;;
        exfat)
            printf '%s\n' "exFAT: часть имён может не сохраниться. Полный обход имён до подтверждения запуска не делается."
            ;;
        ntfs|ntfs3|fuseblk)
            printf '%s\n' "NTFS: права Unix не сохраняются. Это не запрет запуска."
            ;;
        *)
            printf 'Файловая система непроверенного типа (%s). Обычные файлы возможны. Особые ограничения не проверялись.\n' "$(quc_display_path "$1")"
            ;;
    esac
}

quc_note_pending_job() {
    pn_id=$(quc_current_id || true)
    [ -n "$pn_id" ] || return 0
    pn_file=$quc_jobs_dir/$pn_id/state
    [ -f "$pn_file" ] || return 0
    pn_st=$("$quc_bin_awk" -F= '$1 == "copy_status" { print substr($0, index($0, "=") + 1); exit }' "$pn_file")
    case $pn_st in
        ''|SUCCESS) return 0 ;;
        RUNNING|STARTING)
            if quc_read_owner && quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$quc_jobs_dir/$quc_owner_job"; then
                quc_add_problem "уже выполняется другое задание"
                quc_preflight_ok=0
                return 0
            fi
            quc_add_note "предыдущее задание $pn_id не завершено. Меню его не продолжает."
            ;;
        *)
            quc_add_note "есть незавершённое задание $pn_id. Меню его не продолжает. Продолжение: resume."
            ;;
    esac
}

quc_label_for_path() {
    lp_path=$1
    lp_file=$2
    lp_n=0
    quc_lp_label='без метки'
    quc_lp_n=
    while IFS= read -r lp_line || [ -n "$lp_line" ]; do
        [ -n "$lp_line" ] || continue
        lp_n=$(quc_add_bytes "$lp_n" 1)
        quc_volume_fields "$lp_line" || continue
        if [ "$quc_vf_mp" = "$lp_path" ]; then
            quc_lp_label=$quc_vf_label
            quc_lp_n=$lp_n
            return 0
        fi
    done < "$lp_file"
    return 0
}

quc_menu_close() {
    if [ -n "${quc_menu_file:-}" ]; then
        "$quc_bin_rm" -f -- "$quc_menu_file" "$quc_menu_file.seen" 2>/dev/null || true
    fi
}

quc_menu_cancel() {
    quc_menu_close
    printf '%s\n' "Копирование не запущено."
    printf '%s\n' "error_code=E_OK"
}

quc_menu_read() {
    quc_menu_answer=
    if ! IFS= read -r quc_menu_answer; then
        quc_menu_answer=
        return 1
    fi
    quc_menu_answer=$(printf '%s' "$quc_menu_answer" | "$quc_bin_tr" -d '\r')
    return 0
}

quc_menu_show_list() {
    printf '%s\n' "Quiet USB Copy"
    printf '\n'
    if [ "${quc_vol_shown:-0}" = 0 ]; then
        printf '%s\n' "Съёмных накопителей не найдено."
        printf '%s\n' "Введите два абсолютных пути."
    else
        printf '%s\n' "Носители"
        quc_print_volumes "$quc_menu_file"
        if quc_cmp_num "${quc_vol_skipped:-0}" 0 gt; then
            printf 'Не показаны блочные разделы: %s. В список входят только накопители с признаком съёмности 1.\n' "$quc_vol_skipped"
        fi
    fi
    printf '\n'
    printf '%s\n' "Направление само не выбирается."
    printf '%s\n' "Режим: бережный"
    printf '%s\n' "[0] Отмена"
    printf '%s\n' "Источник — номер или путь:"
}

quc_print_side() {
    ps_role=$1
    ps_path=$2
    ps_fs=$3
    ps_bytes=$4
    quc_label_for_path "$ps_path" "$quc_menu_file"
    printf '%s\n' "$ps_role"
    if [ -n "$quc_lp_n" ]; then
        printf '%s. %s   USB' "$quc_lp_n" "$(quc_display_path "$quc_lp_label")"
    else
        printf '%s' "$(quc_display_path "$quc_lp_label")"
    fi
    if [ -n "$ps_bytes" ]; then
        printf ' · %s' "$(quc_human_bytes "$ps_bytes")"
    fi
    ps_free=
    if [ -d "$ps_path" ]; then
        ps_free=$(quc_free_bytes "$ps_path" 2>/dev/null || true)
    fi
    if [ -n "$ps_free" ]; then
        printf ' · свободно %s' "$(quc_human_bytes "$ps_free")"
    fi
    if [ -n "$ps_fs" ]; then
        printf ' · %s' "$(quc_display_path "$ps_fs")"
    fi
    printf '\n'
    printf '   %s\n' "$(quc_display_path "$ps_path")"
}

quc_menu_show_confirm() {
    printf '\n%s\n' "Quiet USB Copy"
    printf '\n'
    quc_print_side "ИСТОЧНИК" "$quc_menu_src" "${quc_source_fs:-}" "${quc_source_fssize:-}"
    printf '\n'
    quc_print_side "НАЗНАЧЕНИЕ" "$quc_menu_dst" "${quc_target_fs:-}" "${quc_target_fssize:-}"
    printf '\n'
    quc_label_for_path "$quc_menu_src" "$quc_menu_file"
    qm_src_name=$(quc_display_path "$quc_lp_label")
    quc_label_for_path "$quc_menu_dst" "$quc_menu_file"
    qm_dst_name=$(quc_display_path "$quc_lp_label")
    printf '%s → %s\n' "$qm_src_name" "$qm_dst_name"
    printf '\n'
    if [ "$quc_preflight_ok" = 1 ]; then
        printf '%s\n' "Проверка: готово"
    else
        printf '%s\n' "Проверка: запускать нельзя"
    fi
    if [ -n "$quc_problems" ]; then
        printf '%s\n' "$quc_problems" | while IFS= read -r qm_line || [ -n "$qm_line" ]; do
            [ -n "$qm_line" ] || continue
            printf 'Причина: %s\n' "$qm_line"
        done
    fi
    if [ -n "$quc_notes" ]; then
        printf '%s\n' "$quc_notes" | while IFS= read -r qm_line || [ -n "$qm_line" ]; do
            [ -n "$qm_line" ] || continue
            printf 'Замечание: %s\n' "$qm_line"
        done
    fi
    printf '%s\n' "Режим: бережный"
    printf '\n'
    if [ "$quc_preflight_ok" = 1 ]; then
        printf '%s\n' "[1] Начать"
    fi
    printf '%s\n' "[2] Изменить выбор"
    printf '%s\n' "[0] Отмена"
    printf '%s\n' "Выбор:"
}

quc_cmd_interactive() {
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        printf '%s\n' "Выбор накопителей открывается только в терминале без аргументов." >&2
        printf '%s\n' "Команды: sh quiet_usb_copy.sh help" >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    if ! quc_prepare_state; then
        printf '%s\n' "Служебный каталог недоступен." >&2
        printf '%s\n' "error_code=E_ENV" >&2
        return 70
    fi
    if quc_runtime_prepare; then
        quc_menu_file=$quc_runtime_base/menu.$$
    else
        quc_menu_file=$quc_state_dir/menu.$$
    fi
    while :; do
        if ! quc_collect_volumes "$quc_menu_file"; then
            quc_menu_close
            printf '%s\n' "Не удалось прочитать список носителей." >&2
            printf '%s\n' "error_code=E_FAIL" >&2
            return 1
        fi
        quc_menu_show_list
        if ! quc_menu_read; then
            quc_menu_cancel
            return 0
        fi
        case $quc_menu_answer in
            0)
                quc_menu_cancel
                return 0
                ;;
        esac
        quc_menu_src=$(quc_volume_pick "$quc_menu_answer" "$quc_menu_file") || {
            printf '%s\n' "Источник не выбран."
            continue
        }
        printf '%s\n' "Назначение — номер или путь:"
        if ! quc_menu_read; then
            quc_menu_cancel
            return 0
        fi
        case $quc_menu_answer in
            0)
                quc_menu_cancel
                return 0
                ;;
        esac
        quc_menu_dst=$(quc_volume_pick "$quc_menu_answer" "$quc_menu_file") || {
            printf '%s\n' "Назначение не выбрано."
            continue
        }
        quc_source_fs=
        quc_target_fs=
        quc_source_fssize=
        quc_target_fssize=
        if quc_validate_pair "$quc_menu_src" "$quc_menu_dst" fresh; then
            quc_preflight_ok=1
        else
            quc_preflight_ok=0
        fi
        if [ -n "${quc_target_fs:-}" ]; then
            qm_caut=$(quc_fs_caution "$quc_target_fs" || true)
            if [ -n "$qm_caut" ]; then
                quc_add_note "$qm_caut"
            fi
        fi
        quc_note_pending_job
        while :; do
            quc_menu_show_confirm
            if ! quc_menu_read; then
                quc_menu_cancel
                return 0
            fi
            case $quc_menu_answer in
                0)
                    quc_menu_cancel
                    return 0
                    ;;
                2) break ;;
                1)
                    if [ "$quc_preflight_ok" != 1 ]; then
                        printf '%s\n' "Запуск запрещён."
                        continue
                    fi
                    if quc_read_owner && quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$quc_jobs_dir/$quc_owner_job"; then
                        quc_add_problem "уже выполняется другое задание"
                        quc_preflight_ok=0
                        printf '%s\n' "Запуск запрещён."
                        continue
                    fi
                    printf '%s\n' "Копирование запущено в фоне. Статус по запросу: sh quiet_usb_copy.sh status"
                    quc_menu_close
                    quc_verify_during=0
                    quc_profile=gentle
                    quc_launch_prepared
                    ;;
                *)
                    printf '%s\n' "Нужно 1, 2 или 0."
                    ;;
            esac
        done
    done
}
quc_make_probe_dir() {
    if quc_runtime_prepare; then
        pd=$quc_runtime_base/probe.$$
    elif [ -n "${quc_state_dir:-}" ] && [ -d "$quc_state_dir" ] && [ ! -L "$quc_state_dir" ]; then
        pd=$quc_state_dir/probe.$$
    else
        return 1
    fi
    if [ -e "$pd" ] || [ -L "$pd" ]; then
        return 1
    fi
    "$quc_bin_mkdir" -p -- "$pd" 2>/dev/null || return 1
    "$quc_bin_chmod" 700 -- "$pd" 2>/dev/null || return 1
    printf '%s\n' "$pd"
}

quc_remove_probe_dir() {
    pd=$1
    [ -n "$pd" ] || return 1
    if [ -L "$pd" ] || [ ! -d "$pd" ]; then
        return 1
    fi
    ok=0
    if [ -n "${quc_runtime_base:-}" ]; then
        case $pd in
            "$quc_runtime_base"/probe.*) ok=1 ;;
        esac
    fi
    if [ -n "${quc_state_dir:-}" ]; then
        case $pd in
            "$quc_state_dir"/probe.*) ok=1 ;;
        esac
    fi
    [ "$ok" = 1 ] || return 1
    "$quc_bin_rm" -rf -- "$pd"
}

quc_cmd_doctor() {
    if [ "$#" -ne 0 ]; then
        printf '%s\n' "doctor не принимает аргументы." >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    printf 'quiet-usb-copy %s\n' "$QUC_VERSION"
    printf 'build %s\n' "$QUC_BUILD"
    printf '%s\n' "Обязательные программы: найдены."
    if "$quc_bin_find" /proc/self -xdev -print0 -quit >/dev/null 2>&1; then
        printf '%s\n' "find -print0: да"
    else
        printf '%s\n' "find -print0: нет"
    fi
    printf 'awk: %s\n' "$quc_bin_awk"
    if [ -n "${quc_bin_sync:-}" ]; then
        printf 'sync: %s\n' "$quc_bin_sync"
    else
        printf '%s\n' "sync: нет в PATH"
    fi
    if [ -n "${quc_bin_findmnt:-}" ]; then
        printf '%s\n' "findmnt: да, необязательная программа"
    else
        printf '%s\n' "findmnt: нет, для меток используется /dev/disk/by-label"
    fi
    sync_mode=none
    if quc_prepare_state; then
        probe=$(quc_make_probe_dir) || probe=
        if [ -n "$probe" ]; then
            saved_job=${quc_job_dir:-}
            saved_run=${quc_run_dir:-}
            quc_job_dir=$probe
            quc_run_dir=$probe
            quc_probe_copy_tools || true
            sync_mode=${quc_sync_mode:-none}
            quc_job_dir=$saved_job
            quc_run_dir=$saved_run
            quc_remove_probe_dir "$probe" || true
        fi
        printf 'sync-проба: %s\n' "$sync_mode"
        if [ -n "${quc_runtime_base:-}" ]; then
            printf 'Временный каталог: %s\n' "$quc_runtime_base"
        else
            printf '%s\n' "Временный каталог: запасной внутри каталога состояния, XDG_RUNTIME_DIR не использован."
        fi
        printf 'Каталог состояния: %s\n' "$quc_state_dir"
    else
        printf '%s\n' "Служебный каталог недоступен."
        printf '%s\n' "error_code=E_ENV"
        return 70
    fi
    printf '%s\n' "Профиль gentle: nice 19 и ionice best-effort 7 только у своего процесса. Задержки флешки этим не отменяются."
    printf '%s\n' "Меню не обходит дерево файлов, пока не выбраны оба пути."
    printf '%s\n' "Уведомления других программ не отключаются. Своих окон и звуков нет."
    printf '%s\n' "Коды выхода: 0 принята, 1 отказ или сбой, 2 аргументы, 70 среда."
    printf '%s\n' "error_code: E_OK E_FAIL E_USAGE E_ENV E_REJECT E_NOJOB."
    printf '%s\n' "Этот запуск не подтверждает дистрибутив. Полный набор этой копии выполнялся на Pop!_OS 24.04. РЕД ОС, Fedora и RHEL не отмечены как проверенные."
    printf '%s\n' "error_code=E_OK"
    return 0
}

quc_cmd_selftest() {
    if [ "$#" -ne 0 ]; then
        printf '%s\n' "selftest не принимает аргументы." >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    st_bad=0
    got=$(quc_decide_copy_status '' 1 0 0 0 0)
    [ "$got" = SUCCESS ] || st_bad=$(quc_add_bytes "$st_bad" 1)
    sample='a b'
    enc=$(quc_hex_encode "$sample")
    if ! quc_decode_hex_var "$enc" || [ "$quc_decoded" != "$sample" ]; then
        st_bad=$(quc_add_bytes "$st_bad" 1)
    fi
    quc_volume_candidate /dev/sdb1 vfat /media/DISK yes || st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_volume_candidate /dev/weird-name1 exfat /media/ODD yes || st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_volume_candidate tmpfs tmpfs /media/DISK yes && st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_volume_candidate /dev/sda1 ext4 /home yes && st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_volume_candidate /dev/nvme0n1p1 ext4 /mnt/data no && st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_volume_candidate /dev/mmcblk0p1 vfat /media/ODD unknown && st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_answer_is_yes "да" || st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_answer_is_yes "yes" && st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_default_job_vars
    quc_copy_status=SUCCESS
    quc_verify_status=size
    quc_sync_status=command_ok
    quc_files_done=1
    quc_files_total=1
    quc_profile=gentle
    text=$(quc_print_human)
    case $text in
        *'Копирование завершено.'*) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $text in
        *'Для извлечения'*) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $text in
        *'можно извлекать'*) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $text in
        *'copy_status='*) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    quc_copy_status=PARTIAL
    quc_error='ошибка чтения'
    text=$(quc_print_human)
    case $text in
        *'Копирование завершено частично.'*) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $text in
        *'Копирование завершено.'*) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $text in
        *'Причина: ошибка чтения'*) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $text in
        *'Подробнее: report'*) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    caut=$(quc_fs_caution mysteryfs || true)
    case $caut in
        *'непроверен'*) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $caut in
        *'запускать нельзя'*) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    caut=$(quc_fs_caution ext4 || true)
    if [ -n "$caut" ]; then
        st_bad=$(quc_add_bytes "$st_bad" 1)
    fi
    msg=$(quc_disk_pair_problem tmpfs tmpfs || true)
    if [ -n "$msg" ]; then
        st_bad=$(quc_add_bytes "$st_bad" 1)
    fi
    if [ "$st_bad" != 0 ]; then
        printf 'selftest: ошибки %s\n' "$st_bad" >&2
        printf '%s\n' "error_code=E_FAIL" >&2
        return 1
    fi
    printf '%s\n' "selftest: готово"
    printf '%s\n' "error_code=E_OK"
    return 0
}

quc_cleanup_one_tree() {
    root=$1
    [ -n "$root" ] || return 0
    [ -d "$root" ] || return 0
    [ -L "$root" ] && return 0
    cl_list=$quc_state_dir/cleanup.list.$$
    : > "$cl_list" || return 1
    "$quc_bin_find" "$root" -mindepth 1 -maxdepth 1 -type d -print > "$cl_list" 2>/dev/null || true
    while IFS= read -r cl_dir || [ -n "$cl_dir" ]; do
        [ -n "$cl_dir" ] || continue
        case $cl_dir in
            "$root"/*) ;;
            *) continue ;;
        esac
        if [ -L "$cl_dir" ] || [ ! -d "$cl_dir" ]; then
            continue
        fi
        cl_id=$("$quc_bin_basename" -- "$cl_dir")
        if [ -d "$quc_jobs_dir/$cl_id" ]; then
            continue
        fi
        quc_job_id=$cl_id
        quc_rm_owned_dir "$cl_dir" || true
    done < "$cl_list"
    "$quc_bin_rm" -f -- "$cl_list" 2>/dev/null || true
}

quc_cmd_cleanup() {
    quc_cleanup_dry=0
    if [ "$#" -eq 1 ] && [ "$1" = "--dry-run" ]; then
        quc_cleanup_dry=1
    elif [ "$#" -ne 0 ]; then
        printf '%s\n' "cleanup принимает только --dry-run и удаляет только служебные данные Quiet USB Copy." >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    if ! quc_prepare_state; then
        printf '%s\n' "Служебный каталог недоступен." >&2
        printf '%s\n' "error_code=E_ENV" >&2
        return 70
    fi
    kept=0
    removed=0
    cl_list=$quc_state_dir/cleanup.list.$$
    : > "$cl_list" || return 1
    "$quc_bin_find" "$quc_jobs_dir" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print > "$cl_list" 2>/dev/null || true
    while IFS= read -r cl_dir || [ -n "$cl_dir" ]; do
        [ -n "$cl_dir" ] || continue
        case $cl_dir in
            "$quc_jobs_dir"/*) ;;
            *) continue ;;
        esac
        cl_id=$("$quc_bin_basename" -- "$cl_dir")
        if [ -L "$cl_dir" ]; then
            printf 'Можно удалить: %s\n' "$cl_id"
            if [ "$quc_cleanup_dry" != 1 ]; then
                "$quc_bin_rm" -f -- "$cl_dir" 2>/dev/null || true
            fi
            removed=$(quc_add_bytes "$removed" 1)
            continue
        fi
        if ! quc_job_id_safe "$cl_id" || ! quc_load_state "$cl_dir/state"; then
            printf 'Оставлено: %s\n' "$cl_id"
            kept=$(quc_add_bytes "$kept" 1)
            continue
        fi
        case $quc_copy_status in
            RUNNING|STARTING)
                printf 'Оставлено выполняющееся задание: %s\n' "$cl_id"
                kept=$(quc_add_bytes "$kept" 1)
                continue
                ;;
        esac
        printf 'Можно удалить: %s\n' "$cl_id"
        if [ "$quc_cleanup_dry" = 1 ]; then
            removed=$(quc_add_bytes "$removed" 1)
            continue
        fi
        quc_job_id=$cl_id
        quc_job_dir=$cl_dir
        quc_open_run_dir
        quc_drop_scratch
        "$quc_bin_rm" -rf -- "$cl_dir" 2>/dev/null || true
        if [ -d "$cl_dir" ]; then
            printf 'Не удалось удалить: %s\n' "$cl_id" >&2
            kept=$(quc_add_bytes "$kept" 1)
        else
            removed=$(quc_add_bytes "$removed" 1)
        fi
    done < "$cl_list"
    "$quc_bin_rm" -f -- "$cl_list" 2>/dev/null || true
    if [ "$quc_cleanup_dry" != 1 ]; then
        quc_runtime_prepare || true
        if [ -n "${quc_runtime_base:-}" ]; then
            quc_cleanup_one_tree "$quc_runtime_base/jobs"
            menu_root=$quc_runtime_base
            if [ -d "$menu_root" ] && [ ! -L "$menu_root" ]; then
                "$quc_bin_find" "$menu_root" -mindepth 1 -maxdepth 1 -type f -name 'menu.*' -print 2>/dev/null | while IFS= read -r menu_file || [ -n "$menu_file" ]; do
                    case $menu_file in
                        "$menu_root"/menu.*) "$quc_bin_rm" -f -- "$menu_file" 2>/dev/null || true ;;
                    esac
                done
            fi
        fi
        if [ -d "$quc_state_dir/run/jobs" ]; then
            quc_cleanup_one_tree "$quc_state_dir/run/jobs"
        fi
        if [ -d "$quc_state_dir" ] && [ ! -L "$quc_state_dir" ]; then
            "$quc_bin_find" "$quc_state_dir" -mindepth 1 -maxdepth 1 -type f -name 'menu.*' -print 2>/dev/null | while IFS= read -r menu_file || [ -n "$menu_file" ]; do
                case $menu_file in
                    "$quc_state_dir"/menu.*) "$quc_bin_rm" -f -- "$menu_file" 2>/dev/null || true ;;
                esac
            done
        fi
        if [ -f "$quc_current" ]; then
            cur=$(quc_current_id || true)
            if [ -z "$cur" ] || [ ! -d "$quc_jobs_dir/$cur" ]; then
                "$quc_bin_rm" -f -- "$quc_current" 2>/dev/null || true
            fi
        fi
        if [ "$kept" = 0 ]; then
            if quc_read_owner && quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$quc_jobs_dir/$quc_owner_job"; then
                printf '%s\n' "Блокировка выполняющегося задания не тронута."
            else
                "$quc_bin_rm" -f -- "$quc_last_error" "$quc_owner" 2>/dev/null || true
                if [ -d "$quc_state_dir/lock.d" ] && [ ! -L "$quc_state_dir/lock.d" ]; then
                    "$quc_bin_rm" -rf -- "$quc_state_dir/lock.d" 2>/dev/null || true
                fi
            fi
        fi
    fi
    if [ "$quc_cleanup_dry" = 1 ]; then
        printf '%s\n' "Удаление не выполнялось."
        printf 'Будет удалено служебных заданий: %s\n' "$removed"
    else
        printf 'Удалено служебных заданий: %s\n' "$removed"
    fi
    printf 'Оставлено незавершённых: %s\n' "$kept"
    printf '%s\n' "error_code=E_OK"
    return 0
}

quc_main() {
    set -f
    umask 077
    export LC_ALL=C
    case ${1:-} in
        version|--version|-V)
            quc_cmd_version
            return 0
            ;;
        help|-h|--help)
            quc_cmd_help
            return 0
            ;;
    esac
    if ! quc_resolve_tools; then
        if [ "${1:-}" = start ] || [ "${1:-}" = resume ] || [ "${1:-}" = _worker ]; then
            exit 70
        fi
        printf 'Не найдены обязательные программы:%s\n' "$quc_missing" >&2
        exit 70
    fi
    quc_self=$(quc_self_path) || exit 70
    if [ "$#" -eq 0 ]; then
        quc_cmd_interactive
        return $?
    fi
    cmd=$1
    shift
    case $cmd in
        start|check|status|report|stop|resume|verify|help|-h|--help|doctor|selftest|cleanup|version|_worker) ;;
        *)
            if [ "$#" -eq 1 ]; then
                set -- "$cmd" "$1"
                cmd=start
            else
                quc_cmd_help >&2
                exit 2
            fi
            ;;
    esac
    case $cmd in
        help|-h|--help) quc_cmd_help ;;
        check) quc_cmd_check "$@" ;;
        start) quc_cmd_start "$@" ;;
        status) quc_cmd_status "$@" ;;
        report) quc_cmd_report "$@" ;;
        stop) quc_cmd_stop "$@" ;;
        resume) quc_cmd_resume "$@" ;;
        verify) quc_cmd_verify "$@" ;;
        doctor) quc_cmd_doctor "$@" ;;
        selftest) quc_cmd_selftest "$@" ;;
        cleanup) quc_cmd_cleanup "$@" ;;
        version) quc_cmd_version "$@" ;;
        _worker) quc_cmd_worker "$@" ;;
    esac
}

if [ "${QUC_SOURCE_ONLY:-}" = 1 ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

quc_main "$@"

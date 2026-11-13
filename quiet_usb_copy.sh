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
# eject_status отдельно от copy_status. Успех копирования не означает,
# что назначение отключено. Автоотключение касается только назначения.

# Разделы этого файла, по месту, без перестановки функций:
#   Общие настройки и константы
#   Вспомогательные функции
#   Служебные каталоги
#   Состояние и восстановление
#   Устройства и файловые системы
#   Предварительная проверка
#   Безопасное копирование
#   Локальная копия STAGED
#   Автоматическое отключение
#   Пользовательский интерфейс
#   Диагностика и точка входа

umask 077

# --- Общие настройки и константы ---

QUC_VERSION=0.4.0-rc.10
QUC_BUILD=20261112.3
QUC_PARTIAL_PREFIX=.quc-partial.
QUC_MAX_ATTEMPTS=3
QUC_FAT_MAX=4294967295

if [ "${QUC_SOURCE_ONLY:-}" != 1 ]; then
    IFS=' 	
'
fi

# --- Вспомогательные функции ---

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

# Печатный ASCII (пробел … '~') кодируется одним awk. Остальные байты,
# включая перевод строки, табуляцию и UTF-8, идут прежним путём od.
quc_hex_encode() {
    case $1 in
        '') return 0 ;;
        # Пробел внутри класса в кавычках: иначе dash режет шаблон на два слова.
        *[!" "-~]*)
            printf '%s' "$1" | LC_ALL=C od -An -tx1 | LC_ALL=C tr -d '[:space:]' | LC_ALL=C tr 'A-F' 'a-f'
            return
            ;;
    esac
    hx_awk=${quc_bin_awk:-awk}
    QUC_HEX=$1 "$hx_awk" 'BEGIN {
        s = ENVIRON["QUC_HEX"]
        t = " !\"#$%&'\''()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"
        n = length(s)
        for (i = 1; i <= n; i++) {
            v = index(t, substr(s, i, 1))
            if (v < 1) exit 1
            printf "%02x", 31 + v
        }
    }'
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

# Ведущие нули для dash — восьмеричные. Снимаем их до арифметики.
# Нечисло уходит в awk: сравнение 2^32 остаётся точным.
quc_int_strip() {
    quc_int_out=$1
    quc_int_neg=0
    case $quc_int_out in
        -*)
            quc_int_neg=1
            quc_int_out=${quc_int_out#-}
            ;;
    esac
    case $quc_int_out in
        ''|*[!0-9]*) return 1 ;;
    esac
    while :; do
        case $quc_int_out in
            0?*) quc_int_out=${quc_int_out#0} ;;
            *) break ;;
        esac
    done
    if [ -z "$quc_int_out" ]; then
        quc_int_out=0
        quc_int_neg=0
    fi
    if [ "$quc_int_neg" = 1 ]; then
        quc_int_out=-$quc_int_out
    fi
    return 0
}

quc_add_bytes_awk() {
    LC_ALL=C awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN { printf "%.0f", (a + 0) + (b + 0) }'
}

quc_cmp_num_awk() {
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

quc_add_bytes() {
    if quc_int_strip "${1:-0}"; then
        ab_a=$quc_int_out
        if quc_int_strip "${2:-0}"; then
            printf '%s\n' "$((ab_a + quc_int_out))"
            return 0
        fi
    fi
    quc_add_bytes_awk "$1" "$2"
}

quc_cmp_num() {
    if quc_int_strip "${1:-0}"; then
        cm_a=$quc_int_out
        if quc_int_strip "${2:-0}"; then
            case $3 in
                ge) [ "$cm_a" -ge "$quc_int_out" ]; return $? ;;
                gt) [ "$cm_a" -gt "$quc_int_out" ]; return $? ;;
                lt) [ "$cm_a" -lt "$quc_int_out" ]; return $? ;;
                le) [ "$cm_a" -le "$quc_int_out" ]; return $? ;;
                eq) [ "$cm_a" -eq "$quc_int_out" ]; return $? ;;
                *) return 2 ;;
            esac
        fi
    fi
    quc_cmp_num_awk "$1" "$2" "$3"
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

# --- Служебные каталоги ---

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

# --- Состояние и восстановление ---

quc_default_job_vars() {
    quc_version=$QUC_VERSION
    quc_job_id=''
    quc_source=''
    quc_target=''
    quc_source_dev=''
    quc_target_dev=''
    quc_source_mntid=''
    quc_target_mntid=''
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
    quc_source_mode=direct
    quc_dest_mode=root
    quc_dest_rel=''
    quc_stage_status=none
    quc_stage_dir=''
    quc_stage_dev=''
    quc_stage_manifest=''
    quc_stage_tool=''
    quc_recovery_status=none
    quc_job_phase=CREATED
    quc_read_root=''
    quc_write_root=''
    quc_write_ino=''
    quc_publish_limited=0
    quc_publish_mode=
    quc_dest_link_probe=UNKNOWN
    quc_partial_rel_hex=
    quc_partial_ino=
    quc_partial_bytes=0
    quc_partial_visible=0
    quc_mount_mark=0
    quc_mount_secret=''
    quc_eject_policy=no
    quc_eject_status=skipped_policy
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
        stage)
            if [ "${quc_hx_stage_set:-}" = 1 ] && [ "$quc_hx_stage_raw" = "$ec_val" ]; then
                quc_hex_out=$quc_hx_stage
                return 0
            fi
            quc_hx_stage=$(quc_hex_encode "$ec_val")
            quc_hx_stage_raw=$ec_val
            quc_hx_stage_set=1
            quc_hex_out=$quc_hx_stage
            ;;
        *)
            quc_hex_out=$(quc_hex_encode "$ec_val")
            ;;
    esac
}

# Пишет состояние на внутренний диск заменой одного файла.
# Каталог задания уже выбран. Обновляет source_dependency перед записью.
# Успех: 0. Отказ: 1, предыдущий файл состояния не затирается пустым.
# eject_status лежит рядом с copy_status и не подменяет его.
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
    quc_encode_cached stage "${quc_stage_dir:-}"
    stg_hex=$quc_hex_out
    quc_compute_source_dependency
    if [ "${quc_cr_ready:-}" != 1 ]; then
        quc_cr=$(printf '\r')
        quc_cr_ready=1
    fi
    case ${quc_error:-} in
        *'
'*|*"$quc_cr"*)
            quc_error_line=$(quc_one_line "$quc_error")
            ;;
        *)
            quc_error_line=$quc_error
            ;;
    esac
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
        printf 'error=%s\n' "$quc_error_line"
        printf 'tree_changed=%s\n' "$quc_tree_changed"
        printf 'metadata_gaps=%s\n' "$quc_metadata_gaps"
        printf 'sync_unconfirmed=%s\n' "$quc_sync_unconfirmed"
        printf 'sync_status=%s\n' "$quc_sync_status"
        printf 'sync_mode=%s\n' "$quc_sync_mode"
        printf 'profile=%s\n' "${quc_profile:-gentle}"
        printf 'fatal_kind=%s\n' "$quc_fatal_kind"
        printf 'source_mntid=%s\n' "${quc_source_mntid:-}"
        printf 'target_mntid=%s\n' "${quc_target_mntid:-}"
        printf 'mount_mark=%s\n' "${quc_mount_mark:-0}"
        printf 'mount_secret=%s\n' "${quc_mount_secret:-}"
        printf 'source_mode=%s\n' "${quc_source_mode:-direct}"
        printf 'source_dependency=%s\n' "$quc_source_dependency"
        printf 'dest_mode=%s\n' "${quc_dest_mode:-root}"
        printf 'dest_rel=%s\n' "${quc_dest_rel:-}"
        printf 'stage_status=%s\n' "${quc_stage_status:-none}"
        printf 'stage_dir_hex=%s\n' "$stg_hex"
        printf 'stage_dev=%s\n' "${quc_stage_dev:-}"
        printf 'stage_manifest=%s\n' "${quc_stage_manifest:-}"
        printf 'stage_tool=%s\n' "${quc_stage_tool:-}"
        printf 'recovery_status=%s\n' "${quc_recovery_status:-none}"
        printf 'job_phase=%s\n' "${quc_job_phase:-CREATED}"
        printf 'eject_policy=%s\n' "${quc_eject_policy:-no}"
        printf 'eject_status=%s\n' "${quc_eject_status:-skipped_policy}"
        printf 'publish_mode=%s\n' "${quc_publish_mode:-}"
        printf 'dest_link_probe=%s\n' "${quc_dest_link_probe:-UNKNOWN}"
        printf 'partial_rel_hex=%s\n' "${quc_partial_rel_hex:-}"
        printf 'partial_ino=%s\n' "${quc_partial_ino:-}"
        printf 'partial_bytes=%s\n' "${quc_partial_bytes:-0}"
        printf 'partial_visible=%s\n' "${quc_partial_visible:-0}"
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
            source_mntid)
                case $val in
                    ''|*[!0-9]*) quc_source_mntid='' ;;
                    *) quc_source_mntid=$val ;;
                esac
                ;;
            target_mntid)
                case $val in
                    ''|*[!0-9]*) quc_target_mntid='' ;;
                    *) quc_target_mntid=$val ;;
                esac
                ;;
            mount_mark)
                case $val in
                    1) quc_mount_mark=1 ;;
                    *) quc_mount_mark=0 ;;
                esac
                ;;
            mount_secret) quc_mount_secret=$val ;;
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
            source_mode) quc_source_mode=$val ;;
            dest_mode) quc_dest_mode=$val ;;
            dest_rel) quc_dest_rel=$val ;;
            stage_status) quc_stage_status=$val ;;
            stage_dir_hex)
                if [ -n "$val" ]; then
                    quc_decode_hex_var "$val" || return 1
                    quc_stage_dir=$quc_decoded
                fi
                ;;
            stage_dev) quc_stage_dev=$val ;;
            stage_manifest) quc_stage_manifest=$val ;;
            stage_tool) quc_stage_tool=$val ;;
            recovery_status) quc_recovery_status=$val ;;
            job_phase) quc_job_phase=$val ;;
            eject_policy) quc_eject_policy=$val ;;
            eject_status) quc_eject_status=$val ;;
            publish_mode) quc_publish_mode=$val ;;
            dest_link_probe) quc_dest_link_probe=$val ;;
            partial_rel_hex) quc_partial_rel_hex=$val ;;
            partial_ino) quc_partial_ino=$val ;;
            partial_bytes) quc_partial_bytes=$(quc_norm_uint "$val") ;;
            partial_visible)
                case $val in
                    0|1) quc_partial_visible=$val ;;
                    *) quc_partial_visible=0 ;;
                esac
                ;;
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
    case $quc_source_mode in
        direct|staged) ;;
        *) quc_source_mode=direct ;;
    esac
    case $quc_dest_mode in
        root|separate) ;;
        *) quc_dest_mode=root ;;
    esac
    case $quc_stage_status in
        none|preparing|verifying|READY|failed|damaged) ;;
        *) quc_stage_status=none ;;
    esac
    case $quc_recovery_status in
        none|resumed|refused|uncertain) ;;
        *) quc_recovery_status=none ;;
    esac
    case $quc_job_phase in
        CREATED|PREFLIGHT|STAGING|STAGE_VERIFY|READY|TRANSFER|TARGET_VERIFY|COMPLETED|FAILED|PARTIAL|CANCELLED|INTERRUPTED|UNCERTAIN) ;;
        *) quc_job_phase=CREATED ;;
    esac
    case ${quc_eject_policy:-} in
        yes|no) ;;
        *) quc_eject_policy=no ;;
    esac
    case ${quc_eject_status:-} in
        planned|unmounted|power_off|skipped_policy|unavailable|refused|unknown) ;;
        *) quc_eject_status=unknown ;;
    esac
    case ${quc_publish_mode:-} in
        link|exclusive) ;;
        *) quc_publish_mode= ;;
    esac
    case ${quc_dest_link_probe:-} in
        link|exclusive|unsupported|UNKNOWN) ;;
        *) quc_dest_link_probe=UNKNOWN ;;
    esac
    case ${quc_partial_rel_hex:-} in
        ''|*[!0-9A-Fa-f]*) quc_partial_rel_hex= ;;
    esac
    case ${quc_partial_ino:-} in
        ''|*[!0-9]*) quc_partial_ino= ;;
    esac
    quc_partial_bytes=$(quc_norm_uint "${quc_partial_bytes:-0}")
    case ${quc_partial_visible:-} in
        0|1) ;;
        *) quc_partial_visible=0 ;;
    esac
    case $quc_dest_rel in
        ''|*[!A-Za-z0-9._-]*) quc_dest_rel='' ;;
    esac
    if ! quc_mount_secret_ok; then
        quc_mount_secret=''
    fi
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

# Один awk на запрос. Путь передаётся префиксом команды: awk -v раскрывает
# обратные косые черты. Последнее совпадение побеждает. Номер — первое поле,
# не major:minor. Байт 0x1c только отделяет хвост от подстановки команды.
# --- Устройства и файловые системы ---

quc_mountinfo_lookup() {
    mi_path=$1
    quc_mi_fstype=''
    quc_mi_source=''
    quc_mi_id=''
    if [ ! -r /proc/self/mountinfo ]; then
        return 1
    fi
    mi_parsed=$(QUC_MI_PATH=$mi_path "$quc_bin_awk" '
        function unesc(s,    out, i, n, c, o, v) {
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
            return out
        }
        BEGIN { want = ENVIRON["QUC_MI_PATH"]; found = 0 }
        {
            if (unesc($5) != want) next
            fst = ""
            src = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "-") {
                    fst = $(i + 1)
                    src = $(i + 2)
                    break
                }
            }
            if (fst == "" || src == "") next
            hit_fst = fst
            hit_src = unesc(src)
            hit_id = $1
            found = 1
        }
        END {
            if (!found) exit 1
            printf "%s\n%s\n%s", hit_fst, hit_id, hit_src
            printf "\034"
        }
    ' /proc/self/mountinfo) || return 1
    mi_mark=$(printf '\034')
    case $mi_parsed in
        *"$mi_mark") ;;
        *) return 1 ;;
    esac
    mi_parsed=${mi_parsed%"$mi_mark"}
    mi_nl='
'
    quc_mi_fstype=${mi_parsed%%"$mi_nl"*}
    mi_rest=${mi_parsed#*"$mi_nl"}
    quc_mi_id=${mi_rest%%"$mi_nl"*}
    quc_mi_source=${mi_rest#*"$mi_nl"}
    case $quc_mi_id in
        ''|*[!0-9]*)
            quc_mi_fstype=''
            quc_mi_source=''
            quc_mi_id=''
            return 1
            ;;
    esac
    [ -n "$quc_mi_fstype" ] || return 1
    return 0
}

# Два пути за один проход. При неудаче вызывающий повторяет два отдельных
# запроса, чтобы сообщение назвало источник или назначение.
quc_mountinfo_lookup_pair() {
    mi_path=$1
    mi_path2=$2
    quc_mi_fstype=
    quc_mi_source=
    quc_mi_id=
    quc_mi2_fstype=
    quc_mi2_source=
    quc_mi2_id=
    if [ ! -r /proc/self/mountinfo ]; then
        return 1
    fi
    if [ -z "${quc_mi_mark:-}" ]; then
        quc_mi_mark=$(printf '\034')
    fi
    mi_parsed=$(QUC_MI_PATH=$mi_path QUC_MI_PATH2=$mi_path2 "$quc_bin_awk" '
        function unesc(s,    out, i, n, c, o, v) {
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
            return out
        }
        BEGIN {
            want1 = ENVIRON["QUC_MI_PATH"]
            want2 = ENVIRON["QUC_MI_PATH2"]
            f1 = 0
            f2 = 0
        }
        {
            p = unesc($5)
            if (p != want1 && p != want2) next
            fst = ""
            src = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "-") {
                    fst = $(i + 1)
                    src = $(i + 2)
                    break
                }
            }
            if (fst == "" || src == "") next
            if (p == want1) {
                a_fst = fst
                a_src = unesc(src)
                a_id = $1
                f1 = 1
            }
            if (p == want2) {
                b_fst = fst
                b_src = unesc(src)
                b_id = $1
                f2 = 1
            }
        }
        END {
            if (!f1 || !f2) exit 1
            printf "%s\n%s\n%s", a_fst, a_id, a_src
            printf "\034"
            printf "%s\n%s\n%s", b_fst, b_id, b_src
            printf "\034"
        }
    ' /proc/self/mountinfo) || return 1
    case $mi_parsed in
        *"$quc_mi_mark"*"$quc_mi_mark") ;;
        *) return 1 ;;
    esac
    mi_parsed=${mi_parsed%"$quc_mi_mark"}
    mi_second=${mi_parsed##*"$quc_mi_mark"}
    mi_first=${mi_parsed%%"$quc_mi_mark"*}
    mi_nl='
'
    quc_mi2_fstype=${mi_first%%"$mi_nl"*}
    mi_rest=${mi_first#*"$mi_nl"}
    quc_mi2_id=${mi_rest%%"$mi_nl"*}
    quc_mi2_source=${mi_rest#*"$mi_nl"}
    quc_mi_fstype=${mi_second%%"$mi_nl"*}
    mi_rest=${mi_second#*"$mi_nl"}
    quc_mi_id=${mi_rest%%"$mi_nl"*}
    quc_mi_source=${mi_rest#*"$mi_nl"}
    case $quc_mi2_id in
        ''|*[!0-9]*) return 1 ;;
    esac
    case $quc_mi_id in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -n "$quc_mi2_fstype" ] || return 1
    [ -n "$quc_mi_fstype" ] || return 1
    [ -n "$quc_mi2_source" ] || return 1
    [ -n "$quc_mi_source" ] || return 1
    return 0
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

# Старшая тетрада младших 16 бит st_mode: 8 файл, 4 каталог, a ссылка.
quc_kind_from_mode() {
    km=$1
    quc_kind_out=
    case $km in
        ''|*[!0-9A-Fa-f]*) return 1 ;;
    esac
    while :; do
        case $km in
            [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) break ;;
            [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*) km=${km#?} ;;
            *)
                quc_kind_out=other
                return 0
                ;;
        esac
    done
    case $km in
        [8]*) quc_kind_out=regular ;;
        [4]*) quc_kind_out=dir ;;
        [aA]*) quc_kind_out='link' ;;
        [1]*) quc_kind_out=fifo ;;
        [cC]*) quc_kind_out=socket ;;
        [2]*) quc_kind_out=char ;;
        [6]*) quc_kind_out=block ;;
        *) quc_kind_out=other ;;
    esac
    return 0
}

quc_kind_of() {
    mode=$("$quc_bin_stat" -c '%f' -- "$1" 2>/dev/null) || return 1
    quc_kind_from_mode "$mode" || return 1
    printf '%s\n' "$quc_kind_out"
}

# Один stat: тип и отпечаток размера со временем. Режим прав читается позже.
quc_stat_file() {
    quc_stat_mode=
    quc_stat_fp=
    quc_stat_raw=$("$quc_bin_stat" -c '%f|%s|%y' -- "$1" 2>/dev/null) || return 1
    case $quc_stat_raw in
        *'|'*) ;;
        *) return 1 ;;
    esac
    quc_stat_mode=${quc_stat_raw%%|*}
    sf_rest=${quc_stat_raw#*|}
    case $sf_rest in
        *'|'*) ;;
        *) return 1 ;;
    esac
    sf_size=${sf_rest%%|*}
    sf_when=${sf_rest#*|}
    quc_stat_fp=$sf_size' '$sf_when
    return 0
}

# Родитель пути без внешнего процесса. Корень остаётся корнем, имени без
# косой черты соответствует точка. Вызывающий сохраняет quc_parent сразу:
# следующий вызов перезаписывает его.
quc_set_parent() {
    quc_parent=$1
    case $quc_parent in
        /) return 0 ;;
        */)
            while :; do
                case $quc_parent in
                    /) break ;;
                    */) quc_parent=${quc_parent%/} ;;
                    *) break ;;
                esac
            done
            ;;
    esac
    case $quc_parent in
        */*)
            quc_parent=${quc_parent%/*}
            if [ -z "$quc_parent" ]; then
                quc_parent=/
            fi
            ;;
        *) quc_parent=. ;;
    esac
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

# --- Предварительная проверка ---

# Сумма размеров обычных файлов одного каталога.
# Принимает путь. Печатает целое число байт и больше ничего.
# Не меняет переменные задания и не копит список путей в переменной.
# Успех: 0. Отказ: 1, в том числе если обход завершился с ошибкой.
# Частичная сумма при ошибке обхода не считается результатом.
quc_tree_bytes() {
    tb_rc_file=${TMPDIR:-/tmp}/quc-tbrc.$$
    tb_err=${TMPDIR:-/tmp}/quc-tberr.$$
    "$quc_bin_rm" -f -- "$tb_rc_file" "$tb_err" 2>/dev/null || true
    : > "$tb_err" || return 1
    tb_sum=$(
        {
            "$quc_bin_find" "$1" -xdev -type f -exec "$quc_bin_stat" -c '%s' {} +
            echo $? > "$tb_rc_file"
        } 2>"$tb_err" | "$quc_bin_awk" '{ s += $1 } END { printf "%.0f", s + 0 }'
    )
    tb_rc=1
    if [ -f "$tb_rc_file" ]; then
        tb_rc=$("$quc_bin_cat" "$tb_rc_file" 2>/dev/null || printf '1\n')
    fi
    "$quc_bin_rm" -f -- "$tb_rc_file" "$tb_err" 2>/dev/null || true
    case $tb_rc in
        0) ;;
        *) return 1 ;;
    esac
    case $tb_sum in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$tb_sum"
}

# fat — имена Windows и предел 4 ГиБ. exfat и ntfs — те же имена без этого предела.
# posix — отдельная проверка имён не нужна. other — тип не из этого списка.
# fuseblk не отличает NTFS от другой FUSE-системы: предел 4 ГиБ к нему не применяется.
quc_name_class() {
    case $1 in
        vfat|msdos|fat|msdosfs) printf '%s\n' fat ;;
        exfat) printf '%s\n' exfat ;;
        ntfs|ntfs3|fuseblk) printf '%s\n' ntfs ;;
        ext2|ext3|ext4|btrfs|xfs|tmpfs|f2fs|'') printf '%s\n' posix ;;
        *) printf '%s\n' other ;;
    esac
}

quc_fat_limit() {
    case $(quc_name_class "$1") in
        fat) printf '%s\n' "$QUC_FAT_MAX" ;;
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
    case $(quc_name_class "$fn_fs") in
        fat|exfat|ntfs) ;;
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

# Правила компонента те же, что в quc_fat_component_bad. Расхождение — дефект.
# Регистр сравнивается только для ASCII: tolower в локали C.
# Юникодное совпадение регистра этой проверкой не обещается.
# Обход не меняет источник и не создаёт имён в назначении.
# Отказ обхода запрещает старт. Проверка одного файла при копировании остаётся.
quc_scan_win_names() {
    sn_root=$1
    quc_name_bad=0
    quc_name_fold=0
    quc_name_links=0
    quc_name_sample=
    quc_name_fold_sample=
    if [ -z "$sn_root" ] || [ -L "$sn_root" ] || [ ! -d "$sn_root" ]; then
        return 1
    fi
    if [ -z "${quc_bin_find:-}" ] || [ -z "${quc_bin_awk:-}" ] || [ -z "${quc_bin_cat:-}" ]; then
        return 1
    fi
    sn_rc_file=${TMPDIR:-/tmp}/quc-nrc.$$
    "$quc_bin_rm" -f -- "$sn_rc_file" 2>/dev/null || true
    sn_line=$(
        cd -- "$sn_root" || exit 1
        {
            "$quc_bin_find" . -xdev -mindepth 1 -print0
            echo $? > "$sn_rc_file"
        } | LC_ALL=C "$quc_bin_awk" '
BEGIN { RS = "\0"; bad = 0; fold = 0; sample = ""; fsample = "" }
function badcomp(s,    n, i, c, o, u, last) {
    n = length(s)
    if (n == 0 || n > 255) return 1
    if (index(s, "\n") > 0 || index(s, "\r") > 0) return 1
    last = substr(s, n, 1)
    if (last == " " || last == ".") return 1
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c ~ /[<>:"\\|?*]/) return 1
        o = index("\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037\177", c)
        if (o > 0) return 1
    }
    u = toupper(s)
    sub(/\..*$/, "", u)
    if (u ~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/) return 1
    return 0
}
{
    p = $0
    sub(/^\.\//, "", p)
    if (p == "" || p == ".") next
    rest = p
    nbad = 0
    while (rest != "") {
        slash = index(rest, "/")
        if (slash > 0) {
            part = substr(rest, 1, slash - 1)
            rest = substr(rest, slash + 1)
        } else {
            part = rest
            rest = ""
        }
        if (part == "" || part == ".") continue
        if (badcomp(part)) nbad = 1
    }
    if (nbad == 1) {
        bad++
        if (sample == "") sample = p
    }
    key = tolower(p)
    if ((key in seen) && seen[key] != p) {
        fold++
        if (fsample == "") fsample = seen[key] " и " p
    } else if (!(key in seen)) {
        seen[key] = p
    }
}
END {
    gsub(/\n/, "?", sample)
    gsub(/\r/, "?", sample)
    gsub(/\n/, "?", fsample)
    gsub(/\r/, "?", fsample)
    print bad + 0
    print fold + 0
    print sample
    print fsample
}
'
    ) || {
        "$quc_bin_rm" -f -- "$sn_rc_file" 2>/dev/null || true
        return 1
    }
    sn_rc=1
    if [ -f "$sn_rc_file" ]; then
        sn_rc=$("$quc_bin_cat" "$sn_rc_file" 2>/dev/null || printf '1\n')
    fi
    sn_link_line=$(
        cd -- "$sn_root" || exit 1
        "$quc_bin_find" . -xdev -mindepth 1 -type l -print0 |
            LC_ALL=C "$quc_bin_awk" 'BEGIN { RS = "\0"; n = 0 } $0 != "" { n++ } END { print n + 0 }'
    ) || sn_link_line=
    "$quc_bin_rm" -f -- "$sn_rc_file" 2>/dev/null || true
    case $sn_rc in
        0) ;;
        *) return 1 ;;
    esac
    sn_bad=$(printf '%s\n' "$sn_line" | "$quc_bin_awk" 'NR == 1 { print; exit }')
    sn_fold=$(printf '%s\n' "$sn_line" | "$quc_bin_awk" 'NR == 2 { print; exit }')
    sn_sample=$(printf '%s\n' "$sn_line" | "$quc_bin_awk" 'NR == 3 { print; exit }')
    sn_fsample=$(printf '%s\n' "$sn_line" | "$quc_bin_awk" 'NR == 4 { print; exit }')
    case $sn_bad in
        ''|*[!0-9]*) return 1 ;;
    esac
    case $sn_fold in
        ''|*[!0-9]*) return 1 ;;
    esac
    case $sn_link_line in
        ''|*[!0-9]*) return 1 ;;
    esac
    quc_name_bad=$sn_bad
    quc_name_fold=$sn_fold
    quc_name_links=$sn_link_line
    quc_name_sample=$sn_sample
    quc_name_fold_sample=$sn_fsample
    return 0
}

# Вызывается только для fat, exfat и ntfs. На posix ничего не обходит.
# Несовместимое имя и совпадение регистра запрещают старт.
# Символьная ссылка на FAT и exFAT объясняется заранее и не становится SUCCESS.
quc_apply_name_policy() {
    case $(quc_name_class "${quc_target_fs:-}") in
        fat|exfat|ntfs) ;;
        *) return 0 ;;
    esac
    if ! quc_scan_win_names "$quc_source"; then
        quc_add_problem "не удалось проверить имена до запуска. Копирование не начато."
        return 0
    fi
    if quc_cmp_num "$quc_name_bad" 0 gt; then
        if [ -n "$quc_name_sample" ]; then
            quc_add_problem "имён, которые это назначение не сохранит: $quc_name_bad. Пример: $(quc_display_path "$quc_name_sample"). Копирование не начато."
        else
            quc_add_problem "имён, которые это назначение не сохранит: $quc_name_bad. Копирование не начато."
        fi
    fi
    if quc_cmp_num "$quc_name_fold" 0 gt; then
        if [ -n "$quc_name_fold_sample" ]; then
            quc_add_problem "имён, совпадающих без учёта регистра: $quc_name_fold. Пример: $(quc_display_path "$quc_name_fold_sample"). На этом назначении они станут одним именем. Копирование не начато."
        else
            quc_add_problem "имён, совпадающих без учёта регистра: $quc_name_fold. На этом назначении они станут одним именем. Копирование не начато."
        fi
    fi
    case $(quc_name_class "${quc_target_fs:-}") in
        fat|exfat)
            if quc_cmp_num "$quc_name_links" 0 gt; then
                quc_add_note "символьных ссылок: $quc_name_links. На FAT и exFAT они не сохраняются, итог не будет SUCCESS."
            fi
            ;;
    esac
    return 0
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
    hf_line=''
    hf_rc=0
    hf_digest=''
    if ! quc_hash_tool; then
        return 1
    fi
    hf_line=$("$quc_hash_bin" -- "$1" 2>/dev/null) || hf_rc=$?
    if [ "$hf_rc" -ne 0 ]; then
        return 1
    fi
    hf_digest=$(printf '%s\n' "$hf_line" | "$quc_bin_awk" 'NR == 1 && NF { print $1; exit }')
    case $hf_digest in
        ''|*[!0-9A-Fa-f]*) return 1 ;;
    esac
    printf '%s\n' "$hf_digest"
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
        quc_source_mntid=$quc_mi_id
        quc_source_uuid=$(quc_uuid_of "$path" || true)
        quc_source_fssize=$(quc_fs_bytes "$path" || printf '0')
        quc_source_disk=$(quc_disk_name "$quc_source_spec" 0) || quc_source_disk=
    else
        quc_target_fs=$quc_mi_fstype
        quc_target_spec=$quc_mi_source
        quc_target_dev=$(quc_dev_of "$path") || quc_target_dev=''
        quc_target_mntid=$quc_mi_id
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
    fi
    if [ "$mode" = fresh ] || [ "$mode" = separate ]; then
        need=$(quc_tree_bytes "$quc_source") || need=''
        if [ -z "$need" ]; then
            quc_add_problem "не удалось определить объём источника"
            need=0
        fi
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
                req = need + extra
                if (have >= req) print "yes"
                else printf "no %.0f\n", req
            }')
            case $ok in
                yes) ;;
                no\ *)
                    sp_req=${ok#no }
                    quc_add_problem "недостаточно свободного места (нужно около $(quc_human_bytes "$sp_req") с запасом, доступно $(quc_human_bytes "$have"))"
                    ;;
                *)
                    quc_add_problem "недостаточно свободного места"
                    ;;
            esac
        fi
        lim=$(quc_fat_limit "$quc_target_fs")
        if [ -n "$lim" ]; then
            too=$("$quc_bin_find" "$quc_source" -xdev -type f -exec "$quc_bin_stat" -c '%s' {} + 2>/dev/null | "$quc_bin_awk" -v lim="$lim" 'BEGIN { n = 0 } ($1 + 0) > (lim + 0) { n++ } END { print n + 0 }')
            if quc_cmp_num "$too" 0 gt; then
                quc_add_note "файлов больше предела FAT32 ($too): они не будут скопированы, итог не будет SUCCESS"
            fi
        fi
        quc_apply_name_policy
    fi
    if [ "$mode" = fresh ] || [ "$mode" = separate ]; then
        probe=$quc_target/$QUC_PARTIAL_PREFIX"write-probe.$$"
        if [ -z "$quc_problems" ]; then
            if ! quc_reserve_partial "$probe"; then
                quc_add_problem "пробная запись в назначение не удалась"
            else
                pr_ino=$("$quc_bin_stat" -c '%i' -- "$probe" 2>/dev/null || true)
                quc_drop_owned "$probe" "$pr_ino"
                if [ -e "$probe" ] || [ -L "$probe" ]; then
                    quc_add_problem "не удалось убрать пробный файл назначения"
                fi
            fi
        fi
    fi
    if [ -n "$quc_problems" ]; then
        return 1
    fi
    return 0
}

quc_source_detached() {
    [ "${quc_source_mode:-direct}" = staged ] && [ "${quc_stage_status:-none}" = READY ]
}

# Поле справочное. Чтение источника отключает только quc_source_detached.
# Значение из файла не читается: status и запись пересчитывают его заново.
quc_compute_source_dependency() {
    quc_source_dependency=unknown
    case ${quc_source_mode:-direct} in
        staged)
            case ${quc_stage_status:-none} in
                READY)
                    case ${quc_job_phase:-} in
                        STAGING|STAGE_VERIFY)
                            quc_source_dependency=required
                            ;;
                        *)
                            case ${quc_copy_status:-} in
                                UNCERTAIN) quc_source_dependency=unknown ;;
                                *) quc_source_dependency=not_required ;;
                            esac
                            ;;
                    esac
                    ;;
                preparing|verifying)
                    quc_source_dependency=required
                    ;;
                none)
                    case ${quc_copy_status:-} in
                        SUCCESS|FAILED|UNCERTAIN) quc_source_dependency=unknown ;;
                        *) quc_source_dependency=required ;;
                    esac
                    ;;
                damaged|failed)
                    quc_source_dependency=unknown
                    ;;
                *)
                    quc_source_dependency=unknown
                    ;;
            esac
            ;;
        *)
            case ${quc_copy_status:-} in
                RUNNING|STARTING|INTERRUPTED|CANCELLED|PARTIAL)
                    quc_source_dependency=required
                    ;;
                SUCCESS)
                    quc_source_dependency=not_required
                    ;;
                *)
                    quc_source_dependency=unknown
                    ;;
            esac
            ;;
    esac
}

# Метка лежит только в каталоге записи. Номер точки и номер устройства ядро
# может выдать заново сразу после замены носителя, поэтому их сравнения мало.
# Секрет не вращается вместе с token: resume выдаёт заданию новый token.
# Inode каталога записи живёт только в этом процессе и запоминается заново,
# когда метка совпала. В файл состояния он не пишется: на FAT номер не
# переживает повторное подключение.
quc_mount_secret_ok() {
    case ${quc_mount_secret:-} in
        ''|*[!A-Za-z0-9._-]*|.*) return 1 ;;
    esac
    return 0
}

quc_mount_mark_path() {
    quc_mount_secret_ok || return 1
    [ -n "${quc_write_root:-}" ] || return 1
    case $quc_write_root in
        "$quc_target"|"$quc_target"/*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$quc_write_root/.quc-mnt-$quc_mount_secret"
}

quc_mount_mark_matches() {
    mm_one=$1
    [ -n "$mm_one" ] || return 1
    quc_mount_secret_ok || return 1
    if [ -L "$mm_one" ] || [ ! -f "$mm_one" ]; then
        return 1
    fi
    mm_dev=$(quc_dev_of "$mm_one" || true)
    if [ -z "$mm_dev" ] || [ "$mm_dev" != "$quc_target_dev" ]; then
        return 1
    fi
    mm_expect=$(printf '%s\n' "$quc_mount_secret"; printf x)
    mm_expect=${mm_expect%x}
    mm_got=$("$quc_bin_cat" "$mm_one" 2>/dev/null; printf x)
    mm_got=${mm_got%x}
    [ "$mm_got" = "$mm_expect" ]
}

quc_mount_mark_still() {
    if [ "${quc_mount_mark:-0}" != 1 ]; then
        return 0
    fi
    quc_mount_secret_ok || return 1
    if [ -z "${quc_write_root:-}" ] || [ -L "$quc_write_root" ] || [ ! -d "$quc_write_root" ]; then
        return 1
    fi
    mm_live=$(quc_mount_mark_path) || return 1
    quc_mount_mark_matches "$mm_live"
}

quc_ino_of() {
    "$quc_bin_stat" -c '%i' -- "$1" 2>/dev/null
}

quc_write_ino_still() {
    if [ -z "${quc_write_ino:-}" ] || [ -z "${quc_write_root:-}" ]; then
        return 0
    fi
    wi_now=$(quc_ino_of "$quc_write_root" || true)
    if [ -z "$wi_now" ] || [ "$wi_now" != "$quc_write_ino" ]; then
        quc_error="каталог записи подменён"
        return 1
    fi
    return 0
}

quc_mount_mark_accept() {
    quc_mount_mark=1
    quc_write_ino=$(quc_ino_of "$quc_write_root" || true)
    if [ -z "$quc_write_ino" ]; then
        quc_error="не удалось запомнить каталог записи"
        return 1
    fi
    return 0
}

# Занятое временное имя не удаляется: это может быть чужой объект.
# 0 — имени нет. 1 — путь уже занят.
quc_clear_partial_name() {
    cn_path=$1
    if [ -e "$cn_path" ] || [ -L "$cn_path" ]; then
        return 1
    fi
    return 0
}

quc_note_owned() {
    no_ino=$1
    case $no_ino in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ -z "${quc_job_dir:-}" ] || [ -L "$quc_job_dir" ] || [ ! -d "$quc_job_dir" ]; then
        return 0
    fi
    printf '%s\n' "$no_ino" >> "$quc_job_dir/owned.ino" 2>/dev/null || true
    return 0
}

quc_ino_listed() {
    il_ino=$1
    if [ -z "$il_ino" ] || [ -z "${quc_job_dir:-}" ] || [ ! -f "$quc_job_dir/owned.ino" ]; then
        return 1
    fi
    "$quc_bin_awk" -v i="$il_ino" '$0 == i { found = 1 } END { exit found ? 0 : 1 }' "$quc_job_dir/owned.ino"
}

# Удаляет только имя с тем же inode. Ссылку не разыменовывает: rm -f
# снимает само имя ссылки. Чужой inode остаётся.
quc_drop_owned() {
    do_path=$1
    do_ino=$2
    if [ -z "$do_path" ] || [ -z "$do_ino" ]; then
        return 0
    fi
    if [ ! -e "$do_path" ] && [ ! -L "$do_path" ]; then
        return 0
    fi
    do_now=$("$quc_bin_stat" -c '%i' -- "$do_path" 2>/dev/null || true)
    if [ -z "$do_now" ] || [ "$do_now" != "$do_ino" ]; then
        return 0
    fi
    "$quc_bin_rm" -f -- "$do_path" 2>/dev/null || true
    return 0
}

quc_reserve_partial() {
    rp_path=$1
    if ! quc_clear_partial_name "$rp_path"; then
        return 1
    fi
    if ! (set -C; : > "$rp_path"); then
        return 1
    fi
    if [ -L "$rp_path" ] || [ ! -f "$rp_path" ]; then
        return 1
    fi
    rp_ino=$("$quc_bin_stat" -c '%i' -- "$rp_path" 2>/dev/null || true)
    quc_note_owned "$rp_ino"
    return 0
}

quc_write_exclusive() {
    wx_path=$1
    wx_data=$2
    quc_wx_ino=
    if ! quc_clear_partial_name "$wx_path"; then
        return 1
    fi
    wx_ino=$(
        set -C
        exec 3>"$wx_path" || exit 1
        "$quc_bin_stat" -L -c '%i' /proc/self/fd/3 || exit 1
        printf '%s\n' "$wx_data" >&3 || exit 1
    ) || return 1
    case $wx_ino in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ -L "$wx_path" ] || [ ! -f "$wx_path" ]; then
        return 1
    fi
    wx_now=$("$quc_bin_stat" -c '%i' -- "$wx_path" 2>/dev/null || true)
    if [ -z "$wx_now" ] || [ "$wx_now" != "$wx_ino" ]; then
        return 1
    fi
    quc_wx_ino=$wx_ino
    quc_note_owned "$wx_ino"
    return 0
}

# Снимает поля незавершённого конечного имени. Сам файл не удаляет.
quc_partial_clear() {
    quc_partial_rel_hex=
    quc_partial_ino=
    quc_partial_bytes=0
    quc_partial_visible=0
}

# Запоминает видимый незавершённый файл только если inode всё ещё наш.
# Не удаляет имя и не объявляет содержимое проверенным.
quc_partial_remember() {
    pr_path=$1
    pr_hex=$2
    pr_ino=$3
    if [ -z "$pr_ino" ] || [ -z "$pr_hex" ]; then
        return 0
    fi
    if [ -L "$pr_path" ] || [ ! -f "$pr_path" ]; then
        return 0
    fi
    pr_now=$("$quc_bin_stat" -c '%i' -- "$pr_path" 2>/dev/null || true)
    if [ -z "$pr_now" ] || [ "$pr_now" != "$pr_ino" ]; then
        return 0
    fi
    pr_sz=$(quc_file_size "$pr_path" || true)
    case $pr_sz in
        ''|*[!0-9]*) pr_sz=0 ;;
    esac
    quc_partial_rel_hex=$pr_hex
    quc_partial_ino=$pr_ino
    quc_partial_bytes=$pr_sz
    quc_partial_visible=1
    quc_note_owned "$pr_ino"
    quc_save_state || true
    return 0
}

# Удаляет только обычный файл с тем же inode. Ссылку и чужой inode не трогает.
quc_probe_drop() {
    pd_path=$1
    pd_ino=$2
    if [ -z "$pd_path" ] || [ -L "$pd_path" ] || [ ! -f "$pd_path" ]; then
        return 0
    fi
    quc_drop_owned "$pd_path" "$pd_ino"
    return 0
}

quc_probe_fds_close() {
    if [ "${quc_probe_fd3:-0}" = 1 ]; then
        exec 3>&-
        quc_probe_fd3=0
    fi
    if [ "${quc_probe_fd4:-0}" = 1 ]; then
        exec 4>&-
        quc_probe_fd4=0
    fi
}

# Закрывает дескрипторы пробы и снимает эталон. Вызывается после cmp.
quc_probe_cleanup() {
    quc_probe_fds_close
    if [ -n "${quc_probe_ref:-}" ] && [ -n "${quc_bin_rm:-}" ]; then
        "$quc_bin_rm" -f -- "$quc_probe_ref" 2>/dev/null || true
    fi
    quc_probe_ref=
}

# Проверяет назначение в этом процессе. link — жёсткая ссылка создаёт имя.
# exclusive — повторное создание того же имени не затирает файл, ссылки нет.
# Такой файл виден до конца записи и не является атомарной публикацией.
# unsupported — копирование не начинается. Права каталога доказательством не служат.
# Успех: 0 и режим link или exclusive. Отказ: 1, режим пуст.
# Без cmp проба не выполняется: это не отказ файловой системы.
quc_select_publish_mode_run() {
    sp_dir=$1
    quc_publish_mode=
    quc_dest_link_probe='unsupported'
    quc_probe_fd3=0
    quc_probe_fd4=0
    quc_probe_ref=
    quc_error=
    if [ -z "$sp_dir" ] || [ -L "$sp_dir" ] || [ ! -d "$sp_dir" ]; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    if [ -z "${quc_bin_cmp:-}" ]; then
        quc_publish_mode=
        quc_dest_link_probe=UNKNOWN
        quc_error=
        return 0
    fi
    if [ -z "${quc_bin_stat:-}" ] || [ -z "${quc_bin_ln:-}" ] || [ -z "${quc_state_dir:-}" ] || [ -L "$quc_state_dir" ] || [ ! -d "$quc_state_dir" ]; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    sp_n=0
    sp_name=
    while [ "$sp_n" -lt 8 ]; do
        sp_n=$((sp_n + 1))
        sp_try=$sp_dir/${QUC_PARTIAL_PREFIX}mode.$$.$sp_n
        if [ ! -e "$sp_try" ] && [ ! -L "$sp_try" ]; then
            sp_name=$sp_try
            break
        fi
    done
    if [ -z "$sp_name" ]; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    quc_probe_ref=$quc_state_dir/.quc-probe-byte.$$
    if ! printf 'Q\n' > "$quc_probe_ref"; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    set -C
    if exec 3>"$sp_name"; then
        quc_probe_fd3=1
    fi
    set +C
    if [ "$quc_probe_fd3" != 1 ]; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    sp_ino=$("$quc_bin_stat" -L -c '%i' /proc/self/fd/3 2>/dev/null || true)
    case $sp_ino in
        ''|*[!0-9]*)
            quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
            quc_probe_fds_close
            quc_probe_drop "$sp_name" "$sp_ino"
            return 1
            ;;
    esac
    if ! printf 'Q\n' >&3; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        quc_probe_drop "$sp_name" "$sp_ino"
        return 1
    fi
    quc_probe_fds_close
    sp_now=$("$quc_bin_stat" -c '%i' -- "$sp_name" 2>/dev/null || true)
    if [ -L "$sp_name" ] || [ ! -f "$sp_name" ] || [ -z "$sp_now" ] || [ "$sp_now" != "$sp_ino" ]; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_drop "$sp_name" "$sp_ino"
        return 1
    fi
    if [ -z "${quc_bin_cmp:-}" ] || ! "$quc_bin_cmp" -s -- "$quc_probe_ref" "$sp_name"; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_drop "$sp_name" "$sp_ino"
        quc_probe_fds_close
        return 1
    fi
    # Повторное открытие того же имени должно быть отвергнуто. Ошибка
    # перенаправления у exec завершает dash, поэтому проверка идёт в подоболочке.
    # Успех подоболочки значит, что имя можно заменить: режим небезопасен.
    if (set -C; exec 4>"$sp_name") >/dev/null 2>&1; then
        quc_probe_fds_close
        sp_now=$("$quc_bin_stat" -c '%i' -- "$sp_name" 2>/dev/null || true)
        if [ -n "$sp_now" ] && [ "$sp_now" = "$sp_ino" ] && [ ! -L "$sp_name" ]; then
            quc_probe_drop "$sp_name" "$sp_ino"
        fi
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    sp_now=$("$quc_bin_stat" -c '%i' -- "$sp_name" 2>/dev/null || true)
    if [ -L "$sp_name" ] || [ "$sp_now" != "$sp_ino" ] || ! "$quc_bin_cmp" -s -- "$quc_probe_ref" "$sp_name"; then
        if [ -n "$sp_now" ] && [ "$sp_now" = "$sp_ino" ] && [ ! -L "$sp_name" ]; then
            quc_probe_drop "$sp_name" "$sp_ino"
        fi
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    sp_link=$sp_dir/${QUC_PARTIAL_PREFIX}ln.$$.$sp_n
    if [ -e "$sp_link" ] || [ -L "$sp_link" ]; then
        quc_probe_drop "$sp_name" "$sp_ino"
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    if "$quc_bin_ln" -- "$sp_name" "$sp_link" 2>/dev/null; then
        sp_li=$("$quc_bin_stat" -c '%i' -- "$sp_link" 2>/dev/null || true)
        if [ -n "$sp_li" ] && [ "$sp_li" = "$sp_ino" ] && [ ! -L "$sp_link" ]; then
            quc_probe_drop "$sp_link" "$sp_ino"
            quc_probe_drop "$sp_name" "$sp_ino"
            quc_probe_fds_close
            if [ -e "$sp_name" ] || [ -L "$sp_name" ] || [ -e "$sp_link" ] || [ -L "$sp_link" ]; then
                quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
                return 1
            fi
            quc_publish_mode='link'
            quc_dest_link_probe='link'
            quc_error=
            return 0
        fi
        quc_probe_drop "$sp_name" "$sp_ino"
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    if [ -e "$sp_link" ] || [ -L "$sp_link" ]; then
        quc_probe_drop "$sp_name" "$sp_ino"
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    if [ -z "${quc_bin_cmp:-}" ]; then
        quc_probe_drop "$sp_name" "$sp_ino"
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        quc_probe_fds_close
        return 1
    fi
    quc_probe_drop "$sp_name" "$sp_ino"
    quc_probe_fds_close
    if [ -e "$sp_name" ] || [ -L "$sp_name" ]; then
        quc_error="На этом назначении нельзя создать новое имя без риска замены. Копирование не начато."
        return 1
    fi
    quc_publish_mode='exclusive'
    quc_dest_link_probe='exclusive'
    quc_error=
    return 0
}

# Эталон сравнения живёт до возврата: внутренние закрытия дескрипторов его не стирают.
quc_select_publish_mode() {
    quc_select_publish_mode_run "$1"
    sp_rc=$?
    quc_probe_cleanup
    return "$sp_rc"
}

# Пишет метку сразу в конечное имя. Файл виден до проверки и не заменяет чужое.
quc_mark_place_exclusive() {
    mx_live=$1
    if [ -L "$mx_live" ]; then
        quc_error="метка назначения является символьной ссылкой"
        return 1
    fi
    if [ -e "$mx_live" ]; then
        if quc_mount_mark_matches "$mx_live"; then
            quc_mount_mark_accept
            return $?
        fi
        quc_error="метка назначения уже занята другим объектом"
        return 1
    fi
    set -C
    mx_open=0
    if exec 3>"$mx_live"; then
        mx_open=1
    fi
    set +C
    if [ "$mx_open" != 1 ]; then
        if quc_mount_mark_matches "$mx_live"; then
            quc_mount_mark_accept
            return $?
        fi
        quc_error="не удалось закрепить метку назначения"
        return 1
    fi
    mx_ino=$("$quc_bin_stat" -L -c '%i' /proc/self/fd/3 2>/dev/null || true)
    case $mx_ino in
        ''|*[!0-9]*)
            exec 3>&-
            quc_error="не удалось закрепить метку назначения"
            return 1
            ;;
    esac
    if ! printf '%s\n' "$quc_mount_secret" >&3; then
        exec 3>&-
        quc_probe_drop "$mx_live" "$mx_ino"
        quc_error="не удалось записать метку назначения"
        return 1
    fi
    exec 3>&-
    if [ -L "$mx_live" ] || [ ! -f "$mx_live" ]; then
        quc_error="метка назначения записана неверно"
        return 1
    fi
    mx_now=$("$quc_bin_stat" -c '%i' -- "$mx_live" 2>/dev/null || true)
    if [ -z "$mx_now" ] || [ "$mx_now" != "$mx_ino" ]; then
        quc_error="метка назначения уже занята другим объектом"
        return 1
    fi
    if ! quc_mount_mark_matches "$mx_live"; then
        quc_probe_drop "$mx_live" "$mx_ino"
        quc_error="метка назначения не подтвердилась"
        return 1
    fi
    if ! quc_mount_mark_accept; then
        return 1
    fi
    return 0
}

# Фиксирует уже сверенное конечное имя. Размер без cmp успехом не считается.
quc_visible_commit() {
    vc_src=$1
    vc_dst=$2
    vc_hex=$3
    vc_size=$4
    vc_fp=$5
    vc_hash=${6:--}
    if [ -L "$vc_dst" ] || [ ! -f "$vc_dst" ]; then
        quc_error="конечный файл не подтверждён"
        return 2
    fi
    vc_dev=$(quc_dev_of "$vc_dst" || true)
    if [ "$vc_dev" != "$quc_target_dev" ]; then
        quc_error="файл оказался не на файловой системе назначения и не удалён автоматически"
        return 10
    fi
    if [ -z "${quc_bin_cmp:-}" ] || ! "$quc_bin_cmp" -s -- "$vc_src" "$vc_dst"; then
        quc_error="содержимое копии не совпало и не объявлено готовым"
        return 2
    fi
    vc_now=$(quc_file_size "$vc_dst" || true)
    if [ "$vc_now" != "$vc_size" ]; then
        quc_error="размер после переноса не совпал"
        return 2
    fi
    quc_apply_metadata "$vc_src" "$vc_dst"
    vc_fp_hex=$(quc_hex_encode "$vc_fp")
    quc_append_meta F "$vc_hex" "$vc_size" "$vc_fp_hex" "$vc_hash" || return 2
    quc_partial_clear
    case $vc_size in
        ''|*[!0-9]*|0*)
            quc_bytes_done=$(quc_add_bytes "$quc_bytes_done" "$vc_size")
            ;;
        *)
            quc_bytes_done=$((quc_bytes_done + vc_size))
            ;;
    esac
    return 0
}

# Копирует обычный файл сразу в конечное имя, если жёсткой ссылки нет.
# Имя видно до конца записи. До cmp оно не готово и в done.meta не попадает.
# Чужой inode не удаляется. mv для данных пользователя не вызывается.
quc_copy_visible() {
    cv_src=$1
    cv_dst=$2
    cv_rel=$3
    cv_hex=$4
    cv_fp_given=${5:-}
    cv_attempt=1
    cv_unstable=0
    if [ -z "${quc_bin_cmp:-}" ]; then
        quc_error="сравнение содержимого недоступно, запись без жёсткой ссылки не начата"
        return 2
    fi
    while quc_cmp_num "$cv_attempt" "$QUC_MAX_ATTEMPTS" le; do
        if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
            quc_stop_requested=1
            return 20
        fi
        if ! quc_identity_still; then
            return 10
        fi
        if [ "$cv_attempt" = 1 ] && [ -n "$cv_fp_given" ]; then
            cv_fp1=$cv_fp_given
        else
            cv_fp1=$(quc_fingerprint "$cv_src" || true)
        fi
        if [ -z "$cv_fp1" ]; then
            quc_error="не удалось прочитать сведения о файле"
            return 2
        fi
        cv_size=${cv_fp1%% *}
        cv_lim=$(quc_fat_limit "$quc_target_fs")
        if [ -n "$cv_lim" ] && quc_cmp_num "$cv_size" "$cv_lim" gt; then
            quc_error="файл больше предела FAT32 ($(quc_human_bytes "$cv_size"))"
            quc_log ERROR "path=$(quc_display_path "$cv_rel") $quc_error"
            return 4
        fi
        if quc_fat_name_bad "$quc_target_fs" "$cv_rel"; then
            quc_error="имя несовместимо с назначением"
            quc_log ERROR "path=$(quc_display_path "$cv_rel") $quc_error"
            return 4
        fi
        quc_set_parent "$cv_rel"
        cv_parent=$quc_parent
        case $cv_parent in
            .|'') ;;
            *)
                quc_ensure_dir "$cv_parent"
                cv_rc=$?
                if [ "$cv_rc" -ne 0 ]; then
                    return "$cv_rc"
                fi
                ;;
        esac
        quc_set_parent "$cv_dst"
        if ! quc_dest_dir_still "$quc_parent"; then
            return 10
        fi
        if [ -e "$cv_dst" ] || [ -L "$cv_dst" ]; then
            if [ -L "$cv_dst" ] || [ ! -f "$cv_dst" ]; then
                quc_error="в назначении уже есть другой объект, он не заменён"
                return 11
            fi
            if "$quc_bin_cmp" -s -- "$cv_src" "$cv_dst"; then
                cv_fp2=$(quc_fingerprint "$cv_src" || true)
                if [ -n "$cv_fp2" ] && [ "$cv_fp2" = "$cv_fp1" ]; then
                    quc_visible_commit "$cv_src" "$cv_dst" "$cv_hex" "$cv_size" "$cv_fp1" -
                    return $?
                fi
            fi
            cv_now=$("$quc_bin_stat" -c '%i' -- "$cv_dst" 2>/dev/null || true)
            if [ "$quc_partial_visible" = 1 ] && [ "$quc_partial_rel_hex" = "$cv_hex" ] && [ -n "$quc_partial_ino" ] && [ "$cv_now" = "$quc_partial_ino" ]; then
                quc_drop_owned "$cv_dst" "$quc_partial_ino"
                if [ -e "$cv_dst" ] || [ -L "$cv_dst" ]; then
                    quc_error="незавершённый файл не снят, замена не выполняется"
                    return 11
                fi
                quc_partial_clear
                quc_save_state || true
            else
                quc_error="в назначении уже есть другой объект, он не заменён"
                return 11
            fi
        fi
        quc_set_phase "copying:$cv_attempt" "$cv_rel"
        quc_transfer_rel_hex=$cv_hex
        quc_transfer_visible=1
        quc_transfer_exclusive "$cv_src" "$cv_dst" yes
        cv_rc=$?
        quc_transfer_visible=0
        if [ "$cv_rc" -ne 0 ]; then
            if [ "$cv_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ]; then
                return 20
            fi
            if [ "$cv_rc" -eq 11 ]; then
                quc_error="в назначении уже есть другой объект, он не заменён"
                return 11
            fi
            if [ -f "$(quc_scratch_file transfer.err)" ] && "$quc_bin_grep" -q -e 'No space left' -e 'Disk quota exceeded' "$(quc_scratch_file transfer.err)"; then
                quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                quc_error="на назначении закончилось место"
                return 10
            fi
            if ! quc_identity_still; then
                return 10
            fi
            if [ -n "$quc_fill_ino" ]; then
                quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                quc_error="не удалось записать файл, незавершённый результат оставлен"
                return 2
            fi
            cv_attempt=$(quc_add_bytes "$cv_attempt" 1)
            continue
        fi
        cv_delay=${QUC_POST_COPY_DELAY:-0}
        case $cv_delay in
            0) ;;
            *) cv_delay=$(quc_pause_seconds QUC_POST_COPY_DELAY 0 30) ;;
        esac
        if [ "$cv_delay" != 0 ]; then
            quc_set_phase "confirming:$cv_attempt" "$cv_rel"
            if ! quc_sleep_interruptible "$cv_delay"; then
                quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                return 20
            fi
        fi
        cv_fp2=$(quc_fingerprint "$cv_src" || true)
        if [ -z "$cv_fp2" ] || [ "$cv_fp1" != "$cv_fp2" ]; then
            quc_drop_owned "$cv_dst" "$quc_fill_ino"
            if [ -e "$cv_dst" ] || [ -L "$cv_dst" ]; then
                quc_error="файл изменился, а прежняя копия не снята"
                return 11
            fi
            quc_partial_clear
            cv_unstable=1
            quc_log INFO "path=$(quc_display_path "$cv_rel") файл изменился во время копирования, повтор $cv_attempt"
            cv_attempt=$(quc_add_bytes "$cv_attempt" 1)
            continue
        fi
        if [ -L "$cv_dst" ] || [ ! -f "$cv_dst" ]; then
            quc_error="в назначении уже есть другой объект, он не заменён"
            return 11
        fi
        cv_now=$("$quc_bin_stat" -c '%i' -- "$cv_dst" 2>/dev/null || true)
        if [ -z "$quc_fill_ino" ] || [ "$cv_now" != "$quc_fill_ino" ]; then
            quc_error="в назначении уже есть другой объект, он не заменён"
            return 11
        fi
        if ! "$quc_bin_cmp" -s -- "$cv_src" "$cv_dst"; then
            quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
            quc_error="содержимое копии не совпало и не объявлено готовым"
            return 2
        fi
        cv_hash='-'
        if [ "$quc_verify_during" = 1 ]; then
            if ! quc_hash_tool; then
                quc_verify_tool=unavailable
            else
                quc_verify_tool=$quc_hash_name
                cv_h1=$(quc_hash_file "$cv_src" || true)
                cv_h2=$(quc_hash_file "$cv_dst" || true)
                cv_h3=$(quc_hash_file "$cv_src" || true)
                if [ -z "$cv_h1" ] || [ -z "$cv_h2" ] || [ -z "$cv_h3" ] || [ "$cv_h1" != "$cv_h3" ]; then
                    quc_drop_owned "$cv_dst" "$quc_fill_ino"
                    if [ -e "$cv_dst" ] || [ -L "$cv_dst" ]; then
                        quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                        quc_error="содержимое изменилось во время проверки"
                        return 2
                    fi
                    quc_partial_clear
                    cv_unstable=1
                    cv_attempt=$(quc_add_bytes "$cv_attempt" 1)
                    continue
                fi
                if [ "$cv_h1" != "$cv_h2" ]; then
                    quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                    quc_error="контрольная сумма копии не совпала"
                    return 2
                fi
                cv_hash=$cv_h1
            fi
        fi
        if quc_source_detached; then
            cv_expect=$(quc_stage_hash_for "$cv_rel" || true)
            cv_got=$(quc_hash_file "$cv_dst" || true)
            if [ -z "$cv_expect" ] || [ -z "$cv_got" ] || [ "$cv_expect" != "$cv_got" ]; then
                quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                quc_error="локальная копия файла не совпала с описанием"
                return 2
            fi
        fi
        cv_pre=${QUC_PRE_PUBLISH_PAUSE:-0}
        case $cv_pre in
            0) ;;
            *) cv_pre=$(quc_pause_seconds QUC_PRE_PUBLISH_PAUSE 0 60) ;;
        esac
        if [ "$cv_pre" != 0 ]; then
            quc_set_phase "prepublish" "$cv_rel"
            if ! quc_sleep_interruptible "$cv_pre"; then
                quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
                return 20
            fi
        fi
        if ! quc_identity_still; then
            quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
            return 10
        fi
        cv_fp3=$(quc_fingerprint "$cv_src" || true)
        cv_now=$("$quc_bin_stat" -c '%i' -- "$cv_dst" 2>/dev/null || true)
        if [ -L "$cv_dst" ] || [ ! -f "$cv_dst" ] || [ "$cv_now" != "$quc_fill_ino" ]; then
            quc_error="в назначении уже есть другой объект, он не заменён"
            return 11
        fi
        if [ -z "$cv_fp3" ] || [ "$cv_fp3" != "$cv_fp1" ] || ! "$quc_bin_cmp" -s -- "$cv_src" "$cv_dst"; then
            quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
            quc_error="содержимое копии не совпало и не объявлено готовым"
            return 2
        fi
        quc_visible_commit "$cv_src" "$cv_dst" "$cv_hex" "$cv_size" "$cv_fp1" "$cv_hash"
        cv_pub=$?
        if [ "$cv_pub" -ne 0 ]; then
            quc_partial_remember "$cv_dst" "$cv_hex" "$quc_fill_ino"
            return "$cv_pub"
        fi
        return 0
    done
    if [ "$cv_unstable" = 1 ]; then
        quc_error="файл менялся во время копирования, согласованная копия не получена"
        quc_log ERROR "path=$(quc_display_path "$cv_rel") $quc_error"
        return 3
    fi
    quc_error="не удалось скопировать файл"
    quc_log ERROR "path=$(quc_display_path "$cv_rel") $quc_error"
    return 2
}

# Создаёт символьную ссылку сразу под конечным именем. Чужое имя не заменяется.
quc_copy_link_visible() {
    if ! quc_identity_still; then
        return 10
    fi
    clv_src=$1
    clv_dst=$2
    clv_rel=$3
    clv_hex=$4
    clv_target=$("$quc_bin_readlink" -- "$clv_src" 2>/dev/null || true)
    if [ -z "$clv_target" ] && [ ! -L "$clv_src" ]; then
        return 2
    fi
    quc_set_parent "$clv_rel"
    clv_parent=$quc_parent
    case $clv_parent in
        .|'') ;;
        *)
            quc_ensure_dir "$clv_parent"
            clv_rc=$?
            if [ "$clv_rc" -ne 0 ]; then
                return "$clv_rc"
            fi
            ;;
    esac
    quc_set_parent "$clv_dst"
    if ! quc_dest_dir_still "$quc_parent"; then
        return 10
    fi
    if [ -e "$clv_dst" ] || [ -L "$clv_dst" ]; then
        if [ -L "$clv_dst" ]; then
            clv_got=$("$quc_bin_readlink" -- "$clv_dst" 2>/dev/null || true)
            if [ -n "$clv_target" ] && [ "$clv_got" = "$clv_target" ]; then
                clv_th=$(quc_hex_encode "$clv_target")
                quc_append_meta L "$clv_hex" 0 "$clv_th" - || return 2
                quc_partial_clear
                return 0
            fi
        fi
        quc_error="в назначении уже есть другой объект, он не заменён"
        return 11
    fi
    if ! "$quc_bin_ln" -s -- "$clv_target" "$clv_dst" 2>"$(quc_scratch_file transfer.err)"; then
        if [ -e "$clv_dst" ] || [ -L "$clv_dst" ]; then
            quc_error="в назначении уже есть другой объект, он не заменён"
            return 11
        fi
        quc_error="файловая система назначения не поддерживает символьные ссылки"
        quc_log ERROR "path=$(quc_display_path "$clv_rel") $quc_error"
        return 4
    fi
    clv_ino=$("$quc_bin_stat" -c '%i' -- "$clv_dst" 2>/dev/null || true)
    if [ -z "$clv_ino" ] || [ ! -L "$clv_dst" ]; then
        quc_error="символьная ссылка записана неверно"
        return 2
    fi
    quc_partial_rel_hex=$clv_hex
    quc_partial_ino=$clv_ino
    quc_partial_bytes=0
    quc_partial_visible=1
    quc_note_owned "$clv_ino"
    quc_save_state || true
    clv_got=$("$quc_bin_readlink" -- "$clv_dst" 2>/dev/null || true)
    if [ "$clv_got" != "$clv_target" ]; then
        quc_error="символьная ссылка записана неверно"
        return 2
    fi
    clv_th=$(quc_hex_encode "$clv_target")
    quc_append_meta L "$clv_hex" 0 "$clv_th" - || return 2
    quc_partial_clear
    return 0
}

# Новое имя при доступной жёсткой ссылке публикуется только через ln без -L.
# Это link(2): занятое имя даёт отказ и не заменяется. mv для данных
# пользователя не вызывается. Нулевой код mv не считается публикацией.
# Если ссылки нет, конечное имя создаётся отдельно и не называется атомарным.
# --- Безопасное копирование ---

# Публикует уже записанный временный файл под новым именем.
# Принимает временный путь, конечный путь и inode временного файла.
# Успех: 0, только если временное имя исчезло и inode назначения совпал.
# Отказ: 11, чужое имя уже есть. Отказ: 2, ссылку создать нельзя.
# Чужое имя не снимается, даже если inode после ссылки не совпал.
quc_install_new() {
    in_tmp=$1
    in_dst=$2
    in_ino=${3:-}
    if [ -e "$in_dst" ] || [ -L "$in_dst" ]; then
        return 11
    fi
    if [ -n "$in_ino" ]; then
        in_now=$("$quc_bin_stat" -c '%i' -- "$in_tmp" 2>/dev/null || true)
        if [ -z "$in_now" ] || [ "$in_now" != "$in_ino" ]; then
            return 2
        fi
    fi
    if "$quc_bin_ln" -- "$in_tmp" "$in_dst" 2>/dev/null; then
        in_dst_ino=$("$quc_bin_stat" -c '%i' -- "$in_dst" 2>/dev/null || true)
        if [ -n "$in_ino" ]; then
            if [ -z "$in_dst_ino" ] || [ "$in_dst_ino" != "$in_ino" ]; then
                # Имя уже не наш inode. Снимать его нельзя: это может быть чужой объект.
                return 2
            fi
            quc_drop_owned "$in_tmp" "$in_ino"
            if [ -e "$in_tmp" ] || [ -L "$in_tmp" ]; then
                return 2
            fi
            return 0
        fi
        in_tmp_ino=$("$quc_bin_stat" -c '%i' -- "$in_tmp" 2>/dev/null || true)
        if [ -n "$in_dst_ino" ] && [ "$in_dst_ino" = "$in_tmp_ino" ]; then
            quc_drop_owned "$in_tmp" "$in_tmp_ino"
        fi
        if [ -e "$in_tmp" ] || [ -L "$in_tmp" ]; then
            return 2
        fi
        if [ -e "$in_dst" ] || [ -L "$in_dst" ]; then
            return 0
        fi
        return 2
    fi
    if [ -e "$in_dst" ] || [ -L "$in_dst" ]; then
        return 11
    fi
    if [ -n "$in_ino" ]; then
        in_now=$("$quc_bin_stat" -c '%i' -- "$in_tmp" 2>/dev/null || true)
        if [ -z "$in_now" ] || [ "$in_now" != "$in_ino" ]; then
            return 2
        fi
    fi
    if [ "${quc_publish_limited:-0}" != 1 ]; then
        quc_publish_limited=1
        quc_log INFO "безопасная публикация недоступна: жёсткая ссылка не создана, замена имени не используется"
    fi
    return 2
}

quc_mount_mark_place() {
    if ! quc_mount_secret_ok; then
        quc_mount_secret=$quc_token
    fi
    if ! quc_mount_secret_ok; then
        quc_mount_secret=$(quc_new_token)
    fi
    if ! quc_mount_secret_ok; then
        quc_error="не удалось создать метку назначения"
        return 1
    fi
    if [ -L "$quc_write_root" ] || [ ! -d "$quc_write_root" ]; then
        quc_error="каталог записи недоступен для метки"
        return 1
    fi
    if ! quc_dest_dir_still "$quc_write_root"; then
        return 1
    fi
    mm_live=$(quc_mount_mark_path) || {
        quc_error="не удалось выбрать путь метки назначения"
        return 1
    }
    quc_save_state || true
    mm_pause=${QUC_PRE_MARK_PAUSE:-0}
    case $mm_pause in
        0) ;;
        *) mm_pause=$(quc_pause_seconds QUC_PRE_MARK_PAUSE 0 30) ;;
    esac
    if [ "$mm_pause" != 0 ]; then
        quc_set_phase "mark" ""
        if ! quc_sleep_interruptible "$mm_pause"; then
            quc_error="прервано до записи метки назначения"
            return 1
        fi
    fi
    if [ -L "$mm_live" ]; then
        quc_error="метка назначения является символьной ссылкой"
        return 1
    fi
    if [ -e "$mm_live" ]; then
        if quc_mount_mark_matches "$mm_live"; then
            if ! quc_mount_mark_accept; then
                return 1
            fi
            return 0
        fi
        quc_error="метка назначения уже занята другим объектом"
        return 1
    fi
    if [ "${quc_publish_mode:-}" = exclusive ]; then
        quc_mark_place_exclusive "$mm_live"
        return $?
    fi
    mm_tmp=$quc_write_root/${QUC_PARTIAL_PREFIX}$$.mnt
    if ! quc_write_exclusive "$mm_tmp" "$quc_mount_secret"; then
        quc_drop_owned "$mm_tmp" "$quc_wx_ino"
        quc_error="не удалось записать метку назначения"
        return 1
    fi
    if [ -L "$mm_tmp" ] || [ ! -f "$mm_tmp" ]; then
        quc_drop_owned "$mm_tmp" "$quc_wx_ino"
        quc_error="метка назначения записана неверно"
        return 1
    fi
    mm_dev=$(quc_dev_of "$mm_tmp" || true)
    if [ -z "$mm_dev" ] || [ "$mm_dev" != "$quc_target_dev" ]; then
        quc_drop_owned "$mm_tmp" "$quc_wx_ino"
        quc_error="метка назначения оказалась на другой файловой системе"
        return 1
    fi
    quc_install_new "$mm_tmp" "$mm_live" "$quc_wx_ino"
    mm_rc=$?
    if [ "$mm_rc" -ne 0 ]; then
        quc_drop_owned "$mm_tmp" "$quc_wx_ino"
        if quc_mount_mark_matches "$mm_live"; then
            if ! quc_mount_mark_accept; then
                return 1
            fi
            return 0
        fi
        if [ "$mm_rc" -eq 11 ]; then
            quc_error="метка назначения уже занята другим объектом"
        else
            quc_error="не удалось закрепить метку назначения"
        fi
        return 1
    fi
    if [ -e "$mm_tmp" ] || [ -L "$mm_tmp" ]; then
        quc_drop_owned "$mm_tmp" "$quc_wx_ino"
        if [ -e "$mm_tmp" ] || [ -L "$mm_tmp" ]; then
            quc_error="временный файл метки остался в назначении"
            return 1
        fi
    fi
    if ! quc_mount_mark_matches "$mm_live"; then
        quc_error="метка назначения не подтвердилась"
        return 1
    fi
    if ! quc_mount_mark_accept; then
        return 1
    fi
    return 0
}

quc_mount_mark_release() {
    if [ "${quc_mount_mark:-0}" != 1 ]; then
        return 0
    fi
    mm_live=$(quc_mount_mark_path) || return 1
    if ! quc_mount_mark_matches "$mm_live"; then
        quc_error="метка назначения не совпала и не удалена"
        return 1
    fi
    if ! "$quc_bin_rm" -f -- "$mm_live"; then
        quc_error="не удалось убрать метку назначения"
        return 1
    fi
    if [ -e "$mm_live" ] || [ -L "$mm_live" ]; then
        quc_error="не удалось убрать метку назначения"
        return 1
    fi
    quc_mount_mark=0
    return 0
}

quc_mount_mark_cleanup_dest() {
    if [ "${quc_mount_mark:-0}" != 1 ]; then
        return 0
    fi
    quc_mount_secret_ok || return 0
    if ! quc_bind_roots; then
        return 0
    fi
    mm_live=$(quc_mount_mark_path) || return 0
    if [ ! -e "$mm_live" ] && [ ! -L "$mm_live" ]; then
        return 0
    fi
    if ! quc_mount_mark_matches "$mm_live"; then
        return 0
    fi
    "$quc_bin_rm" -f -- "$mm_live" 2>/dev/null || true
    return 0
}

quc_identity_target_now() {
    if [ -n "${quc_target_mntid:-}" ] && [ "$quc_mi_id" != "$quc_target_mntid" ]; then
        quc_error="точка монтирования назначения сменилась"
        return 1
    fi
    now_t=$(quc_dev_of "$quc_target" || true)
    if [ -z "$now_t" ] || [ "$now_t" != "$quc_target_dev" ]; then
        quc_error="устройство назначения изменилось во время работы"
        return 1
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

quc_identity_source_now() {
    if [ -n "${quc_source_mntid:-}" ] && [ "$quc_mi_id" != "$quc_source_mntid" ]; then
        quc_error="точка монтирования источника сменилась"
        return 1
    fi
    now_s=$(quc_dev_of "$quc_source" || true)
    if [ -z "$now_s" ] || [ "$now_s" != "$quc_source_dev" ]; then
        quc_error="устройство источника изменилось во время работы"
        return 1
    fi
    if [ -n "$quc_source_uuid" ]; then
        u=$(quc_uuid_of "$quc_source" || true)
        if [ "$u" != "$quc_source_uuid" ]; then
            quc_error="UUID источника не совпал"
            return 1
        fi
    fi
    return 0
}

# Сверяет источник и назначение с запомненными идентификаторами.
# Аргументов нет. При отказе пишет quc_error.
# Успех: 0. Отказ: 1, копирование этого шага прекращается.
# Совпадение размера или времени файла здесь не проверяется.
quc_identity_still() {
    if quc_source_detached; then
        quc_stage_identity || return 1
        if ! quc_mountinfo_lookup "$quc_target"; then
            quc_error="назначение больше не смонтировано"
            return 1
        fi
        quc_identity_target_now || return 1
    elif quc_mountinfo_lookup_pair "$quc_source" "$quc_target"; then
        quc_mi_id_saved=$quc_mi_id
        quc_mi_id=$quc_mi2_id
        if ! quc_identity_source_now; then
            return 1
        fi
        quc_mi_id=$quc_mi_id_saved
        quc_identity_target_now || return 1
    else
        if ! quc_mountinfo_lookup "$quc_source"; then
            quc_error="источник больше не смонтирован"
            return 1
        fi
        quc_identity_source_now || return 1
        if ! quc_mountinfo_lookup "$quc_target"; then
            quc_error="назначение больше не смонтировано"
            return 1
        fi
        quc_identity_target_now || return 1
    fi
    if ! quc_mount_mark_still; then
        quc_error="назначение сменило носитель"
        return 1
    fi
    if ! quc_write_ino_still; then
        return 1
    fi
    return 0
}

quc_resume_identity() {
    if quc_source_detached; then
        quc_stage_identity || return 1
        src_fs=$quc_source_fs
        src_spec=$quc_source_spec
        src_uuid=$quc_source_uuid
        src_size=$quc_source_fssize
    else
        if ! quc_mountinfo_lookup "$quc_source"; then
            quc_error="источник не смонтирован"
            return 1
        fi
        src_fs=$quc_mi_fstype
        src_spec=$quc_mi_source
    fi
    if ! quc_mountinfo_lookup "$quc_target"; then
        quc_error="назначение не смонтировано"
        return 1
    fi
    if quc_source_detached; then
        :
    elif ! quc_mountinfo_lookup "$quc_source"; then
        return 1
    else
        src_fs=$quc_mi_fstype
        src_spec=$quc_mi_source
    fi
    if ! quc_mountinfo_lookup "$quc_target"; then
        return 1
    fi
    dst_fs=$quc_mi_fstype
    dst_spec=$quc_mi_source
    if quc_source_detached; then
        src_uuid=$quc_source_uuid
        src_size=$quc_source_fssize
    else
        src_uuid=$(quc_uuid_of "$quc_source" || true)
        src_size=$(quc_fs_bytes "$quc_source" || printf '0')
    fi
    dst_uuid=$(quc_uuid_of "$quc_target" || true)
    dst_size=$(quc_fs_bytes "$quc_target" || printf '0')
    if quc_source_detached; then
        :
    elif [ -n "$quc_source_uuid" ]; then
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
    if quc_source_detached; then
        :
    else
        quc_source_dev=$(quc_dev_of "$quc_source") || return 1
    fi
    quc_target_dev=$(quc_dev_of "$quc_target") || return 1
    quc_source_fs=$src_fs
    quc_target_fs=$dst_fs
    quc_source_spec=$src_spec
    quc_target_spec=$dst_spec
    quc_source_uuid=$src_uuid
    quc_target_uuid=$dst_uuid
    if ! quc_source_detached && quc_mountinfo_lookup "$quc_source"; then
        quc_source_mntid=$quc_mi_id
    fi
    if quc_mountinfo_lookup "$quc_target"; then
        quc_target_mntid=$quc_mi_id
    fi
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
        QUC_PRE_PUBLISH_PAUSE) raw=${QUC_PRE_PUBLISH_PAUSE:-$def} ;;
        QUC_PRE_MARK_PAUSE) raw=${QUC_PRE_MARK_PAUSE:-$def} ;;
        QUC_PRE_VERIFY_PAUSE) raw=${QUC_PRE_VERIFY_PAUSE:-$def} ;;
        QUC_FILL_PAUSE) raw=${QUC_FILL_PAUSE:-$def} ;;
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

# Дочерний процесс не наследует fd 9: иначе после SIGKILL worker
# короткий sleep/cp удерживает flock и resume не может взять блокировку.
quc_spawn_child() {
    (
        exec 9>&-
        exec "$@"
    ) &
    quc_child_pid=$!
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
        quc_spawn_child "$quc_bin_sleep" 1
        # Нельзя писать `if ! cmd; then rc=$?`: `!` обнуляет $?.
        quc_wait_pid "$quc_child_pid"
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

# Дескриптор 3 открыт с O_EXCL в этом процессе. Потомок пишет в
# унаследованный /proc/self/fd/3 и не открывает путь заново: подмена
# имени ссылкой не перенаправляет запись. quc_fill_ino пуст, если путь
# уже не тот inode: вызывающий не должен его удалять.
quc_transfer_exclusive() {
    te_src=$1
    te_dst=$2
    te_sync=${3:-yes}
    te_visible=${quc_transfer_visible:-0}
    quc_transfer_visible=0
    quc_fill_ino=
    te_err=$(quc_scratch_file transfer.err)
    : > "$te_err"
    if [ -e "$te_dst" ] || [ -L "$te_dst" ]; then
        return 11
    fi
    set -C
    if ! exec 3>"$te_dst"; then
        set +C
        return 11
    fi
    set +C
    te_ino=$("$quc_bin_stat" -L -c '%i' /proc/self/fd/3 2>/dev/null || true)
    case $te_ino in
        ''|*[!0-9]*)
            exec 3>&-
            return 11
            ;;
    esac
    if [ "$te_visible" = 1 ]; then
        quc_partial_rel_hex=${quc_transfer_rel_hex:-}
        quc_partial_ino=$te_ino
        quc_partial_bytes=0
        quc_partial_visible=1
        quc_note_owned "$te_ino"
        quc_save_state || true
    fi
    te_pause=${QUC_FILL_PAUSE:-0}
    case $te_pause in
        0) ;;
        *) te_pause=$(quc_pause_seconds QUC_FILL_PAUSE 0 30) ;;
    esac
    if [ "$te_pause" != 0 ]; then
        if ! quc_sleep_interruptible "$te_pause"; then
            te_now=$("$quc_bin_stat" -c '%i' -- "$te_dst" 2>/dev/null || true)
            exec 3>&-
            if [ -n "$te_now" ] && [ "$te_now" = "$te_ino" ] && [ ! -L "$te_dst" ] && [ -f "$te_dst" ]; then
                quc_fill_ino=$te_ino
                quc_note_owned "$te_ino"
            fi
            return 20
        fi
    fi
    if [ "${quc_cp_sparse:-0}" = 1 ]; then
        quc_spawn_child "$quc_bin_cp" --sparse=auto -- "$te_src" /proc/self/fd/3 2>"$te_err"
    else
        quc_spawn_child "$quc_bin_cp" -- "$te_src" /proc/self/fd/3 2>"$te_err"
    fi
    quc_wait_pid "$quc_child_pid"
    te_rc=$?
    exec 3>&-
    te_now=
    if [ -e "$te_dst" ] || [ -L "$te_dst" ]; then
        te_now=$("$quc_bin_stat" -c '%i' -- "$te_dst" 2>/dev/null || true)
    fi
    if [ "$te_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ] || [ -f "${quc_job_dir:-/nonexistent}/stop-requested" ]; then
        if [ -n "$te_ino" ] && [ "$te_now" = "$te_ino" ] && [ ! -L "$te_dst" ]; then
            quc_fill_ino=$te_ino
            quc_note_owned "$te_ino"
        fi
        return 20
    fi
    if [ -z "$te_ino" ] || [ -z "$te_now" ] || [ "$te_now" != "$te_ino" ] || [ -L "$te_dst" ] || [ ! -f "$te_dst" ]; then
        return 11
    fi
    quc_fill_ino=$te_ino
    quc_note_owned "$te_ino"
    if [ "$te_rc" -ne 0 ]; then
        return "$te_rc"
    fi
    if [ "$te_sync" = yes ] && { [ "$quc_sync_mode" = data ] || [ "$quc_sync_mode" = file ]; }; then
        (
            exec 9>&-
            quc_sync_cmd "$te_dst"
        ) 2>>"$te_err" &
        quc_wait_pid "$!"
        te_rc=$?
        if [ "$te_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ] || [ -f "$quc_job_dir/stop-requested" ]; then
            return 20
        fi
        if [ "$te_rc" -ne 0 ]; then
            quc_sync_unconfirmed=1
            quc_sync_status=unconfirmed
            quc_log INFO "не удалось синхронизировать данные файла"
        fi
    fi
    return 0
}

# Имя из done.meta не даёт права заменить файл. Функция только выбирает
# текст отказа, если объект похож на ранее опубликованный.
quc_may_replace_own() {
    ro_hex=$1
    ro_dst=$2
    if [ "${quc_run_mode:-}" != resume ] || [ -z "$ro_hex" ]; then
        return 1
    fi
    ro_line=$(quc_meta_line "$ro_hex" || true)
    if [ -z "$ro_line" ]; then
        return 1
    fi
    ro_kind=$(printf '%s\n' "$ro_line" | "$quc_bin_awk" -F '\t' '{ print $1; exit }')
    case $ro_kind in
        F)
            if [ -L "$ro_dst" ] || [ ! -f "$ro_dst" ]; then
                return 1
            fi
            ;;
        L)
            if [ ! -L "$ro_dst" ]; then
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac
    ro_dev=$(quc_dev_of "$ro_dst" || true)
    if [ -z "$ro_dev" ] || [ "$ro_dev" != "$quc_target_dev" ]; then
        return 1
    fi
    if [ -n "${quc_write_root:-}" ]; then
        case $ro_dst in
            "$quc_write_root"/*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

quc_publish_file() {
    pf_tmp=$1
    pf_dst=$2
    pf_hex=${3:-}
    pf_ino=${4:-}
    if [ -e "$pf_dst" ] || [ -L "$pf_dst" ]; then
        if [ -f "$pf_dst" ] && [ ! -L "$pf_dst" ] && [ -f "$pf_tmp" ] && [ ! -L "$pf_tmp" ] && [ -n "${quc_bin_cmp:-}" ] && "$quc_bin_cmp" -s -- "$pf_tmp" "$pf_dst"; then
            quc_drop_owned "$pf_tmp" "$pf_ino"
            return 0
        fi
        if [ -L "$pf_dst" ] && [ -L "$pf_tmp" ]; then
            pf_a=$("$quc_bin_readlink" -- "$pf_dst" 2>/dev/null || true)
            pf_b=$("$quc_bin_readlink" -- "$pf_tmp" 2>/dev/null || true)
            if [ -n "$pf_b" ] && [ "$pf_a" = "$pf_b" ]; then
                quc_drop_owned "$pf_tmp" "$pf_ino"
                return 0
            fi
        fi
        if quc_may_replace_own "$pf_hex" "$pf_dst"; then
            quc_error="ранее опубликованный файл изменён и не заменён"
            quc_log INFO "path=$(quc_display_path "$pf_dst") $quc_error"
        else
            quc_error="в назначении уже есть другой объект, он не заменён"
        fi
        quc_drop_owned "$pf_tmp" "$pf_ino"
        return 11
    fi
    quc_install_new "$pf_tmp" "$pf_dst" "$pf_ino"
    pf_rc=$?
    if [ "$pf_rc" -eq 0 ]; then
        return 0
    fi
    if [ "$pf_rc" -eq 11 ]; then
        quc_error="в назначении уже есть другой объект, он не заменён"
    else
        quc_error="не удалось опубликовать файл без замены существующего имени"
    fi
    quc_drop_owned "$pf_tmp" "$pf_ino"
    if [ "$pf_rc" -eq 11 ]; then
        return 11
    fi
    return 2
}

quc_ensure_dir() {
    ed_rel=$1
    ed_dest=${quc_write_root:-$quc_target}
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
        if [ -d "$ed_dest" ] && [ ! -L "$ed_dest" ]; then
            ed_dev=$(quc_dev_of "$ed_dest" || true)
            if [ "$ed_dev" != "$quc_target_dev" ]; then
                quc_error="каталог назначения сменил файловую систему"
                return 10
            fi
            continue
        fi
        if ! quc_identity_still; then
            return 10
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
    # Префикс x: иначе awk сравнивает hex как число и склеивает разные пути.
    "$quc_bin_awk" -F '\t' -v p="$1" '(("x" $2) == ("x" p)) { line = $0; found = 1 } END { if (found) print line; exit found ? 0 : 1 }' "$quc_meta_file"
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

quc_dest_dir_still() {
    dd_dir=$1
    quc_dd_ino=
    if [ -z "$dd_dir" ] || [ -L "$dd_dir" ] || [ ! -d "$dd_dir" ]; then
        quc_error="каталог записи сменился"
        return 1
    fi
    if [ -n "${quc_write_root:-}" ]; then
        case $dd_dir in
            "$quc_write_root"|"$quc_write_root"/*) ;;
            *)
                quc_error="каталог записи вне выбранного размещения"
                return 1
                ;;
        esac
        if [ -L "$quc_write_root" ] || [ ! -d "$quc_write_root" ]; then
            quc_error="каталог записи сменился"
            return 1
        fi
    fi
    dd_stat=$("$quc_bin_stat" -c '%d %i' -- "$dd_dir" 2>/dev/null || true)
    case $dd_stat in
        *' '*) ;;
        *)
            dd_stat=
            ;;
    esac
    dd_dev=${dd_stat%% *}
    dd_ino=${dd_stat#* }
    if [ -z "$dd_dev" ] || [ "$dd_dev" != "$quc_target_dev" ]; then
        quc_error="каталог записи сменил файловую систему"
        return 1
    fi
    case $dd_ino in
        ''|*[!0-9]*)
            quc_error="каталог записи сменился"
            return 1
            ;;
    esac
    if [ -n "${quc_write_ino:-}" ] && [ -n "${quc_write_root:-}" ]; then
        if [ "$dd_dir" = "$quc_write_root" ]; then
            if [ "$dd_ino" != "$quc_write_ino" ]; then
                quc_error="каталог записи подменён"
                return 1
            fi
        else
            dd_root=$("$quc_bin_stat" -c '%i' -- "$quc_write_root" 2>/dev/null || true)
            if [ -z "$dd_root" ] || [ "$dd_root" != "$quc_write_ino" ]; then
                quc_error="каталог записи подменён"
                return 1
            fi
        fi
    fi
    quc_dd_ino=$dd_ino
    return 0
}

# Копирует один обычный файл в новое имя.
# Принимает источник, назначение, относительный путь, hex и отпечаток.
# Меняет счётчики, quc_error и журнал. Повторяет попытку до QUC_MAX_ATTEMPTS.
# Успех: 0. Отказ: 2 чтение, 4 размер, 10 носитель, 11 публикация, 20 сигнал.
# Не заменяет существующее имя и не публикует в другой каталог.
# Режим exclusive пишет сразу в конечное имя. Пустой режим остаётся на ln.
quc_copy_regular() {
    if [ "${quc_publish_mode:-}" = exclusive ]; then
        quc_copy_visible "$@"
        return $?
    fi
    cr_src=$1
    cr_dst=$2
    cr_rel=$3
    cr_hex=$4
    cr_fp_given=${5:-}
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
        if [ "$cr_attempt" = 1 ] && [ -n "$cr_fp_given" ]; then
            cr_fp1=$cr_fp_given
        else
            cr_fp1=$(quc_fingerprint "$cr_src" || true)
        fi
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
        if quc_fat_name_bad "$quc_target_fs" "$cr_rel"; then
            quc_error="имя несовместимо с назначением"
            quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
            return 4
        fi
        quc_set_parent "$cr_rel"
        cr_parent=$quc_parent
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
        quc_set_parent "$cr_dst"
        cr_tmp_dir=$quc_parent
        if ! quc_dest_dir_still "$cr_tmp_dir"; then
            return 10
        fi
        cr_dir_ino=$quc_dd_ino
        cr_tmp=$cr_tmp_dir/$QUC_PARTIAL_PREFIX$$.$cr_attempt
        if [ -e "$cr_tmp" ] || [ -L "$cr_tmp" ]; then
            quc_error="временное имя занято"
            quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
            return 2
        fi
        quc_set_phase "copying:$cr_attempt" "$cr_rel"
        quc_transfer_exclusive "$cr_src" "$cr_tmp" yes
        cr_rc=$?
        if [ "$cr_rc" -ne 0 ]; then
            quc_drop_owned "$cr_tmp" "$quc_fill_ino"
            if [ "$cr_rc" -eq 20 ] || [ "${quc_stop_requested:-0}" = 1 ]; then
                return 20
            fi
            if [ "$cr_rc" -eq 11 ]; then
                quc_error="временный файл подменён или имя занято"
                cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
                continue
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
        if [ -L "$cr_tmp" ] || [ ! -f "$cr_tmp" ]; then
            quc_error="временный файл подменён"
            return 2
        fi
        cr_delay=${QUC_POST_COPY_DELAY:-0}
        case $cr_delay in
            0) ;;
            *) cr_delay=$(quc_pause_seconds QUC_POST_COPY_DELAY 0 30) ;;
        esac
        if [ "$cr_delay" != 0 ]; then
            quc_set_phase "confirming:$cr_attempt" "$cr_rel"
            if ! quc_sleep_interruptible "$cr_delay"; then
                quc_drop_owned "$cr_tmp" "$quc_fill_ino"
                return 20
            fi
        fi
        cr_fp2=$(quc_fingerprint "$cr_src" || true)
        cr_dsize=$(quc_file_size "$cr_tmp" || true)
        if [ -z "$cr_fp2" ] || [ "$cr_fp1" != "$cr_fp2" ] || [ "$cr_dsize" != "$cr_size" ]; then
            quc_drop_owned "$cr_tmp" "$quc_fill_ino"
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
                    quc_drop_owned "$cr_tmp" "$quc_fill_ino"
                    cr_unstable=1
                    quc_log INFO "path=$(quc_display_path "$cr_rel") содержимое изменилось во время проверки"
                    cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
                    continue
                fi
                if [ "$cr_h1" != "$cr_h2" ]; then
                    quc_drop_owned "$cr_tmp" "$quc_fill_ino"
                    quc_log ERROR "path=$(quc_display_path "$cr_rel") контрольная сумма копии не совпала"
                    cr_attempt=$(quc_add_bytes "$cr_attempt" 1)
                    continue
                fi
                cr_hash=$cr_h1
            fi
        fi
        if ! quc_identity_still; then
            quc_drop_owned "$cr_tmp" "$quc_fill_ino"
            return 10
        fi
        if quc_source_detached; then
            cr_expect=$(quc_stage_hash_for "$cr_rel" || true)
            cr_got=$(quc_hash_file "$cr_tmp" || true)
            if [ -z "$cr_expect" ] || [ -z "$cr_got" ] || [ "$cr_expect" != "$cr_got" ]; then
                quc_drop_owned "$cr_tmp" "$quc_fill_ino"
                quc_error="локальная копия файла не совпала с описанием"
                return 2
            fi
        fi
        cr_pre=${QUC_PRE_PUBLISH_PAUSE:-0}
        case $cr_pre in
            0) ;;
            *) cr_pre=$(quc_pause_seconds QUC_PRE_PUBLISH_PAUSE 0 60) ;;
        esac
        if [ "$cr_pre" != 0 ]; then
            quc_set_phase "prepublish" "$cr_rel"
            if ! quc_sleep_interruptible "$cr_pre"; then
                quc_drop_owned "$cr_tmp" "$quc_fill_ino"
                return 20
            fi
        fi
        if ! quc_dest_dir_still "$cr_tmp_dir"; then
            quc_drop_owned "$cr_tmp" "$quc_fill_ino"
            return 10
        fi
        cr_dir_now=$quc_dd_ino
        if [ -z "$cr_dir_ino" ] || [ "$cr_dir_now" != "$cr_dir_ino" ]; then
            quc_error="каталог записи подменён"
            quc_drop_owned "$cr_tmp" "$quc_fill_ino"
            return 10
        fi
        if [ -L "$cr_tmp" ] || [ ! -f "$cr_tmp" ]; then
            quc_error="временный файл подменён"
            return 2
        fi
        if [ -z "$quc_fill_ino" ]; then
            quc_error="временный файл подменён"
            return 2
        fi
        quc_publish_file "$cr_tmp" "$cr_dst" "$cr_hex" "$quc_fill_ino"
        cr_pub=$?
        if [ "$cr_pub" -ne 0 ]; then
            if [ "$cr_pub" -eq 11 ]; then
                return 11
            fi
            if ! quc_identity_still; then
                return 10
            fi
            return 2
        fi
        cr_pub_stat=$("$quc_bin_stat" -c '%d %s' -- "$cr_dst" 2>/dev/null || true)
        case $cr_pub_stat in
            *' '*) ;;
            *) cr_pub_stat= ;;
        esac
        cr_dev=${cr_pub_stat%% *}
        cr_final=${cr_pub_stat#* }
        if [ "$cr_dev" != "$quc_target_dev" ]; then
            quc_error="файл оказался не на файловой системе назначения и не удалён автоматически"
            quc_log ERROR "path=$(quc_display_path "$cr_rel") $quc_error"
            return 10
        fi
        if [ "$cr_final" != "$cr_size" ]; then
            quc_error="размер после переноса не совпал"
            return 2
        fi
        quc_apply_metadata "$cr_src" "$cr_dst"
        cr_fp_hex=$(quc_hex_encode "$cr_fp1")
        quc_append_meta F "$cr_hex" "$cr_size" "$cr_fp_hex" "$cr_hash" || return 2
        case $cr_size in
            ''|*[!0-9]*|0*)
                quc_bytes_done=$(quc_add_bytes "$quc_bytes_done" "$cr_size")
                ;;
            *)
                quc_bytes_done=$((quc_bytes_done + cr_size))
                ;;
        esac
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
    if [ "${quc_publish_mode:-}" = exclusive ]; then
        quc_copy_link_visible "$@"
        return $?
    fi
    if ! quc_identity_still; then
        return 10
    fi
    src=$1
    dst=$2
    rel=$3
    path_hex=$4
    target=$("$quc_bin_readlink" -- "$src" 2>/dev/null || true)
    if [ -z "$target" ] && [ ! -L "$src" ]; then
        return 2
    fi
    quc_set_parent "$rel"
    parent=$quc_parent
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
    quc_set_parent "$dst"
    tmp_dir=$quc_parent
    if ! quc_dest_dir_still "$tmp_dir"; then
        return 10
    fi
    tmp=$tmp_dir/$QUC_PARTIAL_PREFIX$$.link
    if ! quc_clear_partial_name "$tmp"; then
        quc_error="временное имя занято"
        return 2
    fi
    if ! "$quc_bin_ln" -s -- "$target" "$tmp" 2>"$(quc_scratch_file transfer.err)"; then
        quc_error="файловая система назначения не поддерживает символьные ссылки"
        quc_log ERROR "path=$(quc_display_path "$rel") $quc_error"
        return 4
    fi
    cl_ino=$("$quc_bin_stat" -c '%i' -- "$tmp" 2>/dev/null || true)
    if [ -z "$cl_ino" ] || [ ! -L "$tmp" ]; then
        quc_drop_owned "$tmp" "$cl_ino"
        quc_error="временное имя ссылки подменено"
        return 2
    fi
    quc_note_owned "$cl_ino"
    quc_publish_file "$tmp" "$dst" "$path_hex" "$cl_ino"
    cl_pub=$?
    if [ "$cl_pub" -ne 0 ]; then
        if [ "$cl_pub" -eq 11 ]; then
            return 11
        fi
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
            [ -f "$path" ] && [ ! -L "$path" ] || return 1
            [ -f "$dst" ] && [ ! -L "$dst" ] || return 1
            case $size in
                ''|*[!0-9]*) return 1 ;;
            esac
            nowsz=$(quc_file_size "$dst" || true)
            [ "$nowsz" = "$size" ] || return 1
            if [ -n "${quc_bin_cmp:-}" ]; then
                if "$quc_bin_cmp" -s -- "$path" "$dst"; then
                    return 0
                fi
                return 1
            fi
            if [ "$hash" != - ] && [ -n "$hash" ]; then
                nowh=$(quc_hash_file "$dst" || true)
                srch=$(quc_hash_file "$path" || true)
                if [ -n "$nowh" ] && [ "$nowh" = "$hash" ] && [ "$srch" = "$hash" ]; then
                    return 0
                fi
            fi
            return 1
            ;;
        *) return 1 ;;
    esac
}

quc_record_result() {
    rc=$1
    rel=$2
    case $rc in
        0)
            quc_files_done=$((quc_files_done + 1))
            ;;
        2)
            quc_files_failed=$((quc_files_failed + 1))
            quc_log ERROR "path=$(quc_display_path "$rel") ${quc_error:-ошибка копирования}"
            ;;
        3)
            quc_files_uncertain=$((quc_files_uncertain + 1))
            ;;
        4)
            quc_files_skipped=$((quc_files_skipped + 1))
            ;;
        11)
            quc_files_failed=$((quc_files_failed + 1))
            quc_log ERROR "path=$(quc_display_path "$rel") ${quc_error:-объект не заменён}"
            ;;
        10|20) return "$rc" ;;
        *)
            quc_files_failed=$((quc_files_failed + 1))
            ;;
    esac
    return 0
}

# Обрабатывает один путь плана: каталог, файл или отказ от уже сделанного.
# Принимает абсолютный путь источника. Меняет счётчики и kind после пропуска.
# Успех: 0, включая пропуск уже скопированного. Сигнал: 20.
# Отказ пропуска не записывается как успех: тип источника восстанавливается.
quc_handle_path() {
    path=$1
    hp_root=${quc_read_root:-$quc_source}
    hp_write=${quc_write_root:-$quc_target}
    case $path in
        "$hp_root") return 0 ;;
        "$hp_root"/*) ;;
        *)
            quc_log ERROR "пропущен неожиданный путь"
            return 0
            ;;
    esac
    prefix=$hp_root/
    rel=${path#"$prefix"}
    if [ -z "$rel" ]; then
        return 0
    fi
    dst=$hp_write/$rel
    path_hex=$(quc_hex_encode "$path")
    kind=
    hp_fp=
    hp_kind=
    if quc_stat_file "$path"; then
        if quc_kind_from_mode "$quc_stat_mode"; then
            kind=$quc_kind_out
            hp_kind=$quc_kind_out
        fi
        hp_fp=$quc_stat_fp
    fi
    if [ "$quc_run_mode" = resume ] && quc_should_skip_done "$path" "$dst" "$path_hex"; then
        quc_files_done=$((quc_files_done + 1))
        # Внутри skip нет local: kind там становится F, D или L.
        if [ "$hp_kind" = regular ]; then
            sz=${hp_fp%% *}
            case $sz in
                ''|*[!0-9]*|0*)
                    quc_bytes_done=$(quc_add_bytes "$quc_bytes_done" "${sz:-0}")
                    ;;
                *)
                    quc_bytes_done=$((quc_bytes_done + sz))
                    ;;
            esac
        fi
        return 0
    fi
    # Отказ от пропуска не есть успех. Возвращаем тип источника до case.
    kind=$hp_kind
    case $kind in
        dir) quc_copy_dir "$rel" "$path_hex" ;;
        regular) quc_copy_regular "$path" "$dst" "$rel" "$path_hex" "$hp_fp" ;;
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
    pause=${QUC_FILE_PAUSE:-0}
    case $pause in
        0) ;;
        *) pause=$(quc_pause_seconds QUC_FILE_PAUSE 0 60) ;;
    esac
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
        quc_spawn_child "$quc_bin_find" "$root" -xdev -print0 > "$nul" 2>"$(quc_scratch_file transfer.err)"
        quc_wait_pid "$quc_child_pid"
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
    quc_write_plan "$now" "${quc_read_root:-$quc_source}"
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
        quc_write_plan "$now" "${quc_read_root:-$quc_source}"
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
    cp_root=${quc_write_root:-$quc_target}
    cp_read=${quc_read_root:-$quc_source}
    "$quc_bin_find" "$cp_root" -xdev \( -type f -o -type l \) -name "${QUC_PARTIAL_PREFIX}*" -print 2>/dev/null | while IFS= read -r p; do
        if [ -L "$p" ]; then
            continue
        fi
        if [ ! -f "$p" ]; then
            continue
        fi
        rel=${p#"$cp_root"/}
        base=$(basename -- "$rel")
        case $base in
            ${QUC_PARTIAL_PREFIX}*) ;;
            *) continue ;;
        esac
        src_same=$cp_read/$rel
        if [ -e "$src_same" ] || [ -L "$src_same" ]; then
            continue
        fi
        cp_ino=$("$quc_bin_stat" -c '%i' -- "$p" 2>/dev/null || true)
        if quc_ino_listed "$cp_ino"; then
            quc_drop_owned "$p" "$cp_ino"
        fi
    done
    return 0
}

quc_dest_unexpected() {
    du_list=$(quc_scratch_file dest-scan.hex)
    du_root=${quc_write_root:-$quc_target}
    du_read=${quc_read_root:-$quc_source}
    quc_write_plan "$du_list" "$du_root"
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
        if [ "$du_path" = "$du_root" ]; then
            continue
        fi
        du_rel=${du_path#"$du_root"/}
        du_base=$(basename -- "$du_rel")
        case $du_base in
            ${QUC_PARTIAL_PREFIX}*) continue ;;
        esac
        if quc_mount_secret_ok && [ "$du_path" = "$du_root/.quc-mnt-$quc_mount_secret" ]; then
            if quc_mount_mark_matches "$du_path"; then
                continue
            fi
        fi
        du_src=$du_read/$du_rel
        if [ -e "$du_src" ] || [ -L "$du_src" ]; then
            continue
        fi
        quc_hex_encode "$du_path"
        printf '\n'
        return 0
    done < "$du_list"
    return 0
}

# --- Автоматическое отключение ---

# Есть ли ещё дочерние процессы этого shell.
# Аргументов нет. Не меняет состояние задания.
# Успех: 0, детей нет. Отказ: 1, детей нет возможности подтвердить или они есть.
# Пока дочерний процесс копирования жив, отключение не начинается.
quc_eject_children_clear() {
    ej_cf=/proc/$$/task/$$/children
    if [ ! -r "$ej_cf" ]; then
        return 1
    fi
    ej_kids=''
    IFS= read -r ej_kids < "$ej_cf" || true
    if [ -n "$ej_kids" ]; then
        return 1
    fi
    return 0
}

# Ищет udisksctl и неинтерактивный режим. Не вызывает само отключение.
# Успех: 0, quc_bin_udisksctl задан. Отказ: 1, вызов делать нельзя.
# quc_ej_power_tool=1 только если у power-off есть тот же режим.
quc_eject_tool_ready() {
    quc_bin_udisksctl=$(command -v udisksctl 2>/dev/null || true)
    quc_ej_power_tool=0
    if [ -z "$quc_bin_udisksctl" ] || [ ! -x "$quc_bin_udisksctl" ]; then
        quc_bin_udisksctl=''
        return 1
    fi
    ej_help=$("$quc_bin_udisksctl" unmount --help 2>&1 || true)
    case $ej_help in
        *--no-user-interaction*) ;;
        *)
            quc_bin_udisksctl=''
            return 1
            ;;
    esac
    ej_help=$("$quc_bin_udisksctl" power-off --help 2>&1 || true)
    case $ej_help in
        *--no-user-interaction*) quc_ej_power_tool=1 ;;
    esac
    return 0
}

# 0: этот источник относится к тому же диску, что и quc_ej_block / ej_disk.
# Неразрешённый диск не считается совпадением.
quc_eject_same_disk() {
    ej_src=$1
    ej_disk=$2
    case $ej_src in
        /dev/*) ;;
        *) return 1 ;;
    esac
    if [ -n "${quc_ej_block:-}" ] && [ "$ej_src" = "$quc_ej_block" ]; then
        return 0
    fi
    ej_sd=$(quc_disk_name "$ej_src" 0) || return 1
    if [ -n "$ej_disk" ] && [ -n "$ej_sd" ] && [ "$ej_sd" = "$ej_disk" ]; then
        return 0
    fi
    return 1
}

# 0: блок или его диск держит корень системы или другой обязательный путь.
quc_eject_is_system() {
    ej_block=$1
    ej_disk=$2
    for ej_path in / /home /boot /usr /var /tmp; do
        if [ ! -d "$ej_path" ]; then
            continue
        fi
        if ! quc_mountinfo_lookup "$ej_path"; then
            continue
        fi
        if [ "$quc_mi_source" = "$ej_block" ]; then
            return 0
        fi
        if quc_eject_same_disk "$quc_mi_source" "$ej_disk"; then
            return 0
        fi
    done
    return 1
}

# 0: у того же диска есть другая используемая точка.
quc_eject_foreign_live() {
    ej_disk=$1
    ej_target=$2
    ej_file=${TMPDIR:-/tmp}/quc-ejrows.$$
    "$quc_bin_awk" '
        function unesc(s,    out, i, n, c, o, v) {
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
            return out
        }
        {
            src = ""
            for (i = 1; i <= NF; i++) if ($i == "-") { src = $(i + 2); break }
            if (src == "") next
            printf "%s\t%s\n", unesc($5), unesc(src)
        }
    ' /proc/self/mountinfo > "$ej_file" || {
        "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
        return 0
    }
    ej_tab=$(printf '\t')
    ej_found=1
    while IFS=$ej_tab read -r ej_mp ej_src; do
        [ -n "$ej_mp" ] || continue
        if [ "$ej_mp" = "$ej_target" ]; then
            continue
        fi
        if quc_eject_same_disk "$ej_src" "$ej_disk"; then
            ej_found=0
            break
        fi
    done < "$ej_file"
    "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
    return "$ej_found"
}

# 0: соседние LUN и держатели не мешают снятию питания. Иначе питание не трогаем.
# Список устройств пишется в файл и читается построчно, без накопления в переменной.
quc_eject_power_clear() {
    ej_disk=$1
    if [ -z "$ej_disk" ]; then
        return 1
    fi
    ej_file=${TMPDIR:-/tmp}/quc-ejlun.$$
    ej_hold=/sys/class/block/$ej_disk/holders
    if [ -d "$ej_hold" ]; then
        "$quc_bin_find" "$ej_hold" -mindepth 1 -maxdepth 1 -print > "$ej_file" 2>/dev/null
        ej_rc=$?
        if [ "$ej_rc" -ne 0 ]; then
            "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
            return 1
        fi
        if [ -s "$ej_file" ]; then
            "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
            return 1
        fi
    fi
    ej_link=/sys/class/block/$ej_disk/device
    if [ ! -L "$ej_link" ]; then
        "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
        return 1
    fi
    ej_real=$("$quc_bin_readlink" -f -- "$ej_link" 2>/dev/null || true)
    if [ -z "$ej_real" ]; then
        "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
        return 1
    fi
    ej_parent=$("$quc_bin_dirname" -- "$ej_real")
    ej_scope=$("$quc_bin_dirname" -- "$ej_parent")
    ej_base=$("$quc_bin_basename" -- "$ej_real")
    "$quc_bin_find" /sys/class/block -mindepth 2 -maxdepth 2 -name device -type l -print > "$ej_file" 2>/dev/null
    ej_rc=$?
    if [ "$ej_rc" -ne 0 ] || [ ! -s "$ej_file" ]; then
        "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
        return 1
    fi
    # 0 — соседнего LUN нет, питание можно рассматривать. 1 — есть другой LUN.
    ej_blocked=0
    while IFS= read -r ej_dev; do
        [ -n "$ej_dev" ] || continue
        ej_got=$("$quc_bin_readlink" -f -- "$ej_dev" 2>/dev/null || true)
        case $ej_got in
            "$ej_scope"/*)
                ej_bn=$("$quc_bin_basename" -- "$ej_got")
                if [ "$ej_bn" != "$ej_base" ]; then
                    ej_blocked=1
                    break
                fi
                ;;
        esac
    done < "$ej_file"
    "$quc_bin_rm" -f -- "$ej_file" 2>/dev/null || true
    if [ "$ej_blocked" = 1 ]; then
        return 1
    fi
    return 0
}

# Собирает факты о назначении. Не вызывает udisksctl.
# Успех: 0 и quc_ej_mount_ok=1. Отказ: 1, отключение делать нельзя.
# Не меняет copy_status. Питание разрешено только при quc_ej_power_ok=1.
quc_eject_gather() {
    quc_ej_block=''
    quc_ej_disk=''
    quc_ej_mount_ok=0
    quc_ej_power_ok=0
    if ! quc_mountinfo_lookup "$quc_target"; then
        return 1
    fi
    ej_src=$quc_mi_source
    ej_id=$quc_mi_id
    if [ -n "${quc_target_mntid:-}" ] && [ "$ej_id" != "$quc_target_mntid" ]; then
        return 1
    fi
    ej_dev=$(quc_dev_of "$quc_target" || true)
    if [ -z "$ej_dev" ] || [ "$ej_dev" != "${quc_target_dev:-}" ]; then
        return 1
    fi
    if [ -n "${quc_target_uuid:-}" ]; then
        ej_u=$(quc_uuid_of "$quc_target" || true)
        if [ "$ej_u" != "$quc_target_uuid" ]; then
            return 1
        fi
    fi
    case $ej_src in
        /dev/*) ;;
        *) return 1 ;;
    esac
    if [ -n "${quc_target_spec:-}" ] && [ "$quc_target_spec" != "$ej_src" ]; then
        return 1
    fi
    if [ -n "${quc_source_spec:-}" ] && [ "$ej_src" = "$quc_source_spec" ]; then
        return 1
    fi
    quc_ej_block=$ej_src
    quc_ej_disk=$(quc_disk_name "$quc_ej_block" 0) || quc_ej_disk=''
    if [ -z "$quc_ej_disk" ]; then
        quc_ej_block=''
        return 1
    fi
    if quc_eject_is_system "$quc_ej_block" "$quc_ej_disk"; then
        quc_ej_block=''
        return 1
    fi
    if quc_mountinfo_lookup "$quc_source"; then
        if quc_eject_same_disk "$quc_mi_source" "$quc_ej_disk"; then
            quc_ej_block=''
            return 1
        fi
    fi
    if ! quc_mountinfo_lookup "$quc_target"; then
        quc_ej_block=''
        return 1
    fi
    if [ "$quc_mi_source" != "$quc_ej_block" ]; then
        quc_ej_block=''
        return 1
    fi
    if quc_eject_foreign_live "$quc_ej_disk" "$quc_target"; then
        quc_ej_block=''
        return 1
    fi
    if [ "${quc_ej_power_tool:-0}" = 1 ] && quc_eject_power_clear "$quc_ej_disk"; then
        quc_ej_power_ok=1
    fi
    quc_ej_mount_ok=1
    return 0
}

# Вызывает штатное отключение. Требует quc_ej_mount_ok=1 и уже проверенный блок.
# Меняет только quc_eject_status. Успех функции: 0.
# Не использует принудительный режим и не трогает источник.
quc_eject_run() {
    if [ "${quc_ej_mount_ok:-0}" != 1 ] || [ -z "${quc_ej_block:-}" ]; then
        quc_eject_status=skipped_policy
        return 0
    fi
    case $quc_ej_block in
        /dev/*) ;;
        *)
            quc_eject_status=skipped_policy
            return 0
            ;;
    esac
    if [ -n "${quc_source_spec:-}" ] && [ "$quc_ej_block" = "$quc_source_spec" ]; then
        quc_eject_status=skipped_policy
        return 0
    fi
    if quc_eject_is_system "$quc_ej_block" "${quc_ej_disk:-}"; then
        quc_eject_status=skipped_policy
        return 0
    fi
    if [ -z "${quc_bin_udisksctl:-}" ]; then
        quc_eject_status=unavailable
        return 0
    fi
    ej_cap=${TMPDIR:-/tmp}/quc-ejcap.$$
    : > "$ej_cap" || ej_cap=''
    if [ -n "$ej_cap" ]; then
        "$quc_bin_udisksctl" unmount -b "$quc_ej_block" --no-user-interaction >"$ej_cap" 2>&1
    else
        "$quc_bin_udisksctl" unmount -b "$quc_ej_block" --no-user-interaction >/dev/null 2>&1
    fi
    ej_rc=$?
    if quc_mountinfo_lookup "$quc_target"; then
        ej_still=1
    else
        ej_still=0
    fi
    if [ "$ej_rc" -ne 0 ] && [ "$ej_still" = 1 ]; then
        quc_eject_status=refused
    elif [ "$ej_rc" -ne 0 ] || [ "$ej_still" = 1 ]; then
        quc_eject_status=unknown
    else
        quc_eject_status=unmounted
        if [ "${quc_ej_power_ok:-0}" = 1 ] && [ -n "${quc_ej_disk:-}" ] && [ -e "/dev/$quc_ej_disk" ] \
            && ! quc_eject_is_system "$quc_ej_block" "$quc_ej_disk" \
            && ! quc_eject_foreign_live "$quc_ej_disk" "$quc_target" \
            && quc_eject_power_clear "$quc_ej_disk"; then
            if [ -n "$ej_cap" ]; then
                "$quc_bin_udisksctl" power-off -b "/dev/$quc_ej_disk" --no-user-interaction >"$ej_cap" 2>&1
            else
                "$quc_bin_udisksctl" power-off -b "/dev/$quc_ej_disk" --no-user-interaction >/dev/null 2>&1
            fi
            ej_rc=$?
            if [ "$ej_rc" -eq 0 ]; then
                if [ ! -e "/dev/$quc_ej_disk" ]; then
                    quc_eject_status=power_off
                else
                    "$quc_bin_udisksctl" info -b "/dev/$quc_ej_disk" >"${ej_cap:-/dev/null}" 2>&1
                    ej_rc=$?
                    if [ "$ej_rc" -ne 0 ]; then
                        quc_eject_status=power_off
                    fi
                fi
            fi
        fi
    fi
    if [ -n "$ej_cap" ]; then
        "$quc_bin_rm" -f -- "$ej_cap" 2>/dev/null || true
    fi
    quc_log INFO "eject_status=$quc_eject_status"
    return 0
}

# Сверяет уже опубликованные имена с источником. Не публикует и не удаляет.
# Ставит verify_status=checksum или byte только после чтения конечных файлов.
# size и none сюда не записываются. Смена источника даёт uncertain.
# Успех: 0, если проверка дошла до итога. Сигнал: 20.
quc_verify_published() {
    quc_verify_bad=0
    quc_verify_uncertain=0
    quc_verify_rows=0
    vp_tool_dead=0
    vp_root=${quc_read_root:-$quc_source}
    vp_write=${quc_write_root:-$quc_target}
    vp_real=$("$quc_bin_readlink" -f -- "$vp_write" 2>/dev/null || true)
    vp_src_real=$("$quc_bin_readlink" -f -- "$vp_root" 2>/dev/null || true)
    if [ -z "$vp_real" ] || [ -L "$vp_write" ] || [ ! -d "$vp_write" ]; then
        quc_verify_status=failed
        quc_verify_tool=${quc_verify_tool:-}
        quc_error="каталог назначения не подтверждён перед проверкой содержимого"
        return 0
    fi
    if [ -z "$vp_src_real" ] || [ -L "$vp_root" ] || [ ! -d "$vp_root" ]; then
        quc_verify_status=uncertain
        quc_tree_changed=1
        quc_error="источник изменился во время проверки содержимого"
        return 0
    fi
    if ! quc_hash_tool; then
        if [ -z "${quc_bin_cmp:-}" ]; then
            quc_verify_tool=unavailable
            quc_verify_status=none
            quc_log INFO "проверка содержимого недоступна: нет суммы и нет cmp"
            return 0
        fi
        quc_verify_tool='cmp'
        vp_method=byte
    else
        quc_verify_tool=$quc_hash_name
        vp_method=checksum
    fi
    if [ ! -f "${quc_meta_file:-}" ]; then
        quc_verify_status=failed
        quc_error="список опубликованных файлов отсутствует"
        quc_log INFO "content-verify status=failed tool=$quc_verify_tool"
        return 0
    fi
    vp_tab=$(printf '\t')
    while IFS= read -r vp_line || [ -n "$vp_line" ]; do
        [ -n "$vp_line" ] || continue
        if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
            quc_stop_requested=1
            return 20
        fi
        vp_kind=${vp_line%%"${vp_tab}"*}
        vp_rest=${vp_line#*"${vp_tab}"}
        vp_hex=${vp_rest%%"${vp_tab}"*}
        vp_rest=${vp_rest#*"${vp_tab}"}
        vp_size=${vp_rest%%"${vp_tab}"*}
        vp_rest=${vp_rest#*"${vp_tab}"}
        vp_fphex=${vp_rest%%"${vp_tab}"*}
        case $vp_kind in
            F|L|D) ;;
            *) continue ;;
        esac
        if [ -z "$vp_hex" ] || ! quc_decode_hex_var "$vp_hex"; then
            quc_verify_bad=1
            continue
        fi
        vp_src=$quc_decoded
        case $vp_src in
            "$vp_root") continue ;;
            "$vp_root"/*) ;;
            *)
                quc_verify_bad=1
                continue
                ;;
        esac
        vp_rel=${vp_src#"$vp_root/"}
        case $vp_rel in
            ''|..|../*|*/..|*/../*)
                quc_verify_bad=1
                continue
                ;;
        esac
        quc_verify_rows=$((quc_verify_rows + 1))
        vp_dst=$vp_write/$vp_rel
        if [ "$vp_kind" != L ] && [ -L "$vp_src" ]; then
            quc_verify_uncertain=1
            quc_log INFO "path=$(quc_display_path "$vp_rel") источник сменил вид во время проверки"
            continue
        fi
        if [ "$vp_kind" != L ] && [ -L "$vp_dst" ]; then
            quc_verify_bad=1
            quc_log ERROR "path=$(quc_display_path "$vp_rel") опубликованное имя стало ссылкой"
            continue
        fi
        if [ "$vp_kind" = L ]; then
            quc_set_parent "$vp_dst"
            vp_parent=$quc_parent
            vp_dst_real=$("$quc_bin_readlink" -f -- "$vp_parent" 2>/dev/null || true)
        else
            vp_dst_real=$("$quc_bin_readlink" -f -- "$vp_dst" 2>/dev/null || true)
        fi
        case $vp_dst_real in
            "$vp_real"|"$vp_real"/*) ;;
            *)
                quc_verify_bad=1
                quc_log ERROR "path=$(quc_display_path "$vp_rel") объект вне каталога назначения"
                continue
                ;;
        esac
        case $vp_kind in
            D)
                if [ ! -d "$vp_dst" ]; then
                    quc_verify_bad=1
                fi
                ;;
            L)
                if [ ! -L "$vp_src" ]; then
                    quc_verify_uncertain=1
                elif [ ! -L "$vp_dst" ]; then
                    quc_verify_bad=1
                else
                    vp_a=$("$quc_bin_readlink" -- "$vp_src" 2>/dev/null || true)
                    vp_b=$("$quc_bin_readlink" -- "$vp_dst" 2>/dev/null || true)
                    if [ -z "$vp_a" ] || [ "$vp_a" != "$vp_b" ]; then
                        quc_verify_bad=1
                    fi
                fi
                ;;
            F)
                if [ ! -f "$vp_src" ]; then
                    quc_verify_uncertain=1
                    continue
                fi
                if [ ! -f "$vp_dst" ]; then
                    quc_verify_bad=1
                    continue
                fi
                vp_fp1=$(quc_fingerprint "$vp_src" || true)
                vp_fphex_now=$(quc_hex_encode "$vp_fp1")
                if [ -z "$vp_fp1" ] || [ -z "$vp_fphex" ] || [ "$vp_fphex_now" != "$vp_fphex" ]; then
                    quc_verify_uncertain=1
                    continue
                fi
                vp_dsize=$(quc_file_size "$vp_dst" || true)
                if [ "$vp_dsize" != "$vp_size" ]; then
                    quc_verify_bad=1
                    continue
                fi
                vp_same=0
                if [ "$vp_method" = byte ]; then
                    if "$quc_bin_cmp" -s -- "$vp_src" "$vp_dst"; then
                        vp_same=1
                    fi
                else
                    vp_h1=$(quc_hash_file "$vp_src" || true)
                    vp_h2=$(quc_hash_file "$vp_dst" || true)
                    vp_h3=$(quc_hash_file "$vp_src" || true)
                    if [ -n "$vp_h1" ] && [ "$vp_h1" = "$vp_h2" ] && [ "$vp_h1" = "$vp_h3" ]; then
                        vp_same=1
                    fi
                fi
                vp_fp2=$(quc_fingerprint "$vp_src" || true)
                if [ "$vp_fp1" != "$vp_fp2" ]; then
                    quc_verify_uncertain=1
                    continue
                fi
                if [ "$vp_method" != byte ]; then
                    if [ -z "$vp_h1" ] || [ -z "$vp_h2" ] || [ -z "$vp_h3" ]; then
                        quc_verify_tool=unavailable
                        vp_tool_dead=1
                        continue
                    fi
                    if [ "$vp_h1" != "$vp_h3" ]; then
                        quc_verify_uncertain=1
                        continue
                    fi
                fi
                if [ "$vp_same" != 1 ]; then
                    quc_verify_bad=1
                fi
                ;;
        esac
    done < "$quc_meta_file"
    if [ "$quc_verify_rows" = 0 ] && quc_cmp_num "${quc_files_done:-0}" 0 gt; then
        quc_verify_bad=1
    fi
    if [ "$quc_verify_uncertain" = 1 ]; then
        quc_verify_status=uncertain
        quc_tree_changed=1
        quc_error="источник изменился во время проверки содержимого"
        quc_log INFO "content-verify status=uncertain tool=$quc_verify_tool"
        return 0
    fi
    if [ "$vp_tool_dead" = 1 ]; then
        quc_verify_status=none
        quc_verify_tool=unavailable
        quc_log INFO "проверка содержимого недоступна: средство проверки не сработало"
        return 0
    fi
    if [ "$quc_verify_bad" = 1 ]; then
        quc_verify_status=failed
        quc_error="содержимое опубликованного файла не совпало"
        quc_log INFO "content-verify status=failed tool=$quc_verify_tool"
        return 0
    fi
    quc_verify_status=$vp_method
    quc_log INFO "content-verify status=$quc_verify_status tool=$quc_verify_tool rows=$quc_verify_rows"
    return 0
}

# Решает автоотключение назначения после COPY, VERIFY и SYNC.
# Аргументов нет. Меняет quc_eject_status. Файл состояния пишет вызывающий.
# Успех: 0 всегда. Отказ отключения не меняет copy_status и quc_error.
# size и none отключение не разрешают. SUCCESS не означает долговременную запись.
# Не отключает источник, не запрашивает пароль и не обходит отказ системы.
quc_auto_disconnect() {
    ej_err_saved=${quc_error:-}
    case ${quc_eject_status:-} in
        power_off|unmounted)
            quc_error=$ej_err_saved
            return 0
            ;;
    esac
    if [ "${quc_eject_policy:-no}" != yes ]; then
        quc_eject_status=skipped_policy
        quc_error=$ej_err_saved
        return 0
    fi
    if [ "${quc_copy_status:-}" != SUCCESS ]; then
        quc_eject_status=skipped_policy
        quc_error=$ej_err_saved
        return 0
    fi
    case ${quc_verify_status:-none} in
        checksum|byte) ;;
        *)
            quc_eject_status=skipped_policy
            quc_error=$ej_err_saved
            return 0
            ;;
    esac
    if [ "${quc_sync_status:-unconfirmed}" != command_ok ]; then
        quc_eject_status=skipped_policy
        quc_error=$ej_err_saved
        return 0
    fi
    if ! quc_eject_children_clear; then
        quc_eject_status=skipped_policy
        quc_error=$ej_err_saved
        return 0
    fi
    if ! quc_eject_tool_ready; then
        quc_eject_status=unavailable
        quc_error=$ej_err_saved
        return 0
    fi
    if ! quc_eject_gather; then
        quc_eject_status=skipped_policy
        quc_error=$ej_err_saved
        return 0
    fi
    quc_eject_run
    quc_error=$ej_err_saved
    return 0
}

# Ставит итог копирования, затем отдельно автоотключение, затем файл состояния.
# Принимает вид отказа и текст. Повторный вызов ничего не делает.
# Успех: 0. copy_status и eject_status остаются разными полями.
# Не уничтожает локальную копию и не считает отказ отключения провалом копирования.
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
    case ${quc_verify_status:-none} in
        checksum|byte)
            if quc_cmp_num "$quc_files_uncertain" 0 gt || [ "$quc_tree_changed" = 1 ]; then
                quc_verify_status=uncertain
            elif quc_cmp_num "$quc_files_failed" 0 gt || quc_cmp_num "$quc_files_skipped" 0 gt; then
                quc_verify_status=failed
            fi
            ;;
        failed|uncertain) ;;
        none)
            if [ "${quc_verify_tool:-}" = unavailable ]; then
                quc_verify_status=none
            else
                quc_verify_status=size
            fi
            ;;
    esac
    quc_copy_status=$(quc_decide_copy_status "$quc_fatal_kind" "$quc_files_done" "$quc_files_failed" "$quc_files_uncertain" "$quc_files_skipped" "$quc_tree_changed")
    if [ "$quc_copy_status" = SUCCESS ]; then
        if ! quc_mount_mark_release; then
            quc_fatal_kind=FAILED
            quc_copy_status=FAILED
        fi
    fi
    case $quc_copy_status in
        SUCCESS) quc_job_phase=COMPLETED ;;
        FAILED) quc_job_phase=FAILED ;;
        PARTIAL) quc_job_phase=PARTIAL ;;
        CANCELLED) quc_job_phase=CANCELLED ;;
        INTERRUPTED) quc_job_phase=INTERRUPTED ;;
        UNCERTAIN) quc_job_phase=UNCERTAIN ;;
    esac
    quc_ended=$(quc_now)
    quc_ended_epoch=$(quc_epoch)
    quc_phase='done'
    # Метка уже снята. Повторная проверка метки здесь всегда отказала бы.
    quc_auto_disconnect
    quc_save_state || true
    quc_log INFO "result copy_status=$quc_copy_status verify_status=$quc_verify_status sync_status=${quc_sync_status:-unconfirmed} eject_status=${quc_eject_status:-skipped_policy} done=$quc_files_done failed=$quc_files_failed uncertain=$quc_files_uncertain skipped=$quc_files_skipped"
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

quc_fold_name() {
    printf '%s' "$1" | "$quc_bin_tr" '[:upper:]' '[:lower:]'
}

quc_dest_component_ok() {
    case ${1:-} in
        ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

quc_dest_case_clash() {
    dc_parent=$1
    dc_name=$2
    dc_fold=$(quc_fold_name "$dc_name")
    dc_hit=$(
        "$quc_bin_find" "$dc_parent" -mindepth 1 -maxdepth 1 -print 2>/dev/null | while IFS= read -r dc_path; do
            dc_base=$("$quc_bin_basename" -- "$dc_path")
            if [ "$dc_base" = "$dc_name" ]; then
                continue
            fi
            dc_bf=$(quc_fold_name "$dc_base")
            if [ "$dc_bf" = "$dc_fold" ]; then
                printf '1\n'
                break
            fi
        done
    )
    [ "$dc_hit" = 1 ]
}

quc_pick_dest_rel() {
    pd_base=QUC-$quc_planned_id
    pd_n=0
    while [ "$pd_n" -le 5 ]; do
        if [ "$pd_n" -eq 0 ]; then
            pd_cand=$pd_base
        else
            pd_cand=$pd_base-$pd_n
        fi
        if quc_dest_component_ok "$pd_cand" && [ ! -e "$quc_target/$pd_cand" ] && [ ! -L "$quc_target/$pd_cand" ] && ! quc_dest_case_clash "$quc_target" "$pd_cand"; then
            quc_dest_rel=$pd_cand
            return 0
        fi
        pd_n=$((pd_n + 1))
    done
    quc_error="не удалось подобрать новый каталог назначения"
    return 1
}

quc_claim_dest_dir() {
    cd_name=$quc_dest_rel
    quc_dest_component_ok "$cd_name" || {
        quc_error="имя каталога назначения недопустимо"
        return 1
    }
    cd_path=$quc_target/$cd_name
    case $cd_path in
        "$quc_target"/*) ;;
        *)
            quc_error="каталог назначения вне выбранного носителя"
            return 1
            ;;
    esac
    if quc_dest_case_clash "$quc_target" "$cd_name"; then
        quc_error="имя каталога конфликтует без учёта регистра"
        return 1
    fi
    if [ -L "$cd_path" ]; then
        quc_error="путь нового каталога является символьной ссылкой"
        return 1
    fi
    if [ -d "$cd_path" ]; then
        if [ "$quc_run_mode" != resume ]; then
            quc_error="каталог назначения уже существует и не принят как свой"
            return 1
        fi
        cd_dev=$(quc_dev_of "$cd_path" || true)
        if [ "$cd_dev" != "$quc_target_dev" ]; then
            quc_error="сохранённый каталог оказался на другой файловой системе"
            return 1
        fi
        quc_write_root=$cd_path
        return 0
    fi
    if [ -e "$cd_path" ]; then
        quc_error="на месте каталога назначения уже есть файл"
        return 1
    fi
    if ! "$quc_bin_mkdir" -- "$cd_path"; then
        quc_error="не удалось создать каталог назначения"
        return 1
    fi
    if [ -L "$cd_path" ] || [ ! -d "$cd_path" ]; then
        quc_error="каталог назначения создан неверно"
        return 1
    fi
    cd_dev=$(quc_dev_of "$cd_path" || true)
    if [ "$cd_dev" != "$quc_target_dev" ]; then
        "$quc_bin_rmdir" -- "$cd_path" 2>/dev/null || true
        quc_error="каталог назначения оказался на другой файловой системе"
        return 1
    fi
    quc_write_root=$cd_path
    return 0
}

quc_bind_roots() {
    if quc_source_detached; then
        quc_read_root=$quc_stage_dir/data
    else
        quc_read_root=$quc_source
    fi
    if [ "${quc_dest_mode:-root}" = separate ]; then
        if [ -z "$quc_dest_rel" ]; then
            quc_error="не записан каталог отдельного размещения"
            return 1
        fi
        quc_write_root=$quc_target/$quc_dest_rel
    else
        quc_write_root=$quc_target
    fi
    case $quc_write_root in
        "$quc_target"|"$quc_target"/*) ;;
        *)
            quc_error="каталог записи вне назначения"
            return 1
            ;;
    esac
    if [ -L "$quc_write_root" ]; then
        quc_error="каталог записи является символьной ссылкой"
        return 1
    fi
    if [ "${quc_dest_mode:-root}" = separate ] && [ ! -d "$quc_write_root" ]; then
        quc_error="каталог отдельного размещения отсутствует"
        return 1
    fi
    return 0
}

# --- Локальная копия STAGED ---

quc_stage_root() {
    sr_base=${XDG_DATA_HOME:-$HOME/.local/share}
    case $sr_base in
        /*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$sr_base/quiet-usb-copy/staging"
}

quc_enclosing_fstype() {
    ef_path=$1
    ef_guard=0
    while [ -n "$ef_path" ]; do
        ef_guard=$((ef_guard + 1))
        if [ "$ef_guard" -gt 64 ]; then
            return 1
        fi
        if quc_mountinfo_lookup "$ef_path"; then
            printf '%s\n' "$quc_mi_fstype"
            return 0
        fi
        if [ "$ef_path" = / ]; then
            return 1
        fi
        ef_path=$("$quc_bin_dirname" -- "$ef_path")
    done
    return 1
}

quc_stage_marker_ok() {
    sm_dir=$1
    sm_uid=$2
    [ -d "$sm_dir" ] && [ ! -L "$sm_dir" ] || return 1
    [ -f "$sm_dir/OWNER" ] && [ ! -L "$sm_dir/OWNER" ] || return 1
    sm_job=$(
        "$quc_bin_awk" -F= '$1 == "job_id" { print substr($0, index($0, "=") + 1); exit }' "$sm_dir/OWNER" 2>/dev/null || true
    )
    sm_uid_file=$(
        "$quc_bin_awk" -F= '$1 == "uid" { print substr($0, index($0, "=") + 1); exit }' "$sm_dir/OWNER" 2>/dev/null || true
    )
    sm_base=$("$quc_bin_basename" -- "$sm_dir")
    [ "$sm_job" = "$quc_job_id" ] && [ "$sm_job" = "$sm_base" ] || return 1
    [ -n "$sm_uid" ] && [ "$sm_uid_file" = "$sm_uid" ] || return 1
    return 0
}

quc_stage_wipe_data() {
    wd=$1
    for wd_name in data manifest manifest.body; do
        wd_path=$wd/$wd_name
        if [ -L "$wd_path" ]; then
            quc_error="в локальной копии неожиданная ссылка"
            return 1
        fi
        if [ -e "$wd_path" ]; then
            "$quc_bin_rm" -rf -- "$wd_path" || return 1
        fi
    done
    return 0
}

quc_stage_prepare_dir() {
    sr=$(quc_stage_root) || {
        quc_error="каталог локальной копии не определён"
        return 1
    }
    if [ -L "$sr" ]; then
        quc_error="каталог локальной копии является символьной ссылкой"
        return 1
    fi
    if [ ! -d "$sr" ]; then
        "$quc_bin_mkdir" -p -- "$sr" || {
            quc_error="не удалось создать каталог локальной копии"
            return 1
        }
    fi
    "$quc_bin_chmod" 700 -- "$sr" || return 1
    if [ -L "$sr" ] || [ ! -d "$sr" ]; then
        quc_error="каталог локальной копии недоступен"
        return 1
    fi
    su=$("$quc_bin_stat" -c '%u' -- "$quc_state_dir" 2>/dev/null || true)
    uu=$("$quc_bin_stat" -c '%u' -- "$sr" 2>/dev/null || true)
    if [ -z "$su" ] || [ "$su" != "$uu" ]; then
        quc_error="каталог локальной копии принадлежит не текущему пользователю"
        return 1
    fi
    if quc_paths_nested "$sr" "$quc_source" || quc_paths_nested "$sr" "$quc_target" || quc_paths_nested "$quc_source" "$sr" || quc_paths_nested "$quc_target" "$sr"; then
        quc_error="локальная копия пересекается с источником или назначением"
        return 1
    fi
    sd=$(quc_dev_of "$sr" || true)
    if [ -z "$sd" ] || [ "$sd" = "$quc_source_dev" ] || [ "$sd" = "$quc_target_dev" ]; then
        quc_error="локальная копия не должна лежать на источнике или назначении"
        return 1
    fi
    ft=$(quc_enclosing_fstype "$sr" || true)
    need=$(quc_tree_bytes "$quc_source") || {
        quc_error="не удалось определить объём источника"
        return 1
    }
    if [ "$ft" = tmpfs ] || [ "$ft" = devtmpfs ]; then
        if quc_cmp_num "$need" 33554432 gt; then
            quc_error="большой объём не копируется в tmpfs"
            return 1
        fi
        quc_log INFO "локальная копия небольшого дерева размещена во временной файловой системе"
    fi
    have=$(quc_free_bytes "$sr" || true)
    if [ -z "$have" ]; then
        quc_error="не удалось определить свободное место для локальной копии"
        return 1
    fi
    sf_list=$(quc_scratch_file stage-files)
    if ! "$quc_bin_find" "$quc_source" -xdev -type f -print > "$sf_list"; then
        quc_error="не удалось оценить число файлов источника"
        return 1
    fi
    nfiles=$("$quc_bin_awk" 'END { printf "%.0f", NR + 0 }' "$sf_list")
    ok=$(LC_ALL=C awk -v need="$need" -v have="$have" -v nfiles="$nfiles" 'BEGIN {
        need = need + 0
        have = have + 0
        nfiles = nfiles + 0
        extra = need * 0.1
        if (extra < 1048576) extra = 1048576
        reserve = nfiles * 4096
        if (have >= need + extra + reserve) print "yes"; else print "no"
    }')
    if [ "$ok" != yes ]; then
        quc_error="недостаточно места для локальной копии"
        return 1
    fi
    jd=$sr/$quc_job_id
    if [ -L "$jd" ]; then
        quc_error="чужой каталог локальной копии"
        return 1
    fi
    if [ -e "$jd" ]; then
        if ! quc_stage_marker_ok "$jd" "$uu"; then
            quc_error="чужой каталог локальной копии"
            return 1
        fi
        quc_stage_wipe_data "$jd" || return 1
    else
        "$quc_bin_mkdir" -- "$jd" || {
            quc_error="не удалось создать каталог задания локальной копии"
            return 1
        }
        "$quc_bin_chmod" 700 -- "$jd" || return 1
    fi
    if [ -L "$jd" ] || [ ! -d "$jd" ]; then
        quc_error="каталог задания локальной копии недоступен"
        return 1
    fi
    {
        printf 'job_id=%s\n' "$quc_job_id"
        printf 'uid=%s\n' "$uu"
        printf 'token=%s\n' "$quc_token"
    } > "$jd/OWNER" || return 1
    quc_stage_dir=$jd
    quc_stage_dev=$sd
    "$quc_bin_mkdir" -- "$jd/data" || return 1
    "$quc_bin_chmod" 700 -- "$jd/data" || return 1
    return 0
}

quc_stage_mkdir_rel() {
    sm_rel=$1
    sm_dest=$quc_stage_dir/data
    sm_rest=$sm_rel
    sm_n=0
    while [ -n "$sm_rest" ]; do
        sm_n=$((sm_n + 1))
        if [ "$sm_n" -gt 512 ]; then
            quc_error="слишком глубокий путь локальной копии"
            return 1
        fi
        sm_part=${sm_rest%%/*}
        case $sm_rest in
            */*) sm_rest=${sm_rest#*/} ;;
            *) sm_rest='' ;;
        esac
        if [ -z "$sm_part" ] || [ "$sm_part" = . ] || [ "$sm_part" = .. ]; then
            quc_error="недопустимое имя в локальной копии"
            return 1
        fi
        sm_dest=$sm_dest/$sm_part
        case $sm_dest in
            "$quc_stage_dir/data"/*) ;;
            *)
                quc_error="локальная копия вышла за свой каталог"
                return 1
                ;;
        esac
        if [ -d "$sm_dest" ] && [ ! -L "$sm_dest" ]; then
            continue
        fi
        if [ -e "$sm_dest" ] || [ -L "$sm_dest" ]; then
            quc_error="в локальной копии неожиданный объект"
            return 1
        fi
        "$quc_bin_mkdir" -- "$sm_dest" || return 1
        sm_dev=$(quc_dev_of "$sm_dest" || true)
        if [ -z "$sm_dev" ] || [ "$sm_dev" != "$quc_stage_dev" ]; then
            "$quc_bin_rmdir" -- "$sm_dest" 2>/dev/null || true
            quc_error="локальная копия оказалась на другой файловой системе"
            return 1
        fi
    done
    return 0
}

quc_stage_hash_for() {
    sh_rel=$1
    sh_hex=$(quc_hex_encode "$sh_rel")
    [ -n "$sh_hex" ] || return 1
    [ -f "$quc_stage_dir/manifest" ] || return 1
    # Имя вроде a.txt даёт hex 612e747874. Символ «.» — это байт 2e, и awk
    # читает такую строку как число. $2 == h тогда совпадает с другим именем.
    "$quc_bin_awk" -F '\t' -v h="$sh_hex" '$1 == "F" && (("x" $2) == ("x" h)) { printf "%s\n", $4; found = 1; exit } END { exit found ? 0 : 1 }' "$quc_stage_dir/manifest"
}

quc_stage_count_specials() {
    sc_n=0
    if [ -f "$quc_stage_dir/manifest" ]; then
        sc_n=$("$quc_bin_awk" -F '\t' '$1 == "S" { c++ } END { printf "%.0f", c + 0 }' "$quc_stage_dir/manifest")
    fi
    if quc_cmp_num "$sc_n" 0 gt; then
        quc_files_skipped=$(quc_add_bytes "$quc_files_skipped" "$sc_n")
        quc_error="специальный файл не копируется"
        quc_log ERROR "специальные объекты есть в описании локальной копии и не переносятся"
    fi
}

quc_stage_identity() {
    [ -n "${quc_stage_dir:-}" ] || {
        quc_error="нет каталога локальной копии"
        return 1
    }
    if [ ! -d "$quc_stage_dir" ] || [ -L "$quc_stage_dir" ]; then
        quc_error="локальная копия недоступна"
        return 1
    fi
    si_uid=$("$quc_bin_stat" -c '%u' -- "$quc_state_dir" 2>/dev/null || true)
    quc_stage_marker_ok "$quc_stage_dir" "$si_uid" || {
        quc_error="локальная копия не принадлежит этому заданию"
        return 1
    }
    si_dev=$(quc_dev_of "$quc_stage_dir" || true)
    if [ -z "$si_dev" ] || [ "$si_dev" != "$quc_stage_dev" ]; then
        quc_error="устройство локальной копии изменилось"
        return 1
    fi
    if [ ! -f "$quc_stage_dir/manifest" ] || [ -L "$quc_stage_dir/manifest" ]; then
        quc_error="описание локальной копии отсутствует"
        return 1
    fi
    if [ ! -d "$quc_stage_dir/data" ] || [ -L "$quc_stage_dir/data" ]; then
        quc_error="данные локальной копии отсутствуют"
        return 1
    fi
    if ! quc_hash_tool; then
        quc_error="нет средства проверки локальной копии"
        return 1
    fi
    si_hash=$(quc_hash_file "$quc_stage_dir/manifest" || true)
    if [ -z "$si_hash" ] || [ "$si_hash" != "$quc_stage_manifest" ]; then
        quc_error="описание локальной копии не совпало"
        return 1
    fi
    return 0
}

quc_stage_verify_stored() {
    quc_stage_identity || return 1
    sv_bad=0
    while IFS= read -r sv_line || [ -n "$sv_line" ]; do
        case $sv_line in
            QUC_MANIFEST*|job_id=*|hash_tool=*|records=*) continue ;;
            F*) ;;
            D*|L*|S*) ;;
            '') continue ;;
            *) sv_bad=1; break ;;
        esac
        sv_kind=$(printf '%s\n' "$sv_line" | "$quc_bin_awk" -F '\t' '{ print $1; exit }')
        sv_hex=$(printf '%s\n' "$sv_line" | "$quc_bin_awk" -F '\t' '{ print $2; exit }')
        quc_decode_hex_var "$sv_hex" || {
            sv_bad=1
            break
        }
        sv_rel=$quc_decoded
        case $sv_rel in
            ''|..|../*|*/..|*/../*) sv_bad=1; break ;;
        esac
        sv_path=$quc_stage_dir/data/$sv_rel
        case $sv_path in
            "$quc_stage_dir/data"/*) ;;
            *) sv_bad=1; break ;;
        esac
        case $sv_kind in
            D)
                [ -d "$sv_path" ] && [ ! -L "$sv_path" ] || sv_bad=1
                ;;
            L)
                sv_th=$(printf '%s\n' "$sv_line" | "$quc_bin_awk" -F '\t' '{ print $3; exit }')
                quc_decode_hex_var "$sv_th" || sv_bad=1
                sv_target=$quc_decoded
                [ -L "$sv_path" ] || sv_bad=1
                sv_got=$("$quc_bin_readlink" -- "$sv_path" 2>/dev/null || true)
                [ "$sv_got" = "$sv_target" ] || sv_bad=1
                ;;
            F)
                sv_size=$(printf '%s\n' "$sv_line" | "$quc_bin_awk" -F '\t' '{ print $3; exit }')
                sv_hash=$(printf '%s\n' "$sv_line" | "$quc_bin_awk" -F '\t' '{ print $4; exit }')
                [ -f "$sv_path" ] && [ ! -L "$sv_path" ] || sv_bad=1
                sv_now=$("$quc_bin_stat" -c '%s' -- "$sv_path" 2>/dev/null || true)
                [ "$sv_now" = "$sv_size" ] || sv_bad=1
                sv_got=$(quc_hash_file "$sv_path" || true)
                [ -n "$sv_got" ] && [ "$sv_got" = "$sv_hash" ] || sv_bad=1
                ;;
            S) ;;
        esac
        if [ "$sv_bad" -ne 0 ]; then
            break
        fi
    done < "$quc_stage_dir/manifest"
    if [ "$sv_bad" -ne 0 ]; then
        quc_error="локальная копия повреждена"
        return 1
    fi
    sv_extra=$(quc_scratch_file stage-verify.hex)
    if ! quc_write_plan "$sv_extra" "$quc_stage_dir/data"; then
        quc_error="не удалось прочитать локальную копию"
        return 1
    fi
    while IFS= read -r sv_hex || [ -n "$sv_hex" ]; do
        [ -n "$sv_hex" ] || continue
        if ! quc_decode_hex_var "$sv_hex"; then
            quc_error="локальная копия повреждена"
            return 1
        fi
        sv_path=$quc_decoded
        if [ "$sv_path" = "$quc_stage_dir/data" ]; then
            continue
        fi
        case $sv_path in
            "$quc_stage_dir/data"/*) ;;
            *)
                quc_error="локальная копия вышла за свой каталог"
                return 1
                ;;
        esac
        sv_rel=${sv_path#"$quc_stage_dir/data"/}
        sv_rel_hex=$(quc_hex_encode "$sv_rel")
        sv_hit=$("$quc_bin_awk" -F '\t' -v h="$sv_rel_hex" '(("x" $2) == ("x" h)) && ($1 == "F" || $1 == "D" || $1 == "L") { print "yes"; exit }' "$quc_stage_dir/manifest")
        if [ "$sv_hit" != yes ]; then
            quc_error="в локальной копии есть лишний объект"
            return 1
        fi
    done < "$sv_extra"
    return 0
}

quc_stage_copy_tree() {
    if ! quc_hash_tool; then
        quc_stage_status=failed
        quc_error="нет средства проверки содержимого, локальная копия не фиксируется"
        return 1
    fi
    quc_stage_tool=$quc_hash_name
    quc_job_phase=STAGING
    quc_stage_status=preparing
    quc_save_state || return 1
    st_plan=$(quc_scratch_file stage-plan.hex)
    quc_write_plan "$st_plan" "$quc_source"
    st_rc=$?
    if [ "$st_rc" -ne 0 ]; then
        quc_stage_status=failed
        return "$st_rc"
    fi
    st_body=$quc_stage_dir/manifest.body
    : > "$st_body" || return 1
    while IFS= read -r st_hex || [ -n "$st_hex" ]; do
        [ -n "$st_hex" ] || continue
        if [ -f "$quc_job_dir/stop-requested" ] || [ "${quc_stop_requested:-0}" = 1 ]; then
            quc_stop_requested=1
            quc_stage_status=failed
            return 20
        fi
        if ! quc_identity_still; then
            quc_stage_status=failed
            quc_error="источник пропал до готовности локальной копии"
            return 1
        fi
        if ! quc_decode_hex_var "$st_hex"; then
            quc_stage_status=failed
            return 1
        fi
        st_path=$quc_decoded
        if [ "$st_path" = "$quc_source" ]; then
            continue
        fi
        case $st_path in
            "$quc_source"/*) ;;
            *)
                quc_stage_status=failed
                quc_error="неожиданный путь источника"
                return 1
                ;;
        esac
        st_rel=${st_path#"$quc_source"/}
        st_rel_hex=$(quc_hex_encode "$st_rel")
        st_kind=$(quc_kind_of "$st_path" || true)
        case $st_kind in
            dir)
                quc_stage_mkdir_rel "$st_rel" || {
                    quc_stage_status=failed
                    return 1
                }
                printf 'D\t%s\n' "$st_rel_hex" >> "$st_body" || return 1
                ;;
            regular)
                quc_set_parent "$st_rel"
                st_parent=$quc_parent
                case $st_parent in
                    .|'') ;;
                    *)
                        quc_stage_mkdir_rel "$st_parent" || {
                            quc_stage_status=failed
                            return 1
                        }
                        ;;
                esac
                st_final=$quc_stage_dir/data/$st_rel
                if [ -e "$st_final" ] || [ -L "$st_final" ]; then
                    quc_stage_status=failed
                    quc_error="в локальной копии уже есть объект"
                    return 1
                fi
                st_tmp=$quc_stage_dir/data/$QUC_PARTIAL_PREFIX$$
                if [ -e "$st_tmp" ] || [ -L "$st_tmp" ]; then
                    quc_stage_status=failed
                    quc_error="временное имя локальной копии занято"
                    return 1
                fi
                quc_transfer_exclusive "$st_path" "$st_tmp" no
                st_rc=$?
                if [ "$st_rc" -ne 0 ]; then
                    quc_drop_owned "$st_tmp" "$quc_fill_ino"
                    quc_stage_status=failed
                    quc_error="не удалось прочитать файл в локальную копию"
                    return 1
                fi
                st_h1=$(quc_hash_file "$st_path" || true)
                st_h2=$(quc_hash_file "$st_tmp" || true)
                st_h3=$(quc_hash_file "$st_path" || true)
                st_sz=$(quc_file_size "$st_path" || true)
                st_dz=$(quc_file_size "$st_tmp" || true)
                if [ -z "$st_h1" ] || [ "$st_h1" != "$st_h2" ] || [ "$st_h1" != "$st_h3" ] || [ "$st_sz" != "$st_dz" ]; then
                    quc_drop_owned "$st_tmp" "$quc_fill_ino"
                    quc_stage_status=failed
                    quc_error="файл изменился во время локальной копии"
                    return 1
                fi
                quc_install_new "$st_tmp" "$st_final" "$quc_fill_ino"
                st_rc=$?
                if [ "$st_rc" -ne 0 ]; then
                    quc_drop_owned "$st_tmp" "$quc_fill_ino"
                    quc_stage_status=failed
                    quc_error="не удалось закрепить локальную копию"
                    return 1
                fi
                printf 'F\t%s\t%s\t%s\n' "$st_rel_hex" "$st_sz" "$st_h1" >> "$st_body" || return 1
                ;;
            link)
                quc_set_parent "$st_rel"
                st_parent=$quc_parent
                case $st_parent in
                    .|'') ;;
                    *)
                        quc_stage_mkdir_rel "$st_parent" || {
                            quc_stage_status=failed
                            return 1
                        }
                        ;;
                esac
                st_target=$("$quc_bin_readlink" -- "$st_path" 2>/dev/null || true)
                st_final=$quc_stage_dir/data/$st_rel
                if [ -e "$st_final" ] || [ -L "$st_final" ]; then
                    quc_stage_status=failed
                    return 1
                fi
                if ! "$quc_bin_ln" -s -- "$st_target" "$st_final" 2>/dev/null; then
                    quc_stage_status=failed
                    quc_error="не удалось сохранить символьную ссылку в локальной копии"
                    return 1
                fi
                st_th=$(quc_hex_encode "$st_target")
                printf 'L\t%s\t%s\n' "$st_rel_hex" "$st_th" >> "$st_body" || return 1
                ;;
            fifo|socket|char|block|other)
                printf 'S\t%s\t%s\n' "$st_rel_hex" "$st_kind" >> "$st_body" || return 1
                ;;
            *)
                quc_stage_status=failed
                quc_error="не удалось определить тип файла"
                return 1
                ;;
        esac
        st_pause=${QUC_FILE_PAUSE:-0}
        case $st_pause in
            0) ;;
            *) st_pause=$(quc_pause_seconds QUC_FILE_PAUSE 0 60) ;;
        esac
        if [ "$st_pause" != 0 ]; then
            quc_set_phase "pause" "$st_rel"
            if ! quc_sleep_interruptible "$st_pause"; then
                quc_stage_status=failed
                return 20
            fi
        fi
    done < "$st_plan"
    quc_job_phase=STAGE_VERIFY
    quc_stage_status=verifying
    quc_save_state || return 1
    st_now=$(quc_scratch_file stage-now.hex)
    quc_write_plan "$st_now" "$quc_source"
    st_rc=$?
    if [ "$st_rc" -ne 0 ]; then
        quc_stage_status=failed
        quc_error="источник пропал до готовности локальной копии"
        return 1
    fi
    if ! "$quc_bin_awk" 'NR == FNR { a[$0] = 1; n++; next } { if (!($0 in a)) bad = 1; c++ } END { if (bad || c != n) exit 1 }' "$st_plan" "$st_now"; then
        quc_stage_status=failed
        quc_error="набор источника изменился до фиксации локальной копии"
        return 1
    fi
    while IFS= read -r st_line || [ -n "$st_line" ]; do
        [ -n "$st_line" ] || continue
        st_kind=$(printf '%s\n' "$st_line" | "$quc_bin_awk" -F '\t' '{ print $1; exit }')
        [ "$st_kind" = F ] || continue
        st_hex=$(printf '%s\n' "$st_line" | "$quc_bin_awk" -F '\t' '{ print $2; exit }')
        st_sz=$(printf '%s\n' "$st_line" | "$quc_bin_awk" -F '\t' '{ print $3; exit }')
        st_hash=$(printf '%s\n' "$st_line" | "$quc_bin_awk" -F '\t' '{ print $4; exit }')
        quc_decode_hex_var "$st_hex" || {
            quc_stage_status=failed
            return 1
        }
        st_rel=$quc_decoded
        if ! quc_identity_still; then
            quc_stage_status=failed
            quc_error="источник пропал до готовности локальной копии"
            return 1
        fi
        st_src=$quc_source/$st_rel
        st_dst=$quc_stage_dir/data/$st_rel
        st_h1=$(quc_hash_file "$st_src" || true)
        st_h2=$(quc_hash_file "$st_dst" || true)
        if [ -z "$st_h1" ] || [ "$st_h1" != "$st_hash" ] || [ "$st_h1" != "$st_h2" ]; then
            quc_stage_status=failed
            quc_error="содержимое изменилось до фиксации локальной копии"
            return 1
        fi
        st_nowsz=$(quc_file_size "$st_src" || true)
        if [ "$st_nowsz" != "$st_sz" ]; then
            quc_stage_status=failed
            quc_error="размер изменился до фиксации локальной копии"
            return 1
        fi
    done < "$st_body"
    st_records=$("$quc_bin_awk" 'NF { c++ } END { printf "%.0f", c + 0 }' "$st_body")
    {
        printf '%s\n' "QUC_MANIFEST 1"
        printf 'job_id=%s\n' "$quc_job_id"
        printf 'hash_tool=%s\n' "$quc_stage_tool"
        printf 'records=%s\n' "$st_records"
        "$quc_bin_cat" "$st_body"
    } > "$quc_stage_dir/manifest.tmp.$$" || return 1
    "$quc_bin_mv" -f -- "$quc_stage_dir/manifest.tmp.$$" "$quc_stage_dir/manifest" || return 1
    st_mh=$(quc_hash_file "$quc_stage_dir/manifest" || true)
    if [ -z "$st_mh" ]; then
        quc_stage_status=failed
        quc_error="не удалось зафиксировать описание локальной копии"
        return 1
    fi
    quc_stage_manifest=$st_mh
    quc_stage_status=READY
    quc_job_phase=READY
    quc_save_state || {
        quc_stage_status=failed
        quc_stage_manifest=''
        return 1
    }
    if [ "$quc_sync_mode" = data ] || [ "$quc_sync_mode" = file ]; then
        if ! quc_sync_cmd "$quc_job_dir/state"; then
            quc_sync_unconfirmed=1
            quc_sync_status=unconfirmed
            quc_log INFO "сброс файла состояния после READY не подтверждён"
            quc_save_state || true
        fi
    fi
    quc_log INFO "stage_status=READY tool=$quc_stage_tool records=$st_records"
    quc_log INFO "проверка файлов не является атомарным снимком всего дерева"
    return 0
}

quc_stage_ensure() {
    if [ "${quc_source_mode:-direct}" != staged ]; then
        return 0
    fi
    if [ "$quc_stage_status" = READY ]; then
        if quc_stage_verify_stored; then
            return 0
        fi
        quc_stage_status=damaged
        quc_recovery_status=refused
        quc_error="локальная копия повреждена и не используется"
        quc_save_state || true
        return 1
    fi
    if [ "$quc_stage_status" = damaged ]; then
        quc_recovery_status=refused
        quc_error="локальная копия повреждена и не используется"
        return 1
    fi
    if ! quc_hash_tool; then
        quc_stage_status=failed
        quc_error="нет средства проверки содержимого, локальная копия не фиксируется"
        quc_save_state || true
        return 1
    fi
    if ! quc_stage_prepare_dir; then
        quc_stage_status=failed
        quc_save_state || true
        return 1
    fi
    quc_stage_copy_tree
    st_rc=$?
    if [ "$st_rc" -ne 0 ]; then
        if [ "$quc_stage_status" = READY ]; then
            quc_stage_status=failed
        fi
        quc_save_state || true
        return "$st_rc"
    fi
    return 0
}

quc_stage_remove_job() {
    rj_id=$1
    quc_job_id_safe "$rj_id" || return 1
    rj_root=$(quc_stage_root) || return 1
    rj_dir=$rj_root/$rj_id
    case $rj_dir in
        "$rj_root"/*) ;;
        *) return 1 ;;
    esac
    if [ ! -d "$rj_dir" ] || [ -L "$rj_dir" ]; then
        return 0
    fi
    rj_uid=$("$quc_bin_stat" -c '%u' -- "$quc_state_dir" 2>/dev/null || true)
    saved_id=$quc_job_id
    quc_job_id=$rj_id
    if ! quc_stage_marker_ok "$rj_dir" "$rj_uid"; then
        quc_job_id=$saved_id
        return 1
    fi
    quc_job_id=$saved_id
    "$quc_bin_rm" -rf -- "$rj_dir"
}

quc_stage_offer_check() {
    quc_stage_offer=0
    if ! quc_hash_tool; then
        quc_add_note "локальная копия недоступна: нет программы контрольной суммы"
        return 1
    fi
    so_root=$(quc_stage_root) || return 1
    # Каталог программы может ещё не существовать. Место смотрим у ближайшего
    # существующего предка. Создаёт его только явный выбор локальной копии.
    so_probe=$so_root
    so_guard=0
    while [ ! -d "$so_probe" ] || [ -L "$so_probe" ]; do
        so_guard=$((so_guard + 1))
        so_next=$("$quc_bin_dirname" -- "$so_probe")
        if [ "$so_guard" -gt 64 ] || [ -z "$so_next" ] || [ "$so_next" = "$so_probe" ]; then
            quc_add_note "локальная копия недоступна: нет каталога данных"
            return 1
        fi
        so_probe=$so_next
    done
    so_free=$(quc_free_bytes "$so_probe" || true)
    if [ -z "$so_free" ]; then
        quc_add_note "локальная копия недоступна: не видно свободное место"
        return 1
    fi
    if [ -n "${quc_need_bytes:-}" ] && ! quc_cmp_num "$so_free" "$quc_need_bytes" ge; then
        quc_add_note "локальная копия недоступна: мало места"
        return 1
    fi
    quc_stage_offer=1
    return 0
}

quc_only_nonempty() {
    on_line=$(printf '%s\n' "$quc_problems" | "$quc_bin_awk" 'NF { c++; line = $0 } END { if (c == 1) print line }')
    [ "$on_line" = "назначение не пустое; существующие данные не перезаписываются" ]
}

quc_mentions_nonempty() {
    printf '%s\n' "$quc_problems" | "$quc_bin_grep" -F -x -e "назначение не пустое; существующие данные не перезаписываются" >/dev/null 2>&1
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
    quc_probe_host_compat
    case $quc_compat_cp in
        SUPPORTED) ;;
        *)
            quc_finalize FAILED "безопасная запись через открытый дескриптор недоступна"
            exit 1
            ;;
    esac
    case $quc_compat_publish in
        SUPPORTED|LIMITED) ;;
        *)
            quc_finalize FAILED "безопасная публикация нового имени недоступна"
            exit 1
            ;;
    esac
    case $quc_compat_find in
        SUPPORTED) ;;
        *)
            quc_finalize FAILED "нет обхода find -print0, копирование не начато"
            exit 1
            ;;
    esac
    quc_log INFO "worker pid=$$ mode=$quc_run_mode sparse=$quc_cp_sparse sync_mode=$quc_sync_mode profile=${quc_profile:-gentle} source_mode=${quc_source_mode:-direct} dest_mode=${quc_dest_mode:-root} compat=$quc_compat_level"
    quc_job_phase=PREFLIGHT
    quc_save_state || exit 1
    if [ "$quc_run_mode" = fresh ]; then
        wm_mode=fresh
        if [ "${quc_dest_mode:-root}" = separate ]; then
            wm_mode=separate
        fi
        if ! quc_validate_pair "$quc_source" "$quc_target" "$wm_mode"; then
            quc_error=$(printf '%s\n' "$quc_problems" | "$quc_bin_awk" 'NR == 1 { print; exit }')
            quc_finalize FAILED "${quc_error:-проверка перед копированием не пройдена}"
            exit 1
        fi
        if [ "$wm_mode" = separate ]; then
            if ! quc_claim_dest_dir; then
                quc_finalize FAILED "${quc_error:-не удалось создать каталог назначения}"
                exit 1
            fi
            quc_save_state || exit 1
        fi
    else
        if ! quc_resume_identity; then
            quc_finalize FAILED "${quc_error:-носитель не подтверждён}"
            exit 1
        fi
        "$quc_bin_rm" -f -- "$quc_job_dir/stop-requested" 2>/dev/null || true
        quc_stop_requested=0
        if [ "${quc_dest_mode:-root}" = separate ]; then
            if ! quc_claim_dest_dir; then
                quc_finalize FAILED "${quc_error:-не удалось открыть каталог назначения}"
                exit 1
            fi
        fi
        if ! quc_bind_roots; then
            quc_finalize FAILED "${quc_error:-каталог записи не подтверждён}"
            exit 1
        fi
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
    if [ "${quc_source_mode:-direct}" = staged ]; then
        quc_stage_ensure
        wm_rc=$?
        if [ "$wm_rc" -ne 0 ]; then
            quc_finalize_rc "$wm_rc" "${quc_error:-локальная копия не подготовлена}"
            exit 1
        fi
    fi
    if ! quc_bind_roots; then
        quc_finalize FAILED "${quc_error:-каталог записи не подтверждён}"
        exit 1
    fi
    if ! quc_identity_still; then
        quc_finalize FAILED "${quc_error:-носитель недоступен}"
        exit 1
    fi
    if ! quc_select_publish_mode "$quc_write_root"; then
        quc_finalize FAILED "${quc_error:-На этом назначении нельзя создать новое имя без риска замены. Копирование не начато.}"
        exit 1
    fi
    case ${quc_publish_mode:-} in
        link|exclusive) ;;
        *)
            quc_finalize FAILED "безопасная публикация нового имени недоступна"
            exit 1
            ;;
    esac
    if [ "$quc_publish_mode" = exclusive ]; then
        quc_log INFO "публикация без жёсткой ссылки: новое имя видно до проверки и не считается готовым"
    fi
    quc_save_state || exit 1
    if ! quc_mount_mark_place; then
        quc_finalize FAILED "${quc_error:-не удалось отметить назначение}"
        exit 1
    fi
    quc_save_state || exit 1
    quc_job_phase=TRANSFER
    quc_set_phase planning ''
    quc_write_plan "$(quc_scratch_file plan.hex)" "$quc_read_root"
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
    if quc_source_detached; then
        quc_stage_count_specials || true
    fi
    quc_flag_nested_mounts "$quc_read_root" "источник" || true
    quc_save_state || true
    quc_copy_list "$(quc_scratch_file plan.hex)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        quc_finalize_rc "$rc" "${quc_error:-копирование прервано ошибкой}"
        exit 1
    fi
    quc_job_phase=TARGET_VERIFY
    quc_save_state || true
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
    # COPY завершён. Конечные имена сверяются до sync и до снятия метки.
    if [ "${quc_eject_policy:-no}" = yes ] || [ "${quc_verify_during:-0}" = 1 ]; then
        quc_set_phase "content-verify" ""
        cv_pause=${QUC_PRE_VERIFY_PAUSE:-0}
        case $cv_pause in
            0) ;;
            *) cv_pause=$(quc_pause_seconds QUC_PRE_VERIFY_PAUSE 0 60) ;;
        esac
        if [ "$cv_pause" != 0 ]; then
            if ! quc_sleep_interruptible "$cv_pause"; then
                quc_finalize_rc 20 "прервано до проверки содержимого"
                exit 1
            fi
        fi
        quc_verify_published
        cv_rc=$?
        quc_save_state || true
        if [ "$cv_rc" -ne 0 ]; then
            quc_finalize_rc "$cv_rc" "${quc_error:-проверка содержимого прервана}"
            exit 1
        fi
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
            # Готовый итог значит, что worker уже запустился. Файл ready
            # к этому моменту может быть удалён вместе со служебным мусором.
            case $st in
                SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) return 0 ;;
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

Один экран: источник, назначение и один вердикт. Затем 1, 2, 3, 5 или 0.
2 показывает подробности и не запускает копирование. 3 меняет выбор.
Если на экране есть 4, она начинает предложенную локальную копию.
1 по-прежнему копирует напрямую. Направление само не угадывается.
На экране видно, включено ли автоматическое отключение назначения.
1 подтверждает написанную на экране политику. 5 меняет её и не запускает копирование.
Исходный накопитель программа не отключает. После 1 терминал свободен.
Вопрос во время копирования не задаётся.
Если списка нет, введите два абсолютных пути. Вне терминала меню
не открывается.

status и report показывают, нужен ли исходный накопитель этому заданию.
Прямое копирование: «Источник: ещё требуется для копирования.»
Пока готовится локальная копия: «Источник: пока требуется.»
После проверенной локальной копии: «Источник: больше не требуется Quiet USB Copy.»
Фраза относится только к этой программе. Другие программы могут всё ещё
использовать накопитель. Для извлечения используйте средства ОС.
Неподтверждённая готовность остаётся неизвестной и не называется готовой.
Поле source_dependency: required, not_required или unknown.
Подмена этого поля в файле состояния не меняет ответ status.

  sh quiet_usb_copy.sh status
  sh quiet_usb_copy.sh stop
  sh quiet_usb_copy.sh resume
  sh quiet_usb_copy.sh help

Для автоматизации

  sh quiet_usb_copy.sh start ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh start --profile gentle --verify ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh start --dest-mode separate ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh start --source-mode staged ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh start --eject-dest ИСТОЧНИК НАЗНАЧЕНИЕ
  sh quiet_usb_copy.sh plan ИСТОЧНИК НАЗНАЧЕНИЕ
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

Обычный start копирует в корень пустого назначения. Непустое назначение
без --dest-mode separate отклоняется. separate создаёт новую папку
QUC-<идентификатор> и не меняет уже существующие файлы. В меню такая
папка предлагается сама, путь виден до подтверждения.

staged сначала делает локальную файловую копию в каталоге данных
пользователя и только после проверки содержимого ставит stage_status=READY.
После READY перенос, проверка и resume не читают исходную флешку.
Размеры и время файлов сами по себе READY не дают. Проверка отдельных
файлов не является атомарным снимком всего дерева. MERGE_SAFE не
реализован: отличающийся файл не заменяется.

plan показывает намерение и место. На выбранном назначении создаётся
и сразу удаляется короткое новое имя, чтобы узнать способ публикации.
Поля plan: plan_level READY, LIMITED или REJECT; publish_policy=no-replace;
dest_link_probe link, exclusive, unsupported или UNKNOWN; content_tool.
Если проба выполнена, checks_not_run=dest_hardlink не печатается.
UNKNOWN остаётся, когда назначение не выбрано. Существующее имя не
заменяется. Если жёсткая ссылка доступна, новое имя создаётся ею.
Если ссылки нет и повторное создание того же имени не затирает файл,
имя создаётся сразу и видно до проверки содержимого. Это не атомарная
публикация и не считается готовым файлом, пока содержимое не совпадёт.
Принудительное перемещение не используется. check по-прежнему
требует пустое назначение. resume продолжает прерванное задание, в том
числе если процесс исчез, а блокировка осталась. Изменённый файл при
resume не заменяется. Успешные копирование, контрольная сумма и sync не
заменяют штатное безопасное извлечение средствами операционной системы.
status и report отдельно показывают копирование, проверку содержимого
и синхронизацию. Обычный start не запрашивает отключение назначения.
Отключение выполняется только после успеха копирования, проверки и
синхронизации и только если система разрешает его без пароля.
Отказ системы не отменяет успех копирования. eject_status не заменяет
copy_status. Значения: planned, unmounted, power_off, skipped_policy,
unavailable, refused, unknown. doctor без выбранного назначения печатает compat_level
SUPPORTED, LIMITED или UNSUPPORTED. Неизвестная черта остаётся UNKNOWN
и не превращается в SUPPORTED. Проба записи идёт в частный каталог, не
на накопитель. Успех команды не делает файловую систему проверенной.

Пути с дефисом в начале указывайте после -- :
  sh quiet_usb_copy.sh start -- --источник --назначение

Коды выхода: 0 команда принята, 1 отказ или сбой операции,
2 неверные аргументы, 70 нет программ или служебного каталога.
Строки error_code=: E_OK, E_FAIL, E_USAGE, E_ENV, E_REJECT, E_NOJOB.

Постоянные данные восстановления:
  ${XDG_STATE_HOME:-$HOME/.local/state}/quiet-usb-copy/
Временные списки, если каталог доступен:
  ${XDG_RUNTIME_DIR}/quiet-usb-copy/
На исходной флешке файлы программы не создаются. На назначении во
время задания появляется метка .quc-mnt-…; при успешном завершении
она удаляется. Локальная копия лежит в
  ${XDG_DATA_HOME:-$HOME/.local/share}/quiet-usb-copy/staging/
cleanup удаляет только свои служебные данные и свою локальную копию
удаляемого задания. --dry-run только показывает список.
Выполняющееся задание не удаляется. Не запускайте cleanup, если
прерванное задание ещё нужно продолжить: вместе с заданием уйдёт
и его локальная копия.

Поля state: copy_status, verify_status, sync_status, stage_status,
source_mode, dest_mode, recovery_status, job_phase, source_dependency,
eject_policy, eject_status, publish_mode, dest_link_probe,
partial_rel_hex, partial_ino, partial_bytes, partial_visible.
publish_mode link или exclusive. partial_visible=1 значит имя уже видно,
а содержимое ещё не признано проверенным.
stage_status: none, preparing, verifying, READY, failed, damaged.
source_mode: direct, staged. dest_mode: root, separate.
EOF
}

quc_cmd_version() {
    printf 'quiet-usb-copy %s\n' "$QUC_VERSION"
    printf 'build %s\n' "$QUC_BUILD"
    ver_sha=UNKNOWN
    ver_self=$(quc_self_path 2>/dev/null || true)
    ver_bin=$(command -v sha256sum 2>/dev/null || true)
    ver_awk=$(command -v awk 2>/dev/null || true)
    if [ -n "$ver_self" ] && [ -n "$ver_bin" ] && [ -n "$ver_awk" ]; then
        ver_sha=$("$ver_bin" -- "$ver_self" 2>/dev/null | "$ver_awk" 'NR == 1 && $1 ~ /^[0-9A-Fa-f]+$/ { print $1; exit }')
        [ -n "$ver_sha" ] || ver_sha=UNKNOWN
    fi
    printf 'sha256=%s\n' "$ver_sha"
}

quc_cmd_plan() {
    quc_source_mode=direct
    quc_dest_mode=root
    while [ "$#" -gt 0 ]; do
        case $1 in
            --dest-mode)
                shift
                case ${1:-} in
                    root|separate) quc_dest_mode=$1; shift ;;
                    *)
                        printf '%s\n' "Неизвестный режим назначения." >&2
                        printf '%s\n' "error_code=E_USAGE" >&2
                        return 2
                        ;;
                esac
                ;;
            --source-mode)
                shift
                case ${1:-} in
                    direct|staged) quc_source_mode=$1; shift ;;
                    *)
                        printf '%s\n' "Неизвестный режим источника." >&2
                        printf '%s\n' "error_code=E_USAGE" >&2
                        return 2
                        ;;
                esac
                ;;
            --) shift; break ;;
            -*)
                printf '%s\n' "Неизвестный параметр plan." >&2
                printf '%s\n' "error_code=E_USAGE" >&2
                return 2
                ;;
            *) break ;;
        esac
    done
    if [ "$#" -ne 2 ]; then
        printf '%s\n' "plan нужны два каталога: источник и назначение." >&2
        printf '%s\n' "error_code=E_USAGE" >&2
        return 2
    fi
    quc_prepare_state || true
    pl_mode=fresh
    if [ "$quc_dest_mode" = separate ]; then
        pl_mode=separate
    fi
    pl_nonempty=0
    if ! quc_validate_pair "$1" "$2" "$pl_mode"; then
        if [ "$quc_dest_mode" = root ] && quc_mentions_nonempty; then
            pl_nonempty=1
            if ! quc_validate_pair "$1" "$2" separate; then
                pl_nonempty=0
            fi
        fi
        if [ "$pl_nonempty" != 1 ]; then
            printf '%s\n' "План: копировать нельзя."
            printf '%s\n' "$quc_problems" | while IFS= read -r line; do
                [ -n "$line" ] || continue
                printf 'Причина: %s\n' "$line"
            done
            printf '%s\n' "Копирование не запускается."
            printf '%s\n' "Что сделать: устраните причину и снова выполните plan."
            printf '%s\n' "plan_level=REJECT"
            printf '%s\n' "publish_policy=no-replace"
            printf '%s\n' "dest_link_probe=UNKNOWN"
            printf '%s\n' "plan_result=REJECT"
            printf '%s\n' "error_code=E_REJECT"
            return 1
        fi
    fi
    printf '%s\n' "План: копирование не запускается."
    printf 'source_mode=%s\n' "$quc_source_mode"
    if [ "$pl_nonempty" = 1 ] || [ "$quc_dest_mode" = separate ]; then
        printf '%s\n' "dest_mode=separate"
        printf '%s\n' "Размещение: новая папка QUC-<идентификатор>. Имя выбирается при start и записывается в состояние."
        printf '%s\n' "Существующие данные: не изменяются и не удаляются."
    else
        printf '%s\n' "dest_mode=root"
        printf '%s\n' "Размещение: корень пустого назначения."
        printf '%s\n' "Существующие данные: каталог пуст, посторонние файлы не создаются этой командой."
    fi
    if [ "$quc_source_mode" = staged ]; then
        printf '%s\n' "Сначала локальная файловая копия, затем перенос из неё. После READY исходная флешка не читается."
        printf '%s\n' "Проверка отдельных файлов не является атомарным снимком всего дерева."
        pl_home=$(quc_stage_root || true)
        if [ -n "$pl_home" ]; then
            printf 'Локальная копия: %s\n' "$pl_home"
        fi
        if ! quc_hash_tool; then
            printf '%s\n' "Причина: нет средства проверки содержимого, READY не будет установлен."
            printf '%s\n' "Что сделать: установите sha256sum, sha1sum, md5sum или cksum и снова выполните plan."
            printf '%s\n' "plan_level=REJECT"
            printf '%s\n' "publish_policy=no-replace"
            printf '%s\n' "dest_link_probe=UNKNOWN"
            printf '%s\n' "plan_result=REJECT"
            printf '%s\n' "error_code=E_REJECT"
            return 1
        fi
    else
        printf '%s\n' "Чтение: непосредственно с источника во время переноса."
    fi
    if [ -n "${quc_need_bytes:-}" ]; then
        printf 'Нужно места: %s\n' "$(quc_human_bytes "$quc_need_bytes")"
        printf 'Свободно в назначении: %s\n' "$(quc_human_bytes "${quc_free_have:-0}")"
    fi
    if ! quc_select_publish_mode "$quc_target"; then
        printf 'Причина: %s\n' "${quc_error:-На этом назначении нельзя создать новое имя без риска замены. Копирование не начато.}"
        printf '%s\n' "Копирование не запускается."
        printf '%s\n' "plan_level=REJECT"
        printf '%s\n' "publish_policy=no-replace"
        printf 'dest_link_probe=%s\n' "${quc_dest_link_probe:-unsupported}"
        printf '%s\n' "plan_result=REJECT"
        printf '%s\n' "error_code=E_REJECT"
        return 1
    fi
    if [ "${quc_publish_mode:-}" = exclusive ]; then
        quc_add_note "Жёсткие ссылки на назначении недоступны. Новый файл виден до проверки содержимого и не считается готовым."
    fi
    if [ -n "$quc_notes" ]; then
        printf '%s\n' "$quc_notes" | while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf 'Замечание: %s\n' "$line"
        done
    fi
    printf '%s\n' "Существующие имена не заменяются. Принудительное перемещение не используется."
    case ${quc_publish_mode:-} in
        link)
            printf '%s\n' "Жёсткие ссылки на назначении доступны. Новое имя создаётся ссылкой."
            ;;
        exclusive)
            printf '%s\n' "Жёсткие ссылки на назначении недоступны. Новый файл виден до проверки содержимого и не считается готовым."
            ;;
    esac
    printf '%s\n' "При отказе публикации уже записанные файлы остаются. Дальше: status или report."
    pl_level=READY
    if [ -n "$quc_notes" ]; then
        pl_level=LIMITED
    fi
    pl_tool=none
    if quc_hash_tool; then
        pl_tool=$quc_hash_name
    elif [ -n "${quc_bin_cmp:-}" ]; then
        pl_tool='cmp'
    fi
    printf 'plan_level=%s\n' "$pl_level"
    printf '%s\n' "publish_policy=no-replace"
    printf 'dest_link_probe=%s\n' "${quc_dest_link_probe:-UNKNOWN}"
    printf 'content_tool=%s\n' "$pl_tool"
    printf '%s\n' "MERGE_SAFE=NOT_IMPLEMENTED"
    printf '%s\n' "plan_result=OK"
    printf '%s\n' "error_code=E_OK"
    return 0
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
    if [ -n "${quc_planned_id:-}" ]; then
        if ! quc_job_id_safe "$quc_planned_id"; then
            return 1
        fi
        if [ -e "$quc_jobs_dir/$quc_planned_id" ] || [ -L "$quc_jobs_dir/$quc_planned_id" ]; then
            return 1
        fi
        quc_job_id=$quc_planned_id
    else
        quc_job_id=$(quc_new_job_id)
    fi
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
    case ${quc_eject_policy:-no} in
        yes) quc_eject_status=planned ;;
        *)
            quc_eject_policy=no
            quc_eject_status=skipped_policy
            ;;
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
    quc_source_mode=direct
    quc_dest_mode=root
    quc_dest_rel=
    quc_planned_id=
    quc_eject_policy=no
    while [ "$#" -gt 0 ]; do
        case $1 in
            --verify) verify=1; shift ;;
            --eject-dest) quc_eject_policy=yes; shift ;;
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
            --dest-mode)
                shift
                case ${1:-} in
                    root|separate) quc_dest_mode=$1; shift ;;
                    *)
                        quc_note_error "неизвестный режим назначения"
                        exit 2
                        ;;
                esac
                ;;
            --source-mode)
                shift
                case ${1:-} in
                    direct|staged) quc_source_mode=$1; shift ;;
                    *)
                        quc_note_error "неизвестный режим источника"
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
    cs_mode=fresh
    if [ "$quc_dest_mode" = separate ]; then
        cs_mode=separate
    fi
    cs_ok=0
    if quc_validate_pair "$1" "$2" "$cs_mode"; then
        cs_ok=1
        if [ "$quc_dest_mode" = separate ]; then
            quc_planned_id=$(quc_new_job_id)
            if ! quc_pick_dest_rel; then
                quc_add_problem "${quc_error:-не удалось подобрать новый каталог назначения}"
                cs_ok=0
            fi
        fi
        if [ "$cs_ok" = 1 ] && [ "$quc_source_mode" = staged ]; then
            if ! quc_hash_tool; then
                quc_add_problem "нет средства проверки содержимого, локальная копия не фиксируется"
                cs_ok=0
            fi
        fi
    fi
    if [ "$cs_ok" != 1 ]; then
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
        quc_job_phase=FAILED
        quc_eject_status=skipped_policy
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
    printf 'stage_status=%s\n' "${quc_stage_status:-none}"
    printf 'source_mode=%s\n' "${quc_source_mode:-direct}"
    quc_compute_source_dependency
    printf 'source_dependency=%s\n' "$quc_source_dependency"
    printf 'dest_mode=%s\n' "${quc_dest_mode:-root}"
    printf 'recovery_status=%s\n' "${quc_recovery_status:-none}"
    printf 'job_phase=%s\n' "${quc_job_phase:-CREATED}"
    printf 'eject_policy=%s\n' "${quc_eject_policy:-no}"
    printf 'eject_status=%s\n' "${quc_eject_status:-skipped_policy}"
    if [ -n "${quc_dest_rel:-}" ]; then
        printf 'dest_rel=%s\n' "$quc_dest_rel"
    fi
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

quc_print_source_dependency() {
    quc_compute_source_dependency
    case $quc_source_dependency in
        required)
            if [ "${quc_source_mode:-direct}" = staged ]; then
                printf '%s\n' "Подготовка локальной копии."
                printf '%s\n' "Источник: пока требуется."
            else
                printf '%s\n' "Источник: ещё требуется для копирования."
            fi
            ;;
        not_required)
            if [ "${quc_source_mode:-direct}" = staged ]; then
                printf '%s\n' "Локальная копия подготовлена и проверена."
            fi
            printf '%s\n' "Источник: больше не требуется Quiet USB Copy."
            ;;
        *)
            case ${quc_stage_status:-none} in
                damaged|failed)
                    printf '%s\n' "Источник: статус неизвестен."
                    ;;
                *)
                    printf '%s\n' "Готовность локальной копии не подтверждена."
                    printf '%s\n' "Источник: статус неизвестен."
                    ;;
            esac
            ;;
    esac
}

# Печатает сохранённый итог отключения. Не меняет copy_status и не пересчитывает поле.
quc_print_eject_human() {
    case ${quc_eject_status:-skipped_policy} in
        planned)
            printf '%s\n' "Автоотключение назначения запланировано."
            ;;
        unmounted)
            printf '%s\n' "Файловая система назначения размонтирована. Питание не отключалось."
            ;;
        power_off)
            printf '%s\n' "Питание назначения отключено штатно."
            ;;
        skipped_policy)
            printf '%s\n' "Автоотключение назначения не выполнялось."
            ;;
        unavailable)
            printf '%s\n' "Средство отключения недоступно. Назначение оставлено подключённым."
            ;;
        refused)
            printf '%s\n' "Система отказала в отключении. Назначение оставлено подключённым."
            ;;
        *)
            printf '%s\n' "Результат отключения неизвестен. Не извлекайте накопитель вслепую."
            ;;
    esac
    case ${quc_eject_status:-skipped_policy} in
        power_off|unmounted|unavailable|refused|unknown) return 0 ;;
    esac
    if [ "${quc_eject_policy:-no}" != yes ]; then
        printf '%s\n' "Назначение оставлено подключённым: автоотключение выключено."
        return 0
    fi
    case ${quc_verify_status:-none} in
        checksum|byte) ;;
        failed)
            printf '%s\n' "Назначение оставлено подключённым: содержимое назначения не совпало."
            return 0
            ;;
        uncertain)
            printf '%s\n' "Назначение оставлено подключённым: источник изменился во время проверки."
            return 0
            ;;
        size)
            printf '%s\n' "Назначение оставлено подключённым: содержимое не проверено."
            return 0
            ;;
        *)
            printf '%s\n' "Назначение оставлено подключённым: проверка содержимого недоступна."
            return 0
            ;;
    esac
    if [ "${quc_copy_status:-}" != SUCCESS ]; then
        printf '%s\n' "Назначение оставлено подключённым: копирование не завершено успешно."
        return 0
    fi
    if [ "${quc_sync_status:-unconfirmed}" != command_ok ]; then
        printf '%s\n' "Назначение оставлено подключённым: синхронизация не подтверждена."
        return 0
    fi
    printf '%s\n' "Назначение оставлено подключённым: идентичность назначения или разрешение системы не подтверждены."
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
    if [ "${quc_dest_mode:-root}" = separate ]; then
        printf '%s\n' "Размещение: отдельная папка."
    else
        printf '%s\n' "Размещение: корень назначения."
    fi
    if [ "${quc_source_mode:-direct}" = staged ]; then
        printf '%s\n' "Подготовка: локальная копия."
    fi
    case ${quc_stage_status:-none} in
        READY) printf '%s\n' "Локальная копия: готова." ;;
        damaged) printf '%s\n' "Локальная копия: повреждена." ;;
    esac
    quc_print_source_dependency
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
    quc_print_eject_human
    case ${quc_profile:-gentle} in
        gentle)
            printf '%s\n' "Режим: бережный. Задержки самой флешки возможны."
            ;;
        *)
            printf 'Режим: %s\n' "$quc_profile"
            ;;
    esac
    case $quc_copy_status in
        PARTIAL|FAILED|UNCERTAIN|INTERRUPTED|CANCELLED)
            if [ -n "${quc_error:-}" ]; then
                printf 'Причина: %s\n' "$(quc_one_line "$quc_error")"
            else
                case $quc_copy_status in
                    PARTIAL) printf '%s\n' "Причина: часть объектов не скопирована." ;;
                    INTERRUPTED|CANCELLED) printf '%s\n' "Причина: копирование остановлено до завершения." ;;
                    FAILED) printf '%s\n' "Причина: копирование не удалось." ;;
                    *) printf '%s\n' "Причина: результат не подтверждён." ;;
                esac
            fi
            printf 'Сохранено файлов: %s\n' "${quc_files_done:-0}"
            case ${quc_error:-} in
                *'не поддерживает'*|*'несовместим'*)
                    printf '%s\n' "Вид отказа: операция не поддерживается."
                    ;;
                *'не совпал'*|*'изменён'*|*'повреж'*)
                    printf '%s\n' "Вид отказа: данные не совпали."
                    ;;
            esac
            case $quc_copy_status in
                PARTIAL|INTERRUPTED|CANCELLED)
                    printf '%s\n' "Продолжение: resume. Уже изменённый файл сам не заменяется."
                    printf '%s\n' "Восстановление: возможно."
                    ;;
                *)
                    printf '%s\n' "Продолжение: смотрите report. Файл сам не заменяется."
                    quc_resume_no=0
                    case ${quc_stage_status:-none} in
                        damaged) quc_resume_no=1 ;;
                    esac
                    case ${quc_error:-} in
                        *'не совпал'*|*'изменён'*|*'повреж'*|*'не смонтирован'*|*'больше не'*|*'подмен'*)
                            quc_resume_no=1
                            ;;
                    esac
                    if [ "$quc_resume_no" = 1 ]; then
                        printf '%s\n' "Восстановление: невозможно."
                    fi
                    ;;
            esac
            printf '%s\n' "Подробнее: report"
            ;;
    esac
}

quc_parse_view_args() {
    quc_view_mode=
    quc_view_verbose=0
    quc_view_explicit=0
    quc_view_id=
    while [ "$#" -gt 0 ]; do
        case $1 in
            --machine) quc_view_mode=machine; quc_view_explicit=1 ;;
            --human) quc_view_mode=human; quc_view_explicit=1 ;;
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
    # --verbose добавляет пояснение и технический блок. Явный --machine
    # оставляет только поля: так сценарий автоматизации не получает прозу.
    if [ "$quc_view_verbose" = 1 ]; then
        if [ "$quc_view_explicit" = 1 ] && [ "$quc_view_mode" = machine ]; then
            quc_print_job 0
            quc_print_report_extra
            return 0
        fi
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
            if quc_read_owner && quc_pid_is_worker "$quc_owner_pid" "$quc_owner_start" "$quc_jobs_dir/$quc_owner_job"; then
                quc_note_error "задание ещё выполняется"
                exit 1
            fi
            quc_recovery_status=resumed
            quc_log INFO "процесс задания исчез до итогового статуса"
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
    quc_run_mode=resume
    quc_open_run_dir
    if [ "${quc_dest_mode:-root}" = separate ]; then
        if ! quc_claim_dest_dir; then
            quc_note_error "${quc_error:-не удалось открыть каталог назначения}"
            quc_log ERROR "${quc_error:-separate resume rejected}"
            quc_drop_scratch
            exit 1
        fi
    fi
    if ! quc_bind_roots; then
        quc_note_error "${quc_error:-каталог записи не подтверждён}"
        quc_log ERROR "${quc_error:-bind rejected}"
        quc_drop_scratch
        exit 1
    fi
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
    if [ "${quc_eject_policy:-no}" = yes ]; then
        case ${quc_eject_status:-} in
            unmounted|power_off) ;;
            *) quc_eject_status=planned ;;
        esac
    fi
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
    if ! quc_bind_roots; then
        quc_drop_scratch
        printf '%s\n' "Каталог проверки не подтверждён."
        quc_verify_status=failed
        quc_save_state || true
        return 1
    fi
    plan=$(quc_scratch_file verify.hex)
    if ! quc_write_plan "$plan" "$quc_read_root"; then
        quc_drop_scratch
        if quc_source_detached; then
            printf '%s\n' "Не удалось прочитать локальную копию."
        else
            printf '%s\n' "Не удалось прочитать источник."
        fi
        return 1
    fi
    while IFS= read -r hex || [ -n "$hex" ]; do
        [ -n "$hex" ] || continue
        quc_decode_hex_var "$hex" || continue
        path=$quc_decoded
        if [ "$path" = "$quc_read_root" ]; then
            continue
        fi
        prefix=$quc_read_root/
        rel=${path#"$prefix"}
        dst=$quc_write_root/$rel
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

# --- Пользовательский интерфейс ---

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
            printf '%s\n' "FAT: имена и файлы больше 4 ГиБ проверяются до запуска. Права Unix не сохраняются."
            ;;
        exfat)
            printf '%s\n' "exFAT: запрещённые имена и совпадение регистра проверяются до запуска. Права Unix не сохраняются."
            ;;
        ntfs|ntfs3|fuseblk)
            printf '%s\n' "NTFS: права Unix не сохраняются. Запрещённые имена и совпадение регистра проверяются до запуска."
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
    quc_label_for_path "$ps_path" "$quc_menu_file"
    printf '%s\n' "$ps_role"
    if [ -n "$quc_lp_n" ]; then
        printf '%s. %s\n' "$quc_lp_n" "$(quc_display_path "$quc_lp_label")"
    elif [ -n "$quc_lp_label" ]; then
        printf '%s\n' "$(quc_display_path "$quc_lp_label")"
    fi
    printf '   %s\n' "$(quc_display_path "$ps_path")"
}

quc_menu_set_verdict() {
    qm_verdict=
    qm_reason=
    if [ "$quc_preflight_ok" != 1 ]; then
        qm_verdict='Вердикт: копировать нельзя.'
        if [ -n "$quc_problems" ]; then
            qm_reason=$(printf '%s\n' "$quc_problems" | "$quc_bin_awk" 'NF { print; exit }')
        fi
        if [ -z "$qm_reason" ]; then
            qm_reason='проверка перед копированием не пройдена'
        fi
        return 0
    fi
    if [ -n "$quc_notes" ]; then
        qm_reason=$(printf '%s\n' "$quc_notes" | "$quc_bin_awk" '
            BEGIN { disk = "физический диск однозначно не определён; совпадение разделов не проверялось" }
            {
                if ($0 == "") next
                if ($0 == disk) { has = 1; next }
                print
                found = 1
                exit
            }
            END { if (!found && has) print disk }
        ')
        qm_verdict='Вердикт: можно копировать с ограничением.'
        return 0
    fi
    case ${quc_dest_link_probe:-UNKNOWN} in
        link)
            qm_verdict='Проверка: можно начинать'
            qm_reason=
            ;;
        exclusive)
            qm_reason='новое имя создаётся сразу и проверяется после записи'
            qm_verdict='Вердикт: можно копировать с ограничением.'
            ;;
        unsupported)
            qm_reason='на этом назначении нельзя создать новое имя без риска замены'
            qm_verdict='Вердикт: можно копировать с ограничением.'
            ;;
        *)
            qm_reason='жёсткие ссылки на назначении не проверялись'
            qm_verdict='Вердикт: можно копировать с ограничением.'
            ;;
    esac
    return 0
}

quc_menu_show_details() {
    printf '\n%s\n' "Подробности"
    printf '%s\n' "Запуск не начат."
    printf '%s\n' "Проверки:"
    if [ "$quc_preflight_ok" = 1 ]; then
        printf '%s\n' "  Доступ к накопителям: да"
    else
        printf '%s\n' "  Доступ к накопителям: нельзя"
    fi
    if [ -n "${quc_need_bytes:-}" ] && [ -n "${quc_free_have:-}" ]; then
        printf '  Данные: %s\n' "$(quc_human_bytes "$quc_need_bytes")"
        printf '  Свободно: %s\n' "$(quc_human_bytes "$quc_free_have")"
        case $quc_problems in
            *'недостаточно свободного места'*)
                printf '%s\n' "  Свободное место: недостаточно"
                ;;
            *)
                printf '%s\n' "  Свободное место: достаточно"
                ;;
        esac
    else
        printf '%s\n' "  Свободное место: не подтверждено"
    fi
    if [ "${quc_dest_mode:-root}" = separate ]; then
        printf '%s\n' "  Существующие файлы: защищены"
        if [ -n "${quc_dest_rel:-}" ]; then
            printf '  Папка: %s\n' "$(quc_display_path "$quc_target/$quc_dest_rel")"
        fi
    elif [ -n "${quc_target:-}" ] && [ ! -L "$quc_target" ] && quc_dir_nonempty "$quc_target"; then
        printf '%s\n' "  Существующие файлы: на назначении уже есть данные, копирование в корень не начато"
    else
        printf '%s\n' "  Существующие файлы: назначение пустое"
    fi
    case ${quc_dest_link_probe:-UNKNOWN} in
        link)
            printf '%s\n' "  Жёсткие ссылки на назначении: доступны"
            ;;
        exclusive)
            printf '%s\n' "  Жёсткие ссылки на назначении: недоступны, новое имя создаётся сразу и проверяется после записи"
            ;;
        unsupported)
            printf '%s\n' "  Жёсткие ссылки на назначении: создать новое имя без риска замены нельзя"
            ;;
        *)
            printf '%s\n' "  Жёсткие ссылки на назначении: не проверялись"
            ;;
    esac
    printf '%s\n' "  Файловая система назначения: этой проверкой не подтверждена"
    if [ "${quc_stage_offer:-0}" = 1 ]; then
        printf '%s\n' "  Локальная копия: доступна, чтение по умолчанию с источника"
    else
        printf '%s\n' "  Локальная копия: не используется"
    fi
    if [ -n "$quc_source_fs" ] || [ -n "$quc_target_fs" ]; then
        printf '  Тип: %s → %s\n' "${quc_source_fs:-неизвестен}" "${quc_target_fs:-неизвестен}"
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
    printf '%s\n' "Режим программы: бережный"
    if [ "${quc_eject_policy:-no}" = yes ]; then
        printf '%s\n' "Автоотключение назначения: включено"
    else
        printf '%s\n' "Автоотключение назначения: выключено"
    fi
    printf '%s\n' "Исходный накопитель остаётся подключённым."
}

quc_menu_show_confirm() {
    quc_menu_set_verdict
    printf '\n%s\n' "Quiet USB Copy"
    printf '\n'
    quc_print_side "Источник" "$quc_menu_src"
    printf '\n'
    printf '%s\n' "       ↓"
    printf '\n'
    quc_print_side "Назначение" "$quc_menu_dst"
    printf '\n'
    quc_label_for_path "$quc_menu_src" "$quc_menu_file"
    qm_src_name=$(quc_display_path "$quc_lp_label")
    quc_label_for_path "$quc_menu_dst" "$quc_menu_file"
    qm_dst_name=$(quc_display_path "$quc_lp_label")
    printf 'Направление: %s → %s\n' "$qm_src_name" "$qm_dst_name"
    if [ -n "${quc_need_bytes:-}" ]; then
        printf 'Данные: %s\n' "$(quc_human_bytes "$quc_need_bytes")"
        printf 'Свободно: %s\n' "$(quc_human_bytes "${quc_free_have:-0}")"
    else
        printf '%s\n' "Данные: не посчитано"
        printf '%s\n' "Свободно: не подтверждено"
    fi
    printf '%s\n' "Режим: бережный"
    if [ "${quc_dest_mode:-root}" = separate ] && [ -n "${quc_dest_rel:-}" ]; then
        printf '%s\n' "Размещение: отдельная папка"
        printf 'Папка: %s\n' "$(quc_display_path "$quc_target/$quc_dest_rel")"
        printf '%s\n' "Существующие файлы назначения не изменяются."
    else
        printf '%s\n' "Размещение: корень назначения"
    fi
    printf '%s\n' "Существующие имена не заменяются."
    if [ "$quc_preflight_ok" = 1 ] && [ "${quc_publish_mode:-}" = exclusive ]; then
        printf '%s\n' "Жёсткие ссылки на назначении недоступны. Новый файл виден до проверки содержимого и не считается готовым."
    fi
    if [ "${quc_eject_policy:-no}" = yes ]; then
        printf '%s\n' "Отключение назначения: включено"
        printf '%s\n' "После копирования содержимое будет проверено. При успешной проверке программа попытается безопасно отключить назначение."
    else
        printf '%s\n' "Отключение назначения: выключено"
    fi
    printf '%s\n' "Исходный накопитель остаётся подключённым."
    printf '%s\n' "$qm_verdict"
    if [ -n "$qm_reason" ]; then
        printf 'Причина: %s\n' "$qm_reason"
    fi
    printf '\n'
    if [ "$quc_preflight_ok" = 1 ]; then
        printf '%s\n' "[1] Начать"
    fi
    printf '%s\n' "[2] Подробности"
    printf '%s\n' "[3] Изменить выбор"
    if [ "$quc_preflight_ok" = 1 ] && [ "${quc_stage_offer:-0}" = 1 ]; then
        printf '%s\n' "[4] Сначала локальная копия"
    fi
    if [ "${quc_eject_policy:-no}" = yes ]; then
        printf '%s\n' "[5] Оставить назначение подключённым"
    else
        printf '%s\n' "[5] Включить отключение назначения"
    fi
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
        quc_dest_mode=root
        quc_source_mode=direct
        quc_dest_rel=
        quc_planned_id=
        quc_stage_offer=0
        if quc_validate_pair "$quc_menu_src" "$quc_menu_dst" fresh; then
            quc_preflight_ok=1
        elif quc_mentions_nonempty && quc_validate_pair "$quc_menu_src" "$quc_menu_dst" separate; then
            quc_planned_id=$(quc_new_job_id)
            if quc_pick_dest_rel; then
                quc_dest_mode=separate
                quc_preflight_ok=1
            else
                quc_add_problem "${quc_error:-не удалось подобрать новый каталог назначения}"
                quc_preflight_ok=0
            fi
        else
            quc_preflight_ok=0
        fi
        if [ "$quc_preflight_ok" = 1 ]; then
            quc_stage_offer_check || true
        fi
        if [ -n "${quc_target_fs:-}" ]; then
            qm_caut=$(quc_fs_caution "$quc_target_fs" || true)
            if [ -n "$qm_caut" ]; then
                quc_add_note "$qm_caut"
            fi
        fi
        if [ "$quc_preflight_ok" = 1 ]; then
            if ! quc_select_publish_mode "$quc_target"; then
                quc_add_problem "${quc_error:-На этом назначении нельзя создать новое имя без риска замены. Копирование не начато.}"
                quc_preflight_ok=0
            elif [ "${quc_publish_mode:-}" = exclusive ]; then
                quc_add_note "Жёсткие ссылки на назначении недоступны. Новый файл виден до проверки содержимого и не считается готовым."
            fi
        fi
        quc_note_pending_job
        quc_eject_policy=yes
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
                2)
                    quc_menu_show_details
                    ;;
                3) break ;;
                1|4)
                    if [ "$quc_preflight_ok" != 1 ]; then
                        printf '%s\n' "Запуск запрещён."
                        continue
                    fi
                    if [ "$quc_menu_answer" = 4 ] && [ "${quc_stage_offer:-0}" != 1 ]; then
                        printf '%s\n' "Нужно 1, 2, 3, 5 или 0."
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
                    if [ "$quc_menu_answer" = 4 ]; then
                        quc_source_mode=staged
                    else
                        quc_source_mode=direct
                    fi
                    quc_launch_prepared
                    ;;
                5)
                    if [ "$quc_eject_policy" = yes ]; then
                        quc_eject_policy=no
                    else
                        quc_eject_policy=yes
                    fi
                    ;;
                *)
                    if [ "${quc_stage_offer:-0}" = 1 ]; then
                        printf '%s\n' "Нужно 1, 2, 3, 4, 5 или 0."
                    else
                        printf '%s\n' "Нужно 1, 2, 3, 5 или 0."
                    fi
                    ;;
            esac
        done
    done
}
# Каталог создаётся в текущей оболочке. Подстановка $(...) теряет
# quc_runtime_base, после чего удаление отказывается от своего каталога.
quc_make_probe_dir() {
    quc_probe_path=
    if quc_runtime_prepare; then
        pd_base=$quc_runtime_base
    elif [ -n "${quc_state_dir:-}" ] && [ -d "$quc_state_dir" ] && [ ! -L "$quc_state_dir" ]; then
        pd_base=$quc_state_dir
    else
        return 1
    fi
    quc_probe_seq=$((${quc_probe_seq:-0} + 1))
    pd=$pd_base/probe.$$.$quc_probe_seq
    if [ -e "$pd" ] || [ -L "$pd" ]; then
        return 1
    fi
    "$quc_bin_mkdir" -p -- "$pd" 2>/dev/null || return 1
    "$quc_bin_chmod" 700 -- "$pd" 2>/dev/null || return 1
    quc_probe_path=$pd
    return 0
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

# Проба идёт в частном каталоге состояния, не на накопителе пользователя.
# Успех cp здесь не делает файловую систему назначения проверенной.
quc_probe_host_compat() {
    if [ "${quc_compat_done:-0}" = 1 ]; then
        return 0
    fi
    quc_compat_shell=UNKNOWN
    quc_compat_find=UNKNOWN
    quc_compat_proc=UNKNOWN
    quc_compat_cp=UNKNOWN
    quc_compat_publish=UNKNOWN
    quc_compat_hash=UNKNOWN
    quc_compat_state=UNKNOWN
    quc_compat_recover=UNKNOWN
    quc_compat_data=UNKNOWN
    quc_compat_fs=UNKNOWN
    quc_compat_level=UNKNOWN
    if command -v sh >/dev/null 2>&1; then
        quc_compat_shell=SUPPORTED
    else
        quc_compat_shell=UNSUPPORTED
    fi
    if "$quc_bin_find" /proc/self -xdev -print0 -quit >/dev/null 2>&1; then
        quc_compat_find=SUPPORTED
    else
        quc_compat_find=UNSUPPORTED
    fi
    if [ -d /proc/self/fd ]; then
        quc_compat_proc=SUPPORTED
    else
        quc_compat_proc=UNSUPPORTED
    fi
    if quc_hash_tool; then
        quc_compat_hash=SUPPORTED
    elif [ -n "${quc_bin_cmp:-}" ]; then
        quc_compat_hash=LIMITED
    else
        quc_compat_hash=UNSUPPORTED
    fi
    if [ -n "${quc_state_dir:-}" ] && [ -d "$quc_state_dir" ] && [ ! -L "$quc_state_dir" ]; then
        quc_compat_state=SUPPORTED
        quc_compat_recover=SUPPORTED
    else
        quc_compat_state=UNSUPPORTED
        quc_compat_recover=UNSUPPORTED
    fi
    hc_data=$(quc_stage_root || true)
    if [ -n "$hc_data" ]; then
        if [ -d "$hc_data" ] && [ ! -L "$hc_data" ]; then
            quc_compat_data=SUPPORTED
        else
            quc_compat_data=LIMITED
        fi
    fi
    hc_dir=
    if quc_make_probe_dir; then
        hc_dir=$quc_probe_path
    fi
    if [ -n "$hc_dir" ]; then
        printf 'probe\n' > "$hc_dir/src" || true
        hc_fd=$(
            set -C
            if ! exec 3>"$hc_dir/dst"; then
                set +C
                printf '%s\n' UNSUPPORTED
                exit 0
            fi
            set +C
            hc_ino=$("$quc_bin_stat" -L -c '%i' /proc/self/fd/3 2>/dev/null || true)
            case $hc_ino in
                ''|*[!0-9]*)
                    exec 3>&-
                    printf '%s\n' UNSUPPORTED
                    exit 0
                    ;;
            esac
            hc_wrote=1
            case ${quc_cp_sparse:-0} in
                1)
                    "$quc_bin_cp" --sparse=auto -- "$hc_dir/src" /proc/self/fd/3 >/dev/null 2>&1 || hc_wrote=0
                    ;;
                *)
                    "$quc_bin_cp" -- "$hc_dir/src" /proc/self/fd/3 >/dev/null 2>&1 || hc_wrote=0
                    ;;
            esac
            exec 3>&-
            if [ "$hc_wrote" != 1 ]; then
                printf '%s\n' UNSUPPORTED
                exit 0
            fi
            if [ -L "$hc_dir/dst" ] || [ ! -f "$hc_dir/dst" ]; then
                printf '%s\n' UNSUPPORTED
                exit 0
            fi
            hc_now=$("$quc_bin_stat" -c '%i' -- "$hc_dir/dst" 2>/dev/null || true)
            if [ -z "$hc_now" ] || [ "$hc_now" != "$hc_ino" ]; then
                printf '%s\n' UNSUPPORTED
                exit 0
            fi
            if [ -z "${quc_bin_cmp:-}" ]; then
                printf '%s\n' UNKNOWN
                exit 0
            fi
            if "$quc_bin_cmp" -s -- "$hc_dir/src" "$hc_dir/dst"; then
                printf '%s\n' SUPPORTED
            else
                printf '%s\n' UNSUPPORTED
            fi
        )
        case $hc_fd in
            SUPPORTED|UNSUPPORTED|UNKNOWN) quc_compat_cp=$hc_fd ;;
            *) quc_compat_cp=UNSUPPORTED ;;
        esac
        printf 'link\n' > "$hc_dir/linksrc" || true
        if "$quc_bin_ln" -- "$hc_dir/linksrc" "$hc_dir/linkdst" 2>/dev/null; then
            printf 'other\n' > "$hc_dir/other" || true
            "$quc_bin_mv" -n -- "$hc_dir/other" "$hc_dir/linkdst" >/dev/null 2>&1 || true
            if [ -f "$hc_dir/other" ] && [ -f "$hc_dir/linkdst" ] && [ ! -L "$hc_dir/linkdst" ] && [ -n "${quc_bin_cmp:-}" ] && "$quc_bin_cmp" -s -- "$hc_dir/linksrc" "$hc_dir/linkdst"; then
                quc_compat_publish=SUPPORTED
            else
                quc_compat_publish=UNSUPPORTED
            fi
        elif "$quc_bin_mv" -n -- "$hc_dir/linksrc" "$hc_dir/linkdst" 2>/dev/null; then
            if [ ! -e "$hc_dir/linksrc" ] && [ -f "$hc_dir/linkdst" ] && [ ! -L "$hc_dir/linkdst" ]; then
                quc_compat_publish=LIMITED
            else
                quc_compat_publish=UNSUPPORTED
            fi
        else
            quc_compat_publish=UNSUPPORTED
        fi
        quc_remove_probe_dir "$hc_dir" || true
    fi
    if [ "$quc_compat_shell" = UNSUPPORTED ] || [ "$quc_compat_find" = UNSUPPORTED ] || [ "$quc_compat_proc" = UNSUPPORTED ] || [ "$quc_compat_cp" = UNSUPPORTED ] || [ "$quc_compat_publish" = UNSUPPORTED ] || [ "$quc_compat_state" = UNSUPPORTED ]; then
        quc_compat_level=UNSUPPORTED
    elif [ "$quc_compat_shell" = UNKNOWN ] || [ "$quc_compat_find" = UNKNOWN ] || [ "$quc_compat_proc" = UNKNOWN ] || [ "$quc_compat_cp" = UNKNOWN ] || [ "$quc_compat_publish" = UNKNOWN ] || [ "$quc_compat_state" = UNKNOWN ]; then
        quc_compat_level=UNKNOWN
    elif [ "$quc_compat_fs" = SUPPORTED ] && [ "$quc_compat_cp" = SUPPORTED ] && [ "$quc_compat_publish" = SUPPORTED ] && [ "$quc_compat_hash" = SUPPORTED ] && [ "$quc_compat_data" = SUPPORTED ]; then
        quc_compat_level=SUPPORTED
    else
        quc_compat_level=LIMITED
    fi
    quc_compat_done=1
    return 0
}

quc_print_compat() {
    printf 'compat_level=%s\n' "${quc_compat_level:-UNKNOWN}"
    printf 'host_write=%s\n' "${quc_compat_cp:-UNKNOWN}"
    printf 'fs_gate=%s\n' "${quc_compat_fs:-UNKNOWN}"
    printf 'posix_shell=%s\n' "${quc_compat_shell:-UNKNOWN}"
    printf 'find_print0=%s\n' "${quc_compat_find:-UNKNOWN}"
    printf 'proc_fd=%s\n' "${quc_compat_proc:-UNKNOWN}"
    printf 'fd_publish=%s\n' "${quc_compat_cp:-UNKNOWN}"
    printf 'publish_probe=%s\n' "${quc_compat_publish:-UNKNOWN}"
    printf 'hash_tool=%s\n' "${quc_compat_hash:-UNKNOWN}"
    printf 'state_dir=%s\n' "${quc_compat_state:-UNKNOWN}"
    printf 'recovery=%s\n' "${quc_compat_recover:-UNKNOWN}"
    printf 'data_dir=%s\n' "${quc_compat_data:-UNKNOWN}"
    printf 'Совместимость: %s\n' "${quc_compat_level:-UNKNOWN}"
    printf '%s\n' "Файловая система назначения этой командой не проверялась."
    printf '%s\n' "Успех команды не означает совместимость файловой системы."
}

# --- Диагностика и точка входа ---

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
        probe=
        if quc_make_probe_dir; then
            probe=$quc_probe_path
        fi
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
    quc_probe_host_compat
    quc_print_compat
    if quc_hash_tool; then
        printf 'Контрольная сумма: %s\n' "$quc_hash_name"
    else
        printf '%s\n' "Контрольная сумма: нет. Локальная копия в этом режиме не фиксируется."
    fi
    doc_stage=$(quc_stage_root || true)
    if [ -n "$doc_stage" ]; then
        printf 'Каталог локальной копии: %s\n' "$doc_stage"
    else
        printf '%s\n' "Каталог локальной копии: не определён"
    fi
    printf '%s\n' "Размещение по умолчанию: корень пустого назначения. Непустое — отдельная папка."
    printf '%s\n' "MERGE_SAFE=NOT_IMPLEMENTED"
    printf '%s\n' "Публикация файла: существующее имя не заменяется. Если жёсткая ссылка доступна, новое имя создаётся ею. Если ссылки нет, новое имя создаётся один раз и сразу видно; оно не считается проверенным, пока содержимое не совпадёт. Это не атомарная публикация. Принудительное перемещение не используется."
    printf '%s\n' "publish_policy=no-replace"
    printf '%s\n' "dest_link_probe=UNKNOWN"
    printf '%s\n' "checks_not_run=dest_hardlink"
    if [ -n "${quc_bin_cmp:-}" ]; then
        printf '%s\n' "Сравнение содержимого: cmp"
    else
        printf '%s\n' "Сравнение содержимого: нет"
    fi
    doc_tool=none
    if quc_hash_tool; then
        doc_tool=$quc_hash_name
    elif [ -n "${quc_bin_cmp:-}" ]; then
        doc_tool='cmp'
    fi
    printf 'content_tool=%s\n' "$doc_tool"
    doc_shell=$(command -v sh 2>/dev/null || true)
    if [ -n "$doc_shell" ]; then
        printf 'shell=%s\n' "$doc_shell"
    else
        printf '%s\n' "shell=UNKNOWN"
    fi
    doc_sha=UNKNOWN
    if [ -n "${quc_self:-}" ] && [ -n "${quc_bin_sha256:-}" ]; then
        doc_sha=$("$quc_bin_sha256" -- "$quc_self" 2>/dev/null | "$quc_bin_awk" 'NR == 1 && $1 ~ /^[0-9A-Fa-f]+$/ { print $1; exit }')
        [ -n "$doc_sha" ] || doc_sha=UNKNOWN
    fi
    printf 'sha256=%s\n' "$doc_sha"
    printf '%s\n' "Профиль gentle: nice 19 и ionice best-effort 7 только у своего процесса. Задержки флешки этим не отменяются."
    printf '%s\n' "Меню не обходит дерево файлов, пока не выбраны оба пути."
    printf '%s\n' "Уведомления других программ не отключаются. Своих окон и звуков нет."
    if command -v udisksctl >/dev/null 2>&1; then
        printf '%s\n' "udisksctl: есть, необязательная программа. Отключение назначения ею не обещается."
    else
        printf '%s\n' "udisksctl: нет. Автоотключение назначения недоступно, копирование от этого не зависит."
    fi
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
    quc_fat_name_bad vfat 'CON' || st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_fat_name_bad exfat 'a:b' || st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_fat_name_bad ntfs 'a*b' || st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_fat_name_bad ext4 'a:b' && st_bad=$(quc_add_bytes "$st_bad" 1)
    quc_fat_name_bad vfat 'my file.txt' && st_bad=$(quc_add_bytes "$st_bad" 1)
    case $(quc_name_class tmpfs) in
        posix) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    case $(quc_name_class exfat) in
        exfat) ;;
        *) st_bad=$(quc_add_bytes "$st_bad" 1) ;;
    esac
    msg=$(quc_disk_pair_problem tmpfs tmpfs || true)
    if [ -n "$msg" ]; then
        st_bad=$(quc_add_bytes "$st_bad" 1)
    fi
    quc_default_job_vars
    if [ "$quc_source_mode" != direct ] || [ "$quc_dest_mode" != root ]; then
        st_bad=$(quc_add_bytes "$st_bad" 1)
    fi
    if quc_hash_file /no/such/quc-hash-file >/dev/null 2>&1; then
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
        if [ "$quc_source_mode" = staged ] || [ -n "${quc_stage_dir:-}" ]; then
            printf 'Можно удалить локальную копию: %s\n' "$cl_id"
        fi
        if [ "$quc_cleanup_dry" = 1 ]; then
            removed=$(quc_add_bytes "$removed" 1)
            continue
        fi
        quc_job_id=$cl_id
        quc_job_dir=$cl_dir
        quc_mount_mark_cleanup_dest || true
        if ! quc_stage_remove_job "$cl_id"; then
            printf 'Локальная копия оставлена: %s\n' "$cl_id" >&2
        fi
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
        start|check|status|report|stop|resume|verify|help|-h|--help|doctor|selftest|cleanup|version|plan|_worker) ;;
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
        plan) quc_cmd_plan "$@" ;;
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

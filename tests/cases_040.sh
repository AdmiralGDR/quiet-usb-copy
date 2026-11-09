# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 AdmiralGDR
#
# Quiet USB Copy 0.4.0 groups A–D.
# Sourced by tests/run.sh after the helpers and the 0.3.0 cases.
# FAT32, exFAT and NTFS are not mounted here. Those types stay UNKNOWN.
# A02 checks the ASCII fold refusal on tmpfs, which is case-sensitive.

c40_sha() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

c40_stage_dir() {
    c40_id=$(cat "$XDG_STATE_HOME/quiet-usb-copy/current" 2>/dev/null || true)
    c40_base=${XDG_DATA_HOME:-$HOME/.local/share}
    printf '%s\n' "$c40_base/quiet-usb-copy/staging/$c40_id"
}

c40_owner_pid() {
    awk -F= '$1 == "pid" { print $2; exit }' "$XDG_STATE_HOME/quiet-usb-copy/owner" 2>/dev/null || true
}

c40_quc_count() {
    find "$1" -mindepth 1 -maxdepth 1 -type d -name 'QUC-*' 2>/dev/null | wc -l | tr -d ' '
}

c40_wait_preparing_pause() {
    # Hang ceiling in seconds. Older callers passed an iteration count:
    # 100 steps of 0.2s were 20s. A nice-19 worker can stay in planning
    # longer than that under a full suite (suite-rc3-final.log, T27).
    # The matching phase still returns immediately.
    c40_secs=${1:-80}
    case $c40_secs in
        ''|*[!0-9]*) c40_secs=80 ;;
    esac
    c40_max=$((c40_secs * 5))
    c40_i=0
    while [ "$c40_i" -lt "$c40_max" ]; do
        c40_ph=$(job_field phase || true)
        c40_ss=$(job_field stage_status || true)
        c40_st=$(job_field copy_status || true)
        case $c40_st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) return 1 ;;
        esac
        case $c40_ph in
            *pause*)
                if [ "$c40_ss" != READY ]; then
                    return 0
                fi
                ;;
        esac
        sleep 0.2
        c40_i=$((c40_i + 1))
    done
    return 1
}

c40_wait_ready_running() {
    # Hang ceiling in seconds, same justification as c40_wait_preparing_pause.
    # READY while the job is still running returns immediately.
    c40_secs=${1:-80}
    case $c40_secs in
        ''|*[!0-9]*) c40_secs=80 ;;
    esac
    c40_max=$((c40_secs * 5))
    c40_i=0
    while [ "$c40_i" -lt "$c40_max" ]; do
        c40_ss=$(job_field stage_status || true)
        c40_st=$(job_field copy_status || true)
        if [ "$c40_ss" = READY ]; then
            case $c40_st in
                RUNNING|STARTING) return 0 ;;
            esac
        fi
        case $c40_st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) return 1 ;;
        esac
        sleep 0.2
        c40_i=$((c40_i + 1))
    done
    return 1
}

c40_limited_path() {
    c40_lim=$1
    mkdir -p "$c40_lim" || return 1
    for c40_tool in find stat awk od tr mkdir rmdir rm mv ln chmod date readlink sleep cat cp grep dirname basename cmp; do
        c40_bin=$(PATH=$ORIG_PATH command -v "$c40_tool") || return 1
        ln -s "$c40_bin" "$c40_lim/$c40_tool" || return 1
    done
}

test_A01() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    printf 'payload\n' > "$src/a.txt"
    keep=$(c40_sha "$dst/keep.txt")
    save_src
    run_start --dest-mode separate "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    rel=$(job_field dest_rel || true)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    case $rel in
        QUC-*) ;;
        *) echo "dest_rel=$rel"; bad=1 ;;
    esac
    if [ "$(job_field dest_mode)" != separate ] || [ "$(job_field source_mode)" != direct ]; then
        echo "modes dest=$(job_field dest_mode) source=$(job_field source_mode)"
        bad=1
    fi
    if [ ! -d "$dst/$rel" ] || [ -L "$dst/$rel" ] || [ -e "$dst/a.txt" ]; then
        echo "placement"
        bad=1
    fi
    cmp -s "$src/a.txt" "$dst/$rel/a.txt" || bad=1
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ] || [ "$(c40_quc_count "$dst")" != 1 ]; then
        echo "keep or extra dir"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "separate preserve status=$st"; fi
}

test_A02() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || bad=1
    quc_prepare_state || bad=1
    mkdir -p "$dst/folder"
    printf 'inside\n' > "$dst/folder/keep.txt"
    fold_sha=$(c40_sha "$dst/folder/keep.txt")
    quc_target=$dst
    quc_target_dev=$(quc_dev_of "$dst" || true)
    quc_dest_rel=Folder
    quc_run_mode=fresh
    if quc_claim_dest_dir; then
        echo "case fold was accepted"
        bad=1
    fi
    if [ -e "$dst/Folder" ] || [ -L "$dst/Folder" ]; then
        echo "Folder was created"
        bad=1
    fi
    if [ "$(c40_sha "$dst/folder/keep.txt")" != "$fold_sha" ]; then
        echo "folded directory changed"
        bad=1
    fi
    mkdir -p "$dst/QUC-taken"
    printf 'taken\n' > "$dst/QUC-taken/x.txt"
    taken_sha=$(c40_sha "$dst/QUC-taken/x.txt")
    quc_dest_rel=QUC-taken
    quc_run_mode=fresh
    if quc_claim_dest_dir; then
        echo "existing directory was accepted"
        bad=1
    fi
    if [ "$(c40_sha "$dst/QUC-taken/x.txt")" != "$taken_sha" ]; then
        echo "existing directory changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "case fold or existing dir"; fi
}

test_A03() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || bad=1
    quc_prepare_state || bad=1
    out=$WORK/t-$current/outside
    mkdir -p "$out"
    printf 'secret\n' > "$out/secret"
    secret=$(c40_sha "$out/secret")
    ln -s "$out" "$dst/QUC-link"
    quc_target=$dst
    quc_target_dev=$(quc_dev_of "$dst" || true)
    quc_dest_rel=QUC-link
    quc_run_mode=fresh
    if quc_claim_dest_dir; then
        echo "symlink claim succeeded"
        bad=1
    fi
    if [ "$(c40_sha "$out/secret")" != "$secret" ] || [ -e "$out/a.txt" ]; then
        echo "claim followed the symlink"
        bad=1
    fi
    rm -f -- "$dst/QUC-link"
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    ln -s "$out" "$dst/escape"
    printf 'payload\n' > "$src/a.txt"
    run_start --dest-mode separate "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 80)
    rel=$(job_field dest_rel || true)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    cmp -s "$src/a.txt" "$dst/$rel/a.txt" || bad=1
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ] || [ "$(c40_sha "$out/secret")" != "$secret" ]; then
        echo "foreign data changed"
        bad=1
    fi
    if [ ! -L "$dst/escape" ] || [ -e "$out/a.txt" ]; then
        echo "escape link was followed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "symlink dest status=$st"; fi
}

test_A04() {
    bad=0
    make_pair 8m 256k || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    printf 'small\n' > "$src/a.txt"
    run_start --dest-mode separate "$src" "$dst"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if [ "$(job_field copy_status)" != FAILED ]; then
        echo "status=$(job_field copy_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" report
    if ! grep -q 'недостаточно' "$quc_out"; then
        echo "report missed space"
        cat "$quc_out"
        bad=1
    fi
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ] || [ "$(c40_quc_count "$dst")" != 0 ] || [ -e "$dst/a.txt" ]; then
        echo "dest changed"
        bad=1
    fi
    if [ "$(job_field stage_status)" = READY ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "separate no space"; fi
}

test_A05() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=5
    run_start --dest-mode separate "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "no pause phase=$(job_field phase)"
        bad=1
    fi
    rel=$(job_field dest_rel || true)
    run_quiet "$SH" "$SCRIPT" stop
    if [ "$quc_ec" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ]; then
        echo "stop status=$st"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field dest_rel)" != "$rel" ]; then
        echo "resume status=$st rel=$(job_field dest_rel) want=$rel"
        bad=1
    fi
    if [ "$(c40_quc_count "$dst")" != 1 ]; then
        echo "dir count=$(c40_quc_count "$dst")"
        bad=1
    fi
    trees_ok "$src" "$dst/$rel" || bad=1
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ]; then
        echo "keep changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "separate resume status=$st"; fi
}

test_A06() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    out=$WORK/t-$current/outside
    mkdir -p "$out"
    printf 'secret\n' > "$out/secret"
    secret=$(c40_sha "$out/secret")
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=5
    run_start --dest-mode separate "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "no pause"
        bad=1
    fi
    rel=$(job_field dest_rel || true)
    if [ -z "$rel" ] || [ ! -d "$dst/$rel" ]; then
        echo "missing dest dir $rel"
        bad=1
    else
        rm -rf -- "$dst/$rel"
        ln -s "$out" "$dst/$rel"
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ]; then
        echo "success after substitution"
        bad=1
    fi
    if [ -e "$out/a.txt" ] || [ -e "$out/b.txt" ] || [ "$(c40_sha "$out/secret")" != "$secret" ]; then
        echo "wrote outside"
        bad=1
    fi
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ]; then
        echo "keep changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "path substitution status=$st"; fi
}

test_B01() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'staged\n' > "$src/a.txt"
    cp -a "$src/a.txt" "$WORK/t-$current/payload"
    run_start --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field stage_status)" != READY ] || [ "$(job_field source_mode)" != staged ]; then
        echo "status=$st stage=$(job_field stage_status) mode=$(job_field source_mode)"
        bad=1
    fi
    cmp -s "$WORK/t-$current/payload" "$dst/a.txt" || bad=1
    if ! umount "$src"; then
        echo "umount source"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^verify_status=' "$quc_out"; then
        echo "verify without source ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if grep -q 'ОТЛИЧИЯ НАЙДЕНЫ' "$quc_out" || grep -q '^verify_status=failed$' "$quc_out"; then
        echo "verify failed"
        cat "$quc_out"
        bad=1
    fi
    cmp -s "$WORK/t-$current/payload" "$dst/a.txt" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "staged verify without source status=$st"; fi
}

test_B02() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'early\n' > "$src/a.txt"
    export QUC_FILE_PAUSE=5
    run_start --source-mode staged "$src" "$dst"
    if ! c40_wait_preparing_pause 100; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status) status=$(job_field copy_status)"
        bad=1
    fi
    if ! umount "$src"; then
        echo "umount"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" = READY ] || [ -e "$dst/a.txt" ]; then
        echo "status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "source lost before READY status=$st"; fi
}

test_B03() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'later\n' > "$src/a.txt"
    cp -a "$src/a.txt" "$WORK/t-$current/payload"
    export QUC_FILE_PAUSE=5
    run_start --source-mode staged "$src" "$dst"
    if ! c40_wait_ready_running 120; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status) status=$(job_field copy_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^source_dependency=not_required$' "$quc_out"; then
        echo "ready dependency"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Локальная копия подготовлена и проверена.' "$quc_out" || ! grep -q 'Источник: больше не требуется Quiet USB Copy.' "$quc_out" || grep -q 'Источник: ещё требуется' "$quc_out" || grep -q 'Источник: пока требуется.' "$quc_out"; then
        echo "ready text"
        cat "$quc_out"
        bad=1
    fi
    if ! umount "$src"; then
        echo "umount"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    cmp -s "$WORK/t-$current/payload" "$dst/a.txt" || bad=1
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^source_dependency=not_required$' "$quc_out"; then
        echo "finished dependency"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -ne 0 ] || grep -q '^verify_status=failed$' "$quc_out"; then
        echo "verify ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "source lost after READY status=$st"; fi
}

test_B04() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'intact\n' > "$src/a.txt"
    payload=$(c40_sha "$src/a.txt")
    run_start --source-mode staged "$src" "$dst"
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field stage_status)" != READY ]; then
        echo "status=$st"
        bad=1
    fi
    stage=$(c40_stage_dir)
    if [ ! -f "$stage/data/a.txt" ] || [ ! -f "$stage/manifest" ]; then
        echo "missing stage"
        bad=1
    fi
    printf 'corrupt\n' > "$stage/data/a.txt"
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -eq 0 ] || grep -q '^copy_status=SUCCESS$' "$quc_out"; then
        echo "damaged data still verified"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$(c40_sha "$dst/a.txt")" != "$payload" ]; then
        echo "dest changed after damaged data"
        bad=1
    fi
    printf 'intact\n' > "$stage/data/a.txt"
    printf 'not-a-manifest\n' > "$stage/manifest"
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -eq 0 ]; then
        echo "damaged manifest verified"
        cat "$quc_out"
        bad=1
    fi
    if [ "$(c40_sha "$dst/a.txt")" != "$payload" ]; then
        echo "dest changed after damaged manifest"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "damaged stage"; fi
}

test_B05() {
    bad=0
    lim=$WORK/t-$current/lim
    c40_limited_path "$lim" || { fail "path"; return; }
    make_pair || { fail "mount"; return; }
    printf 'nohash\n' > "$src/a.txt"
    run_quiet env PATH="$lim" "$SH" "$SCRIPT" start --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        echo "start ec=$quc_ec out=$quc_out_n err=$quc_err_n"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$(job_field copy_status)" != FAILED ] || [ "$(job_field stage_status)" = READY ]; then
        echo "status=$(job_field copy_status) stage=$(job_field stage_status)"
        bad=1
    fi
    if [ -e "$dst/a.txt" ]; then
        echo "published without a hash tool"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" report
    if ! grep -q 'нет средства проверки' "$quc_out"; then
        echo "report"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "staged without hash tool"; fi
}

test_B06() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || bad=1
    quc_prepare_state || bad=1
    printf 'a\n' > "$src/a.txt"
    quc_source=$src
    quc_target=$dst
    quc_source_dev=$(quc_dev_of "$src" || true)
    quc_target_dev=$(quc_dev_of "$dst" || true)
    quc_job_id=foreignjob
    quc_token=tok
    quc_job_dir=$XDG_STATE_HOME/quiet-usb-copy/jobs/$quc_job_id
    mkdir -p "$quc_job_dir"
    quc_open_run_dir || true
    root=$(quc_stage_root) || { fail "stage root"; return; }
    mkdir -p "$root/$quc_job_id"
    printf 'SECRET\n' > "$root/$quc_job_id/SECRET"
    printf 'job_id=someone-else\nuid=0\n' > "$root/$quc_job_id/OWNER"
    if quc_stage_prepare_dir; then
        echo "foreign stage accepted"
        bad=1
    fi
    if [ "$(cat "$root/$quc_job_id/SECRET" 2>/dev/null)" != SECRET ]; then
        echo "foreign stage deleted"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "foreign staging"; fi
}

test_B07() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'crash\n' > "$src/a.txt"
    cp -a "$src/a.txt" "$WORK/t-$current/payload"
    export QUC_FILE_PAUSE=5
    run_start --source-mode staged "$src" "$dst"
    if ! c40_wait_ready_running 120; then
        echo "not ready phase=$(job_field phase) stage=$(job_field stage_status)"
        bad=1
    fi
    pid=$(c40_owner_pid)
    case $pid in
        ''|0|1|*[!0-9]*) echo "pid=$pid"; bad=1 ;;
        *) kill -KILL "$pid" 2>/dev/null || bad=1 ;;
    esac
    sleep 0.3
    if [ "$(job_field copy_status)" != RUNNING ] && [ "$(job_field copy_status)" != STARTING ]; then
        echo "status changed to $(job_field copy_status) after SIGKILL"
        bad=1
    fi
    if ! umount "$src"; then
        echo "umount"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field recovery_status)" != resumed ]; then
        echo "status=$st recovery=$(job_field recovery_status)"
        bad=1
    fi
    cmp -s "$WORK/t-$current/payload" "$dst/a.txt" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "sigkill after READY status=$st"; fi
}

test_B08() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=5
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        bad=1
    fi
    src2=$WORK/t-$current/src2
    dst2=$WORK/t-$current/dst2
    mkdir -p "$src2" "$dst2"
    mount -t tmpfs -o size=8m tmpfs "$src2" || bad=1
    mount -t tmpfs -o size=8m tmpfs "$dst2" || bad=1
    printf 'q\n' > "$src2/q.txt"
    run_start "$src2" "$dst2"
    if [ "$quc_ec" -eq 0 ] || [ "$quc_noisy" -ne 0 ] || [ -e "$dst2/q.txt" ]; then
        echo "second start ec=$quc_ec"
        bad=1
    fi
    if [ "$(job_field copy_status)" != RUNNING ] && [ "$(job_field copy_status)" != STARTING ]; then
        echo "first job status=$(job_field copy_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" stop
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ]; then
        echo "stop status=$st"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "second start"; fi
}

test_B09() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'own\n' > "$src/a.txt"
    run_start --source-mode staged "$src" "$dst"
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    stage=$(c40_stage_dir)
    if [ ! -f "$stage/data/a.txt" ]; then
        echo "stage missing"
        bad=1
    fi
    base=${XDG_DATA_HOME:-$HOME/.local/share}
    other=$base/quiet-usb-copy/staging/other-keep
    mkdir -p "$other"
    printf 'SECRET\n' > "$other/SECRET"
    run_quiet "$SH" "$SCRIPT" cleanup
    if [ "$quc_ec" -ne 0 ] || [ -d "$stage" ]; then
        echo "own stage remains ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$(cat "$other/SECRET" 2>/dev/null)" != SECRET ]; then
        echo "foreign stage removed"
        bad=1
    fi
    printf 'own2\n' > "$src/b.txt"
    rm -f -- "$dst/a.txt"
    run_start --source-mode staged "$src" "$dst"
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "second status=$st"
        bad=1
    fi
    stage=$(c40_stage_dir)
    if ! mount -t tmpfs -o size=1m,ro tmpfs "$stage"; then
        echo "read-only mount unavailable"
        bad=1
    else
        run_quiet "$SH" "$SCRIPT" cleanup
        if ! grep -q 'Локальная копия оставлена' "$quc_err"; then
            echo "cleanup did not report the failure"
            cat "$quc_out" "$quc_err"
            bad=1
        fi
        umount "$stage" 2>/dev/null || umount -l "$stage" 2>/dev/null || true
        if [ ! -f "$stage/data/a.txt" ] && [ ! -f "$stage/data/b.txt" ]; then
            echo "stage bytes disappeared after a failed cleanup"
            bad=1
        fi
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "staging cleanup"; fi
}

test_B10() {
    bad=0
    make_pair 64m 64m || { fail "mount"; return; }
    truncate -s 40M "$src/big" || { fail "truncate"; return; }
    stagefs=$WORK/t-$current/stagefs
    mkdir -p "$stagefs"
    mount -t tmpfs -o size=128m tmpfs "$stagefs" || { fail "stage mount"; return; }
    export XDG_DATA_HOME=$stagefs/data
    mkdir -p "$XDG_DATA_HOME"
    run_start --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" = READY ] || [ -e "$dst/big" ]; then
        echo "tmpfs cap status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" report
    if ! grep -q 'tmpfs' "$quc_out"; then
        echo "tmpfs report"
        cat "$quc_out"
        bad=1
    fi
    unset XDG_DATA_HOME
    umount "$stagefs" 2>/dev/null || true
    rm -f -- "$src/big"
    printf 'tiny\n' > "$src/a.txt"
    small=$WORK/t-$current/smallfs
    mkdir -p "$small"
    mount -t tmpfs -o size=256k tmpfs "$small" || { fail "small mount"; return; }
    export XDG_DATA_HOME=$small/data
    mkdir -p "$XDG_DATA_HOME"
    rm -f -- "$dst/a.txt" "$dst/big"
    run_start --source-mode staged "$src" "$dst"
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" = READY ] || [ -e "$dst/a.txt" ]; then
        echo "nospace status=$st"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" report
    if ! grep -q 'недостаточно места для локальной копии' "$quc_out"; then
        echo "space report"
        cat "$quc_out"
        bad=1
    fi
    unset XDG_DATA_HOME
    if [ "$bad" -eq 0 ]; then pass; else fail "staging space"; fi
}

test_B11() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'before\n' > "$src/a.txt"
    export QUC_FILE_PAUSE=5
    run_start --source-mode staged "$src" "$dst"
    if ! c40_wait_preparing_pause 100; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status)"
        bad=1
    fi
    printf 'after\n' > "$src/a.txt"
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" = READY ] || [ -e "$dst/a.txt" ]; then
        echo "status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "mutate during stage status=$st"; fi
}

test_B12() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'ok\n' > "$src/ok.txt"
    printf 'secret\n' > "$src/quc-unreadable"
    chmod 000 "$src/quc-unreadable"
    gcc -shared -fPIC -O2 -o "$WORK/t-$current/eacess.so" "$ROOT/tests/eacess_preload.c" -ldl || {
        fail "preload compile"
        return
    }
    save_src
    export LD_PRELOAD=$WORK/t-$current/eacess.so
    export QUC_FILE_PAUSE=0
    run_start --source-mode staged "$src" "$dst"
    unset LD_PRELOAD
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" = READY ]; then
        echo "status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    if [ -e "$dst/ok.txt" ] || [ -e "$dst/quc-unreadable" ]; then
        echo "published after a read error"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "mid-read status=$st"; fi
}

test_B13() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'phase\n' > "$src/a.txt"
    export QUC_FILE_PAUSE=5
    run_start --source-mode staged "$src" "$dst"
    if ! c40_wait_preparing_pause 100; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" stop
    st=$(wait_done 40)
    if [ "$st" != CANCELLED ] || [ "$(job_field stage_status)" = READY ]; then
        echo "stop status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field stage_status)" != READY ]; then
        echo "resume status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    cmp -s "$src/a.txt" "$dst/a.txt" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "restart between phases status=$st"; fi
}

test_B14() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'manifest\n' > "$src/a.txt"
    export QUC_FILE_PAUSE=5
    run_start --source-mode staged "$src" "$dst"
    if ! c40_wait_preparing_pause 100; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status)"
        bad=1
    fi
    stage=$(c40_stage_dir)
    if [ ! -d "$stage" ]; then
        echo "no stage"
        bad=1
    else
        mv -- "$stage" "$stage.real" || bad=1
        printf 'blocked\n' > "$stage" || bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" = READY ] || [ -e "$dst/a.txt" ]; then
        echo "status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "manifest save status=$st"; fi
}

test_C01() {
    bad=0
    make_pair || { fail "mount"; return; }
    extra=$WORK/t-$current/extra
    mkdir -p "$extra"
    mount -t tmpfs -o size=8m tmpfs "$extra" || { fail "extra"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    printf 'slide\n' > "$src/deck.txt"
    fake=$WORK/t-$current/fake.tsv
    fake_row "$src" ext4 tmpfs "DISK-A" 33554432 30000000 > "$fake"
    fake_row "$extra" ext4 tmpfs "OTHER" 33554432 30000000 >> "$fake"
    fake_row "$dst" ext4 tmpfs "BACKUP" 67108864 65000000 >> "$fake"
    export QUC_FAKE_VOLUMES=$fake
    export QUC_PTY_TIMEOUT=40
    printf '1\n3\n1\n' > "$WORK/t-$current/in"
    COLUMNS=20 LINES=6 TERM=dumb NO_COLOR=1 pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    unset COLUMNS LINES NO_COLOR QUC_PTY_TIMEOUT
    if [ "$quc_pty_rc" -ne 0 ] || [ "$quc_ec" != 0 ]; then
        echo "pty ec=$quc_ec driver=$quc_pty_rc"
        cat "$quc_out" "$quc_meta" "$WORK/last.err"
        bad=1
    fi
    if [ "${quc_pty_esc:-1}" != 0 ]; then
        echo "escape bytes"
        bad=1
    fi
    if ! grep -q 'DISK-A' "$quc_out" || ! grep -q 'Размещение: отдельная папка' "$quc_out" || ! grep -q 'Вердикт: можно копировать с ограничением.' "$quc_out" || ! grep -q 'Копирование запущено в фоне' "$quc_out" || ! grep -q 'Существующие файлы назначения не изменяются.' "$quc_out" || grep -q 'Проверка: готово' "$quc_out" || grep -q 'Размещение: SEPARATE' "$quc_out"; then
        echo "menu text"
        cat "$quc_out"
        bad=1
    fi
    st=$(wait_done 80)
    rel=$(job_field dest_rel || true)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    cmp -s "$src/deck.txt" "$dst/$rel/deck.txt" || bad=1
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ] || [ -e "$dst/deck.txt" ]; then
        echo "keep or root placement"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "menu nonempty status=$st"; fi
}

test_C02() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    printf 'slide\n' > "$src/deck.txt"
    fake=$WORK/t-$current/fake.tsv
    fake_row "$src" ext4 tmpfs "ONE" 33554432 30000000 > "$fake"
    fake_row "$dst" ext4 tmpfs "TWO" 67108864 65000000 >> "$fake"
    export QUC_FAKE_VOLUMES=$fake
    printf '1\n2\n0\n' > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_ec" != 0 ] || ! grep -q 'Копирование не запущено.' "$quc_out" || grep -q 'Копирование запущено' "$quc_out"; then
        echo "cancel text"
        cat "$quc_out"
        bad=1
    fi
    if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ] || [ "$(c40_quc_count "$dst")" != 0 ]; then
        echo "cancel created work"
        bad=1
    fi
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ]; then
        echo "keep changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "cancel nonempty"; fi
}

test_C03() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    keep=$(c40_sha "$dst/keep.txt")
    printf 'plan\n' > "$src/a.txt"
    run_quiet "$SH" "$SCRIPT" plan "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^plan_result=OK$' "$quc_out" || ! grep -q '^dest_mode=separate$' "$quc_out" || ! grep -q 'Существующие данные: не изменяются' "$quc_out" || ! grep -q '^MERGE_SAFE=NOT_IMPLEMENTED$' "$quc_out" || ! grep -q '^plan_level=LIMITED$' "$quc_out" || ! grep -q '^publish_policy=no-replace$' "$quc_out" || ! grep -q '^dest_link_probe=UNKNOWN$' "$quc_out" || ! grep -q '^checks_not_run=dest_hardlink$' "$quc_out" || ! grep -q '^content_tool=' "$quc_out" || ! grep -q 'Не проверено:' "$quc_out"; then
        echo "plan nonempty ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ -f "$XDG_STATE_HOME/quiet-usb-copy/current" ] || [ -e "$dst/a.txt" ] || [ "$(c40_sha "$dst/keep.txt")" != "$keep" ]; then
        echo "plan copied"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" plan "$src"
    if [ "$quc_ec" -ne 2 ] || ! grep -q 'error_code=E_USAGE' "$quc_err"; then
        echo "plan usage ec=$quc_ec"
        bad=1
    fi
    lim=$WORK/t-$current/lim
    c40_limited_path "$lim" || bad=1
    run_quiet env PATH="$lim" "$SH" "$SCRIPT" plan --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -eq 0 ] || ! grep -q '^plan_result=REJECT$' "$quc_out" || grep -q '^plan_result=OK$' "$quc_out" || ! grep -q '^plan_level=REJECT$' "$quc_out" || ! grep -q 'Что сделать:' "$quc_out"; then
        echo "staged plan without hash ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if ! grep -q 'не является атомарным снимком' "$quc_out"; then
        echo "snapshot sentence missing"
        cat "$quc_out"
        bad=1
    fi
    if [ "$(c40_sha "$dst/keep.txt")" != "$keep" ]; then
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "plan"; fi
}

test_C04() {
    bad=0
    run_quiet "$SH" "$SCRIPT" doctor
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^MERGE_SAFE=NOT_IMPLEMENTED$' "$quc_out" || ! grep -q '^Контрольная сумма:' "$quc_out" || ! grep -q 'не отмечены как проверенные' "$quc_out" || ! grep -q '^error_code=E_OK$' "$quc_out" || ! grep -q '^publish_policy=no-replace$' "$quc_out" || ! grep -q '^dest_link_probe=UNKNOWN$' "$quc_out" || ! grep -q '^checks_not_run=dest_hardlink$' "$quc_out" || ! grep -q '^shell=' "$quc_out" || ! grep -q '^sha256=' "$quc_out" || ! grep -q 'Сравнение содержимого:' "$quc_out" || ! grep -q '^compat_level=LIMITED$' "$quc_out" || ! grep -q '^fs_gate=UNKNOWN$' "$quc_out" || ! grep -q '^fd_publish=SUPPORTED$' "$quc_out" || grep -q '^compat_level=SUPPORTED$' "$quc_out" || grep -q 'иначе проверка и mv' "$quc_out"; then
        echo "doctor"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" version
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^quiet-usb-copy 0.4.0-rc.7$' "$quc_out" || ! grep -q '^build 20261108.2$' "$quc_out" || ! grep -q '^sha256=' "$quc_out"; then
        echo "version"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "doctor and version"; fi
}

test_C05() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'quiet\n' > "$src/a.txt"
    run_start --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^stage_status=READY$' "$quc_out" || ! grep -q '^source_mode=staged$' "$quc_out" || ! grep -q '^dest_mode=root$' "$quc_out"; then
        echo "machine status"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "silent staged status=$st"; fi
}

test_D01() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'data\n' > "$src/a.txt"
    run_start "$src" "$dst"
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    payload=$(c40_sha "$dst/a.txt")
    id=$(cat "$XDG_STATE_HOME/quiet-usb-copy/current")
    state=$XDG_STATE_HOME/quiet-usb-copy/jobs/$id/state
    awk 'BEGIN { FS = OFS = "=" } $1 == "source_hex" { $2 = "zz" } { print }' "$state" > "$state.bad" || bad=1
    mv -f -- "$state.bad" "$state" || bad=1
    run_quiet "$SH" "$SCRIPT" status --machine
    if grep -q 'copy_status=SUCCESS' "$quc_out" || grep -q 'Копирование завершено' "$quc_out"; then
        echo "corrupt state looked successful"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$(c40_sha "$dst/a.txt")" != "$payload" ]; then
        echo "dest changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "corrupt state"; fi
}

test_D02() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'same\n' > "$src/a.txt"
    save_src
    run_start "$src" "$dst"
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    printf 'changed\n' > "$dst/a.txt"
    run_quiet "$SH" "$SCRIPT" verify
    if [ "$quc_ec" -eq 0 ] || ! grep -q 'отлича' "$quc_out"; then
        echo "verify ec=$quc_ec"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    src_same || bad=1
    if [ "$(cat "$dst/a.txt")" != changed ]; then
        echo "verify rewrote dest"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "checksum mismatch"; fi
}

test_D04() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'direct\n' > "$src/a.txt"
    printf 'more\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=5
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        bad=1
    fi
    pid=$(c40_owner_pid)
    case $pid in
        ''|0|1|*[!0-9]*) echo "pid=$pid"; bad=1 ;;
        *) kill -KILL "$pid" 2>/dev/null || bad=1 ;;
    esac
    sleep 0.3
    if [ "$(job_field copy_status)" = SUCCESS ]; then
        echo "SIGKILL became SUCCESS"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field recovery_status)" != resumed ]; then
        echo "status=$st recovery=$(job_field recovery_status)"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "direct SIGKILL resume status=$st"; fi
}

test_D05() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    save_src
    export QUC_FILE_PAUSE=5
    run_start "$src" "$dst"
    c40_i=0
    c40_seen=0
    while [ "$c40_i" -lt 80 ]; do
        c40_n=0
        [ -f "$dst/a.txt" ] && c40_n=$((c40_n + 1))
        [ -f "$dst/b.txt" ] && c40_n=$((c40_n + 1))
        c40_st=$(job_field copy_status || true)
        case $c40_st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) break ;;
        esac
        if [ "$c40_n" -eq 1 ]; then
            c40_seen=1
            break
        fi
        sleep 0.2
        c40_i=$((c40_i + 1))
    done
    if [ "$c40_seen" != 1 ]; then
        echo "did not catch one file status=$c40_st"
        bad=1
    elif [ -f "$dst/a.txt" ]; then
        printf 'OTHER\n' > "$dst/b.txt"
        protected=$dst/b.txt
    else
        printf 'OTHER\n' > "$dst/a.txt"
        protected=$dst/a.txt
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$st" != PARTIAL ]; then
        echo "status=$st"
        bad=1
    fi
    if [ -n "${protected:-}" ] && [ "$(cat "$protected")" != OTHER ]; then
        echo "protected file replaced"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "refuse replace status=$st"; fi
}

test_D06() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    save_src
    export QUC_FILE_PAUSE=5
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "no pause"
        bad=1
    fi
    if ! umount "$dst"; then
        echo "umount dest"
        bad=1
    fi
    mount -t tmpfs -o size=8m tmpfs "$dst" || { fail "remount"; return; }
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ]; then
        echo "success on a replaced dest"
        bad=1
    fi
    if [ -e "$dst/a.txt" ] || [ -e "$dst/b.txt" ]; then
        echo "wrote onto the new filesystem"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "dest identity status=$st"; fi
}

test_E01() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    save_src
    e01_wrap=$WORK/t-$current/bin
    e01_log=$WORK/t-$current/mv.log
    mkdir -p "$e01_wrap"
    : > "$e01_log"
    e01_mv=$(PATH=$ORIG_PATH command -v mv) || { fail "mv"; return; }
    cat > "$e01_wrap/ln" <<'EOF'
#!/bin/sh
exit 1
EOF
    cat > "$e01_wrap/mv" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >> "$e01_log"
exec $e01_mv "\$@"
EOF
    chmod 755 "$e01_wrap/ln" "$e01_wrap/mv"
    env PATH="$e01_wrap:$ORIG_PATH" QUC_FILE_PAUSE=8 "$SH" "$SCRIPT" start "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ] || [ -s "$WORK/last.out" ] || [ -s "$WORK/last.err" ]; then
        echo "start noisy or failed"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    e01_i=0
    e01_seen=0
    while [ "$e01_i" -lt 80 ]; do
        e01_n=0
        [ -f "$dst/a.txt" ] && e01_n=$((e01_n + 1))
        [ -f "$dst/b.txt" ] && e01_n=$((e01_n + 1))
        e01_st=$(job_field copy_status || true)
        case $e01_st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) break ;;
        esac
        if [ "$e01_n" -eq 1 ]; then
            e01_seen=1
            break
        fi
        sleep 0.2
        e01_i=$((e01_i + 1))
    done
    e01_protected=''
    e01_copied=''
    e01_src=''
    if [ "$e01_seen" != 1 ]; then
        echo "did not catch one file status=$e01_st"
        bad=1
    elif [ -f "$dst/a.txt" ]; then
        printf 'FOREIGN\n' > "$dst/b.txt"
        e01_protected=$dst/b.txt
        e01_copied=$dst/a.txt
        e01_src=$src/a.txt
    else
        printf 'FOREIGN\n' > "$dst/a.txt"
        e01_protected=$dst/a.txt
        e01_copied=$dst/b.txt
        e01_src=$src/b.txt
    fi
    e01_foreign=''
    if [ -n "$e01_protected" ]; then
        e01_foreign=$(c40_sha "$e01_protected")
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$st" != PARTIAL ]; then
        echo "status=$st"
        bad=1
    fi
    if [ -z "$e01_protected" ] || [ "$(c40_sha "$e01_protected")" != "$e01_foreign" ] || [ "$(cat "$e01_protected")" != FOREIGN ]; then
        echo "foreign file changed"
        bad=1
    fi
    if [ -z "$e01_copied" ] || ! cmp -s "$e01_src" "$e01_copied"; then
        bad=1
    fi
    if [ -z "$e01_copied" ] || ! grep -F -- '-n' "$e01_log" | grep -F -- "$e01_copied" >/dev/null; then
        echo "new file was not published with mv -n"
        cat "$e01_log"
        bad=1
    fi
    if grep -F -- '-f' "$e01_log" | grep -F -- "$e01_protected" >/dev/null; then
        echo "mv -f saw the foreign file"
        cat "$e01_log"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "mv -n keeps foreign file status=$st"; fi
}

test_E02() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || { fail "tools"; return; }
    e02_out=$WORK/t-$current/outside
    mkdir -p "$e02_out"
    printf 'SECRET\n' > "$e02_out/secret"
    e02_sha=$(c40_sha "$e02_out/secret")
    ln -s "$e02_out/secret" "$dst/owned"
    printf 'new\n' > "$WORK/t-$current/payload"
    quc_run_mode=fresh
    quc_write_root=''
    quc_write_ino=''
    quc_publish_limited=0
    quc_log_file=''
    quc_publish_file "$WORK/t-$current/payload" "$dst/owned"
    e02_rc=$?
    if [ "$e02_rc" -ne 11 ]; then
        echo "publish rc=$e02_rc"
        bad=1
    fi
    if [ "$(c40_sha "$e02_out/secret")" != "$e02_sha" ] || [ "$(cat "$e02_out/secret")" != SECRET ]; then
        echo "publish followed the symlink"
        bad=1
    fi
    if [ ! -L "$dst/owned" ]; then
        echo "destination symlink was replaced"
        bad=1
    fi
    e02_part=$dst/.quc-partial.e02
    ln -s "$e02_out/secret" "$e02_part"
    # Прежнее ожидание заменяло ссылку пустым файлом. Занятое имя остаётся.
    if quc_reserve_partial "$e02_part"; then
        echo "reserve replaced an occupied symlink"
        bad=1
    fi
    if [ ! -L "$e02_part" ]; then
        echo "occupied symlink was removed"
        bad=1
    fi
    if [ "$(c40_sha "$e02_out/secret")" != "$e02_sha" ] || [ "$(cat "$e02_out/secret")" != SECRET ]; then
        echo "reserve followed the symlink"
        bad=1
    fi
    mkdir -p "$dst/.quc-partial.dir"
    printf 'KEEPDIR\n' > "$dst/.quc-partial.dir/keep"
    e02_dir=$(c40_sha "$dst/.quc-partial.dir/keep")
    if quc_reserve_partial "$dst/.quc-partial.dir"; then
        echo "directory name was reused"
        bad=1
    fi
    if [ ! -d "$dst/.quc-partial.dir" ] || [ "$(c40_sha "$dst/.quc-partial.dir/keep")" != "$e02_dir" ]; then
        echo "directory at the reserved name was changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "symlink publish and partial"; fi
}

test_E03() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    save_src
    export QUC_FILE_PAUSE=8
    run_start --dest-mode separate "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "no pause phase=$(job_field phase)"
        bad=1
    fi
    e03_rel=$(job_field dest_rel || true)
    e03_live=$dst/$e03_rel
    e03_aside=$dst/aside-slot
    e03_repl=$dst/repl-slot
    if [ -z "$e03_rel" ] || [ ! -d "$e03_live" ] || [ -L "$e03_live" ]; then
        echo "write root missing rel=$e03_rel"
        bad=1
    else
        e03_mark=$(find "$e03_live" -mindepth 1 -maxdepth 1 -type f -name '.quc-mnt-*' -print | head -n 1)
        e03_base=$(basename -- "$e03_mark")
        if [ -z "$e03_mark" ] || [ -L "$e03_mark" ]; then
            echo "mark missing"
            bad=1
        else
            mkdir -p "$e03_repl" || bad=1
            cp -- "$e03_mark" "$e03_repl/$e03_base" || bad=1
            if ! mv -- "$e03_live" "$e03_aside"; then
                echo "could not move the write root"
                bad=1
            elif ! mv -- "$e03_repl" "$e03_live"; then
                echo "could not install the replacement"
                bad=1
            fi
        fi
    fi
    st=$(wait_done 80)
    unset QUC_FILE_PAUSE
    if [ "$st" = SUCCESS ]; then
        echo "success after the directory swap"
        bad=1
    fi
    if [ -e "$e03_live/a.txt" ] || [ -e "$e03_live/b.txt" ]; then
        echo "a file landed in the replacement directory"
        bad=1
    fi
    e03_n=0
    [ -f "$e03_aside/a.txt" ] && e03_n=$((e03_n + 1))
    [ -f "$e03_aside/b.txt" ] && e03_n=$((e03_n + 1))
    if [ "$e03_n" -ne 1 ]; then
        echo "aside count=$e03_n"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "same-filesystem directory swap status=$st"; fi
}

test_E04() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || { fail "tools"; return; }
    if ! quc_mountinfo_lookup "$dst"; then
        echo "lookup failed"
        bad=1
    fi
    e04_id=$(python3 - "$dst" <<'PY'
import sys
path = sys.argv[1]

def unesc(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 3 < len(s) and all(c in "01234567" for c in s[i + 1:i + 4]):
            out.append(chr(int(s[i + 1:i + 4], 8)))
            i += 4
        else:
            out.append(s[i])
            i += 1
    return "".join(out)

last = ""
for line in open("/proc/self/mountinfo", encoding="ascii", errors="surrogateescape"):
    parts = line.split()
    if len(parts) > 4 and unesc(parts[4]) == path:
        last = parts[0]
print(last)
PY
)
    if [ "$quc_mi_fstype" != tmpfs ] || [ -z "$quc_mi_id" ] || [ "$quc_mi_id" != "$e04_id" ] || [ -z "$quc_mi_source" ]; then
        echo "fst=$quc_mi_fstype id=$quc_mi_id want=$e04_id src=$quc_mi_source"
        bad=1
    fi
    if quc_mountinfo_lookup "$dst/no-such-quc-path"; then
        echo "missing path was accepted"
        bad=1
    fi
    if [ -n "$quc_mi_id" ] || [ -n "$quc_mi_fstype" ]; then
        echo "failed lookup left fst=$quc_mi_fstype id=$quc_mi_id"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "mountinfo lookup"; fi
}

run_case A01 test_A01
run_case A02 test_A02
run_case A03 test_A03
run_case A04 test_A04
run_case A05 test_A05
run_case A06 test_A06
run_case B01 test_B01
run_case B02 test_B02
run_case B03 test_B03
run_case B04 test_B04
run_case B05 test_B05
run_case B06 test_B06
run_case B07 test_B07
run_case B08 test_B08
run_case B09 test_B09
run_case B10 test_B10
run_case B11 test_B11
run_case B12 test_B12
run_case B13 test_B13
run_case B14 test_B14
run_case C01 test_C01
run_case C02 test_C02
run_case C03 test_C03
run_case C04 test_C04
run_case C05 test_C05
run_case D01 test_D01
run_case D02 test_D02
run_case D04 test_D04
run_case D05 test_D05
run_case D06 test_D06
run_case E01 test_E01
run_case E02 test_E02
run_case E03 test_E03
run_case E04 test_E04

f_bind_job() {
    quc_resolve_tools || return 1
    quc_prepare_state || return 1
    quc_job_id=fjob
    quc_job_dir=$WORK/t-$current/job
    mkdir -p "$quc_job_dir" || return 1
    quc_run_dir=$quc_job_dir
    quc_log_file=$quc_job_dir/log
    : > "$quc_log_file" || return 1
    quc_publish_limited=0
    quc_run_mode=fresh
    quc_write_ino=
    quc_stop_requested=0
    return 0
}

f_arm_sentinel() {
    printf 'SENTINEL\n' > "$WORK/t-$current/sentinel"
    f_sentinel_sha=$(c40_sha "$WORK/t-$current/sentinel")
}

f_sentinel_ok() {
    [ "$(c40_sha "$WORK/t-$current/sentinel")" = "$f_sentinel_sha" ] && [ "$(cat "$WORK/t-$current/sentinel")" = SENTINEL ]
}

f_fail_ln() {
    f_fail_ln=$1
    cat > "$f_fail_ln" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod 755 "$f_fail_ln" || return 1
}

test_F01() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'payload\n' > "$src/a.txt"
    save_src
    f_arm_sentinel
    export QUC_PRE_PUBLISH_PAUSE=8
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! wait_phase prepublish 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    printf 'FOREIGN\n' > "$dst/a.txt"
    f_sha=$(c40_sha "$dst/a.txt")
    st=$(wait_done 80)
    unset QUC_PRE_PUBLISH_PAUSE
    if [ "$st" = SUCCESS ]; then
        echo "false success"
        bad=1
    fi
    if [ "$(c40_sha "$dst/a.txt")" != "$f_sha" ] || [ "$(cat "$dst/a.txt")" != FOREIGN ]; then
        echo "foreign file changed"
        bad=1
    fi
    f_sentinel_ok || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "foreign file before publish status=$st"; fi
}

test_F02() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'payload\n' > "$src/a.txt"
    save_src
    f_wrap=$WORK/t-$current/bin
    f_log=$WORK/t-$current/mv.log
    mkdir -p "$f_wrap"
    : > "$f_log"
    f_mv=$(PATH=$ORIG_PATH command -v mv) || { fail "mv"; return; }
    f_fail_ln "$f_wrap/ln" || { fail "ln wrapper"; return; }
    cat > "$f_wrap/mv" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$f_log"
exec $f_mv "\$@"
EOF
    chmod 755 "$f_wrap/mv" || bad=1
    env PATH="$f_wrap:$ORIG_PATH" "$SH" "$SCRIPT" start "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ] || [ -s "$WORK/last.out" ] || [ -s "$WORK/last.err" ]; then
        echo "start noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || ! cmp -s "$src/a.txt" "$dst/a.txt"; then
        echo "status=$st"
        bad=1
    fi
    if ! grep -F -- '-n' "$f_log" | grep -F -- "$dst/a.txt" >/dev/null; then
        echo "file was not published with mv -n"
        cat "$f_log"
        bad=1
    fi
    if grep -F -- '-f' "$f_log" | grep -F -- "$dst/a.txt" >/dev/null; then
        echo "mv -f saw the published file"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "hardlink refusal still publishes a free name status=$st"; fi
}

test_F03() {
    bad=0
    f_dir=$WORK/t-$current/gnu
    mkdir -p "$f_dir"
    printf 'KEEP\n' > "$f_dir/dest"
    printf 'NEW\n' > "$f_dir/src"
    f_sha=$(c40_sha "$f_dir/dest")
    f_dino=$(stat -c '%i' "$f_dir/dest")
    f_sino=$(stat -c '%i' "$f_dir/src")
    f_mv=$(PATH=$ORIG_PATH command -v mv) || { fail "mv"; return; }
    "$f_mv" -n -- "$f_dir/src" "$f_dir/dest"
    f_rc=$?
    # Код возврата mv -n при пропуске зависит от версии GNU coreutils
    # (9.4 возвращает 1, 9.7 возвращает 0). Проверяется результат, а не код.
    if [ "$(cat "$f_dir/dest")" != KEEP ] || [ "$(c40_sha "$f_dir/dest")" != "$f_sha" ] \
        || [ "$(stat -c '%i' "$f_dir/dest")" != "$f_dino" ] \
        || [ ! -f "$f_dir/src" ] || [ "$(cat "$f_dir/src")" != NEW ] \
        || [ "$(stat -c '%i' "$f_dir/src")" != "$f_sino" ]; then
        echo "gnu mv -n replaced or lost a file rc=$f_rc"
        bad=1
    fi
    echo "gnu mv -n skip rc=$f_rc"
    # Продукт: mv -n с кодом 0 без переноса (имя заняли между проверкой и mv)
    # не считается публикацией и не трогает чужой файл.
    f_rd=$WORK/t-$current/race
    mkdir -p "$f_rd"
    printf '#!/bin/sh\nprintf "FOREIGN\\n" > "%s/dst"\nexit 0\n' "$f_rd" > "$WORK/t-$current/mv-skip0"
    printf '#!/bin/sh\nexit 1\n' > "$WORK/t-$current/ln-no"
    chmod 755 "$WORK/t-$current/mv-skip0" "$WORK/t-$current/ln-no" || bad=1
    printf 'PAYLOAD\n' > "$f_rd/tmp"
    f_rino=$(stat -c '%i' "$f_rd/tmp")
    quc_bin_ln=$WORK/t-$current/ln-no
    quc_bin_mv=$WORK/t-$current/mv-skip0
    quc_install_new "$f_rd/tmp" "$f_rd/dst" "$f_rino"
    f_rc=$?
    quc_resolve_tools || bad=1
    if [ "$f_rc" -eq 0 ] || [ "$(cat "$f_rd/dst" 2>/dev/null)" != FOREIGN ] \
        || [ "$(cat "$f_rd/tmp" 2>/dev/null)" != PAYLOAD ] \
        || [ "$(stat -c '%i' "$f_rd/tmp" 2>/dev/null)" != "$f_rino" ]; then
        echo "install treated mv -n rc=0 skip as success rc=$f_rc"
        bad=1
    fi
    f_bind_job || { fail "job"; return; }
    f_fail_ln "$WORK/t-$current/ln-fail" || bad=1
    cat > "$WORK/t-$current/mv-no" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod 755 "$WORK/t-$current/mv-no" || bad=1
    printf 'PAYLOAD\n' > "$WORK/t-$current/payload"
    f_ino=$(stat -c '%i' "$WORK/t-$current/payload")
    quc_bin_ln=$WORK/t-$current/ln-fail
    quc_bin_mv=$WORK/t-$current/mv-no
    quc_install_new "$WORK/t-$current/payload" "$f_dir/free" "$f_ino"
    f_rc=$?
    quc_resolve_tools || bad=1
    if [ "$f_rc" -eq 0 ] || [ -e "$f_dir/free" ] || [ ! -f "$WORK/t-$current/payload" ]; then
        echo "install treated mv refusal as success rc=$f_rc"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "mv -n refusal"; fi
}

test_F04() {
    bad=0
    f_bb=$(PATH=$ORIG_PATH command -v busybox || true)
    if [ -z "$f_bb" ]; then
        echo "UNVERIFIED busybox mv -n"
    else
        f_bbdir=$WORK/t-$current/bb
        mkdir -p "$f_bbdir"
        printf 'KEEP\n' > "$f_bbdir/dest"
        printf 'NEW\n' > "$f_bbdir/src"
        f_sha=$(c40_sha "$f_bbdir/dest")
        "$f_bb" mv -n -- "$f_bbdir/src" "$f_bbdir/dest"
        if [ "$(cat "$f_bbdir/dest")" != KEEP ] || [ ! -f "$f_bbdir/src" ] || [ "$(c40_sha "$f_bbdir/dest")" != "$f_sha" ]; then
            echo "busybox mv -n changed the existing file"
            bad=1
        fi
    fi
    f_bind_job || { fail "job"; return; }
    f_fail_ln "$WORK/t-$current/ln-fail" || bad=1
    cat > "$WORK/t-$current/mv-zero" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 755 "$WORK/t-$current/mv-zero" || bad=1
    printf 'PAYLOAD\n' > "$WORK/t-$current/payload"
    f_ino=$(stat -c '%i' "$WORK/t-$current/payload")
    f_free=$WORK/t-$current/free
    quc_bin_ln=$WORK/t-$current/ln-fail
    quc_bin_mv=$WORK/t-$current/mv-zero
    quc_install_new "$WORK/t-$current/payload" "$f_free" "$f_ino"
    f_rc=$?
    quc_resolve_tools || bad=1
    if [ "$f_rc" -eq 0 ] || [ -e "$f_free" ] || [ ! -f "$WORK/t-$current/payload" ]; then
        echo "exit 0 without a move was accepted rc=$f_rc"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "mv -n zero without move"; fi
}

test_F05() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'payload\n' > "$src/a.txt"
    save_src
    f_out=$WORK/t-$current/outside
    mkdir -p "$f_out"
    printf 'SECRET\n' > "$f_out/secret"
    f_sha=$(c40_sha "$f_out/secret")
    f_arm_sentinel
    export QUC_FILL_PAUSE=8
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    f_part=
    f_i=0
    while [ "$f_i" -lt 60 ]; do
        f_part=$(find "$dst" -name '.quc-partial.*' -print 2>/dev/null | head -n 1)
        if [ -n "$f_part" ]; then
            break
        fi
        f_st=$(job_field copy_status || true)
        case $f_st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) break ;;
        esac
        sleep 0.1
        f_i=$((f_i + 1))
    done
    if [ -z "$f_part" ]; then
        echo "temp name was not caught status=$(job_field copy_status)"
        bad=1
    else
        rm -f -- "$f_part"
        ln -s "$f_out/secret" "$f_part" || bad=1
    fi
    st=$(wait_done 80)
    unset QUC_FILL_PAUSE
    if [ -n "$f_part" ] && [ ! -L "$f_part" ]; then
        echo "swapped temp name is no longer a symlink"
        bad=1
    fi
    if [ "$(c40_sha "$f_out/secret")" != "$f_sha" ] || [ "$(cat "$f_out/secret")" != SECRET ]; then
        echo "secret changed"
        bad=1
    fi
    if [ -f "$dst/a.txt" ] && [ ! -L "$dst/a.txt" ] && ! cmp -s "$src/a.txt" "$dst/a.txt"; then
        echo "published file does not match the source"
        bad=1
    fi
    if [ "$st" = SUCCESS ] && { [ ! -f "$dst/a.txt" ] || [ -L "$dst/a.txt" ] || ! cmp -s "$src/a.txt" "$dst/a.txt"; }; then
        echo "success without the source bytes"
        bad=1
    fi
    f_sentinel_ok || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "temp name swapped for a symlink status=$st"; fi
}

test_F06() {
    bad=0
    f_bind_job || { fail "job"; return; }
    f_dst=$WORK/t-$current/place
    mkdir -p "$f_dst"
    printf 'FOREIGN\n' > "$f_dst/.quc-partial.taken"
    f_sha=$(c40_sha "$f_dst/.quc-partial.taken")
    printf 'payload\n' > "$WORK/t-$current/payload"
    quc_transfer_exclusive "$WORK/t-$current/payload" "$f_dst/.quc-partial.taken" no
    f_rc=$?
    if [ "$f_rc" -eq 0 ]; then
        echo "transfer accepted an occupied name"
        bad=1
    fi
    if quc_reserve_partial "$f_dst/.quc-partial.taken"; then
        echo "reserve replaced a foreign file"
        bad=1
    fi
    if [ ! -f "$f_dst/.quc-partial.taken" ] || [ -L "$f_dst/.quc-partial.taken" ] || [ "$(c40_sha "$f_dst/.quc-partial.taken")" != "$f_sha" ] || [ "$(cat "$f_dst/.quc-partial.taken")" != FOREIGN ]; then
        echo "foreign temp file changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "foreign regular temp name"; fi
}

test_F07() {
    bad=0
    f_bind_job || { fail "job"; return; }
    f_dir=$WORK/t-$current/place/.quc-partial.dir
    mkdir -p "$f_dir"
    printf 'KEEPDIR\n' > "$f_dir/keep"
    f_sha=$(c40_sha "$f_dir/keep")
    printf 'payload\n' > "$WORK/t-$current/payload"
    quc_transfer_exclusive "$WORK/t-$current/payload" "$f_dir" no
    f_rc=$?
    if [ "$f_rc" -eq 0 ] || quc_reserve_partial "$f_dir"; then
        echo "directory name was reused rc=$f_rc"
        bad=1
    fi
    if [ ! -d "$f_dir" ] || [ -L "$f_dir" ] || [ "$(c40_sha "$f_dir/keep")" != "$f_sha" ] || [ "$(cat "$f_dir/keep")" != KEEPDIR ]; then
        echo "directory at the temp name changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "directory at temp name"; fi
}

test_F08() {
    bad=0
    make_pair || { fail "mount"; return; }
    mkdir -p "$src/sub"
    printf 'payload\n' > "$src/sub/a.txt"
    save_src
    f_arm_sentinel
    export QUC_PRE_PUBLISH_PAUSE=8
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! wait_phase prepublish 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    if [ ! -d "$dst/sub" ] || [ -L "$dst/sub" ]; then
        echo "parent missing"
        bad=1
    else
        mv -- "$dst/sub" "$dst/sub-aside" || bad=1
        mkdir -p "$dst/sub" || bad=1
        printf 'FOREIGN\n' > "$dst/sub/a.txt"
        f_sha=$(c40_sha "$dst/sub/a.txt")
    fi
    st=$(wait_done 80)
    unset QUC_PRE_PUBLISH_PAUSE
    if [ "$st" = SUCCESS ]; then
        echo "success after parent swap"
        bad=1
    fi
    if [ -z "$f_sha" ] || [ "$(c40_sha "$dst/sub/a.txt")" != "$f_sha" ] || [ "$(cat "$dst/sub/a.txt")" != FOREIGN ]; then
        echo "file in the replacement directory changed"
        bad=1
    fi
    f_sentinel_ok || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "parent directory swapped status=$st"; fi
}

test_F09() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'alpha-one\n' > "$src/a.txt"
    printf 'bravo-two\n' > "$src/b.txt"
    save_src
    f_arm_sentinel
    export QUC_FILE_PAUSE=6
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    if [ "$st" = SUCCESS ]; then
        bad=1
    fi
    f_copied=
    for f_name in a.txt b.txt; do
        if [ -f "$dst/$f_name" ]; then
            f_copied=$f_name
            break
        fi
    done
    if [ -z "$f_copied" ]; then
        echo "nothing copied"
        bad=1
    else
        printf 'CHANGED!!\n' > "$dst/$f_copied"
        f_sha=$(c40_sha "$dst/$f_copied")
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ]; then
        echo "resume replaced changed bytes"
        bad=1
    fi
    if [ -z "$f_copied" ] || [ "$(c40_sha "$dst/$f_copied")" != "$f_sha" ] || [ "$(cat "$dst/$f_copied")" != 'CHANGED!!' ]; then
        echo "changed file was replaced"
        bad=1
    fi
    f_other=b.txt
    if [ "$f_copied" = b.txt ]; then
        f_other=a.txt
    fi
    if [ -f "$dst/$f_other" ] && ! cmp -s "$src/$f_other" "$dst/$f_other"; then
        echo "unchanged sibling mismatch"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'изменён' "$quc_out" || ! grep -q 'Сохранено файлов:' "$quc_out" || ! grep -q 'Продолжение:' "$quc_out" || ! grep -q 'Вид отказа: данные не совпали.' "$quc_out" || ! grep -q 'Проверка содержимого:' "$quc_out" || ! grep -q 'Синхронизация:' "$quc_out" || grep -q 'можно извлекать' "$quc_out"; then
        echo "status text"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" report --verbose
    if ! grep -q 'изменён' "$quc_out" || ! grep -q '^copy_status=' "$quc_out" || ! grep -q 'Вид отказа: данные не совпали.' "$quc_out"; then
        echo "report text"
        cat "$quc_out"
        bad=1
    fi
    f_sentinel_ok || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "changed file before resume status=$st"; fi
}

test_F10() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'alpha-one\n' > "$src/a.txt"
    printf 'bravo-two\n' > "$src/b.txt"
    save_src
    f_out=$WORK/t-$current/outside
    mkdir -p "$f_out"
    printf 'SECRET\n' > "$f_out/secret"
    f_sha=$(c40_sha "$f_out/secret")
    export QUC_FILE_PAUSE=6
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    f_copied=
    for f_name in a.txt b.txt; do
        if [ -f "$dst/$f_name" ]; then
            f_copied=$f_name
            break
        fi
    done
    if [ -z "$f_copied" ]; then
        echo "nothing copied"
        bad=1
    else
        rm -f -- "$dst/$f_copied"
        ln -s "$f_out/secret" "$dst/$f_copied" || bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ]; then
        echo "resume replaced a symlink"
        bad=1
    fi
    if [ -z "$f_copied" ] || [ ! -L "$dst/$f_copied" ]; then
        echo "symlink was removed"
        bad=1
    fi
    if [ "$(c40_sha "$f_out/secret")" != "$f_sha" ] || [ "$(cat "$f_out/secret")" != SECRET ]; then
        echo "secret changed"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "published file replaced by a symlink status=$st"; fi
}

test_F11() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'alpha-one\n' > "$src/a.txt"
    printf 'bravo-two\n' > "$src/b.txt"
    save_src
    export QUC_FILE_PAUSE=6
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    if [ "$st" = SUCCESS ]; then
        bad=1
    fi
    f_sha=
    for f_name in a.txt b.txt; do
        if [ -f "$dst/$f_name" ]; then
            f_sha=$(c40_sha "$dst/$f_name")
            f_keep=$f_name
            break
        fi
    done
    if [ -z "$f_sha" ]; then
        echo "nothing copied"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    if [ -n "$f_keep" ] && [ "$(c40_sha "$dst/$f_keep")" != "$f_sha" ]; then
        echo "unchanged file was rewritten"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "unchanged resume status=$st"; fi
}

test_F12() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'payload\n' > "$src/a.txt"
    save_src
    export QUC_PRE_PUBLISH_PAUSE=8
    run_start "$src" "$dst"
    if ! wait_phase prepublish 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    if [ -e "$dst/a.txt" ] || [ -L "$dst/a.txt" ]; then
        echo "final name exists before publish"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    unset QUC_PRE_PUBLISH_PAUSE
    if [ "$st" = SUCCESS ] || [ -e "$dst/a.txt" ] || [ -L "$dst/a.txt" ]; then
        echo "published despite stop status=$st"
        bad=1
    fi
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || ! cmp -s "$src/a.txt" "$dst/a.txt"; then
        echo "resume status=$st"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "stop before publish status=$st"; fi
}

test_F13() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'alpha-one\n' > "$src/a.txt"
    printf 'bravo-two\n' > "$src/b.txt"
    save_src
    export QUC_FILE_PAUSE=6
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    f_sha=
    for f_name in a.txt b.txt; do
        if [ -f "$dst/$f_name" ]; then
            f_sha=$(c40_sha "$dst/$f_name")
            f_keep=$f_name
            break
        fi
    done
    if [ -z "$f_sha" ]; then
        echo "nothing published"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    unset QUC_FILE_PAUSE
    if [ "$st" = SUCCESS ]; then
        bad=1
    fi
    if [ -n "$f_keep" ] && [ "$(c40_sha "$dst/$f_keep")" != "$f_sha" ]; then
        echo "file changed after stop"
        bad=1
    fi
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    if [ -n "$f_keep" ] && [ "$(c40_sha "$dst/$f_keep")" != "$f_sha" ]; then
        echo "published file changed on resume"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "stop after publish status=$st"; fi
}

test_F14() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'payload\n' > "$src/a.txt"
    save_src
    export QUC_PRE_MARK_PAUSE=8
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! wait_phase mark 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    f_secret=$(job_field mount_secret || true)
    f_mark=$dst/.quc-mnt-$f_secret
    if [ -z "$f_secret" ]; then
        echo "secret missing"
        bad=1
    else
        printf 'FOREIGN-MARK\n' > "$f_mark"
        f_sha=$(c40_sha "$f_mark")
    fi
    st=$(wait_done 80)
    unset QUC_PRE_MARK_PAUSE
    if [ "$st" = SUCCESS ]; then
        echo "success with a blocked mark"
        bad=1
    fi
    if [ -z "$f_secret" ] || [ ! -f "$f_mark" ] || [ -L "$f_mark" ] || [ "$(c40_sha "$f_mark")" != "$f_sha" ] || [ "$(cat "$f_mark")" != FOREIGN-MARK ]; then
        echo "planted mark object changed"
        bad=1
    fi
    if [ -e "$dst/a.txt" ] || [ -L "$dst/a.txt" ]; then
        echo "data was written without a mark"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "service file create error status=$st"; fi
}

test_F15() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'payload-long\n' > "$src/a.txt"
    save_src
    f_wrap=$WORK/t-$current/bin
    mkdir -p "$f_wrap"
    f_cp=$(PATH=$ORIG_PATH command -v cp) || { fail "cp"; return; }
    cat > "$f_wrap/cp" <<EOF
#!/bin/sh
for f_arg in "\$@"; do
    case \$f_arg in
        /proc/self/fd/*)
            printf 'SHORT\n' > "\$f_arg"
            exit 1
            ;;
    esac
done
exec $f_cp "\$@"
EOF
    chmod 755 "$f_wrap/cp" || bad=1
    env PATH="$f_wrap:$ORIG_PATH" "$SH" "$SCRIPT" start "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ] || [ -s "$WORK/last.out" ] || [ -s "$WORK/last.err" ]; then
        echo "start noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ -e "$dst/a.txt" ] || [ -L "$dst/a.txt" ]; then
        echo "incomplete write became a published file status=$st"
        bad=1
    fi
    f_left=$(find "$dst" -name '.quc-partial.*' -print 2>/dev/null | head -n 1)
    if [ -n "$f_left" ]; then
        echo "owned temp remained: $f_left"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "incomplete dest write status=$st"; fi
}

test_F16() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'later\n' > "$src/a.txt"
    printf 'more\n' > "$src/b.txt"
    mkdir -p "$WORK/t-$current/payload"
    cp -a "$src/." "$WORK/t-$current/payload/" || bad=1
    export QUC_FILE_PAUSE=6
    run_start --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! c40_wait_ready_running 120; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status) status=$(job_field copy_status)"
        bad=1
    fi
    if ! umount "$src"; then
        echo "umount"
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    unset QUC_FILE_PAUSE
    if [ "$st" = SUCCESS ]; then
        echo "finished before the planned stop"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^source_dependency=not_required$' "$quc_out"; then
        echo "interrupted after READY dependency=$(grep '^source_dependency=' "$quc_out")"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Локальная копия подготовлена и проверена.' "$quc_out" || grep -q 'Источник: ещё требуется' "$quc_out"; then
        echo "interrupted ready text"
        cat "$quc_out"
        bad=1
    fi
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    cmp -s "$WORK/t-$current/payload/a.txt" "$dst/a.txt" || bad=1
    cmp -s "$WORK/t-$current/payload/b.txt" "$dst/b.txt" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "staged resume without source status=$st"; fi
}

test_F17() {
    bad=0
    make_pair || { fail "mount"; return; }
    f_bind_job || { fail "job"; return; }
    quc_validate_pair "$src" "$dst" fresh || { echo "pair"; fail "validate"; return; }
    quc_write_root=$quc_target
    quc_read_root=$quc_source
    quc_mount_mark=0
    quc_write_ino=
    quc_source_mode=direct
    quc_stage_status=none
    f_out=$WORK/t-$current/outside
    mkdir -p "$f_out"
    printf 'SECRET\n' > "$f_out/secret"
    f_sha=$(c40_sha "$f_out/secret")
    ln -s "$f_out/secret" "$dst/.quc-partial.swap" || bad=1
    printf 'FOREIGN\n' > "$dst/.quc-partial.other"
    f_other=$(c40_sha "$dst/.quc-partial.other")
    printf 'OURS\n' > "$dst/.quc-partial.ours"
    f_ino=$(stat -c '%i' "$dst/.quc-partial.ours")
    printf '%s\n' "$f_ino" > "$quc_job_dir/owned.ino"
    printf 'KEEP\n' > "$dst/keep.txt"
    f_keep=$(c40_sha "$dst/keep.txt")
    quc_cleanup_partials || true
    if [ ! -L "$dst/.quc-partial.swap" ]; then
        echo "cleanup removed a symlink"
        bad=1
    fi
    if [ "$(c40_sha "$f_out/secret")" != "$f_sha" ] || [ "$(cat "$f_out/secret")" != SECRET ]; then
        echo "cleanup followed a symlink"
        bad=1
    fi
    if [ ! -f "$dst/.quc-partial.other" ] || [ "$(c40_sha "$dst/.quc-partial.other")" != "$f_other" ]; then
        echo "unlisted temp file was removed"
        bad=1
    fi
    if [ -e "$dst/.quc-partial.ours" ] || [ -L "$dst/.quc-partial.ours" ]; then
        echo "owned temp remained"
        bad=1
    fi
    if [ "$(c40_sha "$dst/keep.txt")" != "$f_keep" ]; then
        echo "keep changed"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "cleanup symlink"; fi
}

test_F18() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'alpha-one\n' > "$src/a.txt"
    printf 'bravo-two\n' > "$src/b.txt"
    save_src
    export QUC_FILE_PAUSE=6
    run_start "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    f_copied=
    for f_name in a.txt b.txt; do
        if [ -f "$dst/$f_name" ]; then
            f_copied=$f_name
            break
        fi
    done
    f_meta=$XDG_STATE_HOME/quiet-usb-copy/jobs/$(cat "$XDG_STATE_HOME/quiet-usb-copy/current")/done.meta
    if [ -z "$f_copied" ] || [ ! -f "$f_meta" ]; then
        echo "missing copy or meta copied=$f_copied"
        bad=1
    else
        printf 'NOT-A-RECORD\n' > "$f_meta"
        printf 'FOREIGN\n' > "$dst/$f_copied"
        f_sha=$(c40_sha "$dst/$f_copied")
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ]; then
        echo "damaged meta allowed success"
        bad=1
    fi
    if [ -z "$f_copied" ] || [ "$(c40_sha "$dst/$f_copied")" != "$f_sha" ] || [ "$(cat "$dst/$f_copied")" != FOREIGN ]; then
        echo "file was replaced using damaged meta"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "damaged meta status=$st"; fi
}

test_F19() {
    bad=0
    make_pair || { fail "mount"; return; }
    mkdir -p "$src/nest" "$WORK/t-$current/foreign"
    printf 'payload\n' > "$src/nest/file.txt"
    printf 'SECRET\n' > "$WORK/t-$current/foreign/keep.txt"
    f_sha=$(c40_sha "$WORK/t-$current/foreign/keep.txt")
    save_src
    export QUC_PRE_PUBLISH_PAUSE=8
    run_start "$src" "$dst"
    if ! wait_phase prepublish 80; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    if [ -d "$dst/nest" ] && [ ! -L "$dst/nest" ]; then
        mv -- "$dst/nest" "$dst/nest.real" || bad=1
        ln -s "$WORK/t-$current/foreign" "$dst/nest" || bad=1
    else
        echo "nest was not a directory"
        bad=1
    fi
    st=$(wait_done 80)
    unset QUC_PRE_PUBLISH_PAUSE
    if [ "$st" = SUCCESS ]; then
        echo "symlink parent became SUCCESS"
        bad=1
    fi
    if [ "$(c40_sha "$WORK/t-$current/foreign/keep.txt")" != "$f_sha" ]; then
        echo "foreign file changed"
        bad=1
    fi
    if [ -e "$WORK/t-$current/foreign/file.txt" ] || [ -e "$WORK/t-$current/foreign/.quc-partial."* ]; then
        echo "payload entered the foreign directory"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "intermediate symlink status=$st"; fi
}

test_F20() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'good-bytes\n' > "$src/a.txt"
    save_src
    export QUC_PRE_PUBLISH_PAUSE=8
    run_start --source-mode staged "$src" "$dst"
    f_i=0
    f_seen=0
    while [ "$f_i" -lt 400 ]; do
        f_ph=$(job_field phase || true)
        f_ss=$(job_field stage_status || true)
        f_st=$(job_field copy_status || true)
        case $f_st in
            SUCCESS|PARTIAL|FAILED|CANCELLED|INTERRUPTED|UNCERTAIN) break ;;
        esac
        case $f_ph in
            *prepublish*)
                if [ "$f_ss" = READY ]; then
                    f_seen=1
                    break
                fi
                ;;
        esac
        sleep 0.2
        f_i=$((f_i + 1))
    done
    if [ "$f_seen" != 1 ]; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status) status=$(job_field copy_status)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    stage=$(c40_stage_dir)
    if [ ! -f "$stage/data/a.txt" ]; then
        echo "no staged file"
        bad=1
    else
        f_mode=$(stat -c '%a' -- "$stage")
        case $f_mode in
            700) ;;
            *) echo "stage mode $f_mode"; bad=1 ;;
        esac
        printf 'DAMAGED\n' > "$stage/data/a.txt" || bad=1
    fi
    unset QUC_PRE_PUBLISH_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" = SUCCESS ] || [ "$(job_field stage_status)" != damaged ]; then
        echo "damaged stage status=$st stage=$(job_field stage_status)"
        bad=1
    fi
    if [ -e "$dst/a.txt" ] && [ "$(cat "$dst/a.txt" 2>/dev/null)" = DAMAGED ]; then
        echo "damaged bytes were published"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Локальная копия: повреждена.' "$quc_out" || ! grep -q 'Восстановление: невозможно.' "$quc_out" || grep -q 'Копирование завершено.' "$quc_out" || grep -q 'подготовлена и проверена' "$quc_out" || grep -q 'Готовность локальной копии не подтверждена.' "$quc_out" || ! grep -q 'Источник: статус неизвестен.' "$quc_out"; then
        echo "damage status text"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^source_dependency=unknown$' "$quc_out"; then
        echo "damaged dependency"
        cat "$quc_out"
        bad=1
    fi
    src_same || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "damaged staging status=$st"; fi
}

test_F21() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'ok\n' > "$src/a.txt"
    printf 'KEEP\n' > "$dst/../keep-outside"
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ] || ! cmp -s "$src/a.txt" "$dst/a.txt"; then
        echo "status=$st"
        bad=1
    fi
    if find "$dst" -name '.quc-partial.*' -print | grep -q .; then
        echo "partial left on dest"
        bad=1
    fi
    if find "$XDG_RUNTIME_DIR/quiet-usb-copy" -name 'probe.*' -print 2>/dev/null | grep -q .; then
        echo "probe dir left"
        bad=1
    fi
    f_state=$XDG_STATE_HOME/quiet-usb-copy
    f_mode=$(stat -c '%a' -- "$f_state")
    case $f_mode in
        700) ;;
        *) echo "state mode $f_mode"; bad=1 ;;
    esac
    if [ "$(cat "$dst/../keep-outside")" != KEEP ]; then
        echo "outside file changed"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q '^Копирование завершено.$' "$quc_out" || ! grep -q '^Проверка содержимого:' "$quc_out" || ! grep -q '^Синхронизация:' "$quc_out" || grep -q '^copy_status=' "$quc_out"; then
        echo "status mixed"
        cat "$quc_out"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "service data after success status=$st"; fi
}

run_case F01 test_F01
run_case F02 test_F02
run_case F03 test_F03
run_case F04 test_F04
run_case F05 test_F05
run_case F06 test_F06
run_case F07 test_F07
run_case F08 test_F08
run_case F09 test_F09
run_case F10 test_F10
run_case F11 test_F11
run_case F12 test_F12
run_case F13 test_F13
run_case F14 test_F14
run_case F15 test_F15
run_case F16 test_F16
run_case F17 test_F17
run_case F18 test_F18
run_case F19 test_F19
run_case F20 test_F20
run_case F21 test_F21

s_expect() {
    quc_default_job_vars
    quc_source_mode=$1
    quc_stage_status=$2
    quc_job_phase=$3
    quc_copy_status=$4
    quc_files_done=0
    quc_files_total=1
    quc_verify_status=none
    quc_sync_status=unconfirmed
    quc_profile=gentle
    quc_error=
    quc_dest_mode=root
    quc_compute_source_dependency
    if [ "$quc_source_dependency" != "$5" ]; then
        echo "compute $1/$2/$3/$4 got $quc_source_dependency want $5"
        s_bad=1
    fi
    s_text=$(quc_print_human)
    if [ -n "${6:-}" ]; then
        case $s_text in
            *"$6"*) ;;
            *)
                echo "missing [$6] for $1/$2/$3/$4"
                s_bad=1
                ;;
        esac
    fi
    if [ -n "${7:-}" ]; then
        case $s_text in
            *"$7"*)
                echo "forbidden [$7] for $1/$2/$3/$4"
                s_bad=1
                ;;
        esac
    fi
}

test_S01() {
    s_bad=0
    s_expect direct none TRANSFER RUNNING required 'Источник: ещё требуется для копирования.' 'подготовлена и проверена'
    s_expect direct none TRANSFER PARTIAL required 'Источник: ещё требуется для копирования.' 'больше не требуется'
    s_expect direct none INTERRUPTED INTERRUPTED required 'Источник: ещё требуется для копирования.' 'больше не требуется'
    s_expect direct none CANCELLED CANCELLED required 'Источник: ещё требуется для копирования.' 'больше не требуется'
    s_expect direct none STARTING STARTING required 'Источник: ещё требуется для копирования.' 'подготовлена и проверена'
    s_expect direct none COMPLETED SUCCESS not_required 'Источник: больше не требуется Quiet USB Copy.' 'локальной копии'
    s_expect direct none FAILED FAILED unknown 'Источник: статус неизвестен.' 'больше не требуется'
    s_expect direct none UNCERTAIN UNCERTAIN unknown 'Готовность локальной копии не подтверждена.' 'больше не требуется'
    s_expect direct none CREATED '' unknown 'Готовность локальной копии не подтверждена.' 'ещё требуется'
    s_expect staged preparing STAGING RUNNING required 'Источник: пока требуется.' 'больше не требуется'
    s_expect staged verifying STAGE_VERIFY RUNNING required 'Подготовка локальной копии.' 'подготовлена и проверена'
    s_expect staged READY TRANSFER RUNNING not_required 'Локальная копия подготовлена и проверена.' 'Источник: ещё требуется'
    s_expect staged READY READY RUNNING not_required 'Источник: больше не требуется Quiet USB Copy.' 'Источник: пока требуется.'
    s_expect staged READY STAGING RUNNING required 'Источник: пока требуется.' 'подготовлена и проверена'
    s_expect staged READY STAGE_VERIFY RUNNING required 'Подготовка локальной копии.' 'подготовлена и проверена'
    s_expect staged READY TRANSFER UNCERTAIN unknown 'Готовность локальной копии не подтверждена.' 'подготовлена и проверена'
    s_expect staged none STAGING RUNNING required 'Источник: пока требуется.' 'больше не требуется'
    s_expect staged none COMPLETED SUCCESS unknown 'Готовность локальной копии не подтверждена.' 'подготовлена и проверена'
    s_expect staged damaged FAILED FAILED unknown 'Источник: статус неизвестен.' 'Готовность локальной копии не подтверждена.'
    s_expect staged failed FAILED FAILED unknown 'Источник: статус неизвестен.' 'подготовлена и проверена'
    s_expect staged READY INTERRUPTED INTERRUPTED not_required 'Локальная копия подготовлена и проверена.' 'Источник: ещё требуется'
    s_n=$(printf '%s\n' "$s_text" | grep -c 'Для извлечения используйте средства ОС.' || true)
    if [ "$s_n" != 1 ]; then
        echo "eject lines=$s_n"
        s_bad=1
    fi
    case $s_text in
        *'Локальная копия: повреждена.'*)
            echo "ready text included damaged line"
            s_bad=1
            ;;
    esac
    quc_stage_status=damaged
    quc_source_mode=staged
    quc_copy_status=FAILED
    quc_job_phase=FAILED
    s_text=$(quc_print_human)
    case $s_text in
        *'Локальная копия: повреждена.'*) ;;
        *)
            echo "damaged line missing"
            s_bad=1
            ;;
    esac
    case $s_text in
        *'Готовность локальной копии не подтверждена.'*)
            echo "damaged printed unconfirmed"
            s_bad=1
            ;;
    esac
    if [ "$s_bad" -eq 0 ]; then pass; else fail "source dependency matrix"; fi
}

test_S02() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'live\n' > "$src/a.txt"
    printf 'live2\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=4
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! wait_phase pause 40; then
        echo "phase=$(job_field phase) status=$(job_field copy_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^source_dependency=required$' "$quc_out" || ! grep -q '^source_mode=direct$' "$quc_out"; then
        echo "direct running machine"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Источник: ещё требуется для копирования.' "$quc_out" || grep -q 'больше не требуется Quiet USB Copy' "$quc_out" || grep -q 'подготовлена и проверена' "$quc_out"; then
        echo "direct running human"
        cat "$quc_out"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    if [ "$bad" -eq 0 ]; then pass; else fail "direct source dependency"; fi
}

test_S03() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'early\n' > "$src/a.txt"
    export QUC_FILE_PAUSE=4
    run_start --source-mode staged "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec noisy=$quc_noisy"
        bad=1
    fi
    if ! c40_wait_preparing_pause 80; then
        echo "phase=$(job_field phase) stage=$(job_field stage_status) status=$(job_field copy_status)"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --machine
    if ! grep -q '^source_dependency=required$' "$quc_out" || ! grep -q '^source_mode=staged$' "$quc_out"; then
        echo "preparing machine"
        cat "$quc_out"
        bad=1
    fi
    run_quiet "$SH" "$SCRIPT" status --human
    if ! grep -q 'Подготовка локальной копии.' "$quc_out" || ! grep -q 'Источник: пока требуется.' "$quc_out" || grep -q 'больше не требуется Quiet USB Copy' "$quc_out" || grep -q 'подготовлена и проверена' "$quc_out"; then
        echo "preparing human"
        cat "$quc_out"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    if [ "$bad" -eq 0 ]; then pass; else fail "staged preparing dependency"; fi
}

test_S05() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=4
    run_start "$src" "$dst"
    if ! wait_phase pause 40; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    "$SH" "$SCRIPT" stop >/dev/null 2>&1 || bad=1
    st=$(wait_done 40)
    unset QUC_FILE_PAUSE
    case $st in
        INTERRUPTED|CANCELLED|PARTIAL) ;;
        *)
            echo "status=$st"
            bad=1
            ;;
    esac
    s_cur=$XDG_STATE_HOME/quiet-usb-copy/current
    s_id=$(cat "$s_cur" 2>/dev/null || true)
    s_state=$XDG_STATE_HOME/quiet-usb-copy/jobs/$s_id/state
    if [ ! -f "$s_state" ]; then
        echo "no state"
        bad=1
    else
        s_tmp=$WORK/t-$current/state.tamper
        awk '
            BEGIN { found = 0 }
            $0 ~ /^source_dependency=/ { print "source_dependency=not_required"; found = 1; next }
            { print }
            END { if (!found) print "source_dependency=not_required" }
        ' "$s_state" > "$s_tmp" && mv -- "$s_tmp" "$s_state" || bad=1
        run_quiet "$SH" "$SCRIPT" status --machine
        if ! grep -q '^source_dependency=required$' "$quc_out"; then
            echo "trusted tampered not_required"
            cat "$quc_out"
            bad=1
        fi
        run_quiet "$SH" "$SCRIPT" status --human
        if ! grep -q 'Источник: ещё требуется для копирования.' "$quc_out" || grep -q 'больше не требуется Quiet USB Copy' "$quc_out"; then
            echo "human trusted tamper"
            cat "$quc_out"
            bad=1
        fi
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "tampered source_dependency status=$st"; fi
}

g_stub_install() {
    g_stub_dir=$WORK/t-$current/stubbin
    g_stub_log=$WORK/t-$current/udisks.log
    mkdir -p "$g_stub_dir"
    : > "$g_stub_log"
    cat > "$g_stub_dir/udisksctl" << 'EOF'
#!/bin/sh
log=${QUC_STUB_LOG:?}
printf '%s\n' "$*" >> "$log"
cmd=$1
shift
g_help=0
case $cmd in
    unmount|power-off|info) ;;
    *) g_help=1 ;;
esac
for g_arg in "$@"; do
    if [ "$g_arg" = --help ] || [ "$g_arg" = -h ]; then
        g_help=1
    fi
    if [ "$g_arg" = --force ] || [ "$g_arg" = -f ]; then
        printf '%s\n' "saw-force" >> "$log"
        exit 1
    fi
done
if [ "$g_help" = 1 ]; then
    if [ "${QUC_STUB_HELP_OK:-1}" = 0 ]; then
        printf '%s\n' "usage"
        exit 0
    fi
    printf '%s\n' "--no-user-interaction"
    exit 0
fi
case $cmd in
    unmount)
        if [ "${QUC_STUB_UNMOUNT_RC:-1}" = 0 ]; then
            if [ -n "${QUC_STUB_MOUNT:-}" ]; then
                umount "$QUC_STUB_MOUNT" || true
            fi
            exit 0
        fi
        printf '%s\n' "${QUC_STUB_MSG:-denied}" >&2
        exit "${QUC_STUB_UNMOUNT_RC:-1}"
        ;;
    power-off)
        exit "${QUC_STUB_POWER_RC:-1}"
        ;;
    info)
        if [ "${QUC_STUB_INFO_RC:-1}" = 0 ]; then
            printf '%s\n' "present"
            exit 0
        fi
        printf '%s\n' "missing" >&2
        exit "${QUC_STUB_INFO_RC:-1}"
        ;;
esac
exit 1
EOF
    chmod 755 "$g_stub_dir/udisksctl"
    PATH=$g_stub_dir:$ORIG_PATH
    export QUC_STUB_LOG=$g_stub_log
    export QUC_STUB_HELP_OK=1
    export QUC_STUB_UNMOUNT_RC=1
    export QUC_STUB_POWER_RC=1
    export QUC_STUB_INFO_RC=1
    export QUC_STUB_MSG=denied
    unset QUC_STUB_MOUNT
}

g_stub_actions() {
    if [ ! -f "${g_stub_log:-}" ]; then
        printf '0\n'
        return 0
    fi
    g_n=$(grep -c -E '^(unmount|power-off) -b ' "$g_stub_log" || true)
    case $g_n in
        ''|*[!0-9]*) g_n=0 ;;
    esac
    printf '%s\n' "$g_n"
}

test_G01() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'plain\n' > "$src/a.txt"
    run_start "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_status)" != skipped_policy ] || [ "$(job_field eject_policy)" != no ]; then
        echo "status=$st eject=$(job_field eject_status) policy=$(job_field eject_policy)"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ] || grep -F -q -- "$src" "$g_stub_log"; then
        echo "source or action in stub"
        cat "$g_stub_log"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "cli does not eject"; fi
}

test_G02() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'block\n' > "$src/a.txt"
    run_start --eject-dest "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_status)" != skipped_policy ] || [ "$(job_field eject_policy)" != yes ]; then
        echo "status=$st eject=$(job_field eject_status) policy=$(job_field eject_policy)"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "tmpfs called udisksctl"
        cat "$g_stub_log"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "eject-dest on non-block"; fi
}

test_G03() {
    bad=0
    g_stub_install
    quc_resolve_tools || bad=1
    quc_default_job_vars
    quc_eject_policy=yes
    quc_copy_status=RUNNING
    quc_verify_status=size
    quc_sync_status=command_ok
    quc_error=marker
    quc_auto_disconnect
    if [ "$quc_eject_status" != skipped_policy ] || [ "$quc_copy_status" != RUNNING ] || [ "$quc_error" != marker ]; then
        echo "running eject=$quc_eject_status copy=$quc_copy_status"
        bad=1
    fi
    quc_copy_status=SUCCESS
    quc_verify_status=failed
    quc_auto_disconnect
    if [ "$quc_eject_status" != skipped_policy ] || [ "$quc_copy_status" != SUCCESS ]; then
        echo "verify eject=$quc_eject_status"
        bad=1
    fi
    quc_verify_status=size
    quc_sync_status=unconfirmed
    quc_auto_disconnect
    if [ "$quc_eject_status" != skipped_policy ]; then
        echo "sync eject=$quc_eject_status"
        bad=1
    fi
    quc_sync_status=command_ok
    quc_eject_policy=no
    quc_auto_disconnect
    if [ "$quc_eject_status" != skipped_policy ] || [ "$(g_stub_actions)" != 0 ]; then
        echo "policy called the tool"
        cat "$g_stub_log"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "unsafe eject skipped"; fi
}

test_G04() {
    bad=0
    lim=$WORK/t-$current/bin
    mkdir -p "$lim"
    for tool in find stat awk od tr mkdir rmdir rm mv ln chmod date readlink sleep cat cp grep dirname basename cmp sync touch flock setsid nice nohup sha256sum sh; do
        g_bin=$(PATH=$ORIG_PATH command -v "$tool" || true)
        if [ -n "$g_bin" ]; then
            ln -s "$g_bin" "$lim/$tool"
        fi
    done
    if env PATH="$lim" command -v tar >/dev/null 2>&1 || env PATH="$lim" command -v gzip >/dev/null 2>&1 || env PATH="$lim" command -v udisksctl >/dev/null 2>&1; then
        echo "optional tool leaked"
        bad=1
    fi
    make_pair || { fail "mount"; return; }
    printf 'still\n' > "$src/a.txt"
    env PATH="$lim" "$SH" "$SCRIPT" start --eject-dest "$src" "$dst" >"$WORK/last.out" 2>"$WORK/last.err"
    quc_ec=$?
    if [ "$quc_ec" -ne 0 ] || [ -s "$WORK/last.out" ] || [ -s "$WORK/last.err" ]; then
        echo "limited start ec=$quc_ec"
        cat "$WORK/last.out" "$WORK/last.err"
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_status)" != unavailable ] || [ "$(job_field eject_policy)" != yes ]; then
        echo "status=$st eject=$(job_field eject_status) sync=$(job_field sync_status)"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "missing udisksctl tar gzip"; fi
}

test_G05() {
    bad=0
    g_stub_install
    export QUC_STUB_HELP_OK=0
    quc_resolve_tools || bad=1
    quc_default_job_vars
    quc_eject_policy=yes
    quc_copy_status=SUCCESS
    quc_verify_status=checksum
    quc_sync_status=command_ok
    quc_error=kept
    quc_auto_disconnect
    if [ "$quc_eject_status" != unavailable ] || [ "$quc_copy_status" != SUCCESS ] || [ "$quc_error" != kept ]; then
        echo "eject=$quc_eject_status copy=$quc_copy_status"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "help mode still called an action"
        cat "$g_stub_log"
        bad=1
    fi
    if ! grep -q 'unmount --help' "$g_stub_log"; then
        echo "help was not probed"
        cat "$g_stub_log"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "no noninteractive mode"; fi
}

test_G06() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'busy\n' > "$dst/keep.txt"
    quc_resolve_tools || bad=1
    if ! quc_eject_tool_ready; then
        echo "stub help rejected"
        cat "$g_stub_log"
        bad=1
    fi
    case $quc_bin_udisksctl in
        "$g_stub_dir"/udisksctl) ;;
        *) echo "tool=$quc_bin_udisksctl"; bad=1 ;;
    esac
    quc_target=$dst
    quc_source_spec=/dev/loop0
    quc_ej_mount_ok=1
    quc_ej_block=/dev/loop0
    quc_ej_disk=loop0
    quc_ej_power_ok=0
    quc_copy_status=SUCCESS
    quc_eject_run </dev/null
    if [ "$quc_eject_status" != skipped_policy ] || [ "$(g_stub_actions)" != 0 ]; then
        echo "source block was not refused eject=$quc_eject_status"
        cat "$g_stub_log"
        bad=1
    fi
    quc_source_spec=/dev/quc-source-not-dest
    export QUC_STUB_MSG=busy
    quc_ej_mount_ok=1
    quc_ej_block=/dev/loop0
    quc_ej_power_ok=0
    quc_eject_run </dev/null
    if [ "$quc_eject_status" != refused ] || [ "$quc_copy_status" != SUCCESS ]; then
        echo "busy eject=$quc_eject_status copy=$quc_copy_status"
        bad=1
    fi
    if ! grep -q '^unmount -b /dev/loop0 --no-user-interaction$' "$g_stub_log" || grep -q -- '--force' "$g_stub_log"; then
        echo "busy log"
        cat "$g_stub_log"
        bad=1
    fi
    if ! findmnt -n -T "$dst" >/dev/null 2>&1; then
        echo "busy test unmounted the volume"
        bad=1
    fi
    export QUC_STUB_MSG='Not authorized'
    : > "$g_stub_log"
    quc_ej_mount_ok=1
    quc_ej_block=/dev/loop0
    quc_eject_run </dev/null
    if [ "$quc_eject_status" != refused ] || [ "$quc_copy_status" != SUCCESS ]; then
        echo "auth eject=$quc_eject_status"
        bad=1
    fi
    if ! findmnt -n -T "$dst" >/dev/null 2>&1; then
        echo "auth test unmounted the volume"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "busy and auth refusal"; fi
}

test_G08() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'gone\n' > "$dst/a.txt"
    quc_resolve_tools || bad=1
    if ! quc_eject_tool_ready; then
        echo "tool"; bad=1
    fi
    case $quc_bin_udisksctl in
        "$g_stub_dir"/udisksctl) ;;
        *) echo "tool=$quc_bin_udisksctl"; bad=1 ;;
    esac
    export QUC_STUB_UNMOUNT_RC=0
    export QUC_STUB_MOUNT=$dst
    quc_target=$dst
    quc_source_spec=/dev/quc-source-not-dest
    quc_ej_mount_ok=1
    quc_ej_block=/dev/loop0
    quc_ej_disk=loop0
    quc_ej_power_ok=0
    quc_copy_status=SUCCESS
    quc_eject_run </dev/null
    if [ "$quc_eject_status" != unmounted ] || [ "$quc_copy_status" != SUCCESS ]; then
        echo "eject=$quc_eject_status"
        cat "$g_stub_log"
        bad=1
    fi
    if grep -q '^power-off -b ' "$g_stub_log"; then
        echo "power was called"
        bad=1
    fi
    if findmnt -n -T "$dst" >/dev/null 2>&1; then
        g_src=$(findmnt -n -o SOURCE -T "$dst" 2>/dev/null || true)
        if [ "$g_src" = tmpfs ]; then
            echo "tmpfs still mounted"
            bad=1
        fi
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "mock unmount"; fi
}

test_G09() {
    bad=0
    if [ ! -e /dev/loop0 ]; then
        echo "loop0 missing"
        bad=1
    fi
    g_stub_install
    make_pair || { fail "mount"; return; }
    g_sys=$WORK/t-$current/fakesys
    g_loop_scope=$WORK/t-$current/loop-scope/host0/target0
    g_sdz_scope=$WORK/t-$current/sdz-scope/host0/target0
    mkdir -p "$g_sys/loop0/holders" "$g_sys/sdz/holders" "$g_sys/sdz/sdz1" "$g_sys/sdz/sdz2" \
        "$g_sys/sdz-sib" "$g_loop_scope/lun0" "$g_sdz_scope/lun0" "$g_sdz_scope/lun1"
    ln -s "$g_loop_scope/lun0" "$g_sys/loop0/device"
    ln -s "$g_sdz_scope/lun0" "$g_sys/sdz/device"
    ln -s "$g_sdz_scope/lun1" "$g_sys/sdz-sib/device"
    printf '1\n' > "$g_sys/sdz/sdz1/partition"
    printf '2\n' > "$g_sys/sdz/sdz2/partition"
    ln -s "sdz/sdz1" "$g_sys/sdz1"
    ln -s "sdz/sdz2" "$g_sys/sdz2"
    printf 'x\n' > "$g_sys/sdz/holders/dm-0"
    g_bound=0
    if mount --bind "$g_sys" /sys/class/block; then
        g_bound=1
    else
        echo "sysfs bind failed"
        bad=1
    fi
    if [ "$g_bound" = 1 ]; then
        quc_resolve_tools || bad=1
        g_name=$(quc_disk_name /dev/sdz1 0 || true)
        if [ "$g_name" != sdz ]; then
            echo "disk_name=$g_name"
            bad=1
        fi
        if quc_eject_power_clear sdz; then
            echo "holders did not block power"
            bad=1
        fi
        rm -f "$g_sys/sdz/holders/dm-0"
        if quc_eject_power_clear sdz; then
            echo "sibling lun did not block power"
            bad=1
        fi
        quc_ej_block=/dev/sdz1
        if ! quc_eject_same_disk /dev/sdz1 sdz; then
            echo "exact block missed"
            bad=1
        fi
        if ! quc_eject_same_disk /dev/sdz2 sdz; then
            echo "sibling partition missed"
            bad=1
        fi
        if quc_eject_foreign_live quc-not-a-disk /quc-not-mounted; then
            echo "unknown disk looked foreign"
            bad=1
        fi
        if ! quc_eject_tool_ready; then
            echo "tool"; bad=1
        fi
        case $quc_bin_udisksctl in
            "$g_stub_dir"/udisksctl) ;;
            *) echo "tool=$quc_bin_udisksctl"; bad=1 ;;
        esac
        if quc_eject_power_clear loop0; then
            export QUC_STUB_UNMOUNT_RC=0
            export QUC_STUB_MOUNT=$dst
            export QUC_STUB_POWER_RC=0
            export QUC_STUB_INFO_RC=1
            quc_target=$dst
            quc_source_spec=/dev/quc-source-not-dest
            quc_ej_mount_ok=1
            quc_ej_block=/dev/loop0
            quc_ej_disk=loop0
            quc_ej_power_ok=1
            quc_copy_status=SUCCESS
            quc_eject_run </dev/null
            if [ "$quc_eject_status" != power_off ]; then
                echo "eject=$quc_eject_status"
                cat "$g_stub_log"
                bad=1
            fi
            if ! grep -q '^power-off -b /dev/loop0 --no-user-interaction$' "$g_stub_log"; then
                echo "power log"
                cat "$g_stub_log"
                bad=1
            fi
            if grep -q 'info -b /dev/loop0 --no-user-interaction' "$g_stub_log" || grep -q -- '--force' "$g_stub_log"; then
                echo "info flag or force"
                cat "$g_stub_log"
                bad=1
            fi
            if [ ! -e /dev/loop0 ]; then
                echo "loop0 disappeared"
                bad=1
            fi
        else
            echo "loop0 power_clear refused"
            bad=1
        fi
        umount /sys/class/block || bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "mock power and sibling disk"; fi
}

test_G10() {
    bad=0
    make_pair || { fail "mount"; return; }
    quc_resolve_tools || bad=1
    quc_target=$dst
    quc_mountinfo_lookup "$dst" || { echo "lookup"; bad=1; }
    quc_target_mntid=999999999
    quc_target_dev=$(quc_dev_of "$dst" || true)
    quc_target_uuid=
    quc_source_spec=
    quc_ej_power_tool=0
    if quc_eject_gather; then
        echo "changed id was accepted"
        bad=1
    fi
    mkdir -p "$dst/sub"
    quc_target=$dst/sub
    if quc_eject_gather; then
        echo "subdirectory was accepted"
        bad=1
    fi
    quc_ej_block=/dev/loop0
    if ! quc_eject_same_disk /dev/loop0 loop0; then
        echo "same node"
        bad=1
    fi
    if quc_eject_same_disk tmpfs loop0; then
        echo "tmpfs matched a disk"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "identity and mount point"; fi
}

test_G12() {
    bad=0
    sleep 20 &
    g_sleep=$!
    if quc_eject_children_clear; then
        echo "child was invisible"
        cat /proc/$$/task/$$/children 2>/dev/null || true
        bad=1
    fi
    kill "$g_sleep" 2>/dev/null || true
    wait "$g_sleep" 2>/dev/null || true
    if ! quc_eject_children_clear; then
        echo "children remained"
        cat /proc/$$/task/$$/children 2>/dev/null || true
        bad=1
    fi
    quc_default_job_vars
    quc_eject_policy=yes
    quc_copy_status=SUCCESS
    quc_verify_status=size
    quc_sync_status=command_ok
    sleep 20 &
    g_sleep=$!
    quc_auto_disconnect
    kill "$g_sleep" 2>/dev/null || true
    wait "$g_sleep" 2>/dev/null || true
    if [ "$quc_eject_status" != skipped_policy ] || [ "$quc_copy_status" != SUCCESS ]; then
        echo "child eject=$quc_eject_status"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "children block eject"; fi
}

test_G14() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'one\n' > "$src/a.txt"
    printf 'two\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=4
    run_start --eject-dest "$src" "$dst"
    if ! wait_phase pause 80; then
        echo "phase=$(job_field phase)"
        bad=1
    fi
    g_pid=$(c40_owner_pid)
    case $g_pid in
        ''|0|1|*[!0-9]*) echo "pid=$g_pid"; bad=1 ;;
        *) kill -TERM "$g_pid" 2>/dev/null || bad=1 ;;
    esac
    st=$(wait_done 80)
    if [ "$st" != INTERRUPTED ] || [ "$(job_field eject_status)" != skipped_policy ] || [ "$(job_field eject_policy)" != yes ]; then
        echo "after term status=$st eject=$(job_field eject_status)"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "term called eject"
        cat "$g_stub_log"
        bad=1
    fi
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec"
        bad=1
    fi
    if ! wait_phase pause 80; then
        echo "resume phase=$(job_field phase) eject=$(job_field eject_status)"
        bad=1
    fi
    if [ "$(job_field eject_status)" != planned ] || [ "$(job_field eject_policy)" != yes ]; then
        echo "resume planned eject=$(job_field eject_status)"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_status)" != skipped_policy ]; then
        echo "final status=$st eject=$(job_field eject_status)"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "resume called eject"
        cat "$g_stub_log"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "resume keeps policy"; fi
}

test_G15() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'stay\n' > "$src/a.txt"
    run_start "$src" "$dst"
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    umount "$dst" || bad=1
    run_quiet "$SH" "$SCRIPT" status --machine
    if [ "$quc_ec" -ne 0 ] || ! grep -q '^copy_status=SUCCESS$' "$quc_out" || ! grep -q '^eject_status=skipped_policy$' "$quc_out" || ! grep -q '^eject_policy=no$' "$quc_out"; then
        echo "status after unmount"
        cat "$quc_out" "$quc_err"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "status after destination unmount"; fi
}

test_G16() {
    bad=0
    if grep -n -- '--force' "$SCRIPT" >/dev/null; then
        echo "product contains --force"
        bad=1
    fi
    quc_default_job_vars
    quc_copy_status=SUCCESS
    quc_verify_status=size
    quc_sync_status=command_ok
    quc_files_done=1
    quc_files_total=1
    quc_profile=gentle
    for g_st in planned unmounted power_off skipped_policy unavailable refused unknown weird; do
        quc_eject_status=$g_st
        g_text=$(quc_print_human)
        case $g_text in
            *'можно извлекать'*|*'copy_status='*)
                echo "bad human $g_st"
                bad=1
                ;;
        esac
        case $g_text in
            *'Для извлечения используйте средства ОС.'*) ;;
            *) echo "missing os line $g_st"; bad=1 ;;
        esac
    done
    quc_eject_status=refused
    g_text=$(quc_print_human)
    case $g_text in
        *'Система отказала в отключении. Назначение оставлено подключённым.'*) ;;
        *) echo "refused text"; bad=1 ;;
    esac
    quc_eject_status=power_off
    g_text=$(quc_print_human)
    case $g_text in
        *'Питание назначения отключено штатно.'*) ;;
        *) echo "power text"; bad=1 ;;
    esac
    if [ "$bad" -eq 0 ]; then pass; else fail "human eject text"; fi
}

test_G17() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'slide\n' > "$src/deck.txt"
    fake=$WORK/t-$current/fake.tsv
    fake_row "$src" ext4 tmpfs PRESENTATION 33554432 30000000 > "$fake"
    fake_row "$dst" ext4 tmpfs BACKUP 67108864 65000000 >> "$fake"
    export QUC_FAKE_VOLUMES=$fake
    printf '1\n2\n5\n1\n' > "$WORK/t-$current/in"
    pty_run "$WORK/t-$current/in" /bin/sh "$SCRIPT"
    if [ "$quc_pty_rc" -ne 0 ] || [ "$quc_ec" != 0 ]; then
        echo "pty ec=$quc_ec"
        cat "$quc_out" "$quc_meta"
        bad=1
    fi
    if ! grep -q 'Отключение назначения: включено' "$quc_out" || ! grep -q 'Отключение назначения: выключено' "$quc_out" || ! grep -q 'Исходный накопитель остаётся подключённым.' "$quc_out" || ! grep -q 'Копирование запущено в фоне' "$quc_out"; then
        echo "toggle text"
        cat "$quc_out"
        bad=1
    fi
    if grep -q 'copy_status=' "$quc_out" || grep -q 'source_dependency=' "$quc_out"; then
        echo "machine field on the menu"
        bad=1
    fi
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_policy)" != no ] || [ "$(job_field eject_status)" != skipped_policy ]; then
        echo "status=$st policy=$(job_field eject_policy) eject=$(job_field eject_status)"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "toggle still ejected"
        cat "$g_stub_log"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "menu can refuse eject"; fi
}

test_G18() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'kill\n' > "$src/a.txt"
    printf 'more\n' > "$src/b.txt"
    export QUC_FILE_PAUSE=5
    run_start --eject-dest "$src" "$dst"
    if ! wait_phase pause 80; then
        bad=1
    fi
    g_pid=$(c40_owner_pid)
    case $g_pid in
        ''|0|1|*[!0-9]*) echo "pid=$g_pid"; bad=1 ;;
        *) kill -KILL "$g_pid" 2>/dev/null || bad=1 ;;
    esac
    sleep 0.3
    if [ "$(job_field copy_status)" = SUCCESS ]; then
        echo "SIGKILL became SUCCESS"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "kill called eject"
        cat "$g_stub_log"
        bad=1
    fi
    unset QUC_FILE_PAUSE
    run_resume
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "resume ec=$quc_ec"
        bad=1
    fi
    st=$(wait_done 80)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_status)" != skipped_policy ] || [ "$(job_field eject_policy)" != yes ]; then
        echo "status=$st eject=$(job_field eject_status) policy=$(job_field eject_policy)"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "resume called eject"
        cat "$g_stub_log"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "SIGKILL resume does not eject"; fi
}

test_G19() {
    bad=0
    g_stub_install
    make_pair 8m 256k || { fail "mount"; return; }
    printf 'small\n' > "$src/a.txt"
    run_start --eject-dest "$src" "$dst"
    st=$(wait_done 40)
    if [ "$st" = SUCCESS ]; then
        echo "tiny volume accepted a large file"
        bad=1
    fi
    if [ "$(job_field eject_status)" != skipped_policy ] || [ "$(g_stub_actions)" != 0 ]; then
        echo "enospc eject=$(job_field eject_status)"
        cat "$g_stub_log"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "no space does not eject"; fi
}

test_G20() {
    bad=0
    make_pair 32m 32m || { fail "mount"; return; }
    g_i=0
    while [ "$g_i" -lt 200 ]; do
        printf 'x\n' > "$src/f$g_i.txt"
        g_i=$((g_i + 1))
    done
    run_start "$src" "$dst"
    st=$(wait_done 120)
    if [ "$st" != SUCCESS ] || [ "$(job_field eject_status)" != skipped_policy ]; then
        echo "status=$st eject=$(job_field eject_status)"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    g_left=$(find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name 'quc-tbrc.*' -o -name 'quc-tberr.*' -o -name 'quc-ejcap.*' -o -name 'quc-ejrows.*' -o -name 'quc-ejlun.*' \) -print 2>/dev/null || true)
    if [ -n "$g_left" ]; then
        echo "temp left: $g_left"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "many files"; fi
}

test_G21() {
    bad=0
    make_pair 16m 16m || { fail "mount"; return; }
    dd if=/dev/zero of="$src/wide.bin" bs=1024 count=2048 status=none 2>/dev/null || bad=1
    run_start "$src" "$dst"
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ]; then
        echo "status=$st"
        bad=1
    fi
    cmp -s "$src/wide.bin" "$dst/wide.bin" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "large file"; fi
}

test_G23() {
    bad=0
    make_pair || { fail "mount"; return; }
    printf 'cwd\n' > "$src/a.txt"
    cd /tmp || bad=1
    run_start "$src" "$dst"
    cd "$WORK" || bad=1
    st=$(wait_done 40)
    if [ "$st" != SUCCESS ] || [ "$quc_ec" -ne 0 ]; then
        echo "status=$st ec=$quc_ec"
        bad=1
    fi
    trees_ok "$src" "$dst" || bad=1
    if [ "$bad" -eq 0 ]; then pass; else fail "start from another directory"; fi
}

test_G24() {
    bad=0
    run_quiet "$SH" "$SCRIPT" start --eject
    if [ "$quc_ec" -ne 2 ] || [ "$quc_out_n" != 0 ] || [ "$quc_err_n" != 0 ]; then
        echo "ec=$quc_ec out=$quc_out_n err=$quc_err_n"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "unknown eject flag"; fi
}

test_G25() {
    bad=0
    g_old=$ROOT/rollback/0.4.0-rc.5/quiet_usb_copy.sh
    if [ ! -f "$g_old" ]; then
        # В опубликованном дереве нет rollback/: rc.5 берётся из истории git
        # (коммит 1090f43) и сверяется с опубликованной суммой.
        g_old=$WORK/t-$current/rc5.sh
        mkdir -p "$WORK/t-$current"
        if git -C "$ROOT" show 1090f43:quiet_usb_copy.sh > "$g_old" 2>/dev/null \
            && [ "$(c40_sha "$g_old")" = 946e9d86c9508631fc5c00bd9b3c59b611dcb5e9611ef8c551be45b6340f2593 ]; then
            :
        else
            rm -f "$g_old"
        fi
    fi
    if [ ! -f "$g_old" ]; then
        echo "missing rc.5"
        bad=1
    fi
    src_a=$WORK/t-$current/src-a
    dst_a=$WORK/t-$current/dst-a
    src_b=$WORK/t-$current/src-b
    dst_b=$WORK/t-$current/dst-b
    mkdir -p "$src_a" "$dst_a" "$src_b" "$dst_b"
    mount -t tmpfs -o size=16m tmpfs "$src_a" || bad=1
    mount -t tmpfs -o size=16m tmpfs "$dst_a" || bad=1
    mount -t tmpfs -o size=16m tmpfs "$src_b" || bad=1
    mount -t tmpfs -o size=16m tmpfs "$dst_b" || bad=1
    printf 'same\n' > "$src_a/a.txt"
    printf 'same\n' > "$src_b/a.txt"
    g_state=$XDG_STATE_HOME
    g_run=$XDG_RUNTIME_DIR
    export XDG_STATE_HOME=$WORK/t-$current/xdg-old
    export XDG_RUNTIME_DIR=$WORK/t-$current/run-old
    mkdir -p "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    "$SH" "$g_old" start "$src_a" "$dst_a" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ]; then
        echo "old start"
        bad=1
    fi
    g_old_st=$(wait_done 40)
    g_old_copy=$(job_field copy_status || true)
    g_old_verify=$(job_field verify_status || true)
    g_old_sync=$(job_field sync_status || true)
    g_old_done=$(job_field files_done || true)
    g_old_mode=$(job_field source_mode || true)
    export XDG_STATE_HOME=$WORK/t-$current/xdg-new
    export XDG_RUNTIME_DIR=$WORK/t-$current/run-new
    mkdir -p "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
    "$SH" "$SCRIPT" start "$src_b" "$dst_b" >"$WORK/last.out" 2>"$WORK/last.err"
    if [ "$?" -ne 0 ]; then
        echo "new start"
        bad=1
    fi
    g_new_st=$(wait_done 40)
    if [ "$g_old_st" != SUCCESS ] || [ "$g_new_st" != SUCCESS ]; then
        echo "old=$g_old_st new=$g_new_st"
        bad=1
    fi
    if [ "$g_old_copy" != "$(job_field copy_status)" ] || [ "$g_old_verify" != "$(job_field verify_status)" ] || [ "$g_old_sync" != "$(job_field sync_status)" ] || [ "$g_old_done" != "$(job_field files_done)" ] || [ "$g_old_mode" != "$(job_field source_mode)" ]; then
        echo "fields diverged old=$g_old_copy/$g_old_verify/$g_old_sync/$g_old_done/$g_old_mode new=$(job_field copy_status)/$(job_field verify_status)/$(job_field sync_status)/$(job_field files_done)/$(job_field source_mode)"
        bad=1
    fi
    if [ "$(job_field eject_status)" != skipped_policy ] || [ "$(job_field eject_policy)" != no ]; then
        echo "new eject fields"
        bad=1
    fi
    trees_ok "$src_a" "$dst_a" || bad=1
    trees_ok "$src_b" "$dst_b" || bad=1
    export XDG_STATE_HOME=$g_state
    export XDG_RUNTIME_DIR=$g_run
    if [ "$bad" -eq 0 ]; then pass; else fail "differential rc.5"; fi
}

test_G27() {
    bad=0
    g_stub_install
    make_pair || { fail "mount"; return; }
    printf 'KEEP\n' > "$dst/keep.txt"
    g_keep=$(c40_sha "$dst/keep.txt")
    printf 'fresh\n' > "$src/a.txt"
    run_start --eject-dest --source-mode staged --dest-mode separate "$src" "$dst"
    if [ "$quc_ec" -ne 0 ] || [ "$quc_noisy" -ne 0 ]; then
        echo "start ec=$quc_ec"
        bad=1
    fi
    st=$(wait_done 80)
    g_rel=$(job_field dest_rel || true)
    if [ "$st" != SUCCESS ] || [ "$(job_field stage_status)" != READY ] || [ "$(job_field eject_status)" != skipped_policy ] || [ "$(job_field eject_policy)" != yes ]; then
        echo "status=$st stage=$(job_field stage_status) eject=$(job_field eject_status)"
        bad=1
    fi
    cmp -s "$src/a.txt" "$dst/$g_rel/a.txt" || bad=1
    if [ "$(c40_sha "$dst/keep.txt")" != "$g_keep" ] || [ -e "$dst/a.txt" ]; then
        echo "separate placement"
        bad=1
    fi
    if [ "$(g_stub_actions)" != 0 ]; then
        echo "staged called eject"
        cat "$g_stub_log"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then pass; else fail "staged separate eject skipped"; fi
}

run_case S01 test_S01
run_case S02 test_S02
run_case S03 test_S03
run_case S05 test_S05
run_case G01 test_G01
run_case G02 test_G02
run_case G03 test_G03
run_case G04 test_G04
run_case G05 test_G05
run_case G06 test_G06
run_case G08 test_G08
run_case G09 test_G09
run_case G10 test_G10
run_case G12 test_G12
run_case G14 test_G14
run_case G15 test_G15
run_case G16 test_G16
run_case G17 test_G17
run_case G18 test_G18
run_case G19 test_G19
run_case G20 test_G20
run_case G21 test_G21
run_case G23 test_G23
run_case G24 test_G24
run_case G25 test_G25
run_case G27 test_G27

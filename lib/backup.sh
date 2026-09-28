#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/backup.sh
# 备份与恢复:打包 Hermes 数据(配置/记忆/技能/会话/配对/凭据)+ Caddy 站点 +
# 本工具状态。代码与大件缓存不打包(官方安装脚本/缓存可重建),所以包很小。
# 安全约定:恢复不删除任何旧数据,只把现有目录改名挪走(可回滚)。
# =============================================================================

[[ -n "${HV_BACKUP_LOADED:-}" ]] && return 0
HV_BACKUP_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

HV_BACKUP_KEEP="${HV_BACKUP_KEEP:-7}"

# 打包时排除的内容(体积大且可重建)
HV_BACKUP_EXCLUDES=(
    "--exclude=.hermes/hermes-agent"
    "--exclude=.hermes/tools"
    "--exclude=.hermes/logs"
    "--exclude=.hermes/audio_cache"
    "--exclude=.hermes/image_cache"
    "--exclude=.hermes/*.venv"
    "--exclude=*.log"
)

hv_backup_create() {
    hv_require_root
    install -d -m 700 "$HV_BACKUP_DIR"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local label="${1:-manual}"
    local out="${HV_BACKUP_DIR}/hermes-vps-${label}-${ts}.tar.gz"

    hv_step "创建备份 → $out"

    # 备份前给 systemd 单元也留一份(恢复后可直接对照)
    local staged; staged="$(mktemp -d)"
    install -d -m 755 "$staged/systemd" "$staged/etc"
    for f in "/etc/systemd/system/${HV_GW_UNIT:-hermes-gateway.service}" "/etc/systemd/system/hermes-dashboard.service"; do
        [[ -f "$f" ]] && cp -p "$f" "$staged/systemd/" 2>/dev/null || true
    done
    for f in "$HV_STATE_FILE" "$HV_MIRROR_FILE" "$HV_CRED_FILE"; do
        [[ -f "$f" ]] && cp -p "$f" "$staged/etc/" 2>/dev/null || true
    done
    [[ -f /etc/caddy/Caddyfile ]] && cp -p /etc/caddy/Caddyfile "$staged/etc/Caddyfile" 2>/dev/null || true

    local rc=0
    set +e
    tar czf "$out" "${HV_BACKUP_EXCLUDES[@]}" \
        -C "$HV_USER_HOME" "$(basename "$HV_UHOME")" \
        -C "$staged" systemd etc 2>/dev/null
    rc=$?
    set -e
    rm -rf "$staged"

    if [[ $rc -ne 0 ]]; then
        # 目录名不是 .hermes 时(tar -C 的相对路径问题)退回绝对路径打包
        set +e
        tar czf "$out" "${HV_BACKUP_EXCLUDES[@]}" \
            -C / "${HV_UHOME#/}" \
            -C /etc caddy 2>/dev/null
        rc=$?
        set -e
    fi
    [[ $rc -eq 0 && -s "$out" ]] || { hv_err "备份失败"; return 1; }

    chmod 600 "$out"
    hv_ok "备份完成:$(du -h "$out" | awk '{print $1}')  $out"
    hv_backup_prune
    hv_state_set LAST_BACKUP "$out"
}

hv_backup_list() {
    install -d -m 700 "$HV_BACKUP_DIR"
    hv_rule
    if ! ls -1 "$HV_BACKUP_DIR"/hermes-vps-*.tar.gz >/dev/null 2>&1; then
        printf '  暂无备份\n'; hv_rule; return 0
    fi
    printf '  备份目录: %s\n\n' "$HV_BACKUP_DIR"
    ls -lh "$HV_BACKUP_DIR"/hermes-vps-*.tar.gz | awk '{printf "  %s  %s  %s\n", $5, $6" "$7" "$8, $9}'
    hv_rule
}

# 只保留最近 N 份:先列出将删除的文件并确认,绝不静默删
hv_backup_prune() {
    local keep="${1:-$HV_BACKUP_KEEP}"
    local -a all=()
    while IFS= read -r f; do all+=("$f"); done < <(ls -1t "$HV_BACKUP_DIR"/hermes-vps-*.tar.gz 2>/dev/null || true)
    [[ ${#all[@]} -le $keep ]] && return 0
    local -a old=("${all[@]:$keep}")
    hv_info "备份超过 ${keep} 份,以下旧备份将被清理:"
    printf '    %s\n' "${old[@]}"
    if hv_confirm "确认清理这些旧备份?" no; then
        local f
        for f in "${old[@]}"; do rm -f "$f" && hv_dim "   已删除 $f"; done
    fi
}

hv_backup_restore() {
    hv_require_root
    local archive="$1"
    if [[ -z "$archive" ]]; then
        hv_backup_list
        hv_ask archive "输入要恢复的备份文件完整路径" ""
    fi
    [[ -f "$archive" ]] || hv_die "备份文件不存在:$archive"

    hv_warn "恢复会用备份内容覆盖以下位置:"
    printf '    %s            (Hermes 数据:config/记忆/技能/会话/凭据)\n' "$HV_UHOME"
    printf '    /etc/hermes-vps/      (本工具状态;仅当包内存在时)\n'
    printf '    /etc/caddy/Caddyfile  (仅当包内存在时)\n'
    hv_info "现有数据不会被删除:会先改名为 ${HV_UHOME}.pre-restore-<时间戳> 保留"

    hv_confirm "确认继续恢复?" no || return 0

    hv_has_systemd && { systemctl stop hermes-gateway hermes-dashboard 2>/dev/null || true; }

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    if [[ -d "$HV_UHOME" ]]; then
        mv "$HV_UHOME" "${HV_UHOME}.pre-restore-${ts}"
        hv_info "已挪走旧数据:${HV_UHOME}.pre-restore-${ts}"
    fi
    install -d -o "$HV_USER" -g "$HV_USER" -m 700 "$HV_UHOME"

    local tmp; tmp="$(mktemp -d)"
    tar xzf "$archive" -C "$tmp"
    if [[ -d "$tmp/$(basename "$HV_UHOME")" ]]; then
        cp -a "$tmp/$(basename "$HV_UHOME")/." "$HV_UHOME/"
    elif [[ -d "$tmp/.hermes" ]]; then
        cp -a "$tmp/.hermes/." "$HV_UHOME/"
    fi
    [[ -d "$tmp/etc" ]] && cp -a "$tmp/etc/." "$HV_ETC/" 2>/dev/null || true
    [[ -f "$tmp/etc/Caddyfile" ]] && cp -p "$tmp/etc/Caddyfile" /etc/caddy/Caddyfile 2>/dev/null || true
    [[ -d "$tmp/systemd" ]] && cp -a "$tmp/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    rm -rf "$tmp"

    chown -R "$HV_USER:$HV_USER" "$HV_USER_HOME" 2>/dev/null || true
    hv_systemd_reload
    hv_has_systemd && { systemctl start hermes-gateway hermes-dashboard 2>/dev/null || true; }
    hv_ok "恢复完成。校验:hermes-vps doctor"
}

# 定时备份(可选):每天 03:30
hv_backup_schedule_enable() {
    hv_require_root
    hv_has_systemd || { hv_warn "无 systemd,无法设定时备份"; return 1; }
    local self="${HV_INSTALLED_BIN:-/usr/local/bin/hermes-vps}"
    cat >/etc/systemd/system/hermes-vps-backup.service <<EOF
[Unit]
Description=hermes-vps 自动备份
[Service]
Type=oneshot
ExecStart=${self} backup create --label auto --yes
EOF
    cat >/etc/systemd/system/hermes-vps-backup.timer <<'EOF'
[Unit]
Description=hermes-vps 每日自动备份
[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=1800
Persistent=true
[Install]
WantedBy=timers.target
EOF
    hv_systemd_reload
    systemctl enable --now hermes-vps-backup.timer
    hv_ok "已启用每日 03:30 自动备份(保留最近 ${HV_BACKUP_KEEP} 份)"
}

hv_backup_schedule_disable() {
    hv_has_systemd || return 0
    systemctl disable --now hermes-vps-backup.timer >/dev/null 2>&1 || true
    hv_ok "已关闭自动备份"
}

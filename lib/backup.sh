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

# 打包时排除的内容(体积大且可重建 / 运行期文件)
HV_BACKUP_EXCLUDES=(
    "--exclude=.hermes/hermes-agent"
    "--exclude=.hermes/tools"
    "--exclude=.hermes/logs"
    "--exclude=.hermes/audio_cache"
    "--exclude=.hermes/image_cache"
    "--exclude=.hermes/*.venv"
    "--exclude=*.log"
    "--exclude=*.sock"          # gateway.sock 等运行期 socket 不能打包
    "--warning=no-file-changed" # 网关在跑时 state.db 会变,tar 返回 1 属正常
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
        # 兜底:换一种 -C 组合再打一次,但保持 ".hermes/..." 的相对布局
        set +e
        tar czf "$out" "${HV_BACKUP_EXCLUDES[@]}" \
            -C "$(dirname "$HV_UHOME")" "$(basename "$HV_UHOME")" \
            -C "$staged" systemd etc 2>/dev/null
        rc=$?
        set -e
    fi
    # tar 的退出码 1 = "文件在读取时发生变化"之类的警告(网关正在跑就会这样),
    # 这类警告不影响备份可用性,不算失败。
    if [[ $rc -gt 1 || ! -s "$out" ]]; then
        hv_err "备份失败(rc=$rc)"; return 1
    fi

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

    # --- 列出条目(只列一次,顺便避免 tar | head 触发 SIGPIPE) ---
    local listing=""
    listing="$(tar tzf "$archive" 2>/dev/null)" || listing=""
    [[ -n "$listing" ]] || hv_die "无法读取备份包(损坏?):$archive"
    local first="${listing%%$'\n'*}"
    if [[ "$first" != ".hermes" && "$first" != .hermes/* ]]; then
        hv_die "不支持的备份包布局(首条目:$first)。请使用 hermes-vps 生成的备份。"
    fi

    # --- 空间预检:解包是就地覆盖,需要能放下压缩包解压后的内容 ---
    local need_mb avail_mb
    need_mb="$(gzip -l "$archive" 2>/dev/null | awk 'NR==2{printf "%d", $2/1048576}')"
    [[ -z "$need_mb" || "$need_mb" -le 0 ]] && need_mb=200
    avail_mb="$(df -Pm "$HV_USER_HOME" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ -z "$avail_mb" ]] && avail_mb=0
    if [[ "$avail_mb" -lt $((need_mb + 200)) ]]; then
        hv_die "磁盘空间不足:恢复约需 $((need_mb + 200)) MB,当前可用 ${avail_mb} MB(先清理或换台机器)"
    fi

    hv_warn "恢复会用备份内容覆盖以下位置:"
    printf '    %s            (Hermes 数据:config/记忆/技能/会话/凭据)\n' "$HV_UHOME"
    printf '    /etc/hermes-vps/      (本工具状态;仅当包内存在时)\n'
    printf '    /etc/caddy/Caddyfile  (仅当包内存在时)\n'
    hv_info "采用就地合并:代码与 tools 不在备份里,会原样保留,不会被清空"
    hv_info "被覆盖的旧内容会先挪到 ${HV_UHOME}.pre-restore-<时间戳>/ 以便回滚"

    hv_confirm "确认继续恢复?" no || return 0

    # 无论后续成功失败,都要把服务拉回运行状态(否则恢复失败会留下停摆的机器)
    local _services_were_stopped=0
    _hv_restore_restart_services() {
        if [[ "${_services_were_stopped:-0}" == "1" ]] && hv_has_systemd; then
            systemctl start hermes-gateway hermes-dashboard 2>/dev/null || true
            _services_were_stopped=0
        fi
    }
    # EXIT 也要挂:脚本被 hv_die/ERR 陷阱带出去时,RETURN 不会触发
    trap '_hv_restore_restart_services' RETURN EXIT

    if hv_has_systemd; then
        systemctl stop hermes-gateway hermes-dashboard 2>/dev/null || true
        _services_were_stopped=1
    fi

    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local aside="${HV_UHOME}.pre-restore-${ts}"
    install -d -m 700 "$aside"

    # 先从清单里取出 .hermes/ 下的顶层条目(不解包,不占空间)
    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        [[ -e "$HV_UHOME/$name" ]] || continue
        mv "$HV_UHOME/$name" "$aside/$name"
        hv_dim "   挪走 $name"
    done < <(sed -n 's|^\.hermes/\([^/][^/]*\)\(/.*\)\?$|\1|p' <<<"$listing" | sort -u)

    # 就地解包(不经过 /tmp:/tmp 常是小容量 tmpfs,放不下)
    tar xzf "$archive" -C "$HV_USER_HOME" || {
        hv_err "解包失败。回滚点仍在:$aside"
        hv_err "应急:把 $aside 里的内容拷回 $HV_UHOME 即可复原"
        return 1
    }

    # 附带的 /etc 部分(备份包里可能带 Caddyfile、本工具状态、systemd 单元)
    local etctmp; etctmp="$(mktemp -d "${HV_USER_HOME}/.restore-etc.XXXXXX")"
    if tar xzf "$archive" -C "$etctmp" 2>/dev/null --wildcards 'etc/*' 'systemd/*' && [[ -d "$etctmp/etc" || -d "$etctmp/systemd" ]]; then
        [[ -d "$etctmp/etc" ]] && cp -a "$etctmp/etc/." "$HV_ETC/" 2>/dev/null || true
        [[ -f "$etctmp/etc/Caddyfile" ]] && cp -p "$etctmp/etc/Caddyfile" /etc/caddy/Caddyfile 2>/dev/null || true
        [[ -d "$etctmp/systemd" ]] && cp -a "$etctmp/systemd/"*.service /etc/systemd/system/ 2>/dev/null || true
    fi
    rm -rf "$etctmp"

    chown -R "$HV_USER:$HV_USER" "$HV_USER_HOME" 2>/dev/null || true
    chmod 600 "$HV_UHOME/.env" 2>/dev/null || true
    hv_systemd_reload
    _hv_restore_restart_services
    _services_were_stopped=0
    trap - RETURN EXIT
    hv_ok "恢复完成(回滚点:$aside)"
    hv_info "校验:hermes-vps doctor"
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

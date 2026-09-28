# =============================================================================
#  备份 / 恢复 · 更新 · 自检 · 卸载
# =============================================================================

backup_excludes=(
    # 只备份"数据与配置":代码树与 Python 运行时属可重装内容,不打包(恢复时保持原样)
    "--exclude=.hermes/tools"
    "--exclude=.hermes/hermes-agent"
    "--exclude=.hermes/sessions/*"
    "--exclude=.hermes/logs/*"
    "--exclude=.hermes/*.venv"
    "--exclude=.hermes/venv"
    "--exclude=.hermes/uv-cache"
    "--exclude=.hermes/state.db-wal"
    "--exclude=.hermes/state.db-shm"
    "--exclude=.hermes/unpacked.bak"
    "--exclude=.hermes/*.pre-restore-*"
)

backup_create() {
    if [[ "$HV_MODE" == "system" ]]; then require_root "创建备份"; fi
    local tag="${1:-manual}"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local out="$BACKUP_DIR/hermes-${tag}-${ts}.tar.gz"
    hermes_installed || { err "Hermes 未安装,无需备份"; return 1; }

    local need_mb=0
    need_mb="$(du -sm "$UHOME" 2>/dev/null | awk '{print $1}')" || need_mb=0
    [[ -z "$need_mb" ]] && need_mb=0
    local free_mb; free_mb="$(df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}')" || free_mb=0
    if [[ "$free_mb" -lt $(( need_mb / 2 + 50 )) ]]; then
        err "备份目录空间不足(需约 $(( need_mb / 2 ))MB,可用 ${free_mb}MB)"; return 1
    fi

    step "打包备份(含配置/密钥/技能/定时任务/服务单元)"
    local staged; staged="$(mktemp -d)"
    install -d "$staged/etc" "$staged/systemd" 2>/dev/null || true
    [[ -f "$STATE_FILE" ]] && cp -p "$STATE_FILE" "$staged/etc/" 2>/dev/null || true
    [[ -f "$MIRROR_FILE" ]] && cp -p "$MIRROR_FILE" "$staged/etc/" 2>/dev/null || true
    [[ -f "$CRED_FILE" ]] && cp -p "$CRED_FILE" "$staged/etc/" 2>/dev/null || true
    [[ -f "$CADDYFILE" ]] && cp -p "$CADDYFILE" "$staged/etc/Caddyfile" 2>/dev/null || true
    local u
    for u in /etc/systemd/system/hermes-gateway.service /etc/systemd/system/hermes-dashboard.service; do
        [[ -f "$u" ]] && cp -p "$u" "$staged/systemd/" 2>/dev/null || true
    done
    local UD; UD="$(unit_dir)"
    [[ -d "$UD/hermes-dashboard.service.d" ]] && cp -r "$UD/hermes-dashboard.service.d" "$staged/systemd/" 2>/dev/null || true
    [[ -d "$UD/hermes-gateway.service.d" ]] && cp -r "$UD/hermes-gateway.service.d" "$staged/systemd/" 2>/dev/null || true
    mkdir -p "$staged/systemd"
    cp -p "$UD"/hermes-*.service "$staged/systemd/" 2>/dev/null || true
    cp -p "$UD"/hermes-vps-autoupdate.* "$staged/systemd/" 2>/dev/null || true

    local rc=0
    set +e
    tar czf "$out" "${backup_excludes[@]}" \
        -C "$HHOME" "$(basename "$UHOME")" \
        -C "$staged" etc systemd 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -gt 1 ]]; then
        warn "第一次打包失败(rc=$rc),换一种路径组合重试"
        set +e
        tar czf "$out" "${backup_excludes[@]}" \
            -C "$(dirname "$UHOME")" "$(basename "$UHOME")" \
            -C "$staged" etc systemd 2>/dev/null
        rc=$?
        set -e
    fi
    rm -rf "$staged"
    if [[ $rc -gt 1 || ! -s "$out" ]]; then rm -f "$out"; err "备份失败(rc=$rc)"; return 1; fi
    chmod 600 "$out"
    local size; size="$(du -h "$out" 2>/dev/null | awk '{print $1}')"
    ok "备份完成:$out($size)"

    # 只在手动/自动更新时保留 7 份
    local old
    old="$(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null | tail -n +8)" || old=""
    if [[ -n "$old" ]]; then
        dim "自动清理旧备份(保留最近 7 份):"
        while read -r f; do [[ -n "$f" ]] && dim "  删除 $f" && rm -f "$f"; done <<<"$old"
    fi
    return 0
}

backup_list() {
    rule
    printf '    %s备份目录:%s\n' "$BD" "$BACKUP_DIR"
    rule
    local f found=0
    while read -r f; do
        [[ -z "$f" ]] && continue
        found=1
        printf '    %s  %s%s\n' "$(du -h "$f" 2>/dev/null | awk '{print $1}')" "$(basename "$f")" "$N"
    done < <(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null || true)
    [[ $found -eq 0 ]] && printf '    (还没有备份)\n'
    rule
}

backup_restore() {
    if [[ "$HV_MODE" == "system" ]]; then require_root "恢复备份"; fi
    clear_screen
    header "恢复备份"
    local files=() f
    while read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null || true)
    if [[ ${#files[@]} -eq 0 ]]; then warn "没有可用备份"; pause; return 0; fi
    local i=0; local -a list=()
    while read -r f; do [[ -z "$f" ]] && continue; i=$((i+1)); list+=("$f"); printf '    %2d) %s(%s)\n' "$i" "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"; done < <(printf '%s\n' "${files[@]}")
    printf '     0) 返回\n'
    local ch=""; menu_choice ch "选择要恢复的备份编号"
    [[ "$ch" == "0" || -z "$ch" ]] && return 0
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#list[@]} )) || { warn "无效编号"; pause; return 1; }
    local pkg="${list[$((ch-1))]}"
    warn "恢复会把备份内容合并回 ${UHOME}(覆盖同名文件)"
    confirm "确认恢复 $(basename "$pkg") ?" no || { info "已取消"; pause; return 0; }
    backup_create pre-restore || true

    step "校验并解包"
    local staged; staged="$(mktemp -d)"
    local rc=0
    set +e; tar tzf "$pkg" >/dev/null 2>&1; rc=$?; set -e
    if [[ $rc -ne 0 ]]; then rm -rf "$staged"; err "备份包损坏(rc=$rc)"; return 1; fi
    local need_mb; need_mb="$(du -sm "$pkg" | awk '{print $1*3}')"
    local free_mb; free_mb="$(df -Pm "$HHOME" 2>/dev/null | awk 'NR==2{print $4}')" || free_mb=0
    if [[ "$free_mb" -lt "$need_mb" ]]; then rm -rf "$staged"; err "空间不足(需约 ${need_mb}MB,可用 ${free_mb}MB)"; return 1; fi

    systemctl stop hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
    set +e
    tar xzf "$pkg" -C "$staged" 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -gt 1 ]]; then
        rm -rf "$staged"; warn "解包异常(rc=$rc),已中止;服务将拉回"
        systemctl start hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
        return 1
    fi
    local rdir="$staged/$(basename "$UHOME")"
    if [[ -d "$rdir" ]]; then
        install -d "$UHOME/unpacked.bak" 2>/dev/null || true
        # 就地合并:只把将被覆盖的部分挪走,避免破坏安装
        set +e
        ( cd "$rdir" && find . -type f -print0 | while IFS= read -r -d '' rel; do
            dst="$UHOME/$rel"
            if [[ -f "$dst" ]]; then
                mkdir -p "$UHOME/unpacked.bak/$(dirname "$rel")" 2>/dev/null || true
                cp -p "$dst" "$UHOME/unpacked.bak/$rel" 2>/dev/null || true
            fi
            mkdir -p "$(dirname "$dst")" 2>/dev/null || true
            cp -p "$rel" "$dst" 2>/dev/null || true
          done ) 2>/dev/null
        set -e
        chown -R "$HUSER:$HUSER" "$UHOME" 2>/dev/null || true
        ok "配置与数据已合并回 $UHOME"
    fi
    [[ -d "$staged/etc" ]] && {
        [[ -f "$staged/etc/state.env" ]] && cp -p "$staged/etc/state.env" "$STATE_FILE" 2>/dev/null || true
        [[ -f "$staged/etc/Caddyfile" ]] && cp -p "$staged/etc/Caddyfile" "$CADDYFILE" 2>/dev/null || true
        ok "状态与 Caddy 配置已恢复"
    }
    [[ -d "$staged/systemd" ]] && cp -p "$staged"/systemd/* "$(unit_dir)/" 2>/dev/null || true
    rm -rf "$staged"
    systemctl daemon-reload 2>/dev/null || true
    systemctl start hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
    systemctl is-active caddy >/dev/null 2>&1 || systemctl start caddy >/dev/null 2>&1 || true
    sleep 2
    ok "已恢复并拉起服务:$(service_brief)"
    dim "被覆盖的旧文件存于 $UHOME/unpacked.bak(确认无误后可自行删除)"
    pause
}

auto_update_install() {
    local UD; UD="$(unit_dir)"
    if [[ "$HV_MODE" == "system" ]]; then
        require_root "安装每日自动更新"
    else
        if ! user_systemd_ok; then
            warn "用户态:当前会话没有 systemd --user(无 DBus),装不了定时器"
            dim "可自行加 crontab:  30 4 * * * $SELF update --yes --no-restart"
            return 1
        fi
        mkdir -p "$UD"
    fi
    cat >"$UD/hermes-vps-autoupdate.service" <<EOF
[Unit]
Description=Hermes Agent auto update (managed by hermes-vps)
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF update --yes --no-restart
EOF
    cat >"$UD/hermes-vps-autoupdate.timer" <<'EOF'
[Unit]
Description=Daily Hermes Agent update check

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 "$UD/hermes-vps-autoupdate.service" "$UD/hermes-vps-autoupdate.timer"
    sctl daemon-reload 2>/dev/null || true
    sctl enable --now hermes-vps-autoupdate.timer >/dev/null 2>&1 || true
    local next; next="$(sctl list-timers hermes-vps-autoupdate.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')"
    ok "已启用每日自动更新(04:30 左右)${next:+ · 下次:$next}"
}
auto_update_remove() {
    local UD; UD="$(unit_dir)"
    sctl disable --now hermes-vps-autoupdate.timer >/dev/null 2>&1 || true
    rm -f "$UD/hermes-vps-autoupdate.timer" "$UD/hermes-vps-autoupdate.service"
    sctl daemon-reload 2>/dev/null || true
    ok "已关闭自动更新"
}
auto_update_status() {
    if sctl is-enabled hermes-vps-autoupdate.timer >/dev/null 2>&1; then
        local next; next="$(sctl list-timers hermes-vps-autoupdate.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')"
        printf 'enabled%s' "${next:+ · 下次 $next}"
    else
        printf 'disabled'
    fi
}

# ---------------------------------------------------------------------------
# 卸载(逐项列出,逐项确认,绝不批量静默删)
# ---------------------------------------------------------------------------
uninstall_preview() {
    printf '\n  %s将被处理的路径(逐项确认,可单独跳过):%s\n' "$BD" "$N"
    local items=(
      "systemd 单元|/etc/systemd/system/hermes-gateway.service|停用并删除网关服务"
      "systemd 单元|/etc/systemd/system/hermes-dashboard.service|停用并删除面板服务"
      "systemd 单元|/etc/systemd/system/hermes-dashboard.service.d|服务覆盖配置目录"
      "systemd 单元|/etc/systemd/system/hermes-vps-autoupdate.timer|自动更新定时器"
      "systemd 单元|/etc/systemd/system/hermes-vps-autoupdate.service|自动更新服务"
      "数据目录|$UHOME|Hermes 配置/会话/技能/密钥"
      "服务用户|$HHOME|hermes 用户家目录"
      "配置目录|$ETC_DIR|本工具状态与凭据"
      "程序目录|$TOOL_LOG_DIR|本工具日志"
      "Caddy|$CADDYFILE|反代配置"
      "Caddy|/etc/systemd/system/caddy.service|仅当由本工具安装二进制时"
    )
    local it
    for it in "${items[@]}"; do
        local kind path note
        kind="$(cut -d'|' -f1 <<<"$it")"; path="$(cut -d'|' -f2 <<<"$it")"; note="$(cut -d'|' -f3 <<<"$it")"
        if [[ -e "$path" ]]; then printf '    %s[%s]%s %s  %s(%s)%s\n' "$Y" "$kind" "$N" "$path" "$DM" "$note" "$N"
        else printf '    %s[跳过]%s %s  %s(不存在)%s\n' "$DM" "$N" "$path" "$DM" "$N"; fi
    done
    printf '    %s[保留]%s %s/ (备份永远保留)\n' "$G" "$N" "$BACKUP_DIR"
    printf '    %s[保留]%s 防火墙规则、swap、系统依赖(不还原)\n' "$G" "$N"
}

uninstall_run() {
    require_root
    clear_screen
    header "卸载 Hermes 与服务"
    warn "此操作会删除 Hermes 的配置、会话、密钥与技能(备份目录保留)"
    uninstall_preview
    rule
    confirm "确定继续吗?" no || { info "已取消"; pause; return 0; }
    if confirm "卸载前先创建一个备份?" yes; then backup_create pre-uninstall || warn "备份失败,继续?" ; fi
    confirm "最后确认:开始逐项删除?" no || { info "已取消"; pause; return 0; }

    local steps=(
      "hermes-gateway:stop|systemctl stop hermes-gateway; systemctl disable hermes-gateway; rm -f /etc/systemd/system/hermes-gateway.service; rm -rf /etc/systemd/system/hermes-gateway.service.d"
      "hermes-dashboard:stop|systemctl stop hermes-dashboard; systemctl disable hermes-dashboard; rm -f /etc/systemd/system/hermes-dashboard.service; rm -rf /etc/systemd/system/hermes-dashboard.service.d"
      "autoupdate|systemctl disable --now hermes-vps-autoupdate.timer; rm -f /etc/systemd/system/hermes-vps-autoupdate.timer /etc/systemd/system/hermes-vps-autoupdate.service"
      "caddy:stop|systemctl disable --now caddy"
    )
    local st
    for st in "${steps[@]}"; do
        local label="${st%%|*}"; local cmd="${st#*|}"
        if confirm "执行:${label}?" yes; then set +e; eval "$cmd" >/dev/null 2>&1; set -e; ok "$label 完成"; else info "跳过 $label"; fi
    done
    systemctl daemon-reload 2>/dev/null || true

    local paths=(
      "$UHOME|Hermes 数据(配置/会话/技能/密钥)"
      "$HHOME|hermes 用户家目录"
      "$ETC_DIR|本工具状态与凭据"
      "$TOOL_LOG_DIR|本工具日志"
      "$CADDYFILE|Caddy 反代配置"
    )
    local p
    for p in "${paths[@]}"; do
        local path="${p%%|*}" note="${p#*|}"
        [[ -e "$path" ]] || { info "$path 不存在,跳过"; continue; }
        local size; size="$(du -sh "$path" 2>/dev/null | awk '{print $1}')"
        if confirm "删除 ${path}(${size} · ${note})?" no; then
            rm -rf "$path"; ok "已删除 $path"
        else
            info "保留 $path"
        fi
    done
    if id "$HUSER" >/dev/null 2>&1 && confirm "删除系统用户 ${HUSER}?" no; then
        userdel "$HUSER" 2>/dev/null || warn "userdel 失败(可能有进程占用)"
        ok "已删除用户 $HUSER"
    fi
    if [[ -x "$CADDY_BIN" && ! -d /etc/apt/sources.list.d ]] && confirm "删除由本工具安装的 Caddy 二进制?" no; then
        rm -f "$CADDY_BIN"; ok "已删除 $CADDY_BIN"
    fi
    rule
    ok "卸载流程结束"
    dim "保留:$BACKUP_DIR(备份)、防火墙规则、swap、系统依赖"
    dim "如需彻底清理,可再手工检查 /etc/systemd/system 下是否残留 hermes-vps 相关单元"
    pause
}

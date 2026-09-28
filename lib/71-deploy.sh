# ---------------------------------------------------------------------------
# 一键部署
# ---------------------------------------------------------------------------
deploy_all() {
    require_root
    clear_screen
    header "一键部署"
    detect_os
    printf '    系统:%s · %s · %s 核 · 内存 %sMB · 磁盘剩余 %sMB\n' "$OS_NAME" "$ARCH" "$CORES" "$MEM_MB" "$DISK_MB"
    if [[ "$PKG" == "" ]]; then die "不支持的发行版(需要 Debian/Ubuntu 系;其他系统请手工装依赖)"; fi
    if [[ "$INIT" != "systemd" ]]; then die "需要 systemd(未检测到 /run/systemd/system)"; fi
    if [[ "${MEM_MB:-0}" -lt 700 ]]; then warn "内存 ${MEM_MB}MB 偏小,建议 >=1GB"; fi
    if [[ "${DISK_MB:-0}" -lt 2000 ]]; then die "磁盘剩余不足 2GB(当前 ${DISK_MB}MB)"; fi
    rule

    # 域名 / 模型 / 平台:先收集意图,再一口气跑
    local domain email want_model=1 want_platform=0
    domain="$(st_get DOMAIN)"
    ask domain "域名(用于公网访问,留空=只在本机访问)" "$domain"
    if [[ -n "$domain" ]]; then ask email "证书通知邮箱(可留空)" "$(st_get ACME_EMAIL)"; fi
    if [[ "$(st_get MODEL_PROVIDER)" == "" ]]; then
        confirm "现在配置模型提供商(填 API Key,自动验证)?" yes && want_model=1 || want_model=0
    fi
    confirm "现在接入消息平台(QQ/微信等)(稍后可做)?" no && want_platform=1 || want_platform=0
    confirm "开始部署?" yes || { info "已取消"; pause; return 0; }

    local total=10 n=0
    progress() { n=$((n+1)); printf '\n  %s[%d/%d] %s%s\n' "$BD$C" "$n" "$total" "$*" "$N"; }

    progress "系统与依赖"
    deps_install

    progress "内存保护(小内存自动补 swap)"
    ensure_swap || warn "swap 步骤失败,继续"

    progress "网络加速探测(GitHub / PyPI)"
    mirror_probe || warn "未找到可用加速通道,继续用直连"
    mirror_apply_user

    progress "创建服务用户与目录"
    ensure_user
    hermes_ensure_config

    progress "安装 Hermes Agent"
    hermes_install

    progress "配置面板认证门"
    dashboard_ensure_auth
    [[ -n "$domain" ]] && dashboard_webui "$domain" || dashboard_webui ""

    progress "安装并启动服务(systemd)"
    service_gateway_install
    service_dashboard_install
    if dashboard_wait_ready; then ok "面板已就绪(127.0.0.1:${DASH_PORT})"; else warn "面板未在 60 秒内就绪,看日志:journalctl -u hermes-dashboard -n 50"; fi

    progress "配置 Caddy 反向代理与 HTTPS"
    if [[ -n "$domain" ]]; then
        caddy_install
        caddy_write_config "$domain" "$email" "$(st_api_enabled)"
        sleep 2
        local code; code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && ok "HTTPS 生效:https://${domain}/" || warn "域名探活 $code(证书可能还在签发)"
    else
        info "未提供域名,跳过 Caddy 配置(菜单 4 可随时补配)"
    fi
    credentials_write "$domain"

    progress "模型提供商"
    if [[ $want_model -eq 1 ]]; then model_menu; else info "跳过(菜单 2 随时可配)"; fi

    progress "防火墙与收尾"
    firewall_setup || true

    if [[ $want_platform -eq 1 ]]; then plat_menu; fi

    rule
    printf '\n  %s部署完成%s\n' "$BD$G" "$N"
    rule
    dashboard_show_info
    status_panel
    printf '\n'
    if [[ -n "$domain" ]]; then
        dim "浏览器打开:https://${domain}/  账号密码见 ${CRED_FILE}"
    else
        dim "面板在本机 127.0.0.1:${DASH_PORT}(配域名后可用公网访问)"
    fi
    dim "接下来:菜单 2 配模型 → 菜单 3 接平台 → 菜单 7 自检"
    pause
}

# 副本漂移护栏:防止"运行的是一份、系统命令是另一份"导致改了却没生效
check_copy_drift() {
    local other="/usr/local/bin/hermes-vps"
    [[ -f "$other" ]] || return 0
    [[ "$other" == "$SELF" ]] && return 0
    local a b
    a="$(md5sum "$SELF" 2>/dev/null | cut -d' ' -f1)" || a=""
    b="$(md5sum "$other" 2>/dev/null | cut -d' ' -f1)" || b=""
    [[ -n "$a" && "$a" == "$b" ]] && return 0
    printf '
  %s! 系统命令 %s 与当前运行的脚本不是同一版本%s
' "$Y" "$other" "$N"
    printf '  %s  运行中:%s(%s 行)  已安装:%s(%s 行)%s
' "$DM" "$SELF" "$(wc -l <"$SELF")" "$other" "$(wc -l <"$other" 2>/dev/null)" "$N"
    printf '  %s  同步命令:bash %s self-install%s
' "$DM" "$SELF" "$N"
    return 0
}

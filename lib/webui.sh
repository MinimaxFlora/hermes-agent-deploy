#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/webui.sh
# 公网访问相关的 Hermes 侧配置:
#   * Web 管理面板(hermes dashboard,默认 127.0.0.1:9119)
#       - dashboard.public_url   = https://<域名>      (反代后 OAuth/回调/校验都靠它)
#       - 认证门:HERMES_DASHBOARD_BASIC_AUTH_USERNAME/_PASSWORD/_SECRET
#       - 面板绑回环,Caddy 走 loopback 反代(官方推荐姿势,回环代理自动可信)
#   * OpenAI 兼容 API(API_SERVER_*,给 OpenWebUI / LobeChat / 脚本用)
# 生成的密码/token 落到 /etc/hermes-vps/credentials.txt(0600),屏幕只显示一次。
# =============================================================================

[[ -n "${HV_WEBUI_LOADED:-}" ]] && return 0
HV_WEBUI_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

hv_creds_file() { printf '%s' "$HV_CRED_FILE"; }

hv_creds_save() {
    local key="$1" val="$2"
    install -d -m 755 "$HV_ETC"
    [[ -f "$HV_CRED_FILE" ]] || { : >"$HV_CRED_FILE"; chmod 600 "$HV_CRED_FILE"; }
    hv_kv_set "$HV_CRED_FILE" "$key" "$val"
    chmod 600 "$HV_CRED_FILE"
}

hv_creds_get() { hv_kv_get "$HV_CRED_FILE" "$1" "${2:-}"; }

# ---------------------------------------------------------------------------
# 管理面板
# ---------------------------------------------------------------------------
# 参数: hv_dashboard_configure <域名或空>
hv_dashboard_configure() {
    local domain="${1:-}"
    hv_hermes_installed || hv_die "Hermes 未安装"

    local user pass secret
    user="$(hv_creds_get DASHBOARD_USER "admin")"
    pass="$(hv_creds_get DASHBOARD_PASSWORD "")"
    secret="$(hv_creds_get DASHBOARD_SECRET "")"
    [[ -n "$pass" ]] || pass="$(hv_random 18)"
    [[ -n "$secret" ]] || secret="$(hv_random_hex 32)"

    hv_creds_save DASHBOARD_USER "$user"
    hv_creds_save DASHBOARD_PASSWORD "$pass"
    hv_creds_save DASHBOARD_SECRET "$secret"

    hv_env_set HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$user"
    hv_env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$pass"
    hv_env_set HERMES_DASHBOARD_BASIC_AUTH_SECRET "$secret"
    hv_ok "面板认证门已开启(用户名 ${user},密码见 $(hv_creds_file))"

    if [[ -n "$domain" ]]; then
        hv_hermes_config_set dashboard.public_url "https://${domain}"
        hv_state_set DASHBOARD_PUBLIC_URL "https://${domain}"
    else
        hv_info "未设置域名:面板仅本机可用;配好域名后执行 hermes-vps domain set <域名>"
    fi

    # 关键:public_url / 认证环境变量是启动时读取的。改了配置必须重启面板,
    # 否则会出现"配置里声明了公网 URL,但正在跑的进程还没开认证门"的危险窗口。
    hv_dashboard_restart_if_installed
}

hv_dashboard_restart_if_installed() {
    hv_has_systemd || return 0
    systemctl is-enabled hermes-dashboard.service >/dev/null 2>&1 || return 0
    systemctl restart hermes-dashboard.service >/dev/null 2>&1 || {
        hv_warn "面板服务重启失败,请手工检查:systemctl status hermes-dashboard"
        return 0
    }
    hv_info "已重启面板服务使新配置生效"
    hv_dashboard_wait_ready
    hv_dashboard_check_gate
}

# 等面板真正开始监听(启动要几秒;固定 sleep 会误报"未监听")
hv_dashboard_wait_ready() {
    local i=0 limit="${1:-40}"
    while [[ $i -lt $limit ]]; do
        hv_port_in_use "$HV_DASH_PORT" && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# 校验运行中的面板确实开了认证门(防止"配了但没生效")
hv_dashboard_check_gate() {
    hv_have curl || return 0
    if ! hv_port_in_use "$HV_DASH_PORT"; then
        hv_dashboard_wait_ready 40 || { hv_warn "面板端口 ${HV_DASH_PORT} 40 秒内仍未监听(systemctl status hermes-dashboard)"; return 0; }
    fi
    local body; body="$(curl -sS -m 5 "http://127.0.0.1:${HV_DASH_PORT}/api/status" 2>/dev/null | tr -d ' \n')"
    if [[ -z "$body" ]]; then
        hv_warn "无法读取 /api/status,跳过认证门校验"
        return 0
    fi
    if [[ "$body" == *'"auth_required":true'* ]]; then
        hv_ok "面板认证门已开启(auth_required=true)"
        if [[ "$body" == *'"basic"'* ]]; then
            hv_ok "认证方式:用户名/密码(basic)"
        else
            hv_warn "已开认证门但未列出 basic provider,请检查 HERMES_DASHBOARD_BASIC_AUTH_* 是否写入 .env"
        fi
    else
        if [[ -n "$(hv_state_get DASHBOARD_PUBLIC_URL "")" ]]; then
            hv_err "面板声明了公网 URL 但认证门未开启 —— 不要把这种状态暴露到公网!"
            hv_dim "   排查:cat $(hv_user_env_file) | grep HERMES_DASHBOARD; systemctl restart hermes-dashboard"
        else
            hv_dim "   面板当前为本机模式(auth_required=false),配置域名后会自动开启认证门"
        fi
    fi
}

# 面板访问信息(终端展示 + 供 doctor 复用)
hv_dashboard_show_access() {
    local domain; domain="$(hv_state_get DOMAIN "")"
    hv_rule
    printf '  管理面板: %s\n' "$([[ -n $domain ]] && echo "https://${domain}" || echo "http://127.0.0.1:${HV_DASH_PORT}(仅本机)")"
    printf '  用户名  : %s\n' "$(hv_creds_get DASHBOARD_USER "admin")"
    printf '  密码    : %s\n' "$(hv_creds_get DASHBOARD_PASSWORD "(未生成)")"
    printf '  凭据文件: %s (0600)\n' "$(hv_creds_file)"
    hv_rule
}

# ---------------------------------------------------------------------------
# OpenAI 兼容 API server
# ---------------------------------------------------------------------------
# 参数: hv_apiserver_configure [on|off]
hv_apiserver_configure() {
    local want="${1:-on}"
    hv_hermes_installed || hv_die "Hermes 未安装"

    if [[ "$want" == "off" ]]; then
        hv_env_set API_SERVER_ENABLED "false"
        hv_ok "API server 已关闭"
        hv_state_set API_SERVER "off"
        return 0
    fi

    local key; key="$(hv_creds_get API_SERVER_KEY "")"
    [[ -n "$key" ]] || key="$(hv_random_hex 32)"
    hv_creds_save API_SERVER_KEY "$key"

    hv_env_set API_SERVER_ENABLED "true"
    hv_env_set API_SERVER_HOST "127.0.0.1"
    hv_env_set API_SERVER_PORT "$HV_API_PORT"
    hv_env_set API_SERVER_KEY "$key"

    # 只允许 Caddy 反代来的域名访问;CORS 按需放开(默认同源)
    hv_env_set API_SERVER_CORS_ORIGINS "http://127.0.0.1:${HV_DASH_PORT},http://localhost:${HV_DASH_PORT}"

    hv_state_set API_SERVER "on"
    hv_ok "API server 已启用:127.0.0.1:${HV_API_PORT}(密钥见 $(hv_creds_file))"
}

hv_apiserver_show_access() {
    local domain; domain="$(hv_state_get DOMAIN "")"
    hv_rule
    printf '  API Base URL: %s\n' "$([[ -n $domain ]] && echo "https://${domain}/v1" || echo "http://127.0.0.1:${HV_API_PORT}/v1")"
    printf '  API Key     : %s\n' "$(hv_creds_get API_SERVER_KEY "(未生成)")"
    hv_rule
    hv_dim "  在 OpenWebUI / LobeChat / Cherry Studio 里填上面的 Base URL + Key 即可"
}

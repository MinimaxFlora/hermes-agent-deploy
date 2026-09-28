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

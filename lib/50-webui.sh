# =============================================================================

# =============================================================================
#  面板 / API · systemd 服务 · Caddy 反向代理(域名 + 自动 HTTPS)
# =============================================================================

json_field() { # json_field <json> <key>
    local s="$1" k="$2"
    if have jq; then printf '%s' "$s" | jq -r ".${k} // empty" 2>/dev/null | sed -n '1p'
    else printf '%s' "$s" | grep -oE "\"${k}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed -n '1p' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'; fi
}

# ---------------------------------------------------------------------------
# 面板与 API 配置
# ---------------------------------------------------------------------------
dashboard_ensure_auth() { # 认证门:用户名/密码/会话密钥
    local u p s file="$(env_file)"
    u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    s="$(env_get HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
    [[ -z "$u" ]] && { u="admin"; env_set HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$u"; }
    [[ -z "$p" ]] && { p="$(random_str 20)"; env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$p"; ok "已生成面板密码(随机 20 位)"; }
    [[ -z "$s" ]] && { env_set HERMES_DASHBOARD_BASIC_AUTH_SECRET "$(random_hex 32)"; }
    st_set DASH_USER "$u"
    return 0
}

dashboard_webui() { # 公网地址 + 面板绑定
    local domain="${1:-$(st_get DOMAIN)}"
    hcfg dashboard.enabled true >/dev/null 2>&1 || true
    hcfg dashboard.host "127.0.0.1" >/dev/null 2>&1 || true
    hcfg dashboard.port "$DASH_PORT" >/dev/null 2>&1 || true
    if [[ -n "$domain" ]]; then
        hcfg dashboard.public_url "https://${domain}" || return 1
    fi
}

api_server_enable() { # 让 OpenAI 兼容 /v1 在本地端口可用
    local key; key="$(env_get API_SERVER_KEY)"
    [[ -z "$key" ]] && { key="sk-hermes-$(random_str 24)"; env_set API_SERVER_KEY "$key"; }
    env_set API_SERVER_PORT "$API_PORT"
    hcfg "platforms.api_server.enabled" "true" >/dev/null 2>&1 || true
    hcfg "platforms.api_server.port" "$API_PORT" >/dev/null 2>&1 || true
    hcfg "platforms.api_server.host" "127.0.0.1" >/dev/null 2>&1 || true
    st_set API_ENABLED "1"; st_set API_SERVER "on"
    ok "API Server 已开启(127.0.0.1:${API_PORT})"
}
api_server_disable() {
    hcfg "platforms.api_server.enabled" "false" >/dev/null 2>&1 || true
    st_set API_ENABLED "0"; st_set API_SERVER "off"
    ok "API Server 已关闭"
    restart_service hermes-gateway || true
}

credentials_write() {
    local domain="${1:-$(st_get DOMAIN)}" u p s ak
    u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    s="$(env_get HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
    ak="$(env_get API_SERVER_KEY)"
    umask 077
    {
        printf '# hermes-vps 访问凭据(自动生成,请妥善保管)\n'
        printf '# 生成时间:%s\n\n' "$(date -Is)"
        [[ -n "$domain" ]] && printf '面板地址   : https://%s/\n' "$domain" || printf '面板地址   : http://127.0.0.1:%s/(尚未配置域名)\n' "$DASH_PORT"
        printf '面板用户名 : %s\n' "$u"
        printf '面板密码   : %s\n' "$p"
        [[ -n "$domain" ]] && printf 'API 地址   : https://%s/v1\n' "$domain" || printf 'API 地址   : http://127.0.0.1:%s/v1\n' "$API_PORT"
        printf 'API Key    : %s\n' "$ak"
        printf '会话密钥   : %s\n' "$s"
    } >"$CRED_FILE"
    chmod 600 "$CRED_FILE"
}

dashboard_show_info() {
    local domain; domain="$(st_get DOMAIN)"
    header "面板与 API 访问信息"
    local u; u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    rule
    printf '    面板(本机) : http://127.0.0.1:%s/\n' "$DASH_PORT"
    [[ -n "$domain" ]] && printf '    面板(域名) : %shttps://%s/%s\n' "$BD" "$domain" "$N"
    printf '    管理账号   : %s%s%s\n' "$BD" "$u" "$N"
    printf '    密码/APIkey: 见 %s%s%s(600 权限)\n' "$BD" "$CRED_FILE" "$N"
    if [[ "$(st_api_enabled)" == "1" ]]; then
        [[ -n "$domain" ]] && printf '    API        : https://%s/v1  (OpenAI 兼容)\n' "$domain"
        printf '    API        : http://127.0.0.1:%s/v1\n' "$API_PORT"
    else
        printf '    API        : %s未开启%s\n' "$DM" "$N"
    fi
    rule
    printf '    查看密码   : %scat %s%s\n' "$C" "$CRED_FILE" "$N"
    printf '    重置密码   : 菜单 → 面板与 API → 2\n'
    rule
}

dashboard_verify_gate() { # 认证门是否生效
    local code; code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)"
    case "$code" in
        302|303|401|403) printf 'ok' ;;
        200) printf 'open' ;;
        000) printf 'down' ;;
        *) printf 'other:%s' "$code" ;;
    esac
}
dashboard_wait_ready() { # 等待面板监听
    local i=0
    while [[ $i -lt 60 ]]; do
        port_listening "$DASH_PORT" && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}
dashboard_login_test() { # 真实登录一次:成功发 Cookie
    local u p jar code
    u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"; p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    [[ -z "$u" || -z "$p" ]] && { warn "未设置面板账号密码"; return 1; }
    jar="$(mktemp)"
    code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -c "$jar" -X POST \
        -H 'Content-Type: application/json' -d "{\"username\":\"$u\",\"password\":\"$p\"}" \
        "http://127.0.0.1:${DASH_PORT}/api/login" 2>/dev/null || echo 000)"
    local cookies=0; [[ -s "$jar" ]] && cookies="$(grep -c . "$jar" || echo 0)"
    if [[ "$code" == "200" ]]; then
        ok "登录成功(HTTP 200,Cookie ${cookies} 条)"
        local c; c="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -b "$jar" "http://127.0.0.1:${DASH_PORT}/api/config" 2>/dev/null || echo 000)"
        [[ "$c" == "200" ]] && ok "已登录会话可读配置(/api/config → 200)" || warn "会话读取返回 $c"
    else
        err "登录失败(HTTP $code)"
    fi
    rm -f "$jar"
}

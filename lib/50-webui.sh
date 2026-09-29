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
    if [[ -n "$(st_get DOMAIN)" ]]; then
        ok "API Server 已开启:https://$(st_get DOMAIN)/v1"
    else
        ok "API Server 已开启,但未配置域名 → 不对外开放(菜单 4 可配域名)"
    fi
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
        # 只给域名访问地址:服务器上的 127.0.0.1 对使用者没有意义(VPS 上根本访问不到),
        # 所以未配置域名时明确说明"未对外开放",而不是给出一个用不了的地址
        if [[ -n "$domain" ]]; then
            printf '面板地址   : https://%s/\n' "$domain"
        else
            printf '面板地址   : 未配置域名(面板未对外开放;请用菜单 4 配置域名)\n'
        fi
        printf '面板用户名 : %s\n' "$u"
        printf '面板密码   : %s\n' "$p"
        if [[ -n "$domain" ]]; then
            printf 'API 地址   : https://%s/v1\n' "$domain"
        else
            printf 'API 地址   : 未配置域名(API 未对外开放)\n'
        fi
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
    if [[ -n "$(st_get DOMAIN)" ]]; then
        printf '    面板(公网) : %shttps://%s/%s\n' "$G" "$(st_get DOMAIN)" "$N"
    else
        printf '    面板       : %s未对外开放(请用菜单 4 配置域名)%s\n' "$Y" "$N"
    fi
    [[ -n "$domain" ]] && printf '    面板(域名) : %shttps://%s/%s\n' "$BD" "$domain" "$N"
    printf '    管理账号   : %s%s%s\n' "$BD" "$u" "$N"
    printf '    密码/APIkey: 见 %s%s%s(600 权限)\n' "$BD" "$CRED_FILE" "$N"
    if [[ "$(st_api_enabled)" == "1" ]]; then
        if [[ -n "$domain" ]]; then
            printf '    API        : https://%s/v1  (OpenAI 兼容)\n' "$domain"
        else
            printf '    API        : 未对外开放(未配置域名)\n'
        fi
    else
        printf '    API        : %s未开启%s\n' "$DM" "$N"
    fi
    rule
    printf '    查看密码   : %scat %s%s\n' "$C" "$CRED_FILE" "$N"
    printf '    重置密码   : 菜单 → 面板与 API → 2\n'
    rule
}

dashboard_verify_gate() { # 认证门是否生效
    # 用 /api/config 判断:无凭据时应为 401/403。
    # 注意:不能只看 `/` —— 它的 200 可能只是登录页被内联返回(真机踩过:
    # 用户态实例 `/` 返 200 但 /api/config 是 401,误判成"门没生效")。
    local code c2
    code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DASH_PORT}/api/config" 2>/dev/null || echo 000)"
    case "$code" in
        401|403) printf 'ok'; return 0 ;;
        200)     printf 'open'; return 0 ;;
        000)     printf 'down'; return 0 ;;
    esac
    c2="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)"
    case "$c2" in
        302|303|401|403) printf 'ok' ;;
        200) printf 'open' ;;
        000) printf 'down' ;;
        *) printf 'other:%s' "$c2" ;;
    esac
}
# 面板的 Host 白名单是"启动时"从 dashboard.public_url 读定的:写完 public_url 必须重启面板,
# 否则域名访问会被中间件拒成 400 Invalid Host header(真机踩过:配好域名却一直 400)。
# 判定必须用 /login 这类真实页面:**`/` 会先被认证门 302 短路,根本走不到 Host 校验,看不出问题**。
dashboard_host_probe() { # 面板对指定域名的响应码(400 = Host 白名单里没有它)
    local dom="${1:-$(st_get DOMAIN)}" p="${2:-/login?next=%2F}"
    [[ -n "$dom" ]] || { printf '000'; return 0; }
    curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Host: $dom" "http://127.0.0.1:${DASH_PORT}${p}" 2>/dev/null || printf '000'
}
dashboard_ensure_host_ok() { # 域名 Host 被拒 → 重启面板并复验
    local dom; dom="$(st_get DOMAIN)"
    [[ -n "$dom" ]] || return 0
    local code; code="$(dashboard_host_probe "$dom")"
    [[ "$code" != "400" ]] && return 0
    warn "面板拒绝域名 Host($dom,HTTP 400):重启面板使 dashboard.public_url 生效…"
    svc_ctl restart hermes-dashboard >/dev/null 2>&1 || true
    dashboard_wait_ready || true
    code="$(dashboard_host_probe "$dom")"
    if [[ "$code" == "400" ]]; then
        warn "仍被拒绝:请确认 dashboard.public_url($(hcfg_get dashboard.public_url))与实际访问域名一致"
    else
        ok "面板已接受域名 Host(HTTP $code)"
    fi
    return 0
}

dashboard_wait_ready() { # 等待面板监听
    local i=0
    # 后台进程模式(用户态、无 systemd --user):端口有响应不代表是我们的实例
    # (本机可能还有另一个实例占着同一个端口)→ 先确认自己的进程活着
    if [[ "$HV_MODE" != "system" ]] && ! user_systemd_ok; then
        local pf; pf="$(pidfile_for hermes-dashboard)"
        if [[ ! -f "$pf" ]] || ! kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
            return 1
        fi
    fi
    while [[ $i -lt 60 ]]; do
        port_listening "$DASH_PORT" && return 0
        sleep 1; i=$((i + 1))
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

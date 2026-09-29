# ---------------------------------------------------------------------------
# Caddy 安装 / 配置 / 证书
# ---------------------------------------------------------------------------
caddy_installed() { have caddy || [[ -x "$CADDY_BIN" ]]; }
caddy_version() { if have caddy; then caddy version 2>/dev/null | sed -n '1p'; elif [[ -x "$CADDY_BIN" ]]; then "$CADDY_BIN" version 2>/dev/null | sed -n '1p'; fi; }
caddy_bin() { if have caddy; then command -v caddy; else printf '%s' "$CADDY_BIN"; fi; }

caddy_ensure_user() {
    getent group caddy >/dev/null 2>&1 || groupadd --system caddy 2>/dev/null || true
    id caddy >/dev/null 2>&1 || useradd --system --gid caddy --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy 2>/dev/null || true
    install -d -o caddy -g caddy -m 750 /var/lib/caddy 2>/dev/null || true
}

caddy_prepare_runtime() {
    if [[ "$HV_MODE" != "system" ]]; then
        mkdir -p "$CADDY_LOG_DIR" "$(dirname "$CADDYFILE")" 2>/dev/null || true
        [[ -f "$CADDY_LOG_DIR/hermes-access.log" ]] || : >"$CADDY_LOG_DIR/hermes-access.log" 2>/dev/null || true
        return 0
    fi
    require_root "准备 Caddy 运行目录"
    install -d -m 755 "$CADDY_LOG_DIR" 2>/dev/null || mkdir -p "$CADDY_LOG_DIR"
    [[ -f "$CADDY_LOG_DIR/hermes-access.log" ]] || : >"$CADDY_LOG_DIR/hermes-access.log"
    chown -R caddy:caddy "$CADDY_LOG_DIR" 2>/dev/null || true
    chmod 750 "$CADDY_LOG_DIR" 2>/dev/null || true
    chmod 640 "$CADDY_LOG_DIR/hermes-access.log" 2>/dev/null || true
    install -d -m 755 /etc/caddy 2>/dev/null || true
    caddy_ensure_user
    return 0
}

caddy_install_user() { # 用户态:只装二进制,不建系统用户/单元
    if caddy_installed; then ok "Caddy 已可用:$(caddy_version)"; return 0; fi
    step "安装 Caddy(用户态:装到 $CADDY_BIN)"
    local arch="amd64"; [[ "$ARCH" == "aarch64" ]] && arch="arm64"
    mkdir -p "$(dirname "$CADDY_BIN")" "$CADDY_LOG_DIR"
    local tmp; tmp="$(mktemp)"
    curl -fL --max-time 180 -o "$tmp" "https://caddyserver.com/api/download?os=linux&arch=${arch}" \
        || die "下载 Caddy 失败(用户态无法用 apt,只能下载官方二进制)"
    install -m 755 "$tmp" "$CADDY_BIN"; rm -f "$tmp"
    ok "Caddy 已安装:$CADDY_BIN($("$CADDY_BIN" version 2>/dev/null | sed -n '1p'))"
    dim "用户态 Caddy 只能监听高位端口;域名 + 80/443 需要系统级(菜单 4 会提示提权)"
    return 0
}

caddy_install() {
    if [[ "$HV_MODE" != "system" ]]; then caddy_install_user; return $?; fi
    require_root "安装 Caddy"
    if caddy_installed; then ok "Caddy 已安装:$(caddy_version)"; caddy_prepare_runtime; return 0; fi
    step "安装 Caddy"
    local from_apt=0
    if [[ "$PKG" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        pkg_install debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null 2>&1 || true
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            curl -fsSL --max-time 40 "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" 2>/dev/null \
              | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || warn "Caddy 官方源 GPG 下载失败"
        fi
        if [[ -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            printf 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' >/etc/apt/sources.list.d/caddy-stable.list
            printf 'deb-src [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' >>/etc/apt/sources.list.d/caddy-stable.list
            apt-get update -qq >/dev/null 2>&1 || true
            if apt-get install -y -qq caddy >/dev/null 2>&1; then from_apt=1; ok "已通过官方 apt 源安装 Caddy"; fi
        fi
        [[ $from_apt -eq 0 ]] && { info "apt 源不可用,尝试发行版自带包"; apt-get install -y -qq caddy >/dev/null 2>&1 && from_apt=1 || true; }
    fi
    if [[ $from_apt -eq 0 ]]; then
        info "改用官方二进制安装"
        local arch="amd64"; [[ "$ARCH" == "aarch64" ]] && arch="arm64"
        local url="https://caddyserver.com/api/download?os=linux&arch=${arch}"
        local tmp; tmp="$(mktemp)"
        curl -fL --max-time 180 -o "$tmp" "$url" || die "下载 Caddy 失败:$url"
        install -m 755 "$tmp" "$CADDY_BIN"; rm -f "$tmp"
        caddy_ensure_user
        cat >/etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy web server (managed by hermes-vps)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=$CADDY_BIN run --environ --config $CADDYFILE --adapter caddyfile
ExecReload=$CADDY_BIN reload --config $CADDYFILE --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 /etc/systemd/system/caddy.service
        systemctl daemon-reload
        systemctl enable caddy >/dev/null 2>&1 || true
        ok "已用官方二进制安装 Caddy($(caddy_version))"
    fi
    caddy_prepare_runtime
}

caddy_render() { # 生成 Caddyfile 到 stdout
    local domain="$1" email="$2" api_on="$3"
    # 端口可由调用方覆盖:用户态实例的面板/API 端口不一定是 9119/8642(真机踩过 9120),
    # root 侧助手必须按"本实例真实端口"渲染,否则证书配好了但反代打到别人家门上
    local DASH_PORT="${HV_RENDER_DASH_PORT:-$DASH_PORT}"
    local API_PORT="${HV_RENDER_API_PORT:-$API_PORT}"
    if [[ -n "$email" ]]; then
        printf '{\n\tadmin 127.0.0.1:2019\n\temail %s\n}\n\n' "$email"
    else
        printf '{\n\tadmin 127.0.0.1:2019\n}\n\n'
    fi
    cat <<EOF
# 由 hermes-vps 生成 · $(date '+%F %T') · 域名:$domain
$domain {
	encode zstd gzip

	# 探活(仅 Caddy 自己响应,不触碰面板)
	handle /healthz {
		respond "ok" 200
	}
EOF
    if [[ "$api_on" == "1" ]]; then
        cat <<EOF

	# OpenAI 兼容 API
	handle /v1/* {
		reverse_proxy 127.0.0.1:$API_PORT
	}
EOF
    fi
    cat <<EOF

	# 管理面板(含登录与静态资源)
	handle {
		reverse_proxy 127.0.0.1:$DASH_PORT
	}

	log {
		output file $CADDY_LOG_DIR/hermes-access.log {
			roll_size 20MiB
			roll_keep 5
		}
		format json
	}
}
EOF
}

caddy_validate() { # 校验给定内容
    local content="$1" bin tmp
    bin="$(caddy_bin)"
    tmp="$(mktemp /tmp/Caddyfile.XXXXXX)"
    # caddy validate 不只是语法检查:它会 provision 日志写入器,真的去打开日志文件。
    # 当日志目录此刻不可写(非 root 的诊断、CI 上跑 selftest)时,把校验用的日志目标
    # 换成临时目录 —— 语法/路由/指令照样全量校验,只是不再因权限而误判配置无效。
    local log_dir="$CADDY_LOG_DIR"
    if [[ ! -w "$log_dir" ]]; then
        if mkdir -p "$log_dir" 2>/dev/null && [[ -w "$log_dir" ]]; then
            :   # 目录可建(比如 root),用真实路径校验
        else
            log_dir="$(mktemp -d /tmp/hv-caddylog.XXXXXX)"
            content="$(printf '%s\n' "$content" | sed "s|$CADDY_LOG_DIR/|$log_dir/|g")"
            dim "日志目录 $CADDY_LOG_DIR 当前不可写 → 校验改用临时日志目标:$log_dir"
        fi
    fi
    printf '%s\n' "$content" >"$tmp"
    local rc=0
    set +e
    "$bin" validate --adapter caddyfile --config "$tmp" >/tmp/.hv-caddy-validate.out 2>&1
    rc=$?
    set -e
    rm -f "$tmp"
    if [[ "$log_dir" == /tmp/hv-caddylog.* ]]; then rm -rf "$log_dir"; fi
    if [[ $rc -ne 0 ]]; then
        err "Caddyfile 校验失败:"
        sed 's/^/      /' /tmp/.hv-caddy-validate.out | head -n 12 >&2
        return 1
    fi
    return 0
}

caddy_write_config() { # 写入并 reload(校验不通过绝不 reload)
    local domain="$1" email="$2" api_on="$3"
    if [[ "$HV_MODE" == "system" ]]; then require_root "写入 Caddy 配置"; fi
    caddy_prepare_runtime
    local content; content="$(caddy_render "$domain" "$email" "$api_on")"
    caddy_validate "$content" || return 1
    if [[ -f "$CADDYFILE" ]] && [[ "$(cat "$CADDYFILE")" == "$content" ]]; then
        ok "Caddyfile 无变化,跳过"
    else
        [[ -f "$CADDYFILE" ]] && backup_file "$CADDYFILE"
        printf '%s\n' "$content" >"$CADDYFILE"
        chmod 644 "$CADDYFILE"
        ok "已写入 $CADDYFILE"
    fi
    st_set DOMAIN "$domain"; st_set ACME_EMAIL "$email"; st_set API_ENABLED "$api_on"
    caddy_reload
}

caddy_reload() {
    systemctl daemon-reload 2>/dev/null || true
    if systemctl is-active caddy >/dev/null 2>&1; then
        if systemctl reload caddy >/dev/null 2>&1; then ok "Caddy 已热重载"
        else
            warn "reload 失败,尝试重启"
            systemctl restart caddy >/dev/null 2>&1 && ok "Caddy 已重启" || { err "Caddy 启动失败"; caddy_diagnose; return 1; }
        fi
    else
        systemctl enable caddy >/dev/null 2>&1 || true
        if systemctl restart caddy >/dev/null 2>&1; then ok "Caddy 已启动"
        else err "Caddy 启动失败"; caddy_diagnose; return 1; fi
    fi
    return 0
}

caddy_diagnose() {
    have journalctl || return 0
    err "最近日志:"
    journalctl -u caddy -n 15 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
}

caddy_status() {
    local st; st="$(svc_state caddy)"
    printf '%s' "$st"
}
cert_days_left() { # 域名证书剩余天数(经 Caddy 数据目录)
    local domain="$1"
    local dir="/var/lib/caddy/.local/share/caddy/certificates"
    have openssl || return 1
    local f
    f="$(find "$dir" -name "${domain}.crt" 2>/dev/null | sort | tail -n1)" || f=""
    [[ -z "$f" ]] && return 1
    local end; end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
    [[ -z "$end" ]] && return 1
    local end_s now_s
    end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
    now_s="$(date +%s)"
    printf '%s' $(( (end_s - now_s) / 86400 ))
}
cert_expire_date() {
    local domain="$1"
    local dir="/var/lib/caddy/.local/share/caddy/certificates"
    have openssl || return 1
    local f; f="$(find "$dir" -name "${domain}.crt" 2>/dev/null | sort | tail -n1)" || f=""
    [[ -z "$f" ]] && return 1
    openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2 | xargs -I{} date -d '{}' '+%Y-%m-%d' 2>/dev/null
}

# 用户态部署的 root 侧助手:只装/写/校验/重载 Caddy,不碰任何状态文件
# (由普通用户的域名流程通过 sudo 调用;端口由用户侧按本实例传入)
# 解析 domain-root 的参数(独立函数以便单测:真机踩过"多 shift 一次"导致域名位置拿到 --port)
domain_root_parse() { # domain_root_parse <域名> [--port N] [--api-port N] [--email X] [--api 0|1]
    DR_DOMAIN="${1:-}"; shift || true
    DR_PORT="$DASH_PORT"; DR_APIPORT="$API_PORT"; DR_EMAIL=""; DR_API="${API_ENABLED:-0}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)     DR_PORT="${2:-}";    shift 2 || true ;;
            --api-port) DR_APIPORT="${2:-}"; shift 2 || true ;;
            --email)    DR_EMAIL="${2:-}";   shift 2 || true ;;
            --api)      DR_API="${2:-0}";    shift 2 || true ;;
            *)          shift || true ;;
        esac
    done
    return 0
}

domain_root_configure() {
    # 非 root 直接调用是常见误用(它本来就是给 sudo 用的):只提示,不触发 ERR 陷阱打断脚本
    is_root || { err "domain-root 必须由 root 执行(它是用户态部署的 root 侧助手,由 sudo 调用)"; return 0; }
    local DR_DOMAIN DR_PORT DR_APIPORT DR_EMAIL DR_API
    domain_root_parse "$@"
    local domain="$DR_DOMAIN" port="$DR_PORT" apiport="$DR_APIPORT" email="$DR_EMAIL" api_on="$DR_API"
    [[ -n "$domain" ]] || { err "缺少域名"; return 0; }
    # 以 "-" 开头说明调用方参数错位(真机:CLI 多 shift 一次,域名位置成了 --port)
    [[ "$domain" == -* ]] && { err "域名参数错位(拿到的是选项:$domain),请检查调用方式"; return 0; }
    [[ "$port" =~ ^[0-9]+$ && "$apiport" =~ ^[0-9]+$ ]] || { err "端口参数非法:$port / $apiport"; return 1; }
    header "域名与反向代理(root 侧 → 127.0.0.1:$port)"
    caddy_install || return 1
    local content
    content="$(HV_RENDER_DASH_PORT="$port" HV_RENDER_API_PORT="$apiport" caddy_render "$domain" "$email" "$api_on")"
    caddy_validate "$content" || return 1
    if [[ -f "$CADDYFILE" ]] && [[ "$(cat "$CADDYFILE")" == "$content" ]]; then
        ok "Caddyfile 无变化"
    else
        [[ -f "$CADDYFILE" ]] && backup_file "$CADDYFILE"
        printf '%s\n' "$content" >"$CADDYFILE" && chmod 644 "$CADDYFILE" && ok "已写入 $CADDYFILE"
    fi
    caddy_reload
    port_listening 80 || warn "80 端口未监听(证书签发需要 80 可达,确认防火墙/安全组已放行)"
    return 0
}

# 普通用户(用户态)下的域名流程:用户侧设 public_url 并重启面板(Host 校验是启动时快照),
# 80/443 与证书由 root 侧助手完成 —— 绝不用"以 root 重跑整条命令"(那会跑成系统级、指错端口)
domain_configure_usermode() {
    hermes_installed || { warn "请先部署(菜单 1)"; pause; return 0; }
    clear_screen
    header "域名与反向代理(用户态 + root 侧 Caddy)"
    local cur; cur="$(st_get DOMAIN)"
    printf '    当前域名:%s%s%s\n' "$BD" "${cur:-未配置}" "$N"
    dim "本实例面板端口:$DASH_PORT · API 端口:$API_PORT · root 侧配置:/etc/caddy/Caddyfile"
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then ask domain "域名(例:panel.example.com,回车跳过)" "$cur"; fi
    if [[ -z "$domain" ]]; then info "未提供域名,跳过"; pause; return 0; fi
    local email="${HV_ACME_EMAIL:-}"; [[ -n "$email" ]] || ask email "证书通知邮箱(可留空)" "$(st_get ACME_EMAIL)"

    printf '\n'
    dim "检查 DNS 解析…"
    local rc=0; set +e; domain_points_here "$domain"; rc=$?; set -e
    case "$rc" in
        0) ok "解析正确,域名指向本机" ;;
        1) warn "解析到别处或未解析:Let's Encrypt 无法签发(请把 A 记录指向本机公网 IP)" ;;
        2) dim "无法确认解析(缺 getent/dig),继续尝试" ;;
    esac

    local api_on=0
    if [[ "$(hcfg_get "platforms.api_server.enabled" 2>/dev/null)" == *true* ]]; then api_on=1; fi

    # --- root 侧:装 Caddy、写配置(指向本实例端口)、热重载 ---
    local rrc=0
    info "配置 root 侧 Caddy(80/443 + 自动 HTTPS)…"
    if is_root; then
        domain_root_configure "$domain" --port "$DASH_PORT" --api-port "$API_PORT" --email "$email" --api "$api_on" || rrc=$?
    elif have_sudo; then
        # 注意:必须直接执行脚本(靠 shebang),不能写 `sudo bash $SELF` ——
        # sudoers 按"命令路径"匹配,写成 bash 时匹配的是 /usr/bin/bash,白名单规则会失效
        if [[ -x "$SELF" ]]; then
            sudo -n "$SELF" domain-root "$domain" --port "$DASH_PORT" --api-port "$API_PORT" --email "$email" --api "$api_on" || rrc=$?
        else
            sudo -n bash "$SELF" domain-root "$domain" --port "$DASH_PORT" --api-port "$API_PORT" --email "$email" --api "$api_on" || rrc=$?
        fi
        if [[ $rrc -ne 0 ]]; then
            warn "免密 sudo 不可用(需要输入密码或缺少白名单)"
            dim "请手动执行:sudo $SELF domain-root $domain --port $DASH_PORT --api-port $API_PORT"
            dim "或加白名单:/etc/sudoers.d/hermes-vps-domain 内容:$USER ALL=(root) NOPASSWD: $SELF domain-root *"
        fi
    else
        warn "系统里没有 sudo,无法配置 80/443 与证书"
        dim "请让管理员执行:bash $SELF domain-root $domain --port $DASH_PORT"
        rrc=1
    fi

    # --- 用户侧:公网地址 + 重启面板(官方面板在启动时读 public_url 决定接受哪些 Host)---
    dashboard_webui "$domain"
    info "重启面板以应用域名(Host 校验在启动时读取 public_url)…"
    svc_ctl restart hermes-dashboard >/dev/null 2>&1 || true
    dashboard_wait_ready >/dev/null 2>&1 || true
    dashboard_ensure_host_ok >/dev/null 2>&1 || true

    st_set DOMAIN "$domain"; st_set ACME_EMAIL "$email"; st_set API_ENABLED "$api_on"
    if [[ $rrc -ne 0 ]]; then
        warn "root 侧未完成:按上面的提示处理后,用相同域名重跑本命令"
        dim "用户侧已生效:public_url=https://${domain} 且面板已重启"
        pause; return 0
    fi
    ok "HTTPS 已配置:https://${domain}/"
    dim "首次签发约需 10~30 秒"
    sleep 3
    local code; code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && ok "探活成功:https://${domain}/healthz → 200" || warn "探活返回 $code(证书可能还在签发,稍后重试)"
    local lcode; lcode="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/login?next=%2F" 2>/dev/null || echo 000)"
    [[ "$lcode" == "200" ]] && ok "登录页可达:https://${domain}/login → 200(Host 校验通过)" || warn "登录页返回 $lcode"
    credentials_write "$domain" 2>/dev/null || true
    pause
    return 0
}

domain_configure() {
    if [[ "$HV_MODE" != "system" ]]; then domain_configure_usermode "$@"; return $?; fi
    hermes_installed || { warn "请先部署(菜单 1)"; pause; return 1; }
    clear_screen
    header "域名与反向代理(Caddy)"
    local cur; cur="$(st_get DOMAIN)"
    printf '    当前域名:%s%s%s\n' "$BD" "${cur:-未配置}" "$N"
    local domain="${1:-}"
    if [[ -z "$domain" ]]; then ask domain "域名(例:panel.example.com,回车跳过)" "$cur"; fi
    if [[ -z "$domain" ]]; then info "未提供域名,跳过"; pause; return 0; fi
    local email; ask email "证书通知邮箱(可留空)" "$(st_get ACME_EMAIL)"

    printf '\n'
    dim "检查 DNS 解析…"
    local rc=0; set +e; domain_points_here "$domain"; rc=$?; set -e
    case "$rc" in
        0) ok "解析正确,域名指向本机" ;;
        1) warn "解析到别处或未解析:Let's Encrypt 将无法签发(请把 A 记录指向本机公网 IP)" ;;
        2) dim "无法确认解析(缺 getent/dig),继续尝试" ;;
    esac
    port_listening 80 || warn "80 端口未监听(证书签发需要 80 可达;请确认防火墙/安全组已放行)"
    confirm "用该域名写入 Caddy 配置并申请证书?" yes || { info "已取消"; pause; return 0; }

    if [[ "$(hcfg_get "platforms.api_server.enabled")" == *true* ]] && confirm "是否同时对外提供 OpenAI 兼容 API(/v1)?" yes; then
        st_set API_ENABLED 1; st_set API_SERVER on
    else
        st_set API_ENABLED 0; st_set API_SERVER off
    fi
    dashboard_webui "$domain"
    caddy_install || { pause; return 1; }
    caddy_write_config "$domain" "$email" "$(st_api_enabled)" || { pause; return 1; }
    # 官方面板在启动时读取 dashboard.public_url 决定接受哪些 Host:写完必须重启,否则用域名
    # 访问会被中间件拒成 400 Invalid Host header(真机踩过,用户就是栽在这里)
    info "重启面板以应用域名(Host 校验在启动时读取 public_url)…"
    svc_ctl restart hermes-dashboard >/dev/null 2>&1 || true
    if dashboard_wait_ready; then ok "面板已按新域名重启"; else warn "面板未在 60 秒内就绪,稍后用菜单 6 重启"; fi
    dashboard_ensure_host_ok     # 探测用 /login(用 / 会被认证门 302 短路,测不出 Host 是否生效)
    ok "HTTPS 已配置:https://${domain}/"
    dim "首次签发约需 10~30 秒;若失败请看:journalctl -u caddy -n 30"
    sleep 3
    local code; code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && ok "域名探活成功:https://${domain}/healthz → 200" || warn "域名探活返回 $code(证书可能还在签发,稍后重试)"
    credentials_write "$domain"
    pause
}

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
    printf '%s\n' "$content" >"$tmp"
    local rc=0
    set +e
    "$bin" validate --adapter caddyfile --config "$tmp" >/tmp/.hv-caddy-validate.out 2>&1
    rc=$?
    set -e
    rm -f "$tmp"
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

domain_configure() {
    if [[ "$HV_MODE" != "system" ]]; then escalate_or_skip "域名与反向代理(80/443 + 自动 HTTPS)" || true; return 0; fi
    hermes_installed || { warn "请先部署(菜单 1)"; pause; return 1; }
    clear_screen
    header "域名与反向代理(Caddy)"
    local cur; cur="$(st_get DOMAIN)"
    printf '    当前域名:%s%s%s\n' "$BD" "${cur:-未配置}" "$N"
    local domain; ask domain "域名(例:panel.example.com,回车跳过)" "$cur"
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
    ok "HTTPS 已配置:https://${domain}/"
    dim "首次签发约需 10~30 秒;若失败请看:journalctl -u caddy -n 30"
    sleep 3
    local code; code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && ok "域名探活成功:https://${domain}/healthz → 200" || warn "域名探活返回 $code(证书可能还在签发,稍后重试)"
    credentials_write "$domain"
    pause
}

#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/caddy.sh
# Caddy 反向代理:安装、Caddyfile 生成与校验、证书、服务管理。
# 设计要点:
#   * Hermes 面板/API 都绑回环,Caddy 终止 TLS 后从回环反代 —— 官方推荐姿势,
#     回环代理自动被 dashboard.trusted_proxies 信任,不需要放宽信任网段;
#   * 生成的 Caddyfile 带标记注释,只覆盖自己生成的版本,别人的配置先备份再问;
#   * 改动前后都跑 `caddy validate`,校验失败绝不 reload(避免打挂现网)。
# =============================================================================

[[ -n "${HV_CADDY_LOADED:-}" ]] && return 0
HV_CADDY_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

HV_CADDY_BIN="${HV_CADDY_BIN:-/usr/local/bin/caddy}"
HV_CADDY_ETC="${HV_CADDY_ETC:-/etc/caddy}"
HV_CADDYFILE="${HV_CADDY_ETC}/Caddyfile"
HV_CADDY_LOG_DIR="${HV_CADDY_LOG_DIR:-/var/log/caddy}"
HV_CADDY_MARKER="# managed-by: hermes-vps"

hv_caddy_cmd() { if hv_have caddy; then printf 'caddy'; else printf '%s' "$HV_CADDY_BIN"; fi; }
hv_caddy_installed() { hv_have caddy || [[ -x "$HV_CADDY_BIN" ]]; }

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
hv_caddy_install() {
    hv_require_root
    if hv_caddy_installed; then
        hv_ok "Caddy 已安装($("$(hv_caddy_cmd)" version 2>/dev/null | head -n1 || echo 版本未知))"
        return 0
    fi

    hv_step "安装 Caddy"

    # 方案 1:官方 apt 源(可随系统更新)
    if [[ "$HV_PKG" == "apt" ]] && hv_confirm "使用 Caddy 官方 apt 源安装?(推荐,可自动更新)" yes; then
        if hv_caddy_install_apt; then
            hv_state_set CADDY_SOURCE "apt"
            hv_ok "Caddy 已通过 apt 安装:$(caddy version 2>/dev/null | head -n1)"
            hv_caddy_ensure_user
            return 0
        fi
        hv_warn "apt 源安装失败,回退到官方单文件二进制"
    fi

    hv_caddy_install_binary || hv_die "Caddy 安装失败,请检查网络后重试"
    hv_state_set CADDY_SOURCE "binary"
    hv_ok "Caddy 已安装:$("$HV_CADDY_BIN" version 2>/dev/null | head -n1)"
}

hv_caddy_install_apt() {
    set +e
    apt-get install -y -qq --no-install-recommends debian-keyring debian-archive-keyring apt-transport-https gnupg curl 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        >/etc/apt/sources.list.d/caddy-stable.list 2>/dev/null
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq caddy
    local rc=$?
    set -e
    if [[ $rc -ne 0 || ! -x /usr/bin/caddy ]]; then
        rm -f /etc/apt/sources.list.d/caddy-stable.list
        return 1
    fi
    return 0
}

hv_caddy_install_binary() {
    local arch="amd64"
    case "$HV_ARCH" in aarch64) arch="arm64" ;; x86_64) arch="amd64" ;; esac

    # 官方下载接口始终给最新稳定版(可选插件用 &p= 附加)
    local url="https://caddyserver.com/api/download?os=linux&arch=${arch}"
    local tmp; tmp="$(mktemp)"
    hv_info "下载 Caddy 二进制:$url"
    if curl -fsSL --max-time 180 "$url" -o "$tmp" && [[ -s "$tmp" ]]; then
        install -m 755 "$tmp" "$HV_CADDY_BIN"
        rm -f "$tmp"
        hv_caddy_ensure_user
        hv_caddy_write_unit
        return 0
    fi
    rm -f "$tmp"

    # 回退:GitHub Releases(可走加速前缀)
    local prefix="${HV_MIRROR_GH_PREFIX:-}"
    [[ -f "$HV_MIRROR_FILE" ]] && { . "$HV_MIRROR_FILE"; prefix="${HV_MIRROR_GH_PREFIX:-}"; }
    local tar_url="${prefix}https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${arch}.tar.gz"
    hv_warn "官方下载失败,尝试 GitHub Releases:${tar_url}"
    local tgz; tgz="$(mktemp)"
    if curl -fsSL --max-time 240 "$tar_url" -o "$tgz" && [[ -s "$tgz" ]]; then
        local d; d="$(mktemp -d)"
        tar -xzf "$tgz" -C "$d" caddy
        install -m 755 "$d/caddy" "$HV_CADDY_BIN"
        rm -rf "$d" "$tgz"
        hv_caddy_ensure_user
        hv_caddy_write_unit
        return 0
    fi
    rm -f "$tgz"
    return 1
}

hv_caddy_ensure_user() {
    id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
    install -d -m 755 "$HV_CADDY_ETC"
    install -d -o caddy -g caddy -m 750 "$HV_CADDY_LOG_DIR" 2>/dev/null || install -d -m 750 "$HV_CADDY_LOG_DIR"
    install -d -o caddy -g caddy -m 700 /var/lib/caddy 2>/dev/null || true
}

# 运行期前置条件:日志目录存在且属 Caddy 运行用户、证书存储目录可写。
# 必须独立于"是否刚装 Caddy"——apt 包不会建 /var/log/caddy,
# 而 Caddy 是以 caddy 用户运行的,写不进日志目录就直接启动失败。
hv_caddy_prepare_runtime() {
    hv_require_root
    local u="caddy"
    if hv_has_systemd && systemctl cat caddy.service >/dev/null 2>&1; then
        local su; su="$(systemctl show -p User --value caddy.service 2>/dev/null | tr -d '\r')"
        [[ -n "$su" && "$su" != "root" ]] && u="$su"
    fi
    if ! id "$u" >/dev/null 2>&1; then
        hv_caddy_ensure_user
        u="caddy"
    fi
    if ! install -d -o "$u" -g "$u" -m 750 "$HV_CADDY_LOG_DIR" 2>/dev/null; then
        install -d -m 755 "$HV_CADDY_LOG_DIR"
        hv_warn "无法把 $HV_CADDY_LOG_DIR 归属给 $u,已建为 755(若仍写不进日志,Caddy 会启动失败)"
    fi
    # 目录里如果残留 root 拥有的日志文件(例如有人用 root 跑过一次 caddy),
    # Caddy 会以 "open ...: permission denied" 启动失败 —— 这里一并修属主。
    chown -R "$u:$u" "$HV_CADDY_LOG_DIR" 2>/dev/null || true
    install -d -o "$u" -g "$u" -m 700 /var/lib/caddy 2>/dev/null || true
    [[ -d /var/lib/caddy ]] && chown -R "$u:$u" /var/lib/caddy 2>/dev/null || true
    hv_state_set CADDY_RUN_USER "$u"
    return 0
}

# 二进制安装时补一个 systemd 单元(apt 包自带,不覆盖)
hv_caddy_write_unit() {
    hv_has_systemd || return 0
    [[ -f /etc/systemd/system/caddy.service || -f /lib/systemd/system/caddy.service ]] && return 0
    hv_info "写入 systemd 单元 /etc/systemd/system/caddy.service"
    cat >/etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy (managed by hermes-vps)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target
StartLimitIntervalSec=14400
StartLimitBurst=10

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${HV_CADDY_BIN} run --environ --config ${HV_CADDYFILE} --adapter caddyfile
ExecReload=${HV_CADDY_BIN} reload --config ${HV_CADDYFILE} --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-abnormal

[Install]
WantedBy=multi-user.target
EOF
    hv_systemd_reload
}

# ---------------------------------------------------------------------------
# Caddyfile 生成
# ---------------------------------------------------------------------------
hv_caddy_render() {
    local domain="$1" email="$2" with_api="$3" acme_ca="${4:-}"
    local tpl="${HV_SELF_DIR}/data/templates/Caddyfile.tpl"
    [[ -f "$tpl" ]] || hv_die "缺少模板:$tpl"

    local out; out="$(mktemp)"
    sed -e "s|@DOMAIN@|${domain}|g" \
        -e "s|@EMAIL@|${email}|g" \
        -e "s|@DASH_PORT@|${HV_DASH_PORT}|g" \
        -e "s|@API_PORT@|${HV_API_PORT}|g" \
        -e "s|@LOG_DIR@|${HV_CADDY_LOG_DIR}|g" \
        -e "s|@GENERATED_AT@|$(date -Is)|g" "$tpl" >"$out"

    local api_block
    if [[ "$with_api" == "1" ]]; then
        api_block="	# OpenAI 兼容 API(给 OpenWebUI / LobeChat / 脚本用)
	handle /v1/* {
		import hermes_common
		reverse_proxy 127.0.0.1:@API_PORT@
	}
"
        api_block="${api_block//@API_PORT@/$HV_API_PORT}"
    else
        api_block="	# (API 未启用:执行 'hermes-vps web api on' 后重新应用域名即可开启 /v1 反代)"
    fi
    # 用 awk 做多行替换,避免 sed 对多行内容的别扭处理
    awk -v repl="$api_block" '{ if ($0 ~ /@API_BLOCK@/) print repl; else print }' "$out" >"${out}.2"
    mv "${out}.2" "$out"

    if [[ -n "$acme_ca" ]]; then
        awk -v ca="$acme_ca" '{ if ($0 ~ /@ACME_CA_LINE@/) print "\tacme_ca " ca; else print }' "$out" >"${out}.3"
        mv "${out}.3" "$out"
    else
        awk '{ if ($0 ~ /@ACME_CA_LINE@/) print "\t# acme_ca https://acme-staging-v02.api.letsencrypt.org/directory  # 调试用"; else print }' "$out" >"${out}.3"
        mv "${out}.3" "$out"
    fi

    printf '%s' "$out"
}

hv_caddy_write_config() {
    local domain="$1" email="$2" with_api="$3" acme_ca="${4:-}"
    hv_require_root
    hv_caddy_prepare_runtime   # 日志/证书目录必须先就绪,否则 Caddy 起来就退出

    if [[ -f "$HV_CADDYFILE" ]] && ! grep -q "managed-by: hermes-vps" "$HV_CADDYFILE"; then
        hv_warn "现有 $HV_CADDYFILE 不是本工具生成的(通常是发行版自带示例配置)"
        if [[ "${HV_NONINTERACTIVE:-0}" == "1" || "${HV_ASSUME_YES:-0}" == "1" ]]; then
            hv_info "非交互/--yes 模式:自动备份原文件后覆盖"
        else
            hv_confirm "是否备份它并覆盖为 hermes-vps 生成的配置?" no || return 1
        fi
        hv_backup_file "$HV_CADDYFILE"
    fi

    local tmp; tmp="$(hv_caddy_render "$domain" "$email" "$with_api" "$acme_ca")"
    "$(hv_caddy_cmd)" fmt --overwrite "$tmp" >/dev/null 2>&1 || true
    sed -i "1i ${HV_CADDY_MARKER}" "$tmp"

    # 必须显式指定 --adapter caddyfile:临时文件名不带 "Caddyfile" 提示,
    # Caddy 会按 JSON 解析而报 "invalid character '#'"。
    if ! "$(hv_caddy_cmd)" validate --config "$tmp" --adapter caddyfile >/tmp/caddy-validate.out 2>&1; then
        hv_err "Caddyfile 校验失败,配置未生效:"
        sed 's/^/    /' /tmp/caddy-validate.out >&2
        rm -f "$tmp"
        return 1
    fi

    install -d -m 755 "$HV_CADDY_ETC"
    [[ -f "$HV_CADDYFILE" ]] && hv_backup_file "$HV_CADDYFILE"
    install -m 644 "$tmp" "$HV_CADDYFILE"
    rm -f "$tmp"
    hv_ok "已写入 $HV_CADDYFILE(校验通过)"

    hv_state_set DOMAIN "$domain"
    hv_state_set ACME_EMAIL "$email"
    hv_state_set ACME_CA "$acme_ca"
}

# 应用域名:写配置 + 重载
hv_caddy_apply() {
    local domain="$1" email="$2" acme_ca="${3:-}"
    local with_api=0
    [[ "$(hv_state_get API_SERVER "off")" == "on" ]] && with_api=1
    hv_caddy_write_config "$domain" "$email" "$with_api" "$acme_ca" || return 1

    # 域名确定后,把 API 的 CORS 来源收敛到"本机面板 + 该域名",浏览器类客户端才不会被拦
    if [[ "$with_api" == "1" ]]; then
        # shellcheck source=/dev/null
        source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"
        hv_env_set API_SERVER_CORS_ORIGINS "http://127.0.0.1:${HV_DASH_PORT},https://${domain}"
        hv_info "API CORS 来源已更新为 127.0.0.1:${HV_DASH_PORT} 与 https://${domain}"
    fi

    hv_caddy_reload
}

# ---------------------------------------------------------------------------
# 服务管理
# ---------------------------------------------------------------------------
hv_caddy_reload() {
    hv_require_root
    if [[ -f "$HV_CADDYFILE" ]]; then
        if ! "$(hv_caddy_cmd)" validate --config "$HV_CADDYFILE" --adapter caddyfile >/tmp/caddy-validate.out 2>&1; then
            hv_err "校验失败,拒绝重载:"
            sed 's/^/    /' /tmp/caddy-validate.out >&2
            return 1
        fi
    fi
    hv_has_systemd || { hv_warn "无 systemd,请手工重启 caddy"; return 1; }
    systemctl enable caddy >/dev/null 2>&1 || true
    if systemctl is-active --quiet caddy; then
        systemctl reload caddy 2>/dev/null && hv_ok "Caddy 已 reload" || { systemctl restart caddy; hv_ok "Caddy 已 restart"; }
    else
        systemctl start caddy && hv_ok "Caddy 已启动"
    fi
}

hv_caddy_status() {
    hv_rule
    if ! hv_caddy_installed; then
        printf '  Caddy      : 未安装\n'; hv_rule; return 0
    fi
    printf '  Caddy      : %s (%s 安装)\n' "$("$(hv_caddy_cmd)" version 2>/dev/null | head -n1)" "$(hv_state_get CADDY_SOURCE unknown)"
    printf '  服务状态   : %s\n' "$(systemctl is-active caddy 2>/dev/null || echo unknown)"
    printf '  配置文件   : %s\n' "$HV_CADDYFILE"
    local d; d="$(hv_state_get DOMAIN "")"
    printf '  对外域名   : %s\n' "${d:-未设置}"
    if [[ -n "$d" ]]; then
        printf '  证书状态   : '
        local cert=/var/lib/caddy/.local/share/caddy/certificates
        if grep -qs "$d" -r "$cert" 2>/dev/null; then printf '已签发(本地缓存存在)\n'; else printf '未见本地缓存(可能还在签发,或用了系统 CA 路径)\n'; fi
    fi
    printf '  日志       : %s\n' "$HV_CADDY_LOG_DIR"
    hv_rule
}

# 证书健康检查(远程握手,用于 doctor)
hv_caddy_https_check() {
    local domain="$1"
    [[ -z "$domain" ]] && return 1
    curl -sS -o /dev/null -m 10 -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null
}

hv_caddy_logs() {
    if hv_have journalctl; then
        journalctl -u caddy -n "${1:-80}" --no-pager
    else
        tail -n "${1:-80}" "$HV_CADDY_LOG_DIR"/*.log 2>/dev/null
    fi
}

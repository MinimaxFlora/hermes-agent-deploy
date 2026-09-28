#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/service.sh
# 常驻服务托管(systemd 系统级,开机自启,不依赖 linger):
#   hermes-gateway.service    —— 官方 `hermes gateway install --system` 安装,
#                                安装后校验 User= 是否为服务用户,不是就补 drop-in;
#   hermes-dashboard.service  —— 官方只提供 CLI 启动方式,这里由本工具生成单元。
# 面板/网关都绑回环,Caddy 从回环反代。
# =============================================================================

[[ -n "${HV_SERVICE_LOADED:-}" ]] && return 0
HV_SERVICE_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

HV_GW_UNIT="hermes-gateway.service"
HV_DASH_UNIT="hermes-dashboard.service"

# ---------------------------------------------------------------------------
# 网关服务
# ---------------------------------------------------------------------------
hv_service_gateway_install() {
    hv_require_root
    hv_hermes_installed || hv_die "Hermes 未安装"
    hv_has_systemd || { hv_warn "无 systemd,跳过网关服务安装"; return 1; }

    hv_step "安装网关服务(hermes gateway install --system)"
    local rc=0 u=""

    # 方案 A:直接以服务用户身份安装(单元里的 User= 一定正确)
    set +e
    hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" gateway install --system
    rc=$?
    set -e

    # 方案 B:方案 A 失败(服务用户没有 sudo 权限),改由 root 执行,再校验/修正 User=
    if [[ $rc -ne 0 ]]; then
        hv_warn "以 $HV_USER 身份安装失败(rc=$rc),改由 root 安装后修正运行用户"
        set +e
        SUDO_USER="$HV_USER" hv_run_as_user_env "root" \
            "HERMES_HOME=$HV_UHOME" "SUDO_USER=$HV_USER" -- "$HV_HERMES_BIN" gateway install --system
        rc=$?
        set -e
    fi

    # 方案 C:仍然失败 → 用户级服务 + linger
    if [[ $rc -ne 0 ]]; then
        hv_warn "系统级安装失败(rc=$rc),回退到用户级服务 + linger"
        hv_service_gateway_install_user
        return $?
    fi

    hv_service_verify_unit_user "$HV_GW_UNIT"
    systemctl enable "$HV_GW_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$HV_GW_UNIT" >/dev/null 2>&1 || true
    hv_ok "网关服务已安装并启动:$HV_GW_UNIT"
    hv_service_status "$HV_GW_UNIT"
}

hv_service_gateway_install_user() {
    hv_have loginctl && loginctl enable-linger "$HV_USER" >/dev/null 2>&1 || true
    hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" gateway install || true
    set +e
    hv_run_as_user "$HV_USER" systemctl --user daemon-reload
    hv_run_as_user "$HV_USER" systemctl --user enable --now "$HV_GW_UNIT"
    set -e
    hv_warn "已使用用户级服务(需 linger 才开机自启);状态:cron/systemd --user"
    hv_state_set GATEWAY_SERVICE_MODE "user"
}

# 校验单元里的 User=;官方安装器依赖 SUDO_USER 推断用户,root 直接跑时可能写成 root
hv_service_verify_unit_user() {
    local unit="$1" u
    u="$(systemctl show -p User --value "$unit" 2>/dev/null | tr -d '\r' || true)"
    if [[ -z "$u" || "$u" == "root" ]]; then
        hv_warn "$unit 的运行用户是 '${u:-root}',修正为 $HV_USER"
        local dir="/etc/systemd/system/${unit}.d"
        install -d -m 755 "$dir"
        cat >"${dir}/10-hermes-vps-user.conf" <<EOF
# hermes-vps:确保服务以专用用户身份运行(官方安装器在 root 直跑时可能写成 root)
[Service]
User=${HV_USER}
Group=${HV_USER}
Environment=HERMES_HOME=${HV_UHOME}
EOF
        hv_systemd_reload
    fi
    hv_state_set GATEWAY_SERVICE_MODE "system"
}

# ---------------------------------------------------------------------------
# 面板服务(自建单元)
# ---------------------------------------------------------------------------
hv_service_dashboard_install() {
    hv_require_root
    hv_hermes_installed || hv_die "Hermes 未安装"
    hv_has_systemd || { hv_warn "无 systemd,跳过面板服务安装"; return 1; }

    hv_step "安装面板服务($HV_DASH_UNIT,127.0.0.1:${HV_DASH_PORT})"
    hv_write_dashboard_runner

    # 面板必须绑回环 + 配 dashboard.public_url;鉴权门由 basic auth 提供
    local pub; pub="$(hv_state_get DASHBOARD_PUBLIC_URL "")"
    if [[ -z "$pub" ]]; then
        hv_warn "尚未设置 dashboard.public_url:面板只在本机可用(配域名后会自动生效)"
    fi
    if [[ -z "$(hv_env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)" && -z "$(hv_env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH)" ]]; then
        hv_warn "未配置面板密码:绑定非回环地址时 Hermes 会拒绝启动(fail-closed)"
    fi

    cat >"/etc/systemd/system/${HV_DASH_UNIT}" <<EOF
[Unit]
Description=Hermes Agent Web Dashboard (managed by hermes-vps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${HV_USER}
Group=${HV_USER}
# 用 runner 脚本加载 .env(dotenv 里的 export/引号 systemd 的 EnvironmentFile 不一定吃得下)
ExecStart=${HV_UHOME}/bin/hermes-dashboard-run
WorkingDirectory=${HV_USER_HOME}
Restart=always
RestartSec=5
# 退出码 78 = 该主机已有面板后端在跑,重启无用,不要陷入重启风暴
RestartPreventExitStatus=78
KillMode=mixed
KillSignal=SIGTERM
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    hv_systemd_reload
    systemctl enable "$HV_DASH_UNIT" >/dev/null 2>&1 || true
    systemctl restart "$HV_DASH_UNIT" >/dev/null 2>&1 || true
    hv_ok "面板服务已安装:$HV_DASH_UNIT"
    hv_service_status "$HV_DASH_UNIT"
}

# 面板启动器:固定环境 → 加载 .env → 启动面板
hv_write_dashboard_runner() {
    local runner="${HV_UHOME}/bin/hermes-dashboard-run"
    install -d -o "$HV_USER" -g "$HV_USER" -m 755 "${HV_UHOME}/bin"
    cat >"$runner" <<'EOS'
#!/bin/sh
# 由 hermes-vps 生成:面板服务入口(加载 .env 后启动 hermes dashboard)
HOME=__HV_USER_HOME__
HERMES_HOME=__HV_UHOME__
PATH=__HV_USER_HOME__/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME HERMES_HOME PATH
if [ -f /etc/hermes-vps/mirror.env ]; then
    set -a; . /etc/hermes-vps/mirror.env; set +a
fi
if [ -f "$HERMES_HOME/.env" ]; then
    set -a; . "$HERMES_HOME/.env" 2>/dev/null || true; set +a
fi
exec __HV_HERMES_BIN__ dashboard --host 127.0.0.1 --port __HV_DASH_PORT__ --no-open
EOS
    sed -i "s|__HV_USER_HOME__|${HV_USER_HOME}|g; s|__HV_UHOME__|${HV_UHOME}|g; s|__HV_HERMES_BIN__|${HV_HERMES_BIN}|g; s|__HV_DASH_PORT__|${HV_DASH_PORT}|g" "$runner"
    chown "$HV_USER:$HV_USER" "$runner"
    chmod 755 "$runner"
}

# ---------------------------------------------------------------------------
# 通用操作
# ---------------------------------------------------------------------------
hv_service_status() {
    local unit="${1:-}"
    if [[ -z "$unit" ]]; then
        hv_rule
        printf '  %-26s %s\n' "$HV_GW_UNIT" "$(systemctl is-active "$HV_GW_UNIT" 2>/dev/null || echo not-installed)"
        printf '  %-26s %s\n' "$HV_DASH_UNIT" "$(systemctl is-active "$HV_DASH_UNIT" 2>/dev/null || echo not-installed)"
        printf '  %-26s %s\n' "caddy.service" "$(systemctl is-active caddy 2>/dev/null || echo not-installed)"
        hv_rule
        return 0
    fi
    systemctl status "$unit" --no-pager -l 2>&1 | head -n 20
}

hv_service_action() {
    local unit="$1" action="$2"
    hv_require_root
    hv_has_systemd || { hv_warn "无 systemd"; return 1; }
    case "$action" in
        restart)
            # 优先用 hermes gateway restart(会先 drain 在跑的对话),失败再退化到 systemctl
            if [[ "$unit" == "$HV_GW_UNIT" ]]; then
                hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" gateway restart 2>/dev/null \
                    || systemctl restart "$unit"
            else
                systemctl restart "$unit"
            fi
            ;;
        start|stop|status) systemctl "$action" "$unit" ;;
        *) hv_die "不支持的操作:$action" ;;
    esac
}

hv_service_logs() {
    local unit="${1:-$HV_GW_UNIT}" n="${2:-100}"
    if [[ "$unit" == "$HV_GW_UNIT" && "$(hv_state_get GATEWAY_SERVICE_MODE system)" == "user" ]]; then
        hv_run_as_user "$HV_USER" journalctl --user -u "$HV_GW_UNIT" -n "$n" --no-pager
    else
        journalctl -u "$unit" -n "$n" --no-pager
    fi
}

hv_service_restart_all() {
    hv_has_systemd || return 0
    local u
    for u in "$HV_GW_UNIT" "$HV_DASH_UNIT"; do
        systemctl is-enabled "$u" >/dev/null 2>&1 && systemctl restart "$u" 2>/dev/null || true
    done
}

# 等待端口就绪(用于安装后自检)
hv_wait_port() {
    local port="$1" timeout="${2:-60}" i=0
    while [[ $i -lt $timeout ]]; do
        hv_port_in_use "$port" && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

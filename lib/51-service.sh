# ---------------------------------------------------------------------------
# systemd 服务
# ---------------------------------------------------------------------------
ensure_unit_user() { # 保证单元以 hermes 用户运行
    local unit="$1" file="/etc/systemd/system/$1"
    local dir="/etc/systemd/system/${unit}.d"
    local need=0 u=""
    [[ -f "$file" ]] && u="$(awk -F= '/^User=/{gsub(/ /,"",$2); print $2}' "$file" | sed -n '1p')"
    if [[ "$u" != "$HUSER" ]]; then need=1; fi
    if [[ $need -eq 1 ]]; then
        mkdir -p "$dir"
        cat >"$dir/10-hermes-vps-user.conf" <<EOF
# 由 hermes-vps 写入:确保服务以专用用户运行
[Service]
User=$HUSER
Group=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
Environment=HERMES_HOME=$UHOME
EOF
        chmod 644 "$dir/10-hermes-vps-user.conf"
        systemctl daemon-reload 2>/dev/null || true
        info "已补齐 User=$HUSER(原值:${u:-未设置})"
    fi
}

service_gateway_install() {
    require_root
    local unit="hermes-gateway.service" file="/etc/systemd/system/hermes-gateway.service"
    if [[ -f "$file" ]] && systemctl is-enabled "$unit" >/dev/null 2>&1; then
        local u; u="$(awk -F= '/^User=/{gsub(/ /,"",$2); print $2}' "$file" | sed -n '1p')"
        if [[ "$u" == "$HUSER" ]]; then ok "网关服务已就绪(开机自启)"; return 0; fi
    fi
    step "安装网关系统服务"
    local rc=0
    set +e
    HERMES_HOME="$UHOME" HOME="$HHOME" "$HBIN" gateway install --system >/dev/null 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
        run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" gateway install --system >/dev/null 2>&1
        rc=$?
    fi
    set -e
    if [[ $rc -ne 0 || ! -f "$file" ]]; then
        warn "官方安装未生成单元,写入内置单元"
        write_gateway_unit
    fi
    ensure_unit_user "$unit"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" 2>/dev/null || true
    ok "网关服务已安装并启动"
}

write_gateway_unit() {
    cat >/etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent Messaging Gateway (managed by hermes-vps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HUSER
Group=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
Environment=HERMES_HOME=$UHOME
Environment=PATH=$HHOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HHOME/.local/bin/hermes gateway run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/hermes-gateway.service
}

service_dashboard_install() {
    require_root
    local unit="hermes-dashboard.service" file="/etc/systemd/system/hermes-dashboard.service"
    local content
    content="$(cat <<EOF
[Unit]
Description=Hermes Agent Web Dashboard (managed by hermes-vps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HUSER
Group=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
Environment=HERMES_HOME=$UHOME
Environment=PATH=$HHOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HHOME/.local/bin/hermes dashboard
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
)"
    if [[ -f "$file" ]] && diff -q <(printf '%s\n' "$content") "$file" >/dev/null 2>&1 && systemctl is-enabled "$unit" >/dev/null 2>&1; then
        ok "面板服务已就绪(无需变更)"
        return 0
    fi
    step "安装面板系统服务"
    printf '%s\n' "$content" >"$file"
    chmod 644 "$file"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" 2>/dev/null || true
    ok "面板服务已安装并启动"
}

svc() { # 服务名归一化
    case "$1" in
        gateway|hermes-gateway) printf 'hermes-gateway' ;;
        dashboard|panel|hermes-dashboard) printf 'hermes-dashboard' ;;
        caddy) printf 'caddy' ;;
        *) printf '%s' "$1" ;;
    esac
}
start_service()   { local s; s="$(svc "$1")"; systemctl start "$s"  && ok "$s 已启动" || err "$s 启动失败"; }
stop_service()    { local s; s="$(svc "$1")"; systemctl stop "$s"   && ok "$s 已停止" || err "$s 停止失败"; }
restart_service() { local s; s="$(svc "$1")"; systemctl restart "$s" >/dev/null 2>&1 && ok "$s 已重启" || err "$s 重启失败"; }
restart_all_services() {
    local s
    for s in hermes-gateway hermes-dashboard; do systemctl restart "$s" >/dev/null 2>&1 || true; done
    systemctl is-active caddy >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
    sleep 1
    info "已重启:$(service_brief)"
    return 0
}
service_brief() {
    local out="" s
    for s in hermes-gateway hermes-dashboard caddy; do
        local st; st="$(svc_state "$s")"
        if [[ "$st" == "active" ]]; then out+=" ${G}●${N}${s#hermes-}"; else out+=" ${R}○${N}${s#hermes-}($st)"; fi
    done
    printf '%s' "$out"
}
service_logs() {
    local s; s="$(svc "$1")"
    if [[ "$s" == "hermes-gateway" && -f "$UHOME/logs/gateway.log" ]]; then
        dim "按 Ctrl+C 退出日志(网关:$UHOME/logs/gateway.log,平台连接结论在这里)"
        set +e; tail -n 60 -f "$UHOME/logs/gateway.log"; set -e
        return 0
    fi
    dim "按 Ctrl+C 退出日志(${s})"
    set +e; journalctl -u "$s" -n 60 --no-pager; journalctl -u "$s" -f; set -e
}

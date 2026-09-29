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
    if [[ "$HV_MODE" != "system" ]]; then user_service_install hermes-gateway gateway; return $?; fi
    require_root "安装网关系统服务"
    local unit="hermes-gateway.service" file="/etc/systemd/system/hermes-gateway.service"
    if [[ -f "$file" ]] && systemctl is-enabled "$unit" >/dev/null 2>&1; then
        local u; u="$(awk -F= '/^User=/{gsub(/ /,"",$2); print $2}' "$file" | sed -n '1p')"
        if [[ "$u" == "$HUSER" ]]; then ok "网关服务已就绪(开机自启)"; return 0; fi
    fi
    step "安装网关系统服务"
    # ⚠️ 官方 `gateway install --system` 是交互式命令:输出重定向到 /dev/null 时,它若等待确认
    #    就会永久卡住(stdin 仍接在 TTY 上) —— 真机 [7/10] 卡死就是这个原因。
    #    所以:stdin 接 /dev/null(EOF 让它自己退出)+ timeout 兜底;失败就走内置单元。
    local rc=0
    set +e
    timeout 60 env HERMES_HOME="$UHOME" HOME="$HHOME" "$HBIN" gateway install --system </dev/null >/dev/null 2>&1
    rc=$?
    [[ $rc -eq 124 ]] && warn "官方 gateway install --system 超时 60s(可能是交互式确认),改用内置单元"
    if [[ $rc -ne 0 ]]; then
        timeout 60 env -i HOME="$HHOME" HERMES_HOME="$UHOME" \
            PATH="$HHOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            su -s /bin/bash "$HUSER" -c "cd '$HHOME' 2>/dev/null || cd /; '$HBIN' gateway install --system" </dev/null >/dev/null 2>&1
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
    if [[ "$HV_MODE" != "system" ]]; then user_service_install hermes-dashboard dashboard; return $?; fi
    require_root "安装面板系统服务"
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
        dashboard_ensure_host_ok      # 面板的 Host 白名单在启动时读取,域名变了必须重启
        return 0
    fi
    step "安装面板系统服务"
    printf '%s\n' "$content" >"$file"
    chmod 644 "$file"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" 2>/dev/null || true
    ok "面板服务已安装并启动"
    dashboard_ensure_host_ok
}

svc() { # 服务名归一化
    case "$1" in
        gateway|hermes-gateway) printf 'hermes-gateway' ;;
        dashboard|panel|hermes-dashboard) printf 'hermes-dashboard' ;;
        caddy) printf 'caddy' ;;
        *) printf '%s' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# 服务控制(双模式)
#   系统级(root):systemd 系统实例,单元在 /etc/systemd/system
#   用户态(非 root):优先 systemd --user,单元在 ~/.config/systemd/user;
#                    会话没有 DBus 时退回"后台进程 + PID 文件"(日志落 $TOOL_LOG_DIR)
# ---------------------------------------------------------------------------
_USER_SD_OK=""
user_systemd_ok() {
    [[ -n "$_USER_SD_OK" ]] || {
        if have systemctl && systemctl --user show-environment >/dev/null 2>&1; then _USER_SD_OK=1; else _USER_SD_OK=0; fi
    }
    [[ "$_USER_SD_OK" == "1" ]]
}
run_dir() { printf '%s/run' "$ETC_DIR"; }
pidfile_for() { printf '%s/%s.pid' "$(run_dir)" "$1"; }
svc_unit_path() {
    if [[ "$HV_MODE" == "system" ]]; then printf '/etc/systemd/system/%s.service' "$1"
    else printf '%s/.config/systemd/user/%s.service' "$USER_HOME" "$1"; fi
}

# ---------------------------------------------------------------- 官方网关(主机级单例)
# 官方网关是"每主机一个实例":`hermes gateway run` 见到已有实例会直接拒绝
#   "The host gateway already serves profile 'default' — nothing to start."
# 因此用户态的网关必须走官方自己的 restart/stop(它会接管旧实例并起新实例),
# 我们自己的 pidfile 只是缓存 —— 官方进程换了它不会知道(真机踩过)。
gw_pid_from_status() { # 从 stdin 的 `hermes gateway status` 输出里取 PID
    sed -n 's/.*PID: *\([0-9][0-9]*\).*/\1/p' | head -1 || true
    return 0
}
hermes_gw_bin() { # 官方 hermes 可执行(优先用已探测到的 $HBIN)
    local b="${HBIN:-}"
    if [[ -n "$b" && -x "$b" ]]; then printf '%s' "$b"; return 0; fi
    b="$USER_HOME/.local/bin/hermes"
    if [[ -x "$b" ]]; then printf '%s' "$b"; return 0; fi
    return 1
}
official_gateway_pid() { # 官方认为的网关 PID(没跑则空)
    local hbin; hbin="$(hermes_gw_bin)" || { printf ''; return 0; }
    HERMES_HOME="$UHOME" "$hbin" gateway status 2>/dev/null | gw_pid_from_status || true
    return 0
}
usermode_gateway_ctl() { # 网关的用户态生命周期(走官方),成功返回 0
    local action="$1" hbin pid pf
    hbin="$(hermes_gw_bin)" || return 1
    pf="$(pidfile_for hermes-gateway)"
    case "$action" in
        stop)           HERMES_HOME="$UHOME" "$hbin" gateway stop    >/dev/null 2>&1 || true ;;
        restart|reload) HERMES_HOME="$UHOME" "$hbin" gateway restart >/dev/null 2>&1 || true ;;
        start)          : ;;
    esac
    for _ in 1 2 3 4 5 6 7 8; do
        pid="$(official_gateway_pid)"
        [[ -n "$pid" ]] && break
        sleep 1
    done
    if [[ -n "$pid" ]]; then printf '%s' "$pid" >"$pf"; return 0; fi
    [[ "$action" == "stop" ]] && { rm -f "$pf"; return 0; }
    return 1
}

svc_state() { # active / failed / inactive / unknown
    local s="$1"
    if [[ "$HV_MODE" == "system" ]]; then systemctl is-active "$s" 2>/dev/null || echo unknown; return 0; fi
    # 用户态:我们自己的托管方式是"后台进程 + pidfile",必须先看它 ——
    # 只看 systemctl --user 会在"机器上有用户级 systemd、但我们的单元没装"时报 inactive,
    # 而服务与端口其实都正常(真机踩过:菜单显示 inactive,用户以为服务挂了)
    if [[ "$s" == "hermes-gateway" ]]; then
        # 网关是主机级单例:真实状态以官方 status 为准(我们的 pidfile 会过期 —— 用了官方
        # restart 时进程换了 pid,pidfile 还指着旧的,菜单就会显示 inactive)
        local gpid; gpid="$(official_gateway_pid)"
        if [[ -n "$gpid" ]]; then
            local gpf; gpf="$(pidfile_for "$s")"
            [[ "$(cat "$gpf" 2>/dev/null)" == "$gpid" ]] || printf '%s' "$gpid" >"$gpf" 2>/dev/null || true
            printf 'active'; return 0
        fi
    fi
    local pf; pf="$(pidfile_for "$s")"
    if [[ -f "$pf" ]]; then
        if kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then printf 'active'; else printf 'inactive'; fi
        return 0
    fi
    if user_systemd_ok && systemctl --user cat "$s" >/dev/null 2>&1; then
        systemctl --user is-active "$s" 2>/dev/null || echo unknown
        return 0
    fi
    printf 'inactive'
    return 0
}
svc_enabled() {
    local s="$1"
    if [[ "$HV_MODE" == "system" ]]; then systemctl is-enabled "$s" 2>/dev/null || echo unknown; return 0; fi
    if user_systemd_ok; then systemctl --user is-enabled "$s" 2>/dev/null || echo unknown; return 0; fi
    printf 'manual'
    return 0
}
svc_ctl() { # svc_ctl start|stop|restart|reload <svc>
    local action="$1" s="$2"
    if [[ "$HV_MODE" == "system" ]]; then systemctl "$action" "$s" >/dev/null 2>&1; return $?; fi
    # 用户级 systemd 可用 ≠ 我们的单元存在:盲目 systemctl --user restart <不存在的单元>
    # 只会失败(真机:网关/面板"重启失败",而服务其实是我们自己的后台进程)
    if user_systemd_ok && systemctl --user cat "$s" >/dev/null 2>&1; then
        systemctl --user "$action" "$s" >/dev/null 2>&1; return $?
    fi
    # 网关:官方是"每主机一个实例",run 见到已有实例会拒绝启动 → 必须走官方 restart/stop
    if [[ "$s" == "hermes-gateway" ]]; then
        case "$action" in
            restart|reload|stop)
                if usermode_gateway_ctl "$action"; then return 0; fi ;;
            start)
                if usermode_gateway_ctl start; then return 0; fi ;;
        esac
    fi
    case "$action" in
        # 注意:restart 必须是 stop + start —— 只调 start 时,若 pid 还活着会直接返回,
        # 于是"重启"变成空操作(真机踩过:改了配置重启面板却不生效,面板还拿着旧配置)
        start)         usermode_bg_start "$s" >/dev/null 2>&1 ;;
        restart)       usermode_bg_stop "$s" >/dev/null 2>&1; usermode_bg_start "$s" >/dev/null 2>&1 ;;
        stop)          usermode_bg_stop "$s" >/dev/null 2>&1 ;;
        reload)        usermode_bg_stop "$s" >/dev/null 2>&1; usermode_bg_start "$s" >/dev/null 2>&1 ;;
    esac
}

# 用户态后台进程模式:本工具自己写 PID 与日志
usermode_gateway_pid() { # 官方网关的全机单例 PID —— 权威来源是官方自己的 status(真机教训)
    local out p
    [[ -x "$HBIN" ]] || return 1
    out="$(HERMES_HOME="$UHOME" timeout 20 "$HBIN" gateway status 2>/dev/null)" || out=""
    p="$(printf '%s' "$out" | sed -n 's/.*PID: *\([0-9][0-9]*\).*/\1/p' | head -1)"
    [[ -n "$p" ]] && printf '%s' "$p"
    return 0
}

usermode_bg_cmd() {
    case "$1" in
        hermes-gateway)   printf '%s gateway run' "$HBIN" ;;
        hermes-dashboard) printf '%s dashboard --port %s' "$HBIN" "$DASH_PORT" ;;
        caddy)            printf '%s run --config %s --adapter caddyfile' "$(caddy_bin)" "$CADDYFILE" ;;
        *) return 1 ;;
    esac
}
usermode_bg_start() {
    local s="$1" pf log cmd
    mkdir -p "$(run_dir)" "$TOOL_LOG_DIR" 2>/dev/null || true
    pf="$(pidfile_for "$s")"; log="$TOOL_LOG_DIR/${s}.log"
    if [[ -f "$pf" ]] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then return 0; fi
    # 官方网关是全机单例(自带 registry):已在跑就接管它的 PID,绝不重复启动 ——
    # 否则官方回 "already serves profile … nothing to start" 然后退出,我们把自己的
    # "进程已退出" 当成启动失败(真机:网关明明在跑,菜单却报重启失败并显示 inactive)
    if [[ "$s" == "hermes-gateway" ]]; then
        local opid; opid="$(usermode_gateway_pid || true)"
        if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then
            printf '%s' "$opid" >"$pf"
            ok "网关已在运行(已接管官方实例 PID $opid)"
            return 0
        fi
        # registry 里可能留着已死进程的记录,让官方自己清一遍再启
        timeout 30 env HOME="$USER_HOME" HERMES_HOME="$UHOME" "$HBIN" gateway stop >/dev/null 2>&1 || true
    fi
    cmd="$(usermode_bg_cmd "$s")" || return 1
    [[ -x "${cmd%% *}" ]] || { warn "找不到可执行文件:${cmd%% *}"; return 1; }
    # 用 nohup + $! 直接记录真实进程 pid(用 setsid 时 $! 可能只是包装进程 → 之后 stop 杀不到)
    nohup env HOME="$USER_HOME" HERMES_HOME="$UHOME" bash -lc "$cmd" >>"$log" 2>&1 &
    echo $! >"$pf"
    disown 2>/dev/null || true
    sleep 2
    if [[ "$s" == "hermes-gateway" ]]; then
        local opid2; opid2="$(usermode_gateway_pid || true)"
        if [[ -n "$opid2" ]] && kill -0 "$opid2" 2>/dev/null; then printf '%s' "$opid2" >"$pf"; return 0; fi
    fi
    if [[ -f "$pf" ]] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then return 0; else return 1; fi
}
port_owner_pid() { # 谁在监听该端口(需要能看自己的进程)
    command -v ss >/dev/null 2>&1 || return 1
    ss -lntp 2>/dev/null | grep -F ":$1 " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
}
usermode_bg_stop() {
    local s="$1" pf pid i
    pf="$(pidfile_for "$s")"
    # 网关:先走官方 stop(它会把自己的 registry 清干净,否则下次启动会被拒),
    # 再拿官方 PID 兜底 —— 只杀我们自己记录的 pid 会漏掉"手工/被接管"的那种实例
    if [[ "$s" == "hermes-gateway" ]]; then
        local opid; opid="$(usermode_gateway_pid || true)"
        timeout 30 env HOME="$USER_HOME" HERMES_HOME="$UHOME" "$HBIN" gateway stop >/dev/null 2>&1 || true
        if [[ -n "$opid" ]] && kill -0 "$opid" 2>/dev/null; then
            kill "$opid" 2>/dev/null || true
            for i in 1 2 3 4 5; do kill -0 "$opid" 2>/dev/null || break; sleep 1; done
            kill -0 "$opid" 2>/dev/null && kill -9 "$opid" 2>/dev/null || true
        fi
    fi
    pid="$(cat "$pf" 2>/dev/null)" || pid=""
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; sleep 1; fi
    fi
    # 兜底:pid 记录不准时,按端口找真正的进程(面板/网关都会占端口)
    local port=""
    case "$s" in
        hermes-dashboard) port="$DASH_PORT" ;;
        hermes-gateway)   port="$API_PORT" ;;
    esac
    if [[ -n "$port" ]] && port_in_use "$port"; then
        local owner; owner="$(port_owner_pid "$port" || true)"
        if [[ -n "$owner" && "$owner" != "$pid" ]]; then
            kill "$owner" 2>/dev/null || true; sleep 1
            kill -0 "$owner" 2>/dev/null && kill -9 "$owner" 2>/dev/null || true
        fi
    fi
    rm -f "$pf"
    return 0
}

# 用户态服务安装(systemd --user 可用时装单元,否则提示将由后台进程托管)
user_service_install() { # user_service_install <unit> gateway|dashboard
    local name="$1" kind="$2" exec_start dir
    # 本机已经有系统级 Hermes 网关在跑时,官方会拒绝再起一个(并警告共享 DB 会被并发写坏)。
    # 这时用户态实例只提供面板与 CLI —— 明确告知,绝不假装成功。
    if [[ "$kind" == "gateway" ]] && have systemctl && systemctl is-active hermes-gateway >/dev/null 2>&1; then
        warn "本机已有系统级网关在运行(systemd hermes-gateway):用户态不再起第二个网关"
        dim "官方会拒绝重复网关(并发写共享 kanban DB 有损坏风险)。"
        dim "要用用户态网关请先停掉系统级实例:sudo systemctl disable --now hermes-gateway"
        return 0
    fi
    ensure_free_ports
    if ! user_systemd_ok; then
        warn "systemd --user 不可用(没有用户 DBus 会话):${name} 改为后台进程方式"
        if usermode_bg_start "$name"; then
            ok "已以后台进程启动:$name(日志 $TOOL_LOG_DIR/${name}.log,状态见菜单 6)"
        else
            warn "后台启动失败,可稍后在菜单「服务管理」里重试(日志 $TOOL_LOG_DIR/${name}.log)"
        fi
        return 0
    fi
    if [[ "$kind" == "gateway" ]]; then exec_start="$HBIN gateway run"; else exec_start="$HBIN dashboard --port $DASH_PORT"; fi
    dir="$USER_HOME/.config/systemd/user"
    mkdir -p "$dir"
    cat >"$dir/$name.service" <<EOF
[Unit]
Description=Hermes Agent ${kind} (managed by hermes-vps · user mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$USER_HOME
Environment=HOME=$USER_HOME
Environment=HERMES_HOME=$UHOME
Environment=PATH=$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$exec_start
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
    chmod 644 "$dir/$name.service"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable --now "$name" >/dev/null 2>&1 || systemctl --user restart "$name" >/dev/null 2>&1 || true
    ok "用户态服务已安装:$name(单元:$dir/$name.service)"
    if have loginctl; then
        loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||             dim "注销后仍要保持运行,可执行:sudo loginctl enable-linger $(id -un)"
    fi
    return 0
}

start_service()   { local s; s="$(svc "$1")"; if svc_ctl start "$s"; then ok "$s 已启动"; else err "$s 启动失败(看日志:$(svc_log_hint "$s"))"; fi; }
stop_service()    { local s; s="$(svc "$1")"; if svc_ctl stop "$s"; then ok "$s 已停止"; else err "$s 停止失败"; fi; }
restart_service() { local s; s="$(svc "$1")"; if svc_ctl restart "$s"; then ok "$s 已重启"; else err "$s 重启失败(看日志:$(svc_log_hint "$s"))"; fi; }
restart_all_services() {
    local s
    for s in hermes-gateway hermes-dashboard; do svc_ctl restart "$s" >/dev/null 2>&1 || true; done
    [[ "$(svc_state caddy)" == "active" ]] && svc_ctl reload caddy >/dev/null 2>&1 || true
    sleep 1
    info "已重启:$(service_brief)"
    return 0
}
svc_log_hint() {
    local s="$1"
    if [[ "$HV_MODE" == "system" ]]; then printf 'journalctl -u %s -n 50' "$s"; return 0; fi
    if user_systemd_ok && systemctl --user cat "$s" >/dev/null 2>&1; then
        printf 'journalctl --user -u %s -n 50' "$s"; return 0
    fi
    # 用户态不是 systemd 单元:journalctl 只会回 "No entries"(真机把用户带沟里了)。
    # 网关的真实日志在 HERMES_HOME/logs/gateway.log
    if [[ "$s" == "hermes-gateway" ]]; then printf 'tail -60 %s/logs/gateway.log' "$UHOME"; return 0; fi
    printf 'tail -60 %s/%s.log' "$TOOL_LOG_DIR" "$s"
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
    # 网关的平台连接结论写在 Hermes 自己的日志里(两种模式都一样)
    if [[ "$s" == "hermes-gateway" && -f "$UHOME/logs/gateway.log" ]]; then
        dim "按 Ctrl+C 退出日志(网关:$UHOME/logs/gateway.log,平台连接结论在这里)"
        set +e; tail -n 60 -f "$UHOME/logs/gateway.log"; set -e
        return 0
    fi
    if [[ "$HV_MODE" == "system" ]]; then
        dim "按 Ctrl+C 退出日志(${s})"
        set +e; journalctl -u "$s" -n 60 --no-pager; journalctl -u "$s" -f; set -e
        return 0
    fi
    if user_systemd_ok; then
        dim "按 Ctrl+C 退出日志(${s} · systemd --user)"
        set +e; journalctl --user -u "$s" -n 60 --no-pager; journalctl --user -u "$s" -f; set -e
        return 0
    fi
    local log="$TOOL_LOG_DIR/${s}.log"
    dim "按 Ctrl+C 退出日志(后台进程模式:$log)"
    set +e; tail -n 60 -f "$log"; set -e
}

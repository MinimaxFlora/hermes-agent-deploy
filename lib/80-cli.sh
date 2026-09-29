# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

  Hermes Agent · VPS 一键部署与管理  v$V

  运行模式(自动识别,无需参数):
    root        系统级:专用服务用户 hermes、systemd 系统服务、/etc 配置、Caddy 80/443
    普通用户    用户态:全部落在 $HOME,服务用 systemd --user(不可用时后台进程),
                需要特权的功能(域名/HTTPS、防火墙)会提示用 sudo 重新执行

  用法:
    bash ${SELF##*/}                 打开交互菜单(推荐)
    bash ${SELF##*/} <命令> [参数]    直接执行,适合脚本化

  命令:
    install           一键部署(等价菜单 1)
    model             模型提供商配置(install 后可随时执行)
    platform          消息平台接入
    pairing [动作]    配对审批:list|approve <平台> <码>|all|watch [秒]|pairing|open|closed
    domain <域名>     配置 Caddy + 自动 HTTPS
    panel             面板凭据/API 开关
    service <动作>    start|stop|restart|status|logs [gateway|dashboard|caddy]
    diagnose          自检与诊断
    backup            立即备份;restore 恢复
    update            更新 Hermes;auto-update on|off|status
    firewall          配置防火墙
    mirror [--force]  探测并应用国内加速通道
    uninstall         卸载(逐项确认)
    selftest          自检脚本自身(语法/数据表/渲染)
    self-install      把自己装成命令(系统级 /usr/local/bin,用户态 ~/.local/bin)
    version           版本
    mode              显示当前运行模式(系统级 / 用户态)

  通用参数:
    -y, --yes            全部确认自动回答“是”
    --non-interactive    非交互(不提问,用默认值/已有配置)
    --force              强制重装等
    --skip-browser       安装时跳过浏览器组件(省内存/时间)
    --no-color           关闭颜色
    --debug              打开 bash -x
EOF
}


main() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --non-interactive|--no-interactive) NONINTERACTIVE=1 ;;
            --force) FORCE=1 ;;
            --skip-browser) SKIP_BROWSER=1 ;;
            --no-color) NO_COLOR=1; R=""; G=""; Y=""; B=""; C=""; M=""; W=""; BD=""; DM=""; N="" ;;
            --debug) DEBUG_ON=1 ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    [[ "$DEBUG_ON" == "1" ]] && set -x

    detect_os
    # 只读命令不建目录:root 下执行一次 version 都会创建 /etc/hermes-vps、/var/log/hermes-vps,
    # 用户删掉系统级实例后它们又会"自己长回来"(真机踩过)
    case "${args[0]:-}" in
        help|-h|--help|version|-V|--version|mode|--mode|selftest) : ;;
        *) state_init ;;
    esac
    load_mirror_env
    # 生效端口:用户态撞端口时 ensure_free_ports 会把新端口记进 state,这里读回来
    DASH_PORT="$(st_get DASH_PORT "$DASH_PORT")"
    API_PORT="$(st_get API_PORT "$API_PORT")"

    local cmd="${args[0]:-}"
    if [[ -z "$cmd" ]]; then
        if [[ -t 0 && -t 1 ]]; then main_menu
        else usage; fi
        return 0
    fi
    set -- "${args[@]}"
    shift || true

    case "$cmd" in
        help|-h|--help) usage ;;
        version|-V|--version) printf 'hermes-vps %s\n' "$V" ;;
        mode|--mode) printf '运行模式:%s\n配置 %s · 日志 %s · HERMES_HOME %s\n' "$(mode_label)" "$ETC_DIR" "$TOOL_LOG_DIR" "$UHOME" ;;
        install|deploy) deploy_all ;;
        model) model_menu ;;
        platform|platforms) plat_menu ;;
        pairing)
            case "${1:-list}" in
                list|"")        pairing_show ;;
                approve)        pairing_approve_code "${2:-}" "${3:-}" ;;
                all|approve-all) pairing_approve_all ;;
                watch)          pairing_watch "${2:-180}" ;;
                pairing|on)     pairing_policy_set pairing ;;
                open)           pairing_policy_set open ;;
                closed|off)     pairing_policy_set closed ;;
                *) err "用法: pairing [list|approve <平台> <配对码>|all|watch [秒]|pairing|open|closed]"; exit 1 ;;
            esac ;;
        domain) domain_configure ;;
        panel) panel_menu ;;
        service)
            local action="${1:-status}"; shift || true
            case "$action" in
                start) start_service "${1:-gateway}" ;;
                stop) stop_service "${1:-gateway}" ;;
                restart) local t="${1:-all}"; if [[ "$t" == "all" ]]; then restart_all_services; else restart_service "$t"; fi ;;
                status) printf 'Hermes: %s\n' "$(hermes_version 2>/dev/null || echo 未安装)"; printf '服务: %s\n' "$(service_brief)" ;;
                logs) service_logs "${1:-hermes-gateway}" ;;
                *) usage; exit 1 ;;
            esac ;;
        diagnose|diag|doctor) diagnose ;;
        backup) backup_create "${1:-manual}" ;;
        restore) backup_restore ;;
        update) 
            if [[ "${1:-}" == "auto-update" ]]; then
                case "${2:-status}" in on) auto_update_install;; off) auto_update_remove;; *) auto_update_status; echo;; esac
            else hermes_update; fi ;;
        firewall) firewall_setup ;;
        mirror) mirror_probe "${1:+--force}"; mirror_apply_user; mirror_show ;;
        uninstall) uninstall_run ;;
        selftest) selftest ;;
        self-install|selfinstall)
            local target="/usr/local/bin/hermes-vps"
            if [[ "$HV_MODE" != "system" ]]; then
                target="$USER_HOME/.local/bin/hermes-vps"      # 用户态:装进自己的 ~/.local/bin
                mkdir -p "$(dirname "$target")"
            else
                require_root "安装命令到 /usr/local/bin"
            fi
            if [[ -f "$target" ]] && ! cmp -s "$SELF" "$target"; then
                cp -p "$target" "$target.bak" 2>/dev/null || true
                info "旧副本已备份到 $target.bak"
            fi
            install -m 755 "$SELF" "$target" 2>/dev/null || { cp -p "$SELF" "$target" && chmod 755 "$target"; }
            ok "已安装命令:$target"
            if [[ "$HV_MODE" != "system" ]]; then
                case ":$PATH:" in *":$USER_HOME/.local/bin:"*) : ;; *) dim "把 $USER_HOME/.local/bin 加进 PATH 后即可直接输入 hermes-vps";; esac
            fi ;;
        *) err "未知命令:$cmd"; usage; exit 1 ;;
    esac
}

load_mirror_env() {
    [[ -f "$MIRROR_FILE" ]] || return 0
    set +u
    # shellcheck disable=SC1090
    . "$MIRROR_FILE" 2>/dev/null || true
    set -u
    return 0
}

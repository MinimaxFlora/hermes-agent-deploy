# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

  Hermes Agent · VPS 一键部署与管理  v$V

  用法:
    bash ${SELF##*/}                 打开交互菜单(推荐)
    bash ${SELF##*/} <命令> [参数]    直接执行,适合脚本化

  命令:
    install           一键部署(等价菜单 1)
    model             模型提供商配置(install 后可随时执行)
    platform          消息平台接入
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
    self-install      把自己装成命令 /usr/local/bin/hermes-vps
    version           版本

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
    state_init
    load_mirror_env

    local cmd="${args[0]:-}"
    if [[ -z "$cmd" ]]; then
        if [[ -t 0 && -t 1 ]]; then require_root; main_menu
        else usage; fi
        return 0
    fi
    set -- "${args[@]}"
    shift || true

    # 强制 root:只有帮助 / 版本 / 自检可以在非 root 下跑(便于诊断,CI 也要用)
    case "$cmd" in
        help|-h|--help|version|-V|--version|selftest) : ;;
        *) require_root "$cmd" ;;
    esac

    case "$cmd" in
        help|-h|--help) usage ;;
        version|-V|--version) printf 'hermes-vps %s\n' "$V" ;;
        install|deploy) deploy_all ;;
        model) model_menu ;;
        platform|platforms) plat_menu ;;
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
            require_root
            if [[ -f /usr/local/bin/hermes-vps ]] && ! cmp -s "$SELF" /usr/local/bin/hermes-vps; then
                cp -p /usr/local/bin/hermes-vps "/usr/local/bin/hermes-vps.bak" 2>/dev/null || true
                info "旧副本已备份到 /usr/local/bin/hermes-vps.bak"
            fi
            install -m 755 "$SELF" /usr/local/bin/hermes-vps
            ok "已安装命令:/usr/local/bin/hermes-vps(任意目录输入 hermes-vps 即可打开菜单)" ;;
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

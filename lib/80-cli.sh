# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

  Hermes Agent · VPS 一键部署与管理  v$V

  运行模式(仅 Docker Compose):
    root       官方镜像 + 主机 Caddy;没有 Docker 时用 Docker_Private_Source 安装
    普通用户    只能执行只读命令;部署/管理请用 sudo hermes-vps(命令会自动提权)

  用法:
    bash ${SELF##*/}                 打开交互菜单(推荐)
    bash ${SELF##*/} <命令> [参数]    直接执行,适合脚本化

  命令:
    install           一键部署(等价菜单 1)
    model             模型提供商配置(install 后可随时执行)
    platform          消息平台接入
    pairing [动作]    配对审批:list|approve <平台> <码>|all|watch [秒]|pairing|open|closed
    domain <域名>     配置 Caddy + 自动 HTTPS(用户态会自动调 root 侧助手配 80/443)
    panel             面板凭据/API 开关
    service <动作>    start|stop|restart|status|logs [gateway|dashboard|caddy]
    diagnose          自检与诊断
    backup            立即备份;restore 恢复
    update            更新 Hermes;auto-update on|off|status
    engine <动作>      Docker Engine:version|update(按版本化 Release 升级)
    firewall          配置防火墙
    uninstall         卸载(逐项确认)
    selftest          自检脚本自身(语法/数据表/渲染)
    self-install      把自己装成命令(系统级 /usr/local/bin,用户态 ~/.local/bin)
    version           版本
    mode              显示当前运行模式(系统级 / 用户态)

  通用参数:
    -y, --yes            全部确认自动回答“是”
    --non-interactive    非交互(不提问,用默认值/已有配置)
    --force              强制重装等
    --image <镜像>       指定 Hermes 镜像(例:ghcr.io/minimaxflora/hermes-agent:latest)
    --docker-release <tag>   固定 Docker Engine 的 Release(例:v29.7.2;默认最新)
    --docker-version <ver>   固定 docker-ce 包版本(例:29.7.2)
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
            --image) HV_IMAGE_REF="${2:-}"; shift ;;
            --image=*) HV_IMAGE_REF="${1#*=}" ;;
            --docker-release) DOCKER_RELEASE="${2:-}"; shift ;;
            --docker-version) DOCKER_VERSION="${2:-}"; shift ;;
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
    backend_init
    # 生效端口:用户态撞端口时 ensure_free_ports 会把新端口记进 state,这里读回来
    DASH_PORT="$(st_get DASH_PORT "$DASH_PORT")"
    API_PORT="$(st_get API_PORT "$API_PORT")"

    local cmd="${args[0]:-}"
    # 只保留一种部署方式:Docker Compose。除只读命令外一律要求 root(自动 sudo 重跑)。
    case "$cmd" in
        "" )
            # 交互菜单需要 root;无 TTY 时只打印用法(测试/管道场景)
            if [[ -t 0 && -t 1 ]]; then is_root || require_root "Docker Compose 管理"; fi
            ;;
        help|-h|--help|version|-V|--version|mode|--mode|selftest) ;;
        *) is_root || require_root "Docker Compose 部署与管理" ;;
    esac
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
        mode|--mode) printf '运行模式:%s · 后端:%s\n配置 %s · 日志 %s · HERMES_HOME %s\n' "$(mode_label)" "$DEPLOY_BACKEND" "$ETC_DIR" "$TOOL_LOG_DIR" "$UHOME" ;;
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
        domain) domain_configure "${1:-}" ;;
        domain-root) # root 侧助手:用户态部署时由 sudo 调用(只写 Caddy,不碰状态)
            # 注意:此处不能 shift —— 命令本身在进入 case 前已经 shift 过,
            # 再 shift 一次会把域名参数丢掉(真机:Caddyfile 站点地址变成 --port,证书签不出来)
            domain_root_configure "$@" ;;
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
        engine|docker-engine)
            case "${1:-version}" in
                update) docker_engine_update ;;
                version|status)
                    docker --version 2>/dev/null || true
                    docker compose version 2>/dev/null || true
                    ;;
                *) err "用法: engine [version|update]"; exit 1 ;;
            esac ;;
        firewall) firewall_setup ;;
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

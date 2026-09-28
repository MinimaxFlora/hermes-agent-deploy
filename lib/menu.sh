#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/menu.sh
# 交互式菜单(whiptail / 文本回退)。菜单只做编排,逻辑都在各模块里 ——
# 因此所有功能都能用子命令调用,菜单不是唯一入口。
# =============================================================================

[[ -n "${HV_MENU_LOADED:-}" ]] && return 0
HV_MENU_LOADED=1
_HV_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${_HV_LIB}/common.sh"
source "${_HV_LIB}/ui.sh"
source "${_HV_LIB}/detect.sh"
source "${_HV_LIB}/account.sh"
source "${_HV_LIB}/provider.sh"
source "${_HV_LIB}/platform.sh"
source "${_HV_LIB}/webui.sh"
source "${_HV_LIB}/caddy.sh"
source "${_HV_LIB}/service.sh"
source "${_HV_LIB}/backup.sh"
source "${_HV_LIB}/lifecycle.sh"
source "${_HV_LIB}/doctor.sh"
source "${_HV_LIB}/firewall.sh"

hv_menu_main() {
    hv_ui_init
    while :; do
        local choice=""
        hv_menu choice "Hermes Agent VPS" "Hermes 部署/配置/运维 —— 选一项:" \
            deploy   "一键部署(安装 + 面板 + 域名 + 平台)" \
            model    "模型提供商(设置 key 与模型)" \
            platform "消息平台(QQ / 微信 / 企业微信 / TG / 飞书 …)" \
            domain   "域名与反向代理(Caddy / 证书)" \
            web      "面板与 API(密码、开关、访问信息)" \
            service  "服务管理(启动/停止/重启/日志)" \
            doctor   "状态总览与诊断" \
            backup   "备份与恢复" \
            update   "更新(Hermes / 自动更新)" \
            firewall "防火墙与安全" \
            uninstall "卸载" \
            quit     "退出" || return 0
        case "$choice" in
            deploy)    hv_deploy ;;
            model)     hv_menu_model ;;
            platform)  hv_menu_platform ;;
            domain)    hv_menu_domain ;;
            web)       hv_menu_web ;;
            service)   hv_menu_service ;;
            doctor)    hv_doctor ;;
            backup)    hv_menu_backup ;;
            update)    hv_menu_update ;;
            firewall)  hv_firewall_setup ;;
            uninstall) hv_uninstall ;;
            quit|"")   hv_info "再见"; return 0 ;;
        esac
        hv_pause
    done
}

hv_menu_model() {
    local c=""
    hv_menu c "模型提供商" "当前状态:\n$(hv_provider_show 2>/dev/null)" \
        configure "配置/切换提供商" list "列出所有支持的提供商" show "查看当前配置" back "返回" || return 0
    case "$c" in
        configure) hv_provider_configure ;;
        list)      hv_provider_list ;;
        show)      hv_provider_show ;;
    esac
}

hv_menu_platform() {
    local c=""
    hv_menu c "消息平台" "选择操作:" \
        status "查看各平台配置状态" configure "配置某个平台" setup "交互式向导(扫码类平台)" list "列出支持平台" back "返回" || return 0
    case "$c" in
        status)    hv_platform_status ;;
        configure) hv_platform_configure ;;
        setup)     local id=""; hv_ask id "输入平台 ID(如 weixin)" ""; hv_platform_interactive_setup "$id" ;;
        list)      hv_platform_list ;;
    esac
}

hv_menu_domain() {
    local c="" domain; domain="$(hv_state_get DOMAIN "")"
    hv_menu c "域名与反向代理" "当前域名: ${domain:-未配置}" \
        set   "设置/更换域名(自动签发证书)" \
        apply "重载 Caddy 配置" \
        api   "开启/关闭 /v1 API 反代" \
        status "证书与服务状态" \
        conf  "查看生成的 Caddyfile" \
        back  "返回" || return 0
    case "$c" in
        set)
            local d e
            hv_ask d "对外域名(已解析到本机)" "$domain"
            [[ -z "$d" ]] && return 0
            hv_ask e "Let's Encrypt 邮箱" "$(hv_state_get ACME_EMAIL "admin@${d}")"
            hv_caddy_install
            hv_dashboard_configure "$d"
            hv_caddy_apply "$d" "$e"
            ;;
        apply)  hv_caddy_apply "$domain" "$(hv_state_get ACME_EMAIL "")" "$(hv_state_get ACME_CA "")" ;;
        api)
            if [[ "$(hv_state_get API_SERVER off)" == "on" ]]; then hv_apiserver_configure off; else hv_apiserver_configure on; fi
            [[ -n "$domain" ]] && hv_caddy_apply "$domain" "$(hv_state_get ACME_EMAIL "")" "$(hv_state_get ACME_CA "")"
            ;;
        status) hv_caddy_status; hv_status_summary ;;
        conf)   [[ -f "$HV_CADDYFILE" ]] && hv_show_text "Caddyfile" "$HV_CADDYFILE" || hv_warn "尚无 Caddyfile" ;;
    esac
}

hv_menu_web() {
    local c=""
    hv_menu c "面板与 API" "面板/API 访问与凭据" \
        show  "查看访问地址与凭据" \
        reset "重置面板密码" \
        api   "启用/关闭 OpenAI 兼容 API" \
        back  "返回" || return 0
    case "$c" in
        show) hv_dashboard_show_access; hv_apiserver_show_access ;;
        reset)
            hv_creds_save DASHBOARD_PASSWORD "$(hv_random 18)"
            hv_dashboard_configure "$(hv_state_get DOMAIN "")"
            hv_dashboard_show_access
            ;;
        api) if [[ "$(hv_state_get API_SERVER off)" == "on" ]]; then hv_apiserver_configure off; else hv_apiserver_configure on; fi ;;
    esac
}

hv_menu_service() {
    local c="" u=""
    hv_service_status
    hv_menu c "服务管理" "选择操作:" \
        restart-all "重启全部(网关 + 面板)" \
        gateway     "网关(gateway)" \
        dashboard   "面板(dashboard)" \
        caddy       "Caddy" \
        logs        "查看日志" \
        back        "返回" || return 0
    case "$c" in
        restart-all) hv_service_restart_all; hv_caddy_reload || true ;;
        gateway|dashboard)
            u="$c"; [[ "$u" == gateway ]] && u=hermes-gateway.service || u=hermes-dashboard.service
            local a=""; hv_menu a "$u" "操作:" start 启动 stop 停止 restart 重启 status 状态 logs 日志 back 返回
            case "$a" in
                start|stop|restart) hv_service_action "$u" "$a" ;;
                status) systemctl status "$u" --no-pager -l | head -n 25 ;;
                logs)   hv_service_logs "$u" 120 ;;
            esac
            ;;
        caddy)
            local a=""; hv_menu a "Caddy" "操作:" reload 重载 status 状态 logs 日志 back 返回
            case "$a" in
                reload) hv_caddy_reload ;;
                status) hv_caddy_status ;;
                logs)   hv_caddy_logs 120 ;;
            esac
            ;;
        logs)
            local w=""; hv_menu w "日志" "选择日志:" gateway 网关 dashboard 面板 caddy Caddy install 部署日志 agent Agent 日志 access 访问日志 back 返回
            [[ -n "$w" && "$w" != back ]] && hv_logs "$w" 120
            ;;
    esac
}

hv_menu_backup() {
    local c=""
    hv_menu c "备份与恢复" "备份目录:$HV_BACKUP_DIR" \
        create "立即备份" list "列出备份" restore "从备份恢复" auto "自动备份开关" back "返回" || return 0
    case "$c" in
        create)  hv_backup_create manual ;;
        list)    hv_backup_list ;;
        restore) hv_backup_restore "" ;;
        auto)
            if systemctl is-enabled hermes-vps-backup.timer >/dev/null 2>&1; then hv_backup_schedule_disable; else hv_backup_schedule_enable; fi
            ;;
    esac
}

hv_menu_update() {
    local c=""
    hv_autoupdate_status
    hv_menu c "更新" "选择操作:" now "立即更新(先自动备份)" auto "自动更新开关" version "查看版本" back "返回" || return 0
    case "$c" in
        now)     hv_update_all ;;
        auto)    if systemctl is-enabled hermes-vps-update.timer >/dev/null 2>&1; then hv_autoupdate_disable; else hv_autoupdate_enable; fi ;;
        version) hv_info "hermes-vps $(hv_version 2>/dev/null || echo "$HV_VERSION") / Hermes $(hv_hermes_version 2>/dev/null || echo 未安装)" ;;
    esac
}

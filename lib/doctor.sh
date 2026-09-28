#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/doctor.sh
# 诊断与状态总览:环境 / Hermes 版本 / 服务 / 端口 / 域名证书 / 平台 / 备份,
# 以及日志查看入口。目标是"一条命令看清整机状态"。
# =============================================================================

[[ -n "${HV_DOCTOR_LOADED:-}" ]] && return 0
HV_DOCTOR_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/detect.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

_hv_mark() { [[ "$1" == "active" ]] && printf '%s' "${HV_C_GREEN}●${HV_C_RESET}" || printf '%s' "${HV_C_RED}○${HV_C_RESET}"; }

hv_status_summary() {
    hv_detect_os
    local ver="未安装"; hv_hermes_installed && ver="$(hv_hermes_version 2>/dev/null || echo 未知)"
    local domain; domain="$(hv_state_get DOMAIN "")"

    hv_rule
    printf '  %s Hermes        : %s\n' "$(hv_hermes_installed && echo "${HV_C_GREEN}●${HV_C_RESET}" || echo "${HV_C_RED}○${HV_C_RESET}")" "$ver"
    printf '  %s 服务用户      : %s(%s)\n' "$(id "$HV_USER" >/dev/null 2>&1 && echo "${HV_C_GREEN}●${HV_C_RESET}" || echo "${HV_C_RED}○${HV_C_RESET}")" "$HV_USER" "$HV_UHOME"
    if hv_has_systemd; then
        local u s
        for u in hermes-gateway.service hermes-dashboard.service caddy.service; do
            s="$(systemctl is-active "$u" 2>/dev/null || echo unknown)"
            printf '  %s %-24s: %s\n' "$(_hv_mark "$s")" "$u" "$s"
        done
    else
        printf '  %s systemd 不可用(无法托管常驻服务)\n' "${HV_C_YELLOW}!${HV_C_RESET}"
    fi
    printf '  %s 面板端口      : %s(127.0.0.1)\n' "$(hv_port_in_use "$HV_DASH_PORT" && echo "${HV_C_GREEN}●${HV_C_RESET}" || echo "${HV_C_YELLOW}○${HV_C_RESET}")" "$HV_DASH_PORT"
    if [[ "$(hv_state_get API_SERVER off)" == "on" ]]; then
        printf '  %s API 端口      : %s(127.0.0.1)\n' "$(hv_port_in_use "$HV_API_PORT" && echo "${HV_C_GREEN}●${HV_C_RESET}" || echo "${HV_C_YELLOW}○${HV_C_RESET}")" "$HV_API_PORT"
    else
        printf '  %s API 端口      : 未启用\n' "${HV_C_DIM}○${HV_C_RESET}"
    fi
    printf '  %s 对外域名      : %s\n' "$([[ -n $domain ]] && echo "${HV_C_GREEN}●${HV_C_RESET}" || echo "${HV_C_YELLOW}○${HV_C_RESET}")" "${domain:-未配置}"

    if [[ -n "$domain" ]]; then
        local code; code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
        if [[ "$code" == "200" ]]; then
            printf '  %s HTTPS 探活    : https://%s/healthz → 200\n' "${HV_C_GREEN}●${HV_C_RESET}" "$domain"
        else
            printf '  %s HTTPS 探活    : 失败(HTTP %s)—— 检查 DNS/80,443/防火墙/云安全组\n' "${HV_C_RED}○${HV_C_RESET}" "$code"
        fi
    fi
    printf '  %s 磁盘可用      : %s MB  内存:%s MB\n' "${HV_C_GREEN}●${HV_C_RESET}" "$HV_DISK_FREE_MB" "$HV_MEM_MB"
    hv_rule
}

hv_doctor() {
    hv_step "hermes-vps 状态总览"
    hv_status_summary

    if hv_hermes_installed; then
        hv_step "官方 hermes doctor 输出(节选)"
        hv_hermes_doctor_capture 2>/dev/null | tail -n 40 | sed 's/^/    /' || hv_warn "hermes doctor 执行失败"
    fi

    hv_step "凭据与访问信息"
    hv_creds_get DASHBOARD_PASSWORD >/dev/null 2>&1 || true
    # shellcheck source=/dev/null
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/webui.sh" 2>/dev/null || true
    declare -f hv_dashboard_check_gate >/dev/null && hv_dashboard_check_gate || true
    declare -f hv_dashboard_show_access >/dev/null && hv_dashboard_show_access || true
    declare -f hv_apiserver_show_access >/dev/null && [[ "$(hv_state_get API_SERVER off)" == "on" ]] && hv_apiserver_show_access || true

    hv_step "镜像与网络加速"
    hv_mirror_show 2>/dev/null || true

    hv_info "常见排障入口:"
    printf '    hermes-vps logs gateway     网关日志\n'
    printf '    hermes-vps logs dashboard   面板日志\n'
    printf '    hermes-vps logs caddy       Caddy 日志\n'
    printf '    hermes-vps domain status    域名与证书状态\n'
}

hv_logs() {
    local what="${1:-gateway}" n="${2:-120}"
    # shellcheck source=/dev/null
    case "$what" in
        gateway)   source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/service.sh"; hv_service_logs hermes-gateway.service "$n" ;;
        dashboard) source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/service.sh"; hv_service_logs hermes-dashboard.service "$n" ;;
        caddy)     source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/caddy.sh"; hv_caddy_logs "$n" ;;
        install)   tail -n "$n" "${HV_LOG_DIR}/${HV_NAME}.log" 2>/dev/null || hv_warn "无安装日志" ;;
        hermes-install) tail -n "$n" "${HV_UHOME}/logs/install.log" 2>/dev/null || hv_warn "无官方安装日志" ;;
        agent)     tail -n "$n" "${HV_UHOME}/logs/agent.log" 2>/dev/null || hv_warn "无 agent 日志(可能还没跑过对话)" ;;
        access)    tail -n "$n" /var/log/caddy/*.access.log 2>/dev/null || hv_warn "无访问日志" ;;
        *) hv_die "未知日志类型:$what(可选 gateway|dashboard|caddy|install|hermes-install|agent|access)" ;;
    esac
}

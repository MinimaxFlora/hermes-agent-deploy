#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/deploy.sh
# 一键部署编排:参数收集 → 环境准备 → 安装 → 模型 → 面板/API → 平台 → 服务
#              → Caddy 域名 → 防火墙 → 总结报告。
# 每一步都幂等,可重复执行;任何一步失败立即停下并打印日志位置。
# =============================================================================

[[ -n "${HV_DEPLOY_LOADED:-}" ]] && return 0
HV_DEPLOY_LOADED=1
_HV_LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${_HV_LIB}/common.sh"
source "${_HV_LIB}/ui.sh"
source "${_HV_LIB}/detect.sh"
source "${_HV_LIB}/deps.sh"
source "${_HV_LIB}/mirror.sh"
source "${_HV_LIB}/account.sh"
source "${_HV_LIB}/hermes.sh"
source "${_HV_LIB}/provider.sh"
source "${_HV_LIB}/platform.sh"
source "${_HV_LIB}/webui.sh"
source "${_HV_LIB}/service.sh"
source "${_HV_LIB}/caddy.sh"
source "${_HV_LIB}/firewall.sh"

# ---------------------------------------------------------------------------
# 参数收集(命令行/配置文件 → 交互补齐)
# 可用的环境变量(与 CLI 参数一一对应):
#   HV_DOMAIN HV_ACME_EMAIL HV_ACME_CA
#   HV_MODEL_PROVIDER HV_MODEL_KEY HV_MODEL_NAME HV_MODEL_BASE_URL
#   HV_PLATFORMS(逗号分隔) HV_WITH_API(1/0) HV_SKIP_BROWSER(1/0)
#   HV_SKIP_FIREWALL(1/0) HV_SKIP_CADDY(1/0) HV_DASH_USER
# ---------------------------------------------------------------------------
hv_deploy_gather_params() {
    hv_step "部署参数"

    if [[ -z "${HV_DOMAIN:-}" ]] && hv_can_interact; then
        hv_ask HV_DOMAIN "对外访问域名(已解析到本机的 A 记录;留空=暂不配域名)" ""
    fi
    if [[ -n "${HV_DOMAIN:-}" ]]; then
        if [[ -z "${HV_ACME_EMAIL:-}" ]] && hv_can_interact; then
            hv_ask HV_ACME_EMAIL "Let's Encrypt 通知邮箱(证书到期/异常通知)" "admin@${HV_DOMAIN}"
        fi
        if ! hv_domain_resolves_to_this_host "$HV_DOMAIN"; then
            hv_warn "域名 $HV_DOMAIN 的解析结果与当前主机 IP 不一致 —— Caddy 申请证书可能失败"
            hv_dim "   请确认 A 记录已指向本机公网 IP;改完后执行 hermes-vps domain apply"
        fi
    else
        hv_info "未指定域名:稍后可执行 'hermes-vps domain set <域名>' 一键接入 Caddy"
    fi

    if [[ -z "${HV_MODEL_PROVIDER:-}" ]] && hv_can_interact; then
        hv_provider_list
        hv_provider_pick HV_MODEL_PROVIDER || true
    fi
    if [[ -n "${HV_MODEL_PROVIDER:-}" && -z "${HV_MODEL_KEY:-}" ]]; then
        local envkey; envkey="$(hv_provider_envkey "$HV_MODEL_PROVIDER" 2>/dev/null || echo "")"
        if [[ -n "$envkey" ]] && hv_can_interact; then
            hv_ask_secret HV_MODEL_KEY "${HV_MODEL_PROVIDER} 的 API Key(${envkey})"
        fi
    fi
    if [[ -z "${HV_MODEL_NAME:-}" ]] && hv_can_interact; then
        local demo; demo="$(hv_provider_model "${HV_MODEL_PROVIDER:-openrouter}" 2>/dev/null || echo "")"
        hv_ask HV_MODEL_NAME "模型名${demo:+ (回车用 ${demo})}" "$demo"
    fi
    if [[ "${HV_MODEL_PROVIDER:-}" == "__custom__" && -z "${HV_MODEL_BASE_URL:-}" ]] && hv_can_interact; then
        hv_ask HV_MODEL_BASE_URL "自定义端点 Base URL(例: http://127.0.0.1:8000/v1)" ""
    fi

    if [[ -z "${HV_PLATFORMS:-}" ]] && hv_can_interact; then
        local args=() id name mode _rest
        while IFS='|' read -r id name mode _rest; do
            args+=("$id" "$name [$mode]" "off")
        done < <(hv_platform_rows)
        hv_multi HV_PLATFORMS "消息平台" "选择要接入的消息平台(空格分隔的编号可多选):" "${args[@]}"
        HV_PLATFORMS="${HV_PLATFORMS// /,}"
    fi

    if [[ -z "${HV_WITH_API:-}" ]] && hv_can_interact; then
        hv_confirm "是否开启 OpenAI 兼容 API(域名/v1,给 OpenWebUI、LobeChat 等用)?" yes \
            && HV_WITH_API=1 || HV_WITH_API=0
    fi
    HV_WITH_API="${HV_WITH_API:-1}"

    hv_rule
    printf '  域名      : %s\n' "${HV_DOMAIN:-未配置}"
    printf '  证书邮箱  : %s\n' "${HV_ACME_EMAIL:-未设置}"
    printf '  模型提供商: %s\n' "${HV_MODEL_PROVIDER:-未选择}"
    printf '  模型      : %s\n' "${HV_MODEL_NAME:-未指定}"
    printf '  消息平台  : %s\n' "${HV_PLATFORMS:-无}"
    printf '  API 服务  : %s\n' "$([[ "$HV_WITH_API" == 1 ]] && echo 开启 || echo 关闭)"
    printf '  浏览器工具: %s\n' "$([[ "${HV_SKIP_BROWSER:-0}" == 1 ]] && echo "不安装" || echo "安装(约 150MB+)")"
    hv_rule
    hv_confirm "按以上参数开始部署?" yes || hv_die "已取消"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
hv_deploy() {
    hv_require_root
    hv_detect_os
    hv_state_init

    hv_step "1/10 环境检查"
    hv_detect_report | sed 's/^/    /'
    hv_detect_precheck || true

    hv_step "2/10 安装基础依赖"
    hv_deps_install_base

    hv_step "3/10 网络加速探测"
    hv_mirror_probe

    hv_step "4/10 部署参数"
    hv_deploy_gather_params

    hv_step "5/10 创建服务用户与目录"
    hv_ensure_user
    hv_ensure_dirs
    hv_mirror_apply_user

    hv_step "6/10 安装 Hermes"
    HV_SKIP_BROWSER="${HV_SKIP_BROWSER:-0}" hv_hermes_install
    hv_hermes_ensure_config
    if [[ "${HV_SKIP_BROWSER:-0}" != "1" ]]; then
        hv_deps_install_browser_libs
    fi

    hv_step "7/10 配置模型提供商"
    if [[ -n "${HV_MODEL_PROVIDER:-}" ]]; then
        hv_provider_apply "$HV_MODEL_PROVIDER" "${HV_MODEL_KEY:-}" "${HV_MODEL_NAME:-}" "${HV_MODEL_BASE_URL:-}"
    else
        hv_warn "未选择提供商,跳过(稍后:hermes-vps model configure)"
    fi

    hv_step "8/10 面板 / API / 消息平台"
    hv_dashboard_configure "${HV_DOMAIN:-}"
    if [[ "$HV_WITH_API" == "1" ]]; then hv_apiserver_configure on; else hv_apiserver_configure off; fi
    if [[ -n "${HV_PLATFORMS:-}" ]]; then
        local p
        local IFS=','
        for p in $HV_PLATFORMS; do
            [[ -n "$p" ]] && hv_platform_configure "$p"
        done
    fi

    hv_step "9/10 常驻服务(dashboard + gateway)"
    hv_service_dashboard_install
    hv_service_gateway_install

    hv_step "10/10 域名与反向代理"
    if [[ -n "${HV_DOMAIN:-}" && "${HV_SKIP_CADDY:-0}" != "1" ]]; then
        hv_caddy_install
        if [[ "${HV_SKIP_FIREWALL:-0}" != "1" ]]; then hv_firewall_setup; fi
        hv_caddy_apply "$HV_DOMAIN" "${HV_ACME_EMAIL:-}" "${HV_ACME_CA:-}"
        hv_dashboard_configure "$HV_DOMAIN"   # 幂等重放,确保 public_url 已写入
    else
        hv_info "跳过 Caddy(未指定域名或 --skip-caddy)"
        [[ "${HV_SKIP_FIREWALL:-0}" != "1" ]] && hv_firewall_setup || true
    fi

    hv_deploy_final_report
}

hv_deploy_final_report() {
    hv_step "部署完成 · 使用信息"
    local domain; domain="$(hv_state_get DOMAIN "")"

    hv_rule
    if [[ -n "$domain" ]]; then
        printf '  管理面板 : https://%s\n' "$domain"
    else
        printf '  管理面板 : http://127.0.0.1:%s(仅本机,或先配域名)\n' "$HV_DASH_PORT"
    fi
    printf '  面板账号 : %s\n' "$(hv_creds_get DASHBOARD_USER "admin")"
    printf '  面板密码 : %s\n' "$(hv_creds_get DASHBOARD_PASSWORD "(未生成)")"
    if [[ "$(hv_state_get API_SERVER off)" == "on" ]]; then
        printf '  API 地址 : %s\n' "$([[ -n $domain ]] && echo "https://${domain}/v1" || echo "http://127.0.0.1:${HV_API_PORT}/v1")"
        printf '  API Key  : %s\n' "$(hv_creds_get API_SERVER_KEY "(未生成)")"
    fi
    printf '  凭据文件 : %s (0600,请妥善保存)\n' "$(hv_creds_file)"
    hv_rule
    hv_info "常用命令:"
    printf '    hermes-vps doctor            状态总览与体检\n'
    printf '    hermes-vps platform status   消息平台状态\n'
    printf '    hermes-vps logs gateway      网关日志\n'
    printf '    hermes-vps model configure   改模型提供商\n'
    printf '    hermes-vps domain apply      改域名/重载 Caddy\n'
    printf '    hermes-vps backup create     备份\n'
    hv_rule
    hv_dim "  面板里的 Config / Channels / Keys 页可直接改配置,改完点重启即可。"
}

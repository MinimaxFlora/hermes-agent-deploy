#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/firewall.sh
# 防火墙:只放行必需端口(SSH / 80 / 443),不动其它规则、不删任何规则。
# 支持 ufw / firewalld / 纯 nft(只提示)。云厂商安全组需要用户在控制台自行放行。
# =============================================================================

[[ -n "${HV_FIREWALL_LOADED:-}" ]] && return 0
HV_FIREWALL_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"

hv_firewall_backend() {
    if hv_have ufw; then printf 'ufw'
    elif hv_have firewall-cmd; then printf 'firewalld'
    elif hv_have nft; then printf 'nft'
    elif hv_have iptables; then printf 'iptables'
    else printf 'none'; fi
}

# 探测 sshd 端口(可能被改成非 22)
hv_ssh_ports() {
    local ports=""
    if [[ -f /etc/ssh/sshd_config ]]; then
        ports="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | sort -u | tr '\n' ' ')"
    fi
    [[ -z "$ports" ]] && ports="22"
    # 正在监听的 ssh 端口(比配置更真实)
    if hv_have ss; then
        local listening
        listening="$(ss -lntp 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')"
        [[ -n "$listening" ]] && ports="$listening"
    fi
    printf '%s' "$ports"
}

hv_firewall_plan() {
    local ssh_ports; ssh_ports="$(hv_ssh_ports)"
    hv_rule
    printf '  防火墙后端 : %s\n' "$(hv_firewall_backend)"
    printf '  SSH 端口   : %s(先放行,避免把自己关在门外)\n' "$ssh_ports"
    printf '  将放行     : 80/tcp、443/tcp(HTTP/HTTPS;Caddy 签发证书与对外访问)\n'
    printf '  不会改动   : 其余任何现有规则\n'
    hv_rule
}

hv_firewall_setup() {
    hv_require_root
    local backend; backend="$(hv_firewall_backend)"
    hv_firewall_plan
    hv_confirm "按上面的方案配置防火墙?" yes || return 0

    local ssh_ports; ssh_ports="$(hv_ssh_ports)"

    case "$backend" in
        ufw)
            local p
            for p in $ssh_ports; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
            ufw allow 80/tcp  >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
            if ! ufw status | grep -q "Status: active"; then
                hv_info "启用 ufw…"
                ufw --force enable >/dev/null 2>&1 || hv_warn "ufw enable 失败"
            fi
            hv_ok "ufw 已放行 SSH(${ssh_ports// /,}) / 80 / 443"
            ufw status numbered 2>/dev/null | head -n 15 | sed 's/^/    /'
            ;;
        firewalld)
            firewall-cmd --permanent --add-service=http  >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
            local p
            for p in $ssh_ports; do
                firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
            done
            firewall-cmd --reload >/dev/null 2>&1 || hv_warn "firewalld reload 失败"
            hv_ok "firewalld 已放行 SSH(${ssh_ports// /,}) / http / https"
            ;;
        nft|iptables)
            hv_warn "检测到 $backend 但没有 ufw/firewalld 管理面"
            hv_info "本工具不会自动改 nft/iptables 规则(风险高)。请手工确认 80/443 已放行:"
            hv_dim "   nft list ruleset | head -n 40"
            ;;
        *)
            hv_info "未检测到防火墙工具,跳过(很多云主机默认全放行,请确认云控制台安全组)"
            ;;
    esac

    hv_state_set FIREWALL "$backend"
    hv_warn "提醒:云厂商安全组(阿里云/腾讯云/AWS 等)需在控制台另行放行 80、443;"
    hv_dim "   可用 'hermes-vps doctor' 里的 HTTPS 探活确认整条链路是否通"
}

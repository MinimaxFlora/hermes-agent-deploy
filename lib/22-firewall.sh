# ---------------------------------------------------------------------------
# 防火墙(只新增放行,绝不删规则)
# ---------------------------------------------------------------------------
fw_backend() {
    if have ufw; then printf 'ufw'
    elif have firewall-cmd; then printf 'firewalld'
    elif have nft; then printf 'nft'
    elif have iptables; then printf 'iptables'
    else printf 'none'; fi
}
ssh_ports() {
    local ports=""
    [[ -f /etc/ssh/sshd_config ]] && ports="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | sort -u | tr '\n' ' ')"
    if have ss; then
        local l; l="$(ss -lntp 2>/dev/null | grep -i sshd | awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ' ')"
        [[ -n "$l" ]] && ports="$l"
    fi
    [[ -z "$ports" ]] && ports="22"
    printf '%s' "$ports"
}
firewall_setup() {
    if [[ "$HV_MODE" != "system" ]]; then escalate_or_skip "防火墙与安全加固" || true; return 0; fi
    require_root "配置防火墙"
    local be; be="$(fw_backend)"; local sp; sp="$(ssh_ports)"
    rule
    printf '    防火墙后端 : %s\n' "$be"
    printf '    SSH 端口   : %s(先放行,避免把自己关在门外)\n' "$sp"
    printf '    将放行     : 80/tcp、443/tcp\n'
    printf '    不会改动   : 其余任何现有规则\n'
    rule
    confirm "按上面的方案配置防火墙?" yes || return 0
    case "$be" in
        ufw)
            local p; for p in $sp; do ufw allow "${p}/tcp" >/dev/null 2>&1 || true; done
            ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true
            ufw status 2>/dev/null | grep -q "Status: active" || ufw --force enable >/dev/null 2>&1 || warn "ufw enable 失败"
            ok "ufw 已放行 SSH(${sp// /,}) / 80 / 443" ;;
        firewalld)
            firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
            firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
            local p; for p in $sp; do firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true; done
            firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld reload 失败"
            ok "firewalld 已放行 SSH(${sp// /,}) / http / https" ;;
        nft|iptables) warn "检测到 $be 但没有 ufw/firewalld 管理面;本工具不改裸规则,请自行确认 80/443 已放行" ;;
        *) info "未检测到防火墙工具,跳过" ;;
    esac
    warn "云厂商安全组(阿里云/腾讯云/AWS 等)需在控制台另行放行 80、443"
    st_set FIREWALL "$be"
}

# ---------------------------------------------------------------------------
# 通用状态探测
# ---------------------------------------------------------------------------
port_listening() {
    local port="$1"
    if have ss; then ss -lntH "sport = :$port" 2>/dev/null | grep -q . && return 0
    elif have netstat; then netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    fi
    return 1
}
svc_state() { systemctl is-active "$1" 2>/dev/null || echo "unknown"; }
svc_enabled() { systemctl is-enabled "$1" 2>/dev/null || echo "unknown"; }
public_ip_v4() {
    local ip="" u
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        ip="$(curl -s4 --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
    done
    return 1
}
domain_points_here() { # 0=是 1=否 2=未知
    local domain="$1" resolved local_ip
    have getent || return 2
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | sed -n '1p')" || resolved=""
    [[ -z "$resolved" ]] && return 1
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | sed -n '1p')"
    case "$local_ip" in
        10.*|127.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|"")
            local pub; pub="$(public_ip_v4 2>/dev/null || true)"; [[ -n "$pub" ]] && local_ip="$pub" ;;
    esac
    [[ "$resolved" == "$local_ip" ]] && return 0
    ip -4 addr show 2>/dev/null | grep -qw "$resolved" && return 0
    return 1
}

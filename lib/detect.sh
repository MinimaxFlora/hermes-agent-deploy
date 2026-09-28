#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/detect.sh
# 环境探测:发行版 / 架构 / init 系统 / 包管理器 / 资源 / 端口 / 已装状态。
# 探测结果写进全局变量 HV_OS_*,供其它模块判断分支,不做任何修改性动作。
# =============================================================================

[[ -n "${HV_DETECT_LOADED:-}" ]] && return 0
HV_DETECT_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

HV_OS_ID=""; HV_OS_LIKE=""; HV_OS_VER=""; HV_OS_NAME=""
HV_ARCH=""; HV_PKG=""; HV_INIT=""; HV_IS_CONTAINER=0
HV_MEM_MB=0; HV_DISK_FREE_MB=0; HV_CPU_CORES=0

hv_detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        HV_OS_ID="${ID:-unknown}"
        HV_OS_LIKE="${ID_LIKE:-}"
        HV_OS_VER="${VERSION_ID:-}"
        HV_OS_NAME="${PRETTY_NAME:-$HV_OS_ID}"
    else
        HV_OS_ID="unknown"; HV_OS_NAME="未知系统"
    fi

    case "$HV_OS_ID" in
        debian|ubuntu|raspbian|linuxmint|pop) HV_PKG="apt" ;;
        fedora|rhel|centos|rocky|almalinux|ol) HV_PKG="dnf" ;;
        alpine) HV_PKG="apk" ;;
        arch|manjaro) HV_PKG="pacman" ;;
        *)
            case " $HV_OS_LIKE " in
                *debian*|*ubuntu*) HV_PKG="apt" ;;
                *rhel*|*fedora*)   HV_PKG="dnf" ;;
                *alpine*)          HV_PKG="apk" ;;
                *arch*)            HV_PKG="pacman" ;;
                *)                 HV_PKG="" ;;
            esac
            ;;
    esac
    hv_have dnf || { [[ "$HV_PKG" == "dnf" ]] && hv_have yum && HV_PKG="yum" || true; }

    HV_ARCH="$(uname -m)"
    case "$HV_ARCH" in
        x86_64|amd64) HV_ARCH="x86_64" ;;
        aarch64|arm64) HV_ARCH="aarch64" ;;
    esac

    if [[ -d /run/systemd/system ]] && hv_have systemctl; then HV_INIT="systemd"
    elif hv_have rc-service; then HV_INIT="openrc"
    else HV_INIT="unknown"; fi

    # 容器检测(systemd 在容器里可能可用,但仍要提醒)
    if [[ -f /.dockerenv ]] || grep -qaE '(docker|containerd|lxc)' /proc/1/cgroup 2>/dev/null; then
        HV_IS_CONTAINER=1
    fi

    HV_CPU_CORES="$(nproc 2>/dev/null || echo 1)"
    HV_MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    HV_DISK_FREE_MB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
}

hv_detect_report() {
    cat <<EOF
系统        : ${HV_OS_NAME} (${HV_OS_ID} ${HV_OS_VER})
架构        : ${HV_ARCH}
包管理器    : ${HV_PKG:-未知}
init        : ${HV_INIT}
CPU / 内存  : ${HV_CPU_CORES} 核 / ${HV_MEM_MB} MB
根分区可用  : ${HV_DISK_FREE_MB} MB
容器环境    : $([[ $HV_IS_CONTAINER == 1 ]] && echo "是(不建议用 systemd 托管服务)" || echo "否")
服务用户    : ${HV_USER}
EOF
}

# 前置检查:不满足就直接给出人话的失败原因
hv_detect_precheck() {
    local fail=0
    if [[ "$HV_ARCH" != "x86_64" && "$HV_ARCH" != "aarch64" ]]; then
        hv_warn "未验证的架构 $HV_ARCH,官方安装脚本可能没有对应产物"
    fi
    if [[ -z "$HV_PKG" ]]; then
        hv_warn "无法识别的包管理器,基础依赖需要你手工安装: curl git tar xz openssl ca-certificates"
        fail=0
    fi
    if [[ "$HV_MEM_MB" -lt 900 ]]; then
        hv_warn "内存仅 ${HV_MEM_MB} MB,建议 >= 1 GB(安装过程需要编译/解包,可能 OOM)"
    fi
    if [[ "$HV_DISK_FREE_MB" -lt 3000 ]]; then
        hv_warn "根分区可用空间仅 ${HV_DISK_FREE_MB} MB,建议 >= 5 GB(含浏览器工具时建议 >= 8 GB)"
    fi
    if [[ "$HV_INIT" != "systemd" ]]; then
        hv_warn "未检测到 systemd,gateway/dashboard 需要你自行用其他方式守护进程"
    fi
    [[ $fail -eq 0 ]]
}

# 端口是否被占用(返回 0 = 已占用)
hv_port_in_use() {
    local port="$1"
    if hv_have ss; then ss -lntH "sport = :$port" 2>/dev/null | grep -q . && return 0
    elif hv_have netstat; then netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
    fi
    return 1
}

hv_port_owner() {
    local port="$1"
    if hv_have ss; then
        ss -lntp "sport = :$port" 2>/dev/null | awk 'NR>1{print $NF}' | head -n1
    fi
}

# 域名解析检查
hv_domain_resolves_to_this_host() {
    local domain="$1"
    hv_have getent || return 2
    local resolved local_ip
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u | head -n1)"
    [[ -z "$resolved" ]] && return 1
    local_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)"
    [[ -z "$local_ip" ]] && local_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$local_ip" && "$resolved" == "$local_ip" ]] && return 0
    # 也可能解析到本机的其它公网 IP
    if ip -4 addr show 2>/dev/null | grep -qw "$resolved"; then return 0; fi
    return 1
}

hv_is_installed() { hv_hermes_installed; }

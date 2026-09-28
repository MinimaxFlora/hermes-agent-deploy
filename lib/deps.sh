#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/deps.sh
# 基础依赖安装(幂等):curl / git / tar / xz / openssl / ca-certificates /
# whiptail(菜单)/ jq(诊断)/ unzip;可选 Chromium 运行库(浏览器工具用)。
# 只安装缺失的包,绝不批量卸载任何东西。
# =============================================================================

[[ -n "${HV_DEPS_LOADED:-}" ]] && return 0
HV_DEPS_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

HV_BASE_CMDS=(curl git tar openssl)
HV_BASE_PKGS_APT=(curl git tar xz-utils openssl ca-certificates whiptail jq unzip rsync)
HV_BASE_PKGS_DNF=(curl git tar xz openssl ca-certificates newt jq unzip rsync)
HV_BASE_PKGS_APK=(curl git tar xz openssl ca-certificates newt jq unzip rsync)
HV_BASE_PKGS_PACMAN=(curl git tar xz openssl ca-certificates libnewt jq unzip rsync)

# Chromium 运行库(仅浏览器工具需要)
HV_BROWSER_PKGS_APT=(
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0
    libcairo2 libasound2 libatspi2.0-0 libx11-xcb1 fonts-liberation
)
HV_BROWSER_PKGS_DNF=(nss nspr atk at-spi2-atk cups-libs libdrm libxkbcommon libXcomposite libXdamage libXfixes libXrandr mesa-libgbm pango cairo alsa-lib at-spi2-core liberation-fonts)

_hv_pkg_install() {
    local -a pkgs=("$@")
    [[ ${#pkgs[@]} -eq 0 ]] && return 0
    case "$HV_PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq || hv_warn "apt-get update 失败,继续尝试安装"
            apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
            ;;
        dnf)    dnf install -y -q "${pkgs[@]}" ;;
        yum)    yum install -y -q "${pkgs[@]}" ;;
        apk)    apk add --no-cache "${pkgs[@]}" ;;
        pacman) pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
        *)      hv_warn "未知包管理器,请手工安装: ${pkgs[*]}"; return 1 ;;
    esac
}

hv_deps_install_base() {
    hv_require_root
    local missing=()
    local c
    for c in "${HV_BASE_CMDS[@]}"; do hv_have "$c" || missing+=("$c"); done
    hv_have whiptail || true   # 菜单依赖,缺失不致命

    if [[ ${#missing[@]} -gt 0 ]]; then
        hv_step "安装基础依赖: ${missing[*]}"
    else
        hv_step "校验基础依赖(已有则跳过)"
    fi

    case "$HV_PKG" in
        apt)    _hv_pkg_install "${HV_BASE_PKGS_APT[@]}" ;;
        dnf|yum) _hv_pkg_install "${HV_BASE_PKGS_DNF[@]}" ;;
        apk)    _hv_pkg_install "${HV_BASE_PKGS_APK[@]}" ;;
        pacman) _hv_pkg_install "${HV_BASE_PKGS_PACMAN[@]}" ;;
    esac

    local still=()
    for c in "${HV_BASE_CMDS[@]}"; do hv_have "$c" || still+=("$c"); done
    if [[ ${#still[@]} -gt 0 ]]; then
        hv_die "以下命令仍不可用: ${still[*]};请手工安装后重试"
    fi
    hv_ok "基础依赖就绪"
}

hv_deps_install_browser_libs() {
    hv_require_root
    case "$HV_PKG" in
        apt) _hv_pkg_install "${HV_BROWSER_PKGS_APT[@]}" ;;
        dnf|yum) _hv_pkg_install "${HV_BROWSER_PKGS_DNF[@]}" ;;
        *) hv_warn "该发行版请参考 Playwright 依赖文档手工安装 Chromium 运行库" ;;
    esac
    hv_ok "Chromium 运行库处理完成"
}

# ---------------------------------------------------------------------------
# 小内存机器保护
# 安装过程(uv 装 Python、编译依赖、解包 Chromium)在 1GB 内存的 VPS 上容易 OOM,
# 表现为 sshd 无响应/进程被 kill。这里在内存偏小且没有 swap 时创建 swapfile。
# ---------------------------------------------------------------------------
hv_swap_total_mb() {
    awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0
}

hv_ensure_swap() {
    hv_require_root
    local mem_mb="${HV_MEM_MB:-0}" want="${HV_SWAP_SIZE_MB:-2048}"
    [[ "$mem_mb" -eq 0 ]] && mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    local have; have="$(hv_swap_total_mb)"

    if [[ "$mem_mb" -ge 1800 ]]; then
        hv_info "内存 ${mem_mb} MB,无需补充 swap"
        return 0
    fi
    if [[ "$have" -ge 512 ]]; then
        hv_info "已有 swap ${have} MB,跳过"
        return 0
    fi

    hv_warn "内存仅 ${mem_mb} MB 且无 swap:安装过程(装 Python/依赖/浏览器工具)容易 OOM"
    if ! hv_confirm "创建 ${want} MB swapfile(/swapfile)以避免安装被 OOM 杀掉?" yes; then
        hv_warn "跳过 swap,若安装中途失联,请检查 dmesg 是否有 oom-kill"
        return 0
    fi

    if [[ -e /swapfile ]]; then
        hv_info "/swapfile 已存在,尝试启用"
        swapon /swapfile 2>/dev/null || hv_warn "swapon /swapfile 失败"
    else
        # 用 fallocate,失败回退 dd(TMPFS/FS 不支持时 fallocate 会失败)
        fallocate -l "${want}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$want" status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile || { hv_err "swapon 失败"; rm -f /swapfile; return 1; }
        hv_ok "已启用 ${want} MB swap(临时文件 /swapfile)"
    fi

    # 持久化(避免重启后失效,影响后续 hermes update)
    if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
        printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
        hv_info "已写入 /etc/fstab,重启后仍生效"
    fi
    # 小内存机器调低 swappiness 之外的默认无必要;这里只做提示
    hv_info "当前 swap:$(hv_swap_total_mb) MB"
}

# 安装前的一站式内存保护:内存偏小时自动处理
hv_deps_guard_memory() {
    local mem_mb="${HV_MEM_MB:-0}"
    if [[ "$mem_mb" -eq 0 ]]; then
        mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
        HV_MEM_MB="$mem_mb"
    fi
    if [[ "$mem_mb" -lt 1800 ]]; then
        hv_ensure_swap
    fi
    return 0
}

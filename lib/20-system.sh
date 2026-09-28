# =============================================================================
#  环境探测 · 依赖 · 内存保护 · 网络加速 · 防火墙
# =============================================================================

detect_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; OS_VER="${VERSION_ID:-}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
    else
        OS_ID="unknown"; OS_NAME="未知系统"
    fi
    case "$OS_ID" in
        debian|ubuntu|raspbian|linuxmint|pop) PKG="apt" ;;
        fedora|rhel|centos|rocky|almalinux|ol) PKG="dnf" ;;
        alpine) PKG="apk" ;;
        arch|manjaro) PKG="pacman" ;;
        *)
            case " $OS_LIKE " in
                *debian*|*ubuntu*) PKG="apt" ;;
                *rhel*|*fedora*)   PKG="dnf" ;;
                *alpine*)          PKG="apk" ;;
                *arch*)            PKG="pacman" ;;
                *)                 PKG="" ;;
            esac ;;
    esac
    ARCH="$(uname -m)"; [[ "$ARCH" == "amd64" ]] && ARCH="x86_64"; [[ "$ARCH" == "arm64" ]] && ARCH="aarch64"
    if [[ -d /run/systemd/system ]] && have systemctl; then INIT="systemd"; else INIT="unknown"; fi
    CORES="$(nproc 2>/dev/null || echo 1)"
    MEM_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
    DISK_MB="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}' || echo 0)"
    if [[ -z "$DISK_MB" ]]; then DISK_MB=0; fi
    return 0
}

pkg_install() {
    local -a pkgs=("$@"); [[ ${#pkgs[@]} -eq 0 ]] && return 0
    case "$PKG" in
        apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq || warn "apt-get update 失败"; apt-get install -y -qq --no-install-recommends "${pkgs[@]}" ;;
        dnf) dnf install -y -q "${pkgs[@]}" ;;
        yum) yum install -y -q "${pkgs[@]}" ;;
        apk) apk add --no-cache "${pkgs[@]}" ;;
        pacman) pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
        *) warn "未知包管理器,请手工安装:${pkgs[*]}"; return 1 ;;
    esac
}

deps_install() {
    if [[ "$HV_MODE" != "system" ]]; then
        # 用户态:装不了系统包,只检查并提示管理员
        local -a miss=()
        local b; for b in curl git tar openssl; do have "$b" || miss+=("$b"); done
        if [[ ${#miss[@]} -eq 0 ]]; then ok "基础依赖齐备(用户态不需要系统包)"
        else warn "缺少系统命令:${miss[*]}"; dim "请管理员执行:sudo apt-get install -y ${miss[*]}"; fi
        return 0
    fi
    require_root "安装系统依赖"
    local -a pkgs=()
    case "$PKG" in
        apt)    pkgs=(curl git tar xz-utils openssl ca-certificates jq unzip) ;;
        dnf|yum) pkgs=(curl git tar xz openssl ca-certificates jq unzip) ;;
        apk)    pkgs=(curl git tar xz openssl ca-certificates jq unzip) ;;
        pacman) pkgs=(curl git tar xz openssl ca-certificates jq unzip) ;;
    esac
    step "安装基础依赖"
    [[ ${#pkgs[@]} -gt 0 ]] && pkg_install "${pkgs[@]}" || true
    local c
    for c in curl git tar openssl; do have "$c" || die "缺少命令 $c,请手工安装后重试"; done
    ok "基础依赖就绪"
}

browser_libs_install() {
    case "$PKG" in
        apt) pkg_install libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 libcairo2 libasound2 libatspi2.0-0 libx11-xcb1 fonts-liberation ;;
        dnf|yum) pkg_install nss nspr atk at-spi2-atk cups-libs libdrm libxkbcommon libXcomposite libXdamage libXfixes libXrandr mesa-libgbm pango cairo alsa-lib at-spi2-core liberation-fonts ;;
        *) warn "该发行版请参考 Playwright 文档手工装 Chromium 运行库" ;;
    esac
    return 0
}

# 小内存保护:1GB 机器装 Python/打包前端会被 OOM killer 杀掉
swap_total_mb() { awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
ensure_swap() {
    if [[ "$HV_MODE" != "system" ]]; then
        [[ "${MEM_MB:-0}" -lt 1800 ]] && dim "用户态:补 swap 需要 root,已跳过(小内存机器建议让管理员加 swap)"
        return 0
    fi
    require_root "创建 swap 文件"
    local want="${SWAP_MB:-2048}" have_mb
    have_mb="$(swap_total_mb)"
    if [[ "${MEM_MB:-0}" -ge 1800 ]]; then info "内存 ${MEM_MB}MB,无需补充 swap"; return 0; fi
    if [[ "$have_mb" -ge 512 ]]; then info "已有 swap ${have_mb}MB,跳过"; return 0; fi
    warn "内存仅 ${MEM_MB}MB 且无 swap:安装时容易 OOM(会被内核直接杀掉)"
    confirm "创建 ${want}MB swapfile 以避免安装中断?" yes || { warn "已跳过,若安装中途失败请看 dmesg | grep -i oom-kill"; return 0; }
    if [[ -e /swapfile ]]; then swapon /swapfile 2>/dev/null || warn "swapon /swapfile 失败"
    else
        fallocate -l "${want}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$want" status=none
        chmod 600 /swapfile; mkswap /swapfile >/dev/null
        swapon /swapfile || { err "swapon 失败"; rm -f /swapfile; return 1; }
        ok "已启用 ${want}MB swap"
    fi
    grep -q '^/swapfile' /etc/fstab 2>/dev/null || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    return 0
}

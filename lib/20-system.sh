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
        # 官方自带 node 运行时需要 libatomic.so.1:用户态装不了系统包,必须现在讲清楚,
        # 否则要等官方安装脚本跑到 pm install 才失败(真机:Debian 12 最小安装就缺这个)
        if ldconfig -p 2>/dev/null | grep -q "libatomic\.so\.1"; then
            ok "运行库检查通过(libatomic.so.1 存在)"
        else
            warn "缺少 libatomic.so.1(官方自带的 node 运行时需要,缺了会在安装到一半时失败)"
            dim "请管理员先执行:sudo apt-get install -y libatomic1(Debian/Ubuntu)"
            dim "           或:sudo dnf install -y libatomic(RHEL/CentOS)"
        fi
        return 0
    fi
    require_root "安装系统依赖"
    local -a pkgs=()
    case "$PKG" in
        # libatomic1/libstdc++6:官方工具自带的 node 运行时依赖 libatomic.so.1,
        # Debian 12 最小安装默认没有 —— 缺了会在官方脚本的 "pm install" 阶段才炸
        # (node 校验失败 → pm install failed → 退出 1),白等十几分钟。真机踩过。
        apt)    pkgs=(curl git tar xz-utils openssl ca-certificates jq unzip gnupg libatomic1 libstdc++6) ;;
        dnf|yum) pkgs=(curl git tar xz openssl ca-certificates jq unzip gnupg2 libatomic) ;;
        apk)    pkgs=(curl git tar xz openssl ca-certificates jq unzip gnupg) ;;
        pacman) pkgs=(curl git tar xz openssl ca-certificates jq unzip gnupg) ;;
    esac
    step "安装基础依赖"
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        if ! pkg_install "${pkgs[@]}"; then
            warn "系统包安装失败(可能是内存不足或软件源不可用),继续检查已有命令"
            dim "可手动执行:apt-get update && apt-get install -y ${pkgs[*]}"
        fi
    fi
    local c
    for c in curl git tar openssl; do have "$c" || die "缺少命令 $c,请手工安装后重试"; done
    if ! ldconfig -p 2>/dev/null | grep -q "libatomic\.so\.1"; then
        warn "libatomic.so.1 仍缺失(官方 node 运行时依赖):安装可能停在 pm install 阶段"
        dim "手动修复:apt-get install -y libatomic1 或 dnf install -y libatomic"
    fi
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

# 小内存保护:1GB 机器装依赖/解压镜像会被 OOM killer 杀掉
swap_total_mb() { awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
swap_active() { swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; }
ensure_swap() {
    if [[ "$HV_MODE" != "system" ]]; then
        [[ "${MEM_MB:-0}" -lt 1800 ]] && dim "用户态:补 swap 需要 root,已跳过(小内存机器建议让管理员加 swap)"
        return 0
    fi
    require_root "创建 swap 文件"
    local want="${SWAP_MB:-2048}" have_mb free_mb
    have_mb="$(swap_total_mb)"
    if [[ "${MEM_MB:-0}" -ge 1800 ]]; then info "内存 ${MEM_MB}MB,无需补充 swap"; return 0; fi
    if [[ "$have_mb" -ge 512 ]]; then info "已有 swap ${have_mb}MB,跳过"; return 0; fi
    if [[ "${NO_SWAP:-0}" == "1" ]]; then
        warn "已按 NO_SWAP=1 跳过 swap(小内存机器可能 OOM)"
        return 0
    fi

    # 小内存机器默认自动创建,不再等待用户确认(否则还没走到这一步就被 OOM 杀了)
    warn "内存仅 ${MEM_MB}MB 且无 swap:先自动创建 ${want}MB swapfile,避免安装中途被内核杀掉"
    free_mb="$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')" || free_mb=0
    [[ -z "$free_mb" ]] && free_mb=0
    if [[ "$free_mb" -lt $((want + 512)) ]]; then
        want=$((free_mb - 256))
        if [[ "$want" -lt 512 ]]; then
            err "磁盘剩余不足(可用 ${free_mb}MB),无法创建 swapfile"
            return 1
        fi
        warn "磁盘剩余 ${free_mb}MB,swap 降为 ${want}MB"
    fi

    if swap_active; then
        ok "swap 已启用:${have_mb}MB"
        return 0
    fi

    # 已有 /swapfile 但没启用:先尝试启用,失败则重建
    if [[ -e /swapfile ]]; then
        if swapon /swapfile 2>/dev/null; then
            ok "已启用现有 /swapfile"
        else
            swapoff /swapfile 2>/dev/null || true
            rm -f /swapfile
        fi
    fi

    if [[ ! -e /swapfile ]]; then
        if ! fallocate -l "${want}M" /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count="$want" status=none || { err "创建 swapfile 失败"; rm -f /swapfile; return 1; }
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { err "mkswap 失败"; rm -f /swapfile; return 1; }
        swapon /swapfile || { err "swapon 失败"; return 1; }
        ok "已启用 ${want}MB swap"
    fi
    grep -q '^/swapfile' /etc/fstab 2>/dev/null || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
    [[ "${MEM_MB:-0}" -lt 1200 ]] && dim "1GB 机器运行 Docker 镜像会偏慢;swap 已作为兜底"
    return 0
}

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

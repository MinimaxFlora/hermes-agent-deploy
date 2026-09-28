#!/usr/bin/env bash
# =============================================================================
#  install.sh —— 从 GitHub Release 安装 / 升级 hermes-vps
#
#  一条命令:
#     curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
#
#  也可以:
#     bash install.sh --check                只看当前版本与最新版本
#     bash install.sh --version v1.0.0       安装指定版本
#     bash install.sh --to ~/bin             安装到自定义目录
#     bash install.sh --user                 装到 ~/.local/bin(普通用户,不需要 root)
#     bash install.sh --system               装到 /usr/local/bin(root 用)
#     bash install.sh --dry-run              只解析并下载,不安装
#
#  运行模式:工具本身两种身份都支持 —— root 跑 = 系统级(专用服务用户 +
#    systemd 系统服务 + /etc 配置 + Caddy 80/443);普通用户跑 = 用户态
#    (全部落在 $HOME,服务用 systemd --user,不可用时退回后台进程)。
#
#  说明:脚本本体由 GitHub Actions 在打 tag 时构建并上传到 Release,
#        仓库里只有模块化源码(lib/ + bin/),发布产物是自包含单文件。
# =============================================================================
set -Eeuo pipefail

REPO="${HV_REPO:-MinimaxFlora/hermes-agent-deploy}"
ASSET="hermes-vps.sh"
API="https://api.github.com/repos/${REPO}/releases"
WANT_VERSION=""
DEST_DIR=""
DRY_RUN=0
CHECK_ONLY=0
YES=0

C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_DIM=$'\033[2m'; C_BD=$'\033[1m'; C_N=$'\033[0m'
[[ -t 1 ]] || { C_OK=""; C_BAD=""; C_DIM=""; C_BD=""; C_N=""; }
info() { printf '  %s·%s %s\n' "$C_DIM" "$C_N" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_OK" "$C_N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$C_BAD" "$C_N" "$*" >&2; }
die()  { bad "$*"; exit 1; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-V) WANT_VERSION="${2:-}"; shift 2 ;;
        --to|-d) DEST_DIR="${2:-}"; shift 2 ;;
        --user) DEST_DIR="${HOME}/.local/bin"; shift ;;
        --system) DEST_DIR="/usr/local/bin"; shift ;;
        --repo) REPO="${2:-}"; API="https://api.github.com/repos/${REPO}/releases"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        -y|--yes) YES=1; shift ;;
        -h|--help) usage ;;
        *) die "未知参数:$1(用 --help 查看用法)" ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }
need_curl() { have curl || die "缺少 curl"; }

json_tag() { # 从 GitHub API 响应里取第一个 tag_name(不依赖 jq)
    grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

resolve_version() {
    if [[ -n "$WANT_VERSION" ]]; then printf '%s' "$WANT_VERSION"; return 0; fi
    local tag=""
    tag="$(curl -fsSL --max-time 20 "${API}/latest" 2>/dev/null | json_tag)" || tag=""
    if [[ -z "$tag" ]]; then
        info "latest 接口不可用,改用 release 列表"
        tag="$(curl -fsSL --max-time 20 "${API}?per_page=20" 2>/dev/null | json_tag)" || tag=""
    fi
    if [[ -z "$tag" ]]; then
        die "无法获取最新版本(检查网络,或用 --version vX.Y.Z 指定)"
    fi
    printf '%s' "$tag"
}

installed_version() {
    local bin="$1"
    [[ -x "$bin" ]] || return 1
    "$bin" version 2>/dev/null | awk '{print $NF}'
}

default_dest() {
    if [[ -n "$DEST_DIR" ]]; then printf '%s' "$DEST_DIR"
    elif [[ "$(id -u)" -eq 0 ]]; then printf '/usr/local/bin'
    else printf '%s/.local/bin' "$HOME"; fi
}

main() {
    need_curl
    printf '\n  %shermes-vps 安装器%s  %s(%s)%s\n\n' "$C_BD" "$C_N" "$C_DIM" "$REPO" "$C_N"

    local dest target current
    dest="$(default_dest)"

    if [[ $CHECK_ONLY -eq 1 ]]; then
        target="$(resolve_version)"
        current="$(installed_version "$dest/hermes-vps" || true)"
        info "已安装:${current:-无}"
        info "最新版:$target"
        [[ -n "$current" && "v$current" == "$target" ]] && ok "已是最新" || info "可升级:bash install.sh"
        return 0
    fi

    local tag url tmp sha_url
    tag="$(resolve_version)"
    [[ "$tag" == v* ]] || tag="v$tag"
    url="https://github.com/${REPO}/releases/download/${tag}/${ASSET}"
    sha_url="${url}.sha256"
    info "目标版本:$tag"

    tmp="$(mktemp)" || die "无法创建临时文件"
    trap 'rm -f "${tmp:-}"' EXIT

    info "下载 $url"
    curl -fL --retry 3 --retry-delay 2 --max-time 300 -o "$tmp" "$url" \
        || die "下载失败:$url(该版本可能还没构建完成)"

    # 若 Release 附带校验文件,则强制校验
    if curl -fsSL --max-time 30 -o "${tmp}.sha256" "$sha_url" 2>/dev/null; then
        local want got
        want="$(awk '{print $1}' "${tmp}.sha256" | tr -d '\r')"
        got="$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$tmp" | awk '{print $1}')"
        if [[ -n "$want" && "$want" != "$got" ]]; then
            die "校验失败:期望 ${want:0:16}… 实际 ${got:0:16}…(已中止安装)"
        fi
        ok "sha256 校验通过(${got:0:16}…)"
    else
        info "Release 未提供 .sha256,跳过校验"
    fi

    bash -n "$tmp" || die "下载到的文件不是合法 bash 脚本"
    local ver
    ver="$(bash "$tmp" version 2>/dev/null | awk '{print $NF}')" || ver=""
    [[ -n "$ver" ]] && ok "脚本自检通过,版本 $ver"

    if [[ $DRY_RUN -eq 1 ]]; then
        ok "dry-run:已下载到 $tmp(按需保留),未安装"
        trap - EXIT
        return 0
    fi

    mkdir -p "$dest" || die "无法创建目录 $dest"
    if [[ ! -w "$dest" ]]; then
        die "$dest 不可写(需要 root 或改用 --to ~/.local/bin)"
    fi
    local current_before=""
    current_before="$(installed_version "$dest/hermes-vps" || true)"

    if [[ -x "$dest/hermes-vps" && $YES -eq 0 && -t 0 ]]; then
        printf '  已存在 %s(%s),覆盖安装? [Y/n] ' "$dest/hermes-vps" "${current_before:-未知}"
        read -r a || a=""
        [[ "$a" =~ ^[Nn] ]] && { info "已取消"; return 0; }
    fi

    install -m 755 "$tmp" "$dest/hermes-vps" || die "写入 $dest/hermes-vps 失败"
    ok "已安装:$dest/hermes-vps$( [[ -n "$current_before" ]] && printf '(%s → %s)' "$current_before" "$ver" || printf '(%s)' "$ver")"

    printf '\n  %s下一步%s\n' "$C_BD" "$C_N"
    if [[ "$dest" == "/usr/local/bin" ]] || [[ ":$PATH:" == *":$dest:"* ]]; then
        printf '    %s输入 %shermes-vps%s 打开菜单(首次部署选 1)%s\n' "$C_DIM" "$C_BD" "$C_N" "$C_DIM"
    else
        printf '    %s把 %s 加入 PATH,然后运行 hermes-vps%s\n' "$C_DIM" "$dest" "$C_N"
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        printf '    %s当前是 root:直接部署即系统级(专用服务用户 + 系统服务 + 域名 HTTPS)%s\n' "$C_DIM" "$C_N"
    else
        printf '    %s当前是普通用户:直接用即可走用户态(全部落在 $HOME)%s\n' "$C_DIM" "$C_N"
        printf '    %s需要域名/HTTPS(80/443)、防火墙等系统级能力时,再用 sudo hermes-vps%s\n' "$C_DIM" "$C_N"
    fi
    printf '\n'
}

main

#!/usr/bin/env bash
# =============================================================================
#  Hermes Agent · VPS 一键部署与管理(单文件版)
#
#  一个脚本搞定:安装 Hermes → 配置模型 → 接入 QQ/微信等消息平台
#  → Caddy 自动 HTTPS 域名访问 → systemd 常驻 → 自检/备份/更新/卸载
#
#  用法:
#     bash hermes-vps.sh              纯文本交互菜单(推荐)
#     bash hermes-vps.sh install      无人值守部署(配合 --yes 等参数)
#     bash hermes-vps.sh help         全部子命令
#
#  运行环境:Debian / Ubuntu(amd64 / arm64),root 权限
#  仓库/文档:见同目录 README.md
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "需要 bash >= 4(当前 $BASH_VERSION)" >&2; exit 1; fi

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 路径与常量
# ---------------------------------------------------------------------------
V="1.0.0-single"
SELF="${BASH_SOURCE[0]}"
SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"

ETC_DIR="/etc/hermes-vps"
STATE_FILE="$ETC_DIR/state.env"
MIRROR_FILE="$ETC_DIR/mirror.env"
CRED_FILE="$ETC_DIR/credentials.txt"
TOOL_LOG_DIR="/var/log/hermes-vps"
BACKUP_DIR="/var/backups/hermes-vps"

HUSER="hermes"                 # 服务用户
HHOME="/opt/hermes"            # 服务用户家目录
UHOME="/opt/hermes/.hermes"    # HERMES_HOME
HBIN="/opt/hermes/.local/bin/hermes"

DASH_PORT="${DASH_PORT:-9119}"
API_PORT="${API_PORT:-8642}"

CADDYFILE="/etc/caddy/Caddyfile"
CADDY_LOG_DIR="/var/log/caddy"
CADDY_BIN="/usr/local/bin/caddy"

OFFICIAL_INSTALL="https://hermes-agent.nousresearch.com/install.sh"
REPO_URL="https://github.com/NousResearch/hermes-agent.git"

NONINTERACTIVE="${NONINTERACTIVE:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
DEBUG_ON="${DEBUG_ON:-0}"
SKIP_BROWSER="${SKIP_BROWSER:-0}"

# 运行期探测结果(供各函数使用)
OS_ID=""; OS_LIKE=""; OS_VER=""; OS_NAME=""; ARCH=""; PKG=""; INIT=""
MEM_MB=0; DISK_MB=0; CORES=0

# ---------------------------------------------------------------------------
# 颜色与符号
# ---------------------------------------------------------------------------
if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'
    C=$'\033[36m'; M=$'\033[35m'; W=$'\033[37m'; BD=$'\033[1m'; DM=$'\033[2m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; C=""; M=""; W=""; BD=""; DM=""; N=""
fi
OK_SYM="${G}✔${N}"; NO_SYM="${R}✘${N}"; WARN_SYM="${Y}!${N}"; DOT_ON="${G}●${N}"; DOT_OFF="${R}○${N}"; DOT_MID="${Y}◐${N}"

# ---------------------------------------------------------------------------
# 日志与错误
# ---------------------------------------------------------------------------
LOG_FILE="${TOOL_LOG_DIR}/hermes-vps.log"
_log() {
    local lv="$1"; shift
    local line; line="$(date '+%Y-%m-%d %H:%M:%S') [$lv] $*"
    if mkdir -p "$TOOL_LOG_DIR" 2>/dev/null; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
    return 0
}
info() { _log INFO "$*"; printf '  %s %s\n' "${B}·${N}" "$*"; }
ok()   { _log OK   "$*"; printf '  %s %s\n' "$OK_SYM" "$*"; }
warn() { _log WARN "$*"; printf '  %s %s\n' "$WARN_SYM" "$*" >&2; }
err()  { _log ERR  "$*"; printf '  %s %s\n' "$NO_SYM" "$*" >&2; }
dim()  { printf '  %s%s%s\n' "$DM" "$*" "$N"; }
step() { printf '\n  %s%s%s\n' "$BD$C" "▶ $*" "$N"; }
die()  { err "$*"; exit 1; }

on_error() {
    local code=$? line="${1:-?}" cmd="${2:-?}"
    [[ $code -eq 0 ]] && return 0
    # 只在 errexit 生效时当作致命错误;set +e 的容错路径交给调用方
    case "$-" in *e*) : ;; *) return 0 ;; esac
    err "执行失败(退出码 ${code})  位置:${SELF##*/}:${line}  命令:${cmd}"
    [[ -f "$LOG_FILE" ]] && err "完整日志:$LOG_FILE"
    exit "$code"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

have() { command -v "$1" >/dev/null 2>&1; }
require_root() { [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限。请用: sudo bash $SELF ${*:-}"; }
interactive() { [[ "$NONINTERACTIVE" == "1" ]] && return 1; [[ -t 0 && -t 1 ]]; }

random_str() {
    local n="${1:-16}" out=""
    have openssl && out="$(openssl rand -base64 96 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$n" 2>/dev/null)" || out=""
    [[ -z "$out" ]] && out="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" 2>/dev/null)" || out=""
    printf '%s' "$out"
}
random_hex() {
    local n="${1:-32}" out=""
    have openssl && out="$(openssl rand -hex "$n" 2>/dev/null)" || out=""
    [[ -z "$out" ]] && out="$(head -c "$n" /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')" || out=""
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 输入原语(纯文本,无 whiptail)
# ---------------------------------------------------------------------------
pause() {
    interactive || return 0
    printf '\n  %s按回车返回菜单…%s' "$DM" "$N"
    read -r _ || true
}
ask() { # ask <变量名> <提示> [默认值]
    local __v="$1" prompt="$2" def="${3:-}" val=""
    if interactive; then
        if [[ -n "$def" ]]; then printf '  %s%s %s[%s]%s: ' "$BD" "$prompt" "$DM" "$def" "$N"
        else printf '  %s%s%s: ' "$BD" "$prompt" "$N"; fi
        read -r val || true
    fi
    [[ -z "$val" ]] && val="$def"
    printf -v "$__v" '%s' "$val"
}
ask_secret() { # 隐藏输入
    local __v="$1" prompt="$2" val=""
    if interactive; then
        printf '  %s%s%s: ' "$BD" "$prompt" "$N"
        read -r -s val || true; printf '\n'
    fi
    printf -v "$__v" '%s' "$val"
}
confirm() { # confirm <提示> [yes|no]
    local prompt="$1" def="${2:-no}"
    [[ "$ASSUME_YES" == "1" ]] && { info "$prompt → 已按 --yes 自动确认"; return 0; }
    interactive || { [[ "$def" == "yes" ]]; return $?; }
    local hint="y/N"; [[ "$def" == "yes" ]] && hint="Y/n"
    local a=""; printf '  %s%s [%s]: %s' "$BD" "$prompt" "$hint" "$N"; read -r a || true
    [[ -z "$a" ]] && { [[ "$def" == "yes" ]]; return $?; }
    [[ "$a" =~ ^[Yy] ]]
}
menu_choice() { # echo 用户输入;HV_EOF=1 表示输入流已结束(EOF)
    local __v="$1" prompt="${2:-请输入编号}"
    local a=""
    HV_EOF=0
    if interactive; then
        printf '  %s%s%s: ' "$BD" "$prompt" "$N"
        read -r a || { HV_EOF=1; a=""; }
    fi
    printf -v "$__v" '%s' "$a"
    return 0
}

# ---------------------------------------------------------------------------
# 键值存储(.env / 状态 / 凭据)
# ---------------------------------------------------------------------------
kv_set() {
    local file="$1" key="$2" val="$3"
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || : >"$file"
    chmod 600 "$file" 2>/dev/null || true
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"; sed -E "s|^[[:space:]]*(export[[:space:]]+)?${key}=.*|${key}=${val}|" "$file" >"$tmp"
        cat "$tmp" >"$file"; rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$val" >>"$file"
    fi
}
kv_get() {
    local file="$1" key="$2" def="${3:-}" v="" line=""
    if [[ -f "$file" ]]; then
        line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1)" || line=""
        if [[ -n "$line" ]]; then
            v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        fi
    fi
    if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$def"; fi
    return 0
}
kv_del() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp; tmp="$(mktemp)"; grep -vE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" >"$tmp" || true
    cat "$tmp" >"$file"; rm -f "$tmp"
}
state_init() { mkdir -p "$ETC_DIR" "$TOOL_LOG_DIR" "$BACKUP_DIR"; [[ -f "$STATE_FILE" ]] || { : >"$STATE_FILE"; chmod 600 "$STATE_FILE"; }; }
st_set() { state_init; kv_set "$STATE_FILE" "$1" "$2"; }
st_get() { kv_get "$STATE_FILE" "$1" "${2:-}"; }
# API 开关:兼容旧版 state 里的 API_SERVER=on
st_api_enabled() {
    local v; v="$(st_get API_ENABLED)"
    if [[ -z "$v" ]]; then
        local o; o="$(st_get API_SERVER)"
        case "$o" in on|1|true|yes) v=1 ;; *) v=0 ;; esac
    fi
    printf '%s' "$v"
    return 0
}
cred_set() { mkdir -p "$ETC_DIR"; kv_set "$CRED_FILE" "$1" "$2"; chmod 600 "$CRED_FILE"; }
cred_get() { kv_get "$CRED_FILE" "$1" "${2:-}"; }

env_file() { printf '%s/.env' "$UHOME"; }
env_set() { kv_set "$(env_file)" "$1" "$2"; chown "$HUSER:$HUSER" "$(env_file)" 2>/dev/null || true; chmod 600 "$(env_file)"; }
env_get() { kv_get "$(env_file)" "$1" "${2:-}"; }
env_del() { kv_del "$(env_file)" "$1"; }

# 改动前备份文件(保留 5 份)
backup_file() {
    local f="$1"; [[ -f "$f" ]] || return 0
    local d="${f%/*}/.bak"; mkdir -p "$d"
    cp -p "$f" "$d/$(basename "$f").$(date +%Y%m%d%H%M%S)"
    ls -1t "$d" 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$d/$old"; done
}

# ---------------------------------------------------------------------------
# 以服务用户身份执行
# ---------------------------------------------------------------------------
run_as_user_env() { # run_as_user_env <user> [KEY=VAL…] -- cmd args…
    local user="$1"; shift
    local home; home="$(getent passwd "$user" | cut -d: -f6)"
    [[ -n "$home" ]] || die "用户不存在:$user"
    local env_args=("HOME=$home" "PATH=${home}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "TERM=xterm")
    local extra=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    if [[ -f "$MIRROR_FILE" ]]; then
        local k v
        while IFS='=' read -r k v; do
            [[ -z "$k" || "$k" == \#* ]] && continue
            env_args+=("$k=$v")
        done <"$MIRROR_FILE"
    fi
    env_args+=("${extra[@]}")
    env -i "${env_args[@]}" su -s /bin/bash "$user" -c "$(printf '%q ' "$@")"
}
run_as_user() { local u="$1"; shift; run_as_user_env "$u" -- "$@"; }
hh() { # 以 hermes 用户运行 hermes 子命令(自动带 HERMES_HOME)
    run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" "$@"
}
hcfg() { # 写 config.yaml:一律走官方 CLI
    hh config set "$1" "$2" >/dev/null 2>&1 || { warn "config set 失败:$1"; return 1; }
    info "配置已写入:$1 = $2"
}
hcfg_get() { hh config get "$1" 2>/dev/null | tr -d '\r' | sed -n '1p'; }

# 服务用户侧的启动器(交互式向导/扫码要继承 TTY,不能走 env -i)
write_runners() {
    local dir="$UHOME/bin"
    install -d -o "$HUSER" -g "$HUSER" -m 755 "$dir" 2>/dev/null || mkdir -p "$dir"
    cat >"$dir/hermes-run" <<EOS
#!/bin/sh
HOME=$HHOME
HERMES_HOME=$UHOME
PATH=$HHOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME HERMES_HOME PATH
[ -f $MIRROR_FILE ] && { set -a; . $MIRROR_FILE; set +a; }
exec $HBIN "\$@"
EOS
    chmod 755 "$dir/hermes-run"; chown "$HUSER:$HUSER" "$dir/hermes-run" 2>/dev/null || true
}
run_interactive_as_user() { # 保持 TTY:用于官方 setup 向导(微信扫码等)
    write_runners
    su -s /bin/bash "$HUSER" -c "$(printf '%q ' "$@")"
}

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
    require_root
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
    require_root
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

# ---------------------------------------------------------------------------
# 网络加速(国内 VPS:GitHub / PyPI)
# ---------------------------------------------------------------------------
GH_PREFIX_CANDIDATES=("" "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/" "https://gh.llkk.cc/" "https://github.moeyy.xyz/")
PYPI_CANDIDATES=("https://pypi.tuna.tsinghua.edu.cn/simple" "https://mirrors.aliyun.com/pypi/simple" "https://mirrors.cloud.tencent.com/pypi/simple" "https://mirrors.ustc.edu.cn/pypi/simple" "https://pypi.org/simple")

_probe() { # 返回 "<code> <time>"
    local url="$1" t="${2:-8}" out
    out="$(curl -sSL -o /dev/null -m "$t" -w '%{http_code} %{time_total}' -r 0-65536 "$url" 2>/dev/null)" || out="000 99"
    [[ -z "$out" ]] && out="000 99"
    printf '%s' "$out"
}
_probe_ok() { [[ "${1%% *}" =~ ^(200|206|301|302|403|416)$ ]]; }

mirror_probe() {
    local force="${1:-0}"
    if [[ "$force" != "1" && -f "$MIRROR_FILE" ]]; then
        info "已有加速配置($MIRROR_FILE);重新测速: mirror probe --force"
        return 0
    fi
    local probe="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md"
    local p url res t best="" bestt=99
    step "探测 GitHub 通道"
    for p in "${GH_PREFIX_CANDIDATES[@]}"; do
        if [[ -z "$p" ]]; then url="$probe"; else url="${p}${probe}"; fi
        res="$(_probe "$url" 8)"; t="${res##* }"
        if _probe_ok "$res" && awk -v a="$t" -v b="$bestt" 'BEGIN{exit !(a<b)}'; then best="$p"; bestt="$t"; fi
        dim "$([[ -z $p ]] && echo 直连 || echo "$p") → HTTP ${res%% *} / ${t}s"
    done
    if [[ -z "$best" && "$bestt" == "99" ]]; then warn "所有 GitHub 通道均不可用,安装可能失败"; return 1; fi
    ok "GitHub 通道:$([[ -z $best ]] && echo 直连 || echo "$best")(${bestt}s)"
    GH_PREFIX="$best"

    step "探测 Python 包索引"
    local u bestp="" bestpt=99
    for u in "${PYPI_CANDIDATES[@]}"; do
        res="$(_probe "${u%/}/pip/" 8)"; t="${res##* }"
        if _probe_ok "$res" && awk -v a="$t" -v b="$bestpt" 'BEGIN{exit !(a<b)}'; then bestp="$u"; bestpt="$t"; fi
        dim "$u → HTTP ${res%% *} / ${t}s"
    done
    [[ -n "$bestp" ]] && ok "包索引:$bestp(${bestpt}s)" || warn "PyPI 镜像均不可达"

    state_init
    {
        printf '# hermes-vps 网络加速(自动生成)\n'
        printf 'HV_MIRROR_GH_PREFIX=%s\n' "$GH_PREFIX"
        printf 'HV_MIRROR_PYPI_INDEX=%s\n' "$bestp"
    } >"$MIRROR_FILE"
    [[ -n "$bestp" ]] && {
        kv_set "$MIRROR_FILE" UV_DEFAULT_INDEX "$bestp"
        kv_set "$MIRROR_FILE" UV_INDEX_URL "$bestp"
        kv_set "$MIRROR_FILE" PIP_INDEX_URL "$bestp"
    }
    [[ -n "$GH_PREFIX" ]] && kv_set "$MIRROR_FILE" UV_PYTHON_INSTALL_MIRROR "${GH_PREFIX}https://github.com/astral-sh/python-build-standalone/releases/download"
    kv_set "$MIRROR_FILE" UV_HTTP_TIMEOUT "120"
    chmod 644 "$MIRROR_FILE"
}

mirror_apply_user() {
    [[ -f "$MIRROR_FILE" ]] || return 0
    # shellcheck disable=SC1090
    . "$MIRROR_FILE"
    if [[ -n "${HV_MIRROR_GH_PREFIX:-}" ]] && id "$HUSER" >/dev/null 2>&1; then
        run_as_user "$HUSER" git config --global \
            "url.${HV_MIRROR_GH_PREFIX}https://github.com/.insteadOf" "https://github.com/" >/dev/null 2>&1 \
            && info "已为 $HUSER 配置 git GitHub 加速"
    fi
    if [[ -n "${HV_MIRROR_PYPI_INDEX:-}" ]] && id "$HUSER" >/dev/null 2>&1; then
        local udir="$HHOME/.config/uv"
        install -d -o "$HUSER" -g "$HUSER" -m 755 "$udir" 2>/dev/null || mkdir -p "$udir"
        local toml="$udir/uv.toml"
        if [[ -f "$toml" ]] && grep -q '^\[\[index\]\]' "$toml"; then
            info "已有 $toml,保留不动"
        else
            { printf '# 由 hermes-vps 写入\n[[index]]\nurl = "%s"\ndefault = true\n' "$HV_MIRROR_PYPI_INDEX"
              printf 'python-install-mirror = "%s"\n' "${UV_PYTHON_INSTALL_MIRROR:-}"; } >"$toml"
            chown "$HUSER:$HUSER" "$toml" 2>/dev/null || true; chmod 644 "$toml"
        fi
    fi
    { printf '# hermes-vps 网络加速(自动生成)\n'
      [[ -n "${UV_DEFAULT_INDEX:-}" ]] && printf 'export UV_DEFAULT_INDEX="%s"\n' "$UV_DEFAULT_INDEX"
      [[ -n "${UV_INDEX_URL:-}" ]] && printf 'export UV_INDEX_URL="%s"\n' "$UV_INDEX_URL"
      [[ -n "${UV_PYTHON_INSTALL_MIRROR:-}" ]] && printf 'export UV_PYTHON_INSTALL_MIRROR="%s"\n' "$UV_PYTHON_INSTALL_MIRROR"; } >/etc/profile.d/hermes-vps-mirror.sh
    chmod 644 /etc/profile.d/hermes-vps-mirror.sh
}

mirror_show() {
    if [[ ! -f "$MIRROR_FILE" ]]; then info "尚未探测(菜单里选“网络加速探测”即可)"; return 0; fi
    rule
    grep -vE '^\s*#' "$MIRROR_FILE" | sed 's/^/    /'
    rule
}

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
    require_root
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

# =============================================================================
#  服务用户 · Hermes 安装 · 模型提供商(配置 + 真实连通验证)
# =============================================================================

ensure_user() {
    require_root
    if id "$HUSER" >/dev/null 2>&1; then
        local cur; cur="$(getent passwd "$HUSER" | cut -d: -f6)"
        if [[ "$cur" != "$HHOME" ]]; then
            warn "用户 $HUSER 家目录为 $cur(期望 $HHOME)"
            if confirm "改为 $HHOME ?(usermod -d,不搬文件)" no; then usermod -d "$HHOME" "$HUSER"; else HHOME="$cur"; UHOME="${cur}/.hermes"; HBIN="${cur}/.local/bin/hermes"; info "改用现有家目录:$HHOME"; fi
        fi
        info "服务用户已存在:$HUSER(uid $(id -u "$HUSER"))"
    else
        step "创建服务用户 $HUSER"
        useradd --system --create-home --home-dir "$HHOME" --shell /bin/bash --comment "Hermes Agent service account" "$HUSER" 2>/dev/null \
            || useradd -r -m -d "$HHOME" -s /bin/bash "$HUSER"
        passwd -l "$HUSER" >/dev/null 2>&1 || true
        ok "已创建 $HUSER(禁止交互登录)"
    fi
    install -d -o "$HUSER" -g "$HUSER" -m 755 "$HHOME"
    install -d -o "$HUSER" -g "$HUSER" -m 700 "$UHOME"
    install -d -o "$HUSER" -g "$HUSER" -m 755 "$HHOME/.local" "$HHOME/.local/bin"
}

hermes_installed() { [[ -x "$HBIN" ]]; }
hermes_version() {
    hermes_installed || return 1
    local out=""
    out="$(run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" --version 2>/dev/null | sed -n '1p')" || out=""
    if [[ -n "$out" ]]; then printf '%s' "$out"; fi
    return 0
}

hermes_install() {
    require_root
    if hermes_installed; then
        ok "Hermes 已安装($(hermes_version 2>/dev/null || echo 版本未知))"
        if [[ -d "$UHOME/hermes-agent/hermes_cli/web_dist" && "${FORCE:-0}" != "1" ]]; then
            info "已安装且产物完整,跳过重复安装(强制重装:安装时加 --force)"
            return 0
        fi
        [[ -d "$UHOME/hermes-agent/hermes_cli/web_dist" ]] || warn "上次安装不完整(缺界面产物),自动重跑修复"
    fi
    step "执行官方安装脚本(首次 3~10 分钟)"
    local script; script="$(mktemp /tmp/hermes-install-XXXXXX.sh)"
    chmod 644 "$script"
    if ! curl -fsSL --max-time 60 "$OFFICIAL_INSTALL" -o "$script"; then rm -f "$script"; die "下载安装脚本失败:$OFFICIAL_INSTALL"; fi
    install -d -o "$HUSER" -g "$HUSER" -m 700 "$UHOME" 2>/dev/null || true
    chown -R "$HUSER:$HUSER" "$UHOME" 2>/dev/null || true

    local -a flags=(--non-interactive)
    [[ "$SKIP_BROWSER" == "1" ]] && flags+=(--skip-browser)

    local rc=0
    set +e
    run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" "HERMES_REPO_URL=$REPO_URL" "DEBIAN_FRONTEND=noninteractive" \
        -- bash "$script" "${flags[@]}"
    rc=$?
    set -e
    rm -f "$script"
    if [[ $rc -ne 0 ]]; then
        err "官方安装脚本退出码 $rc"
        [[ -f "$UHOME/logs/install.log" ]] && { err "日志尾部:"; tail -n 20 "$UHOME/logs/install.log" | sed 's/^/      /' >&2; }
        return $rc
    fi
    hermes_installed || die "安装后找不到 launcher:$HBIN"
    ok "Hermes 安装完成:$(hermes_version 2>/dev/null || echo 未知)"
    st_set HERMES_VERSION "$(hermes_version 2>/dev/null || echo unknown)"
    st_set INSTALLED_AT "$(date -Is)"
}

hermes_ensure_config() {
    install -d -o "$HUSER" -g "$HUSER" -m 700 "$UHOME" 2>/dev/null || mkdir -p "$UHOME"
    [[ -f "$UHOME/.env" ]] || : >"$UHOME/.env"
    chown "$HUSER:$HUSER" "$UHOME/.env" 2>/dev/null || true; chmod 600 "$UHOME/.env"
    if [[ ! -f "$UHOME/config.yaml" ]]; then
        local ex="$UHOME/hermes-agent/cli-config.yaml.example"
        [[ -f "$ex" ]] && cp "$ex" "$UHOME/config.yaml" || : >"$UHOME/config.yaml"
        chown "$HUSER:$HUSER" "$UHOME/config.yaml" 2>/dev/null || true
    fi
}

hermes_update() {
    hermes_installed || die "Hermes 未安装,请先部署"
    step "更新 Hermes"
    local before; before="$(hermes_version 2>/dev/null || echo unknown)"
    if [[ "${SKIP_BACKUP:-0}" != "1" ]] && confirm "更新前先创建备份?" yes; then backup_create pre-update; fi
    run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" update || warn "hermes update 返回非零"
    restart_all_services
    ok "更新完成:$before → $(hermes_version 2>/dev/null || echo unknown)"
}

# ---------------------------------------------------------------------------
# 模型提供商表:id|名称|密钥变量|示例模型|base_url(为空=不直连验证)|备注
# ---------------------------------------------------------------------------
PROVIDERS=(
"deepseek|DeepSeek 官方|DEEPSEEK_API_KEY|deepseek-chat|https://api.deepseek.com/v1|国内直连,便宜"
"openrouter|OpenRouter 聚合|OPENROUTER_API_KEY|anthropic/claude-sonnet-4.6|https://openrouter.ai/api/v1|一个 key 多模型"
"zai|智谱 GLM (z.ai)|GLM_API_KEY|glm-5|https://open.bigmodel.cn/api/paas/v4|国产"
"kimi-coding-cn|Kimi 月之暗面(国内)|KIMI_CN_API_KEY|kimi-k2.5|https://api.moonshot.cn/v1|国产"
"alibaba|阿里云百炼 DashScope|DASHSCOPE_API_KEY|qwen3.5-plus|https://dashscope.aliyuncs.com/compatible-mode/v1|Qwen 系列"
"minimax-cn|MiniMax(中国端点)|MINIMAX_CN_API_KEY|MiniMax-M2.7||国产"
"openai-api|OpenAI 官方|OPENAI_API_KEY|gpt-5.4|https://api.openai.com/v1|需海外网络"
"anthropic|Anthropic 官方|ANTHROPIC_API_KEY|claude-sonnet-4-6||Claude 系列"
"gemini|Google Gemini|GEMINI_API_KEY|||API Key 方式"
"xai|xAI Grok|XAI_API_KEY|grok-4-fast-reasoning|https://api.x.ai/v1|Responses API"
"deepinfra|DeepInfra|DEEPINFRA_API_KEY||https://api.deepinfra.com/v1/openai|按目录发现"
"novita|NovitaAI|NOVITA_API_KEY|moonshotai/kimi-k2.5|https://api.novita.ai/openai/v1|200+ 模型"
"fireworks|Fireworks AI|FIREWORKS_API_KEY|accounts/fireworks/models/kimi-k2p6|https://api.fireworks.ai/inference/v1|slash 形式模型 ID"
"nvidia|NVIDIA Build|NVIDIA_API_KEY||https://integrate.api.nvidia.com/v1|NIM 托管"
"huggingface|Hugging Face|HF_TOKEN|Qwen/Qwen3.5-397B-A17B|https://router.huggingface.co/v1|开源模型路由"
"xiaomi|小米 MiMo|XIAOMI_API_KEY|mimo-v2-pro||国产"
"tencent-tokenhub|腾讯 TokenHub|TOKENHUB_API_KEY|hy4-preview||国产"
"stepfun|阶跃星辰 StepFun|STEPFUN_API_KEY|||国产"
"__custom__|自定义 OpenAI 兼容端点|CUSTOM_API_KEY|||vLLM / Ollama / One-API / 自建中转"
)

prov_line() { local id="$1" l; for l in "${PROVIDERS[@]}"; do [[ "${l%%|*}" == "$id" ]] && { printf '%s' "$l"; return 0; }; done; return 1; }
prov_field() { local l; l="$(prov_line "$1")" || return 1; awk -F'|' -v i="$2" '{print $i}' <<<"$l"; }
prov_name()   { prov_field "$1" 2; }
prov_env()    { prov_field "$1" 3; }
prov_model()  { prov_field "$1" 4; }
prov_base()   { prov_field "$1" 5; }
prov_note()   { prov_field "$1" 6; }

model_current() { # 输出 "provider|model"
    hermes_installed || return 1
    local p m
    p="$(hcfg_get model.provider)"; m="$(hcfg_get model.default)"
    printf '%s|%s' "${p:--}" "${m:--}"
    return 0
}

model_menu() {
    while :; do
        clear_screen
        header "模型提供商"
        local cur; cur="$(model_current 2>/dev/null || echo "-|-")"
        printf '    当前:%s%s / %s%s\n\n' "$BD" "${cur%%|*}" "${cur##*|}" "$N"
        local i=0 l id nm md note mark
        for l in "${PROVIDERS[@]}"; do
            i=$((i+1)); id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"; md="$(awk -F'|' '{print $4}' <<<"$l")"; note="$(awk -F'|' '{print $6}' <<<"$l")"
            mark="  "; [[ "${cur%%|*}" == "$id" ]] && mark="${G}●${N} "
            printf '    %s%2d)%s %-26s %s%s%s\n' "$mark" "$i" "$N" "$nm" "$DM" "${md:-—}  ${note}" "$N"
        done
        rule
        printf '    编号 = 配置并验证;  %sv<编号>%s = 只验证当前连接;  %stest%s = 用当前模型发一句话;  0) 返回\n' "$C" "$N" "$C" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            0|"") return 0 ;;
            v*) model_verify_menu "${ch#v}" ;;
            test) model_chat_test ;;
            *) if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#PROVIDERS[@]} )); then
                   local line="${PROVIDERS[$((ch-1))]}"; model_configure "${line%%|*}"
               else warn "无效选择:$ch"; pause; fi ;;
        esac
    done
}

model_configure() {
    local id="${1:-}"
    [[ -n "$id" ]] || { local ch=""; menu_choice ch "输入提供商编号或 id"; id="$ch"; }
    if ! prov_line "$id" >/dev/null 2>&1; then err "未知提供商 id:$id"; return 1; fi
    local nm key demo base envv
    nm="$(prov_name "$id" 2>/dev/null || echo "$id")" || true
    envv="$(prov_env "$id" 2>/dev/null || true)"
    demo="$(prov_model "$id" 2>/dev/null || true)"
    base="$(prov_base "$id" 2>/dev/null || true)"

    clear_screen
    header "配置 $nm"
    local keymodel=""
    if [[ "$id" == "__custom__" ]]; then
        ask base "API Base URL(例:http://1.2.3.4:8000/v1)" ""
        [[ -z "$base" ]] && { warn "base_url 不能为空"; pause; return 1; }
        ask keymodel "模型名" ""
        ask_secret key "API Key(本地端点可留空)"
        model_apply __custom__ "$key" "$keymodel" "$base"
        pause; return 0
    fi
    ask_secret key "${envv:-API Key} 的值"
    if [[ -z "$key" ]]; then
        warn "未输入密钥,只写提供商配置"
    fi
    ask keymodel "模型名${demo:+ (回车用 $demo)}" "$demo"
    model_apply "$id" "$key" "$keymodel" "$base"
    pause
}

model_apply() { # id key model base
    local id="$1" key="$2" model="$3" base="${4:-}"
    hermes_installed || { warn "请先部署(菜单 1)"; return 1; }
    [[ "$id" == "__custom__" ]] && id="custom"
    local envv; envv="$(prov_env "$id" 2>/dev/null || true)"
    [[ -n "$key" && -n "$envv" ]] && { env_set "$envv" "$key"; ok "密钥已写入 $UHOME/.env → $envv"; }
    hcfg model.provider "$id" || return 1
    if [[ "$id" == "custom" ]]; then
        [[ -n "$base" ]] && hcfg model.base_url "$base"
        hcfg model.api_mode "chat_completions"
        [[ -n "$envv" ]] && hcfg model.key_env "$envv"
    fi
    [[ -n "$model" ]] && hcfg model.default "$model"
    st_set MODEL_PROVIDER "$id"; [[ -n "$model" ]] && st_set MODEL_NAME "$model"
    info "已写入;下一步做一次真实连通验证"
    [[ -n "$key" && -n "$base" && -n "$model" ]] && model_verify_direct "$id" "$key" "$model" "$base"
    return 0
}

# 直连提供商 API 验证(不经过 agent,最快)
model_verify_direct() {
    local id="$1" key="$2" model="$3" base="$4"
    [[ -z "$base" || -z "$model" || -z "$key" ]] && { dim "该提供商不支持直连快速校验,可用菜单里的 test 发一句话验证"; return 0; }
    local url="${base%/}/chat/completions"
    local body; body="$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_tokens":1,"stream":false}' "$model")"
    local resp code payload
    resp="$(curl -sS -m 30 -w '\n__CODE__%{http_code}' -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' -d "$body" "$url" 2>&1)" || resp=""
    code="${resp##*__CODE__}"; payload="${resp%__CODE__*}"
    case "$code" in
        200) ok "接口连通:${url} → 200(密钥与模型均有效)" ;;
        401|403) err "密钥被拒绝(HTTP $code):$(json_err "$payload")" ;;
        402) err "账户余额/额度不足(HTTP 402):$(json_err "$payload")" ;;
        404) err "模型名或端点不对(HTTP 404):$(json_err "$payload")" ;;
        429) warn "请求过频或额度用尽(HTTP 429):$(json_err "$payload")" ;;
        000) err "网络不可达:$url(海外端点在国内 VPS 需代理)" ;;
        *) err "HTTP $code:$(json_err "$payload")" ;;
    esac
    return 0
}
json_err() {
    local s="$1"
    if have jq; then printf '%s' "$s" | jq -r '.error.message // .message // .error // empty' 2>/dev/null | sed -n '1p' | head -c 300; else printf '%s' "$s" | tr -d '\n' | head -c 300; fi
}

model_verify_menu() {
    local id="${1:-}"; [[ -z "$id" ]] && id="$(st_get MODEL_PROVIDER "$(model_current 2>/dev/null | cut -d'|' -f1)")"
    local key model base envv
    envv="$(prov_env "$id" 2>/dev/null || true)"; key="$(env_get "$envv")"; model="$(hcfg_get model.default)"; base="$(prov_base "$id" 2>/dev/null || true)"
    [[ -z "$base" ]] && base="$(hcfg_get model.base_url)"
    printf '\n'
    dim "提供商:$id   模型:$model   端点:${base:-默认}"
    model_verify_direct "$id" "$key" "$model" "$base"
    pause
}

# 用当前模型真的发一句话(证明整条链路可用)
model_chat_test() {
    hermes_installed || { warn "Hermes 未安装"; pause; return 1; }
    clear_screen
    header "模型连通测试(真实对话)"
    dim "这会通过 Hermes 发一句“只回答:OK”,验证 模型 → 工具链 → 回复 全链路"
    local out rc=0
    set +e
    out="$(run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- timeout 150 "$HBIN" chat -q "只回答两个字:可用" -Q --max-turns 1 2>&1)"
    rc=$?
    set -e
    printf '\n'
    if [[ $rc -eq 0 && -n "$out" ]]; then
        ok "对话成功,模型回复:$(printf '%s' "$out" | tr -d '\n' | head -c 200)"
        st_set MODEL_VERIFIED "$(date '+%F %T')"
    else
        err "对话失败(退出码 $rc):"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/      /'
        dim "常见原因:key 无效 / 模型名不对 / 端点不可达 / 余额不足"
    fi
    pause
}

# =============================================================================
#  消息平台(QQ / 微信 / 企业微信 / Telegram / 飞书 / 钉钉 …)
#  配置 → 写 .env + config.yaml → 立即做官方 API 级连通验证 → 重启网关 → 看日志
# =============================================================================

# id|名称|模式|必需env|可选env|说明
PLATFORMS=(
"qqbot|QQ 机器人(官方 API v2)|qr|QQ_APP_ID,QQ_CLIENT_SECRET|QQBOT_HOME_CHANNEL,QQBOT_HOME_CHANNEL_NAME,QQ_ALLOWED_USERS,QQ_GROUP_ALLOWED_USERS,QQ_ALLOW_ALL_USERS|扫码上线(推荐)或填 AppID/Secret;q.qq.com 建应用"
"weixin|个人微信(iLink 扫码)|qr|WEIXIN_ACCOUNT_ID|WEIXIN_TOKEN,WEIXIN_DM_POLICY,WEIXIN_ALLOWED_USERS,WEIXIN_HOME_CHANNEL|扫码登录;长轮询,无需公网"
"wecom|企业微信 AI 机器人|env|WECOM_BOT_ID,WECOM_SECRET|WECOM_DM_POLICY,WECOM_ALLOWED_USERS|WebSocket 网关"
"feishu|飞书 / Lark|env|FEISHU_APP_ID,FEISHU_APP_SECRET|FEISHU_CONNECTION_MODE,FEISHU_ALLOWED_USERS|长连接模式"
"dingtalk|钉钉机器人|env|DINGTALK_CLIENT_ID,DINGTALK_CLIENT_SECRET|DINGTALK_ALLOWED_USERS|Stream 模式"
"telegram|Telegram|env|TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS,TELEGRAM_HOME_CHANNEL|@BotFather 建机器人"
"discord|Discord|env|DISCORD_BOT_TOKEN|DISCORD_ALLOWED_USERS,DISCORD_HOME_CHANNEL|开发者后台建应用"
"slack|Slack|env|SLACK_BOT_TOKEN,SLACK_APP_TOKEN|SLACK_ALLOWED_USERS|Socket Mode"
"matrix|Matrix|env|MATRIX_HOMESERVER,MATRIX_USER_ID,MATRIX_ACCESS_TOKEN|MATRIX_HOME_ROOM|自建/托管 homeserver"
"whatsapp|WhatsApp|qr|WHATSAPP_ENABLED|WHATSAPP_ALLOWED_USERS|扫码登录"
"email|邮件助手|env|EMAIL_ADDRESS,EMAIL_PASSWORD,EMAIL_IMAP_HOST,EMAIL_SMTP_HOST|EMAIL_ALLOWED_USERS|IMAP + SMTP"
"api_server|OpenAI 兼容 API(给客户端)|env|API_SERVER_KEY|API_SERVER_PORT|OpenWebUI / LobeChat 等"
)

plat_line() { local id="$1" l; for l in "${PLATFORMS[@]}"; do [[ "${l%%|*}" == "$id" ]] && { printf '%s' "$l"; return 0; }; done; return 1; }
plat_field() { local l; l="$(plat_line "$1")" || return 1; awk -F'|' -v i="$2" '{print $i}' <<<"$l"; }
plat_name() { plat_field "$1" 2; }
plat_mode() { plat_field "$1" 3; }
plat_req()  { plat_field "$1" 4; }
plat_opt()  { plat_field "$1" 5; }
plat_note() { plat_field "$1" 6; }

plat_configured() { # 必需 env 是否齐
    local id="$1" req v
    req="$(plat_req "$id")"
    [[ -z "$req" ]] && return 1
    local IFS=','
    for v in $req; do [[ -n "$(env_get "$v")" ]] || return 1; done
    return 0
}
plat_enabled() { [[ "$(hcfg_get "platforms.$1.enabled")" == *true* ]]; }

# 网关日志里的平台连接状态
plat_live_state() {
    local id="$1" log last
    # api_server 直接看端口,别猜日志
    if [[ "$id" == "api_server" ]]; then
        if port_listening "$API_PORT"; then printf 'connected'; else printf 'failed'; fi
        return 0
    fi
    have journalctl || { printf 'unknown'; return 0; }
    log="$(journalctl -u hermes-gateway --since '-2 hours' --no-pager 2>/dev/null \
            | grep -iE "(^|[^a-z])${id}([^a-z]|$)" \
            | grep -viE "rejected invalid api key|peer_ip=" | tail -n 8)" || log=""
    [[ -z "$log" ]] && { printf 'unknown'; return 0; }
    last="$(printf '%s\n' "$log" | tail -n 1)"
    if printf '%s' "$last" | grep -qiE "startup failed|failed to (start|connect|login)|connection failed|invalid|rejected|unauthorized|error"; then
        printf 'failed'; return 0
    fi
    if printf '%s' "$last" | grep -qiE "connected|ready|started|logged in|polling|listening"; then
        printf 'connected'; return 0
    fi
    printf 'seen'
    return 0
}

# 进入官方平台向导(QQ 扫码上线 / 微信扫码登录都走这里)
plat_official_setup() {
    local id="$1"
    hermes_installed || { warn "请先部署(菜单 1)"; pause; return 1; }
    step "进入官方平台配置向导(选 ${id},按提示扫码或填凭据)"
    dim "向导结束后回到本菜单;若卡住可按 Ctrl+C"
    set +e
    run_interactive_as_user "$UHOME/bin/hermes-run" gateway setup
    set -e
    hcfg "platforms.$id.enabled" "true" >/dev/null 2>&1 || true
    local req v; req="$(plat_req "$id")"; local IFS=','
    for v in $req; do
        if [[ -n "$(env_get "$v")" ]]; then ok "$v 已保存"
        else dim "$v 暂未出现在 .env(部分平台凭据存在 $UHOME 下的账号目录,属正常)"; fi
    done
    if confirm "重启网关并查看连接日志?" yes; then
        restart_service hermes-gateway; sleep 8
        printf '\n'; dim "网关状态:$(plat_live_state "$id")"; plat_show_log "$id"
    fi
    pause
}

plat_menu() {
    while :; do
        clear_screen
        header "消息平台"
        local i=0 l id nm md note mark live
        for l in "${PLATFORMS[@]}"; do
            i=$((i+1)); id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"; md="$(awk -F'|' '{print $3}' <<<"$l")"; note="$(awk -F'|' '{print $6}' <<<"$l")"
            if plat_configured "$id"; then
                live="$(plat_live_state "$id" 2>/dev/null || echo unknown)"
                case "$live" in
                    connected) mark="$DOT_ON" ;;
                    failed)    mark="$DOT_OFF" ;;
                    *)         mark="$DOT_MID" ;;
                esac
                printf '    %s %2d) %-24s %s已配置%s  连接:%s\n' "$mark" "$i" "$nm" "$DM" "$N" "$live"
            else
                printf '    %s %2d) %-24s %s未配置%s  %s%s%s\n' "$DM$DOT_OFF" "$i" "$nm" "$DM" "$N" "$DM" "$note" "$N"
            fi
        done
        rule
        printf '    编号 = 配置(输完凭据立即验证);  %sv<编号>%s = 验证连接;  %st<编号>%s = 发测试消息;  0) 返回\n' "$C" "$N" "$C" "$N"
        printf '    提示:%sQQ / 微信 都支持官方扫码上线;飞书/钉钉/TG 等填凭据即可%s\n' "$DM" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            0|"") return 0 ;;
            v*) plat_verify_menu "${ch#v}" ;;
            t*) plat_send_test "${ch#t}" ;;
            *) if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#PLATFORMS[@]} )); then
                   plat_configure "${PLATFORMS[$((ch-1))]%%|*}"
               else warn "无效选择:$ch"; pause; fi ;;
        esac
    done
}

plat_configure() {
    local id="$1" nm mode req opt
    nm="$(plat_name "$id")"; mode="$(plat_mode "$id")"; req="$(plat_req "$id")"; opt="$(plat_opt "$id")"
    clear_screen
    header "配置 ${nm}"
    dim "$(plat_note "$id")"

    if [[ "$mode" == "qr" ]]; then
        printf '\n'
        printf '    %s1)%s 官方扫码向导(推荐,AppID/Secret 由扫码自动获取)\n' "$BD" "$N"
        printf '    %s2)%s 手填凭据写入 .env(适合已有 AppID/Secret)\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local q=""; menu_choice q "请选择"
        case "$q" in
            1) plat_official_setup "$id"; return 0 ;;
            2) : ;;
            *) return 0 ;;
        esac
    fi

    local v val
    local IFS=','
    for v in $req; do
        if [[ -n "$(env_get "$v")" ]]; then
            if confirm "$v 已配置,是否覆盖?" no; then :; else info "$v 保持原值"; continue; fi
        fi
        ask_secret val "$v 的值"
        if [[ -z "$val" ]]; then
            warn "$v 为空,跳过"
        else
            env_set "$v" "$val"; ok "已写入 $v"
        fi
    done
    if [[ -n "$opt" ]] && confirm "是否继续配置可选参数(白名单、首页频道等)?" no; then
        for v in $opt; do
            local cur; cur="$(env_get "$v")"
            ask val "$v${cur:+ (当前 $cur)}" ""
            [[ -n "$val" ]] && { env_set "$v" "$val"; ok "已写入 $v"; }
        done
    fi
    hcfg "platforms.$id.enabled" "true" >/dev/null 2>&1 || true
    st_set "PLATFORM_$id" "true"
    ok "${nm} 已启用"

    # 立即验证(官方 API 级)+ 重启网关看日志
    plat_verify_api "$id"
    if confirm "重启网关使配置生效并观察连接日志?" yes; then
        restart_service hermes-gateway
        sleep 8
        local live; live="$(plat_live_state "$id")"
        case "$live" in
            connected) ok "网关日志:${id} 已连接" ;;
            failed)    err "网关日志:${id} 连接失败(看下面的日志尾部)" ;;
            *)         dim "网关日志暂未见 ${id} 的明确结论,下面给最近日志" ;;
        esac
        plat_show_log "$id"
    fi
    pause
}

plat_verify_menu() {
    local id="${1:-}"
    if [[ -z "$id" || ! "$id" =~ ^[0-9]+$ ]]; then
        local ch=""; menu_choice ch "输入平台编号(1-${#PLATFORMS[@]})"; id="$ch"
    fi
    [[ "$id" =~ ^[0-9]+$ ]] && (( id>=1 && id<=${#PLATFORMS[@]} )) || { warn "无效编号"; pause; return 1; }
    id="${PLATFORMS[$((id-1))]%%|*}"
    clear_screen
    header "验证 $(plat_name "$id")"
    plat_configured "$id" || warn "尚未配置完整凭据,验证可能失败"
    plat_verify_api "$id"
    plat_show_log "$id"
    pause
}

# 官方 API 级验证(尽量用平台自己的接口拿到确定结论)
plat_verify_api() {
    local id="$1"
    case "$id" in
        qqbot)
            local aid asec resp
            aid="$(env_get QQ_APP_ID)"; asec="$(env_get QQ_CLIENT_SECRET)"
            [[ -z "$aid" || -z "$asec" ]] && { dim "缺 QQ_APP_ID / QQ_CLIENT_SECRET"; return 0; }
            resp="$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' \
                    -d "{\"appId\":\"$aid\",\"clientSecret\":\"$asec\"}" \
                    https://bots.qq.com/app/getAppAccessToken 2>&1)" || resp=""
            if [[ "$resp" == *access_token* ]]; then
                ok "QQ 官方接口已认账:拿到 access_token(凭据有效)"
                local exp; exp="$(json_field "$resp" expires_in)"
                [[ -n "$exp" ]] && dim "token 有效期 ${exp}s(网关会自动续)"
            else
                err "QQ 接口拒绝:$(json_err "$resp")"
                dim "常见:AppID/Secret 抄错、机器人未发布/未开启对应 intent"
            fi ;;
        telegram)
            local t; t="$(env_get TELEGRAM_BOT_TOKEN)"
            [[ -z "$t" ]] && { dim "缺 TELEGRAM_BOT_TOKEN"; return 0; }
            local r; r="$(curl -sS -m 20 "https://api.telegram.org/bot${t}/getMe" 2>&1)" || r=""
            if [[ "$r" == *'"ok":true'* ]]; then ok "Telegram 已认账:$(json_field "$r" result.username)"
            else err "Telegram 拒绝:$(json_err "$r")"; fi ;;
        discord)
            local t; t="$(env_get DISCORD_BOT_TOKEN)"
            [[ -z "$t" ]] && { dim "缺 DISCORD_BOT_TOKEN"; return 0; }
            local code; code="$(curl -sS -m 20 -o /tmp/.hv.disc -w '%{http_code}' -H "Authorization: Bot ${t}" https://discord.com/api/v10/users/@me 2>/dev/null || echo 000)"
            [[ "$code" == "200" ]] && ok "Discord 已认账(HTTP 200)" || err "Discord 拒绝(HTTP $code)" ;;
        slack)
            local t; t="$(env_get SLACK_BOT_TOKEN)"
            [[ -z "$t" ]] && { dim "缺 SLACK_BOT_TOKEN"; return 0; }
            local r; r="$(curl -sS -m 20 -H "Authorization: Bearer ${t}" https://slack.com/api/auth.test 2>&1)" || r=""
            [[ "$r" == *'"ok":true'* ]] && ok "Slack 已认账($(json_field "$r" team))" || err "Slack 拒绝:$(json_err "$r")" ;;
        feishu)
            local a s r
            a="$(env_get FEISHU_APP_ID)"; s="$(env_get FEISHU_APP_SECRET)"
            [[ -z "$a" || -z "$s" ]] && { dim "缺 FEISHU_APP_ID / FEISHU_APP_SECRET"; return 0; }
            r="$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -d "{\"app_id\":\"$a\",\"app_secret\":\"$s\"}" \
                 https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal 2>&1)" || r=""
            [[ "$r" == *tenant_access_token* ]] && ok "飞书已认账:拿到 tenant_access_token" || err "飞书拒绝:$(json_err "$r")" ;;
        dingtalk)
            local a s r
            a="$(env_get DINGTALK_CLIENT_ID)"; s="$(env_get DINGTALK_CLIENT_SECRET)"
            [[ -z "$a" || -z "$s" ]] && { dim "缺 DINGTALK_CLIENT_ID / DINGTALK_CLIENT_SECRET"; return 0; }
            r="$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -d "{\"appKey\":\"$a\",\"appSecret\":\"$s\"}" \
                 https://api.dingtalk.com/v1.0/oauth2/accessToken 2>&1)" || r=""
            [[ "$r" == *accessToken* ]] && ok "钉钉已认账:拿到 accessToken" || err "钉钉拒绝:$(json_err "$r")" ;;
        matrix)
            local hs tk r
            hs="$(env_get MATRIX_HOMESERVER)"; tk="$(env_get MATRIX_ACCESS_TOKEN)"
            [[ -z "$hs" || -z "$tk" ]] && { dim "缺 MATRIX_HOMESERVER / MATRIX_ACCESS_TOKEN"; return 0; }
            r="$(curl -sS -m 20 -H "Authorization: Bearer ${tk}" "${hs%/}/_matrix/client/v3/account/whoami" 2>&1)" || r=""
            [[ "$r" == *user_id* ]] && ok "Matrix 已认账:$(json_field "$r" user_id)" || err "Matrix 拒绝:$(json_err "$r")" ;;
        weixin)
            if [[ -n "$(env_get WEIXIN_ACCOUNT_ID)" ]]; then ok "已保存登录态(WEIXIN_ACCOUNT_ID 存在)"; else dim "尚未扫码登录"; fi ;;
        api_server)
            local k; k="$(env_get API_SERVER_KEY)"
            local c1 c2
            c1="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
            c2="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${k}" "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
            [[ "$c1" == "401" || "$c1" == "403" ]] && ok "API 鉴权生效(无 key → $c1)" || warn "无 key 访问返回 $c1(期望 401)"
            [[ "$c2" == "200" ]] && ok "带 key 访问 → 200" || warn "带 key 访问返回 $c2" ;;
        *)
            dim "该平台没有可直连的校验接口,依赖网关连接日志判断(见下)" ;;
    esac
}

plat_show_log() {
    local id="$1" tail_n="${2:-12}"
    have journalctl || return 0
    local l; l="$(journalctl -u hermes-gateway --since '-10 min' --no-pager 2>/dev/null | grep -iE "$id" | tail -n "$tail_n")" || l=""
    if [[ -n "$l" ]]; then
        printf '\n    %s网关日志(%s)%s\n' "$DM" "$id" "$N"
        printf '%s\n' "$l" | sed 's/^/      /' | cut -c1-200
    fi
}

plat_send_test() {
    local id="${1:-}"
    if [[ -z "$id" || ! "$id" =~ ^[0-9]+$ ]]; then
        local ch=""; menu_choice ch "输入平台编号(1-${#PLATFORMS[@]})"; id="$ch"
    fi
    [[ "$id" =~ ^[0-9]+$ ]] && (( id>=1 && id<=${#PLATFORMS[@]} )) || { warn "无效编号"; pause; return 1; }
    local pid="${PLATFORMS[$((id-1))]%%|*}"
    clear_screen
    header "发送测试消息 → $(plat_name "$pid")"
    dim "用 hermes send 通过该平台发一条测试消息(需要平台的 home channel)"
    local out rc=0
    set +e
    out="$(run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" send -t "$pid" "hermes-vps 测试消息:如果你看到这条,说明 ${pid} 收发生了效。" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then ok "发送成功(通过 $pid 的 home channel)"
    else err "发送失败(退出码 $rc):"; printf '%s\n' "$out" | tail -n 10 | sed 's/^/      /'; fi
    dim "若提示需要 home channel:先在平台里给机器人发条消息,或 /sethome;也可指定目标 菜单不提供(用 hermes send -t ${pid}:chat_id)"
    pause
}

# =============================================================================
#  面板 / API · systemd 服务 · Caddy 反向代理(域名 + 自动 HTTPS)
# =============================================================================

json_field() { # json_field <json> <key>
    local s="$1" k="$2"
    if have jq; then printf '%s' "$s" | jq -r ".${k} // empty" 2>/dev/null | sed -n '1p'
    else printf '%s' "$s" | grep -oE "\"${k}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed -n '1p' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/'; fi
}

# ---------------------------------------------------------------------------
# 面板与 API 配置
# ---------------------------------------------------------------------------
dashboard_ensure_auth() { # 认证门:用户名/密码/会话密钥
    local u p s file="$(env_file)"
    u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    s="$(env_get HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
    [[ -z "$u" ]] && { u="admin"; env_set HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$u"; }
    [[ -z "$p" ]] && { p="$(random_str 20)"; env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$p"; ok "已生成面板密码(随机 20 位)"; }
    [[ -z "$s" ]] && { env_set HERMES_DASHBOARD_BASIC_AUTH_SECRET "$(random_hex 32)"; }
    st_set DASH_USER "$u"
    return 0
}

dashboard_webui() { # 公网地址 + 面板绑定
    local domain="${1:-$(st_get DOMAIN)}"
    hcfg dashboard.enabled true >/dev/null 2>&1 || true
    hcfg dashboard.host "127.0.0.1" >/dev/null 2>&1 || true
    hcfg dashboard.port "$DASH_PORT" >/dev/null 2>&1 || true
    if [[ -n "$domain" ]]; then
        hcfg dashboard.public_url "https://${domain}" || return 1
    fi
}

api_server_enable() { # 让 OpenAI 兼容 /v1 在本地端口可用
    local key; key="$(env_get API_SERVER_KEY)"
    [[ -z "$key" ]] && { key="sk-hermes-$(random_str 24)"; env_set API_SERVER_KEY "$key"; }
    env_set API_SERVER_PORT "$API_PORT"
    hcfg "platforms.api_server.enabled" "true" >/dev/null 2>&1 || true
    hcfg "platforms.api_server.port" "$API_PORT" >/dev/null 2>&1 || true
    hcfg "platforms.api_server.host" "127.0.0.1" >/dev/null 2>&1 || true
    st_set API_ENABLED "1"; st_set API_SERVER "on"
    ok "API Server 已开启(127.0.0.1:${API_PORT})"
}
api_server_disable() {
    hcfg "platforms.api_server.enabled" "false" >/dev/null 2>&1 || true
    st_set API_ENABLED "0"; st_set API_SERVER "off"
    ok "API Server 已关闭"
    restart_service hermes-gateway || true
}

credentials_write() {
    local domain="${1:-$(st_get DOMAIN)}" u p s ak
    u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    s="$(env_get HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
    ak="$(env_get API_SERVER_KEY)"
    umask 077
    {
        printf '# hermes-vps 访问凭据(自动生成,请妥善保管)\n'
        printf '# 生成时间:%s\n\n' "$(date -Is)"
        [[ -n "$domain" ]] && printf '面板地址   : https://%s/\n' "$domain" || printf '面板地址   : http://127.0.0.1:%s/(尚未配置域名)\n' "$DASH_PORT"
        printf '面板用户名 : %s\n' "$u"
        printf '面板密码   : %s\n' "$p"
        [[ -n "$domain" ]] && printf 'API 地址   : https://%s/v1\n' "$domain" || printf 'API 地址   : http://127.0.0.1:%s/v1\n' "$API_PORT"
        printf 'API Key    : %s\n' "$ak"
        printf '会话密钥   : %s\n' "$s"
    } >"$CRED_FILE"
    chmod 600 "$CRED_FILE"
}

dashboard_show_info() {
    local domain; domain="$(st_get DOMAIN)"
    header "面板与 API 访问信息"
    local u; u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    rule
    printf '    面板(本机) : http://127.0.0.1:%s/\n' "$DASH_PORT"
    [[ -n "$domain" ]] && printf '    面板(域名) : %shttps://%s/%s\n' "$BD" "$domain" "$N"
    printf '    管理账号   : %s%s%s\n' "$BD" "$u" "$N"
    printf '    密码/APIkey: 见 %s%s%s(600 权限)\n' "$BD" "$CRED_FILE" "$N"
    if [[ "$(st_api_enabled)" == "1" ]]; then
        [[ -n "$domain" ]] && printf '    API        : https://%s/v1  (OpenAI 兼容)\n' "$domain"
        printf '    API        : http://127.0.0.1:%s/v1\n' "$API_PORT"
    else
        printf '    API        : %s未开启%s\n' "$DM" "$N"
    fi
    rule
    printf '    查看密码   : %scat %s%s\n' "$C" "$CRED_FILE" "$N"
    printf '    重置密码   : 菜单 → 面板与 API → 2\n'
    rule
}

dashboard_verify_gate() { # 认证门是否生效
    local code; code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${DASH_PORT}/" 2>/dev/null || echo 000)"
    case "$code" in
        302|303|401|403) printf 'ok' ;;
        200) printf 'open' ;;
        000) printf 'down' ;;
        *) printf 'other:%s' "$code" ;;
    esac
}
dashboard_wait_ready() { # 等待面板监听
    local i=0
    while [[ $i -lt 60 ]]; do
        port_listening "$DASH_PORT" && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}
dashboard_login_test() { # 真实登录一次:成功发 Cookie
    local u p jar code
    u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"; p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    [[ -z "$u" || -z "$p" ]] && { warn "未设置面板账号密码"; return 1; }
    jar="$(mktemp)"
    code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -c "$jar" -X POST \
        -H 'Content-Type: application/json' -d "{\"username\":\"$u\",\"password\":\"$p\"}" \
        "http://127.0.0.1:${DASH_PORT}/api/login" 2>/dev/null || echo 000)"
    local cookies=0; [[ -s "$jar" ]] && cookies="$(grep -c . "$jar" || echo 0)"
    if [[ "$code" == "200" ]]; then
        ok "登录成功(HTTP 200,Cookie ${cookies} 条)"
        local c; c="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -b "$jar" "http://127.0.0.1:${DASH_PORT}/api/config" 2>/dev/null || echo 000)"
        [[ "$c" == "200" ]] && ok "已登录会话可读配置(/api/config → 200)" || warn "会话读取返回 $c"
    else
        err "登录失败(HTTP $code)"
    fi
    rm -f "$jar"
}

# ---------------------------------------------------------------------------
# systemd 服务
# ---------------------------------------------------------------------------
ensure_unit_user() { # 保证单元以 hermes 用户运行
    local unit="$1" file="/etc/systemd/system/$1"
    local dir="/etc/systemd/system/${unit}.d"
    local need=0 u=""
    [[ -f "$file" ]] && u="$(awk -F= '/^User=/{gsub(/ /,"",$2); print $2}' "$file" | sed -n '1p')"
    if [[ "$u" != "$HUSER" ]]; then need=1; fi
    if [[ $need -eq 1 ]]; then
        mkdir -p "$dir"
        cat >"$dir/10-hermes-vps-user.conf" <<EOF
# 由 hermes-vps 写入:确保服务以专用用户运行
[Service]
User=$HUSER
Group=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
Environment=HERMES_HOME=$UHOME
EOF
        chmod 644 "$dir/10-hermes-vps-user.conf"
        systemctl daemon-reload 2>/dev/null || true
        info "已补齐 User=$HUSER(原值:${u:-未设置})"
    fi
}

service_gateway_install() {
    require_root
    local unit="hermes-gateway.service" file="/etc/systemd/system/hermes-gateway.service"
    if [[ -f "$file" ]] && systemctl is-enabled "$unit" >/dev/null 2>&1; then
        local u; u="$(awk -F= '/^User=/{gsub(/ /,"",$2); print $2}' "$file" | sed -n '1p')"
        if [[ "$u" == "$HUSER" ]]; then ok "网关服务已就绪(开机自启)"; return 0; fi
    fi
    step "安装网关系统服务"
    local rc=0
    set +e
    HERMES_HOME="$UHOME" HOME="$HHOME" "$HBIN" gateway install --system >/dev/null 2>&1
    rc=$?
    if [[ $rc -ne 0 ]]; then
        run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" gateway install --system >/dev/null 2>&1
        rc=$?
    fi
    set -e
    if [[ $rc -ne 0 || ! -f "$file" ]]; then
        warn "官方安装未生成单元,写入内置单元"
        write_gateway_unit
    fi
    ensure_unit_user "$unit"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" 2>/dev/null || true
    ok "网关服务已安装并启动"
}

write_gateway_unit() {
    cat >/etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent Messaging Gateway (managed by hermes-vps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HUSER
Group=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
Environment=HERMES_HOME=$UHOME
Environment=PATH=$HHOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HHOME/.local/bin/hermes gateway run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 /etc/systemd/system/hermes-gateway.service
}

service_dashboard_install() {
    require_root
    local unit="hermes-dashboard.service" file="/etc/systemd/system/hermes-dashboard.service"
    local content
    content="$(cat <<EOF
[Unit]
Description=Hermes Agent Web Dashboard (managed by hermes-vps)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$HUSER
Group=$HUSER
WorkingDirectory=$HHOME
Environment=HOME=$HHOME
Environment=HERMES_HOME=$UHOME
Environment=PATH=$HHOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$HHOME/.local/bin/hermes dashboard
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
)"
    if [[ -f "$file" ]] && diff -q <(printf '%s\n' "$content") "$file" >/dev/null 2>&1 && systemctl is-enabled "$unit" >/dev/null 2>&1; then
        ok "面板服务已就绪(无需变更)"
        return 0
    fi
    step "安装面板系统服务"
    printf '%s\n' "$content" >"$file"
    chmod 644 "$file"
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" 2>/dev/null || true
    ok "面板服务已安装并启动"
}

svc() { # 服务名归一化
    case "$1" in
        gateway|hermes-gateway) printf 'hermes-gateway' ;;
        dashboard|panel|hermes-dashboard) printf 'hermes-dashboard' ;;
        caddy) printf 'caddy' ;;
        *) printf '%s' "$1" ;;
    esac
}
start_service()   { local s; s="$(svc "$1")"; systemctl start "$s"  && ok "$s 已启动" || err "$s 启动失败"; }
stop_service()    { local s; s="$(svc "$1")"; systemctl stop "$s"   && ok "$s 已停止" || err "$s 停止失败"; }
restart_service() { local s; s="$(svc "$1")"; systemctl restart "$s" >/dev/null 2>&1 && ok "$s 已重启" || err "$s 重启失败"; }
restart_all_services() {
    local s
    for s in hermes-gateway hermes-dashboard; do systemctl restart "$s" >/dev/null 2>&1 || true; done
    systemctl is-active caddy >/dev/null 2>&1 && systemctl reload caddy >/dev/null 2>&1 || true
    sleep 1
    info "已重启:$(service_brief)"
    return 0
}
service_brief() {
    local out="" s
    for s in hermes-gateway hermes-dashboard caddy; do
        local st; st="$(svc_state "$s")"
        if [[ "$st" == "active" ]]; then out+=" ${G}●${N}${s#hermes-}"; else out+=" ${R}○${N}${s#hermes-}($st)"; fi
    done
    printf '%s' "$out"
}
service_logs() {
    local s; s="$(svc "$1")"
    dim "按 Ctrl+C 退出日志(${s})"
    set +e; journalctl -u "$s" -n 60 --no-pager; journalctl -u "$s" -f; set -e
}

# ---------------------------------------------------------------------------
# Caddy 安装 / 配置 / 证书
# ---------------------------------------------------------------------------
caddy_installed() { have caddy || [[ -x "$CADDY_BIN" ]]; }
caddy_version() { if have caddy; then caddy version 2>/dev/null | sed -n '1p'; elif [[ -x "$CADDY_BIN" ]]; then "$CADDY_BIN" version 2>/dev/null | sed -n '1p'; fi; }
caddy_bin() { if have caddy; then command -v caddy; else printf '%s' "$CADDY_BIN"; fi; }

caddy_ensure_user() {
    getent group caddy >/dev/null 2>&1 || groupadd --system caddy 2>/dev/null || true
    id caddy >/dev/null 2>&1 || useradd --system --gid caddy --home-dir /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy 2>/dev/null || true
    install -d -o caddy -g caddy -m 750 /var/lib/caddy 2>/dev/null || true
}

caddy_prepare_runtime() {
    require_root
    install -d -m 755 "$CADDY_LOG_DIR" 2>/dev/null || mkdir -p "$CADDY_LOG_DIR"
    [[ -f "$CADDY_LOG_DIR/hermes-access.log" ]] || : >"$CADDY_LOG_DIR/hermes-access.log"
    chown -R caddy:caddy "$CADDY_LOG_DIR" 2>/dev/null || true
    chmod 750 "$CADDY_LOG_DIR" 2>/dev/null || true
    chmod 640 "$CADDY_LOG_DIR/hermes-access.log" 2>/dev/null || true
    install -d -m 755 /etc/caddy 2>/dev/null || true
    caddy_ensure_user
    return 0
}

caddy_install() {
    require_root
    if caddy_installed; then ok "Caddy 已安装:$(caddy_version)"; caddy_prepare_runtime; return 0; fi
    step "安装 Caddy"
    local from_apt=0
    if [[ "$PKG" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        pkg_install debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null 2>&1 || true
        if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            curl -fsSL --max-time 40 "https://dl.cloudsmith.io/public/caddy/stable/gpg.key" 2>/dev/null \
              | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || warn "Caddy 官方源 GPG 下载失败"
        fi
        if [[ -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
            printf 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' >/etc/apt/sources.list.d/caddy-stable.list
            printf 'deb-src [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main\n' >>/etc/apt/sources.list.d/caddy-stable.list
            apt-get update -qq >/dev/null 2>&1 || true
            if apt-get install -y -qq caddy >/dev/null 2>&1; then from_apt=1; ok "已通过官方 apt 源安装 Caddy"; fi
        fi
        [[ $from_apt -eq 0 ]] && { info "apt 源不可用,尝试发行版自带包"; apt-get install -y -qq caddy >/dev/null 2>&1 && from_apt=1 || true; }
    fi
    if [[ $from_apt -eq 0 ]]; then
        info "改用官方二进制安装"
        local arch="amd64"; [[ "$ARCH" == "aarch64" ]] && arch="arm64"
        local url="https://caddyserver.com/api/download?os=linux&arch=${arch}"
        local tmp; tmp="$(mktemp)"
        curl -fL --max-time 180 -o "$tmp" "$url" || die "下载 Caddy 失败:$url"
        install -m 755 "$tmp" "$CADDY_BIN"; rm -f "$tmp"
        caddy_ensure_user
        cat >/etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy web server (managed by hermes-vps)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=$CADDY_BIN run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=$CADDY_BIN reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
        chmod 644 /etc/systemd/system/caddy.service
        systemctl daemon-reload
        systemctl enable caddy >/dev/null 2>&1 || true
        ok "已用官方二进制安装 Caddy($(caddy_version))"
    fi
    caddy_prepare_runtime
}

caddy_render() { # 生成 Caddyfile 到 stdout
    local domain="$1" email="$2" api_on="$3"
    if [[ -n "$email" ]]; then
        printf '{\n\tadmin 127.0.0.1:2019\n\temail %s\n}\n\n' "$email"
    else
        printf '{\n\tadmin 127.0.0.1:2019\n}\n\n'
    fi
    cat <<EOF
# 由 hermes-vps 生成 · $(date '+%F %T') · 域名:$domain
$domain {
	encode zstd gzip

	# 探活(仅 Caddy 自己响应,不触碰面板)
	handle /healthz {
		respond "ok" 200
	}
EOF
    if [[ "$api_on" == "1" ]]; then
        cat <<EOF

	# OpenAI 兼容 API
	handle /v1/* {
		reverse_proxy 127.0.0.1:$API_PORT
	}
EOF
    fi
    cat <<EOF

	# 管理面板(含登录与静态资源)
	handle {
		reverse_proxy 127.0.0.1:$DASH_PORT
	}

	log {
		output file $CADDY_LOG_DIR/hermes-access.log {
			roll_size 20MiB
			roll_keep 5
		}
		format json
	}
}
EOF
}

caddy_validate() { # 校验给定内容
    local content="$1" bin tmp
    bin="$(caddy_bin)"
    tmp="$(mktemp /tmp/Caddyfile.XXXXXX)"
    printf '%s\n' "$content" >"$tmp"
    local rc=0
    set +e
    "$bin" validate --adapter caddyfile --config "$tmp" >/tmp/.hv-caddy-validate.out 2>&1
    rc=$?
    set -e
    rm -f "$tmp"
    if [[ $rc -ne 0 ]]; then
        err "Caddyfile 校验失败:"
        sed 's/^/      /' /tmp/.hv-caddy-validate.out | head -n 12 >&2
        return 1
    fi
    return 0
}

caddy_write_config() { # 写入并 reload(校验不通过绝不 reload)
    local domain="$1" email="$2" api_on="$3"
    require_root
    caddy_prepare_runtime
    local content; content="$(caddy_render "$domain" "$email" "$api_on")"
    caddy_validate "$content" || return 1
    if [[ -f "$CADDYFILE" ]] && [[ "$(cat "$CADDYFILE")" == "$content" ]]; then
        ok "Caddyfile 无变化,跳过"
    else
        [[ -f "$CADDYFILE" ]] && backup_file "$CADDYFILE"
        printf '%s\n' "$content" >"$CADDYFILE"
        chmod 644 "$CADDYFILE"
        ok "已写入 $CADDYFILE"
    fi
    st_set DOMAIN "$domain"; st_set ACME_EMAIL "$email"; st_set API_ENABLED "$api_on"
    caddy_reload
}

caddy_reload() {
    systemctl daemon-reload 2>/dev/null || true
    if systemctl is-active caddy >/dev/null 2>&1; then
        if systemctl reload caddy >/dev/null 2>&1; then ok "Caddy 已热重载"
        else
            warn "reload 失败,尝试重启"
            systemctl restart caddy >/dev/null 2>&1 && ok "Caddy 已重启" || { err "Caddy 启动失败"; caddy_diagnose; return 1; }
        fi
    else
        systemctl enable caddy >/dev/null 2>&1 || true
        if systemctl restart caddy >/dev/null 2>&1; then ok "Caddy 已启动"
        else err "Caddy 启动失败"; caddy_diagnose; return 1; fi
    fi
    return 0
}

caddy_diagnose() {
    have journalctl || return 0
    err "最近日志:"
    journalctl -u caddy -n 15 --no-pager 2>/dev/null | sed 's/^/      /' >&2 || true
}

caddy_status() {
    local st; st="$(svc_state caddy)"
    printf '%s' "$st"
}
cert_days_left() { # 域名证书剩余天数(经 Caddy 数据目录)
    local domain="$1"
    local dir="/var/lib/caddy/.local/share/caddy/certificates"
    have openssl || return 1
    local f
    f="$(find "$dir" -name "${domain}.crt" 2>/dev/null | sort | tail -n1)" || f=""
    [[ -z "$f" ]] && return 1
    local end; end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)" || return 1
    [[ -z "$end" ]] && return 1
    local end_s now_s
    end_s="$(date -d "$end" +%s 2>/dev/null)" || return 1
    now_s="$(date +%s)"
    printf '%s' $(( (end_s - now_s) / 86400 ))
}
cert_expire_date() {
    local domain="$1"
    local dir="/var/lib/caddy/.local/share/caddy/certificates"
    have openssl || return 1
    local f; f="$(find "$dir" -name "${domain}.crt" 2>/dev/null | sort | tail -n1)" || f=""
    [[ -z "$f" ]] && return 1
    openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2 | xargs -I{} date -d '{}' '+%Y-%m-%d' 2>/dev/null
}

domain_configure() {
    hermes_installed || { warn "请先部署(菜单 1)"; pause; return 1; }
    clear_screen
    header "域名与反向代理(Caddy)"
    local cur; cur="$(st_get DOMAIN)"
    printf '    当前域名:%s%s%s\n' "$BD" "${cur:-未配置}" "$N"
    local domain; ask domain "域名(例:panel.example.com,回车跳过)" "$cur"
    if [[ -z "$domain" ]]; then info "未提供域名,跳过"; pause; return 0; fi
    local email; ask email "证书通知邮箱(可留空)" "$(st_get ACME_EMAIL)"

    printf '\n'
    dim "检查 DNS 解析…"
    local rc=0; set +e; domain_points_here "$domain"; rc=$?; set -e
    case "$rc" in
        0) ok "解析正确,域名指向本机" ;;
        1) warn "解析到别处或未解析:Let's Encrypt 将无法签发(请把 A 记录指向本机公网 IP)" ;;
        2) dim "无法确认解析(缺 getent/dig),继续尝试" ;;
    esac
    port_listening 80 || warn "80 端口未监听(证书签发需要 80 可达;请确认防火墙/安全组已放行)"
    confirm "用该域名写入 Caddy 配置并申请证书?" yes || { info "已取消"; pause; return 0; }

    if [[ "$(hcfg_get "platforms.api_server.enabled")" == *true* ]] && confirm "是否同时对外提供 OpenAI 兼容 API(/v1)?" yes; then
        st_set API_ENABLED 1; st_set API_SERVER on
    else
        st_set API_ENABLED 0; st_set API_SERVER off
    fi
    dashboard_webui "$domain"
    caddy_install || { pause; return 1; }
    caddy_write_config "$domain" "$email" "$(st_api_enabled)" || { pause; return 1; }
    ok "HTTPS 已配置:https://${domain}/"
    dim "首次签发约需 10~30 秒;若失败请看:journalctl -u caddy -n 30"
    sleep 3
    local code; code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && ok "域名探活成功:https://${domain}/healthz → 200" || warn "域名探活返回 $code(证书可能还在签发,稍后重试)"
    credentials_write "$domain"
    pause
}

# =============================================================================
#  备份 / 恢复 · 更新 · 自检 · 卸载
# =============================================================================

backup_excludes=(
    # 只备份"数据与配置":代码树与 Python 运行时属可重装内容,不打包(恢复时保持原样)
    "--exclude=.hermes/tools"
    "--exclude=.hermes/hermes-agent"
    "--exclude=.hermes/sessions/*"
    "--exclude=.hermes/logs/*"
    "--exclude=.hermes/*.venv"
    "--exclude=.hermes/venv"
    "--exclude=.hermes/uv-cache"
    "--exclude=.hermes/state.db-wal"
    "--exclude=.hermes/state.db-shm"
    "--exclude=.hermes/unpacked.bak"
    "--exclude=.hermes/*.pre-restore-*"
)

backup_create() {
    require_root
    local tag="${1:-manual}"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local out="$BACKUP_DIR/hermes-${tag}-${ts}.tar.gz"
    hermes_installed || { err "Hermes 未安装,无需备份"; return 1; }

    local need_mb=0
    need_mb="$(du -sm "$UHOME" 2>/dev/null | awk '{print $1}')" || need_mb=0
    [[ -z "$need_mb" ]] && need_mb=0
    local free_mb; free_mb="$(df -Pm "$BACKUP_DIR" 2>/dev/null | awk 'NR==2{print $4}')" || free_mb=0
    if [[ "$free_mb" -lt $(( need_mb / 2 + 50 )) ]]; then
        err "备份目录空间不足(需约 $(( need_mb / 2 ))MB,可用 ${free_mb}MB)"; return 1
    fi

    step "打包备份(含配置/密钥/技能/定时任务/服务单元)"
    local staged; staged="$(mktemp -d)"
    install -d "$staged/etc" "$staged/systemd" 2>/dev/null || true
    [[ -f "$STATE_FILE" ]] && cp -p "$STATE_FILE" "$staged/etc/" 2>/dev/null || true
    [[ -f "$MIRROR_FILE" ]] && cp -p "$MIRROR_FILE" "$staged/etc/" 2>/dev/null || true
    [[ -f "$CRED_FILE" ]] && cp -p "$CRED_FILE" "$staged/etc/" 2>/dev/null || true
    [[ -f "$CADDYFILE" ]] && cp -p "$CADDYFILE" "$staged/etc/Caddyfile" 2>/dev/null || true
    local u
    for u in /etc/systemd/system/hermes-gateway.service /etc/systemd/system/hermes-dashboard.service; do
        [[ -f "$u" ]] && cp -p "$u" "$staged/systemd/" 2>/dev/null || true
    done
    [[ -d /etc/systemd/system/hermes-dashboard.service.d ]] && cp -r /etc/systemd/system/hermes-dashboard.service.d "$staged/systemd/" 2>/dev/null || true
    [[ -d /etc/systemd/system/hermes-gateway.service.d ]] && cp -r /etc/systemd/system/hermes-gateway.service.d "$staged/systemd/" 2>/dev/null || true

    local rc=0
    set +e
    tar czf "$out" "${backup_excludes[@]}" \
        -C "$HHOME" "$(basename "$UHOME")" \
        -C "$staged" etc systemd 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -gt 1 ]]; then
        warn "第一次打包失败(rc=$rc),换一种路径组合重试"
        set +e
        tar czf "$out" "${backup_excludes[@]}" \
            -C "$(dirname "$UHOME")" "$(basename "$UHOME")" \
            -C "$staged" etc systemd 2>/dev/null
        rc=$?
        set -e
    fi
    rm -rf "$staged"
    if [[ $rc -gt 1 || ! -s "$out" ]]; then rm -f "$out"; err "备份失败(rc=$rc)"; return 1; fi
    chmod 600 "$out"
    local size; size="$(du -h "$out" 2>/dev/null | awk '{print $1}')"
    ok "备份完成:$out($size)"

    # 只在手动/自动更新时保留 7 份
    local old
    old="$(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null | tail -n +8)" || old=""
    if [[ -n "$old" ]]; then
        dim "自动清理旧备份(保留最近 7 份):"
        while read -r f; do [[ -n "$f" ]] && dim "  删除 $f" && rm -f "$f"; done <<<"$old"
    fi
    return 0
}

backup_list() {
    rule
    printf '    %s备份目录:%s\n' "$BD" "$BACKUP_DIR"
    rule
    local f found=0
    while read -r f; do
        [[ -z "$f" ]] && continue
        found=1
        printf '    %s  %s%s\n' "$(du -h "$f" 2>/dev/null | awk '{print $1}')" "$(basename "$f")" "$N"
    done < <(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null || true)
    [[ $found -eq 0 ]] && printf '    (还没有备份)\n'
    rule
}

backup_restore() {
    require_root
    clear_screen
    header "恢复备份"
    local files=() f
    while read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null || true)
    if [[ ${#files[@]} -eq 0 ]]; then warn "没有可用备份"; pause; return 0; fi
    local i=0; local -a list=()
    while read -r f; do [[ -z "$f" ]] && continue; i=$((i+1)); list+=("$f"); printf '    %2d) %s(%s)\n' "$i" "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"; done < <(printf '%s\n' "${files[@]}")
    printf '     0) 返回\n'
    local ch=""; menu_choice ch "选择要恢复的备份编号"
    [[ "$ch" == "0" || -z "$ch" ]] && return 0
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#list[@]} )) || { warn "无效编号"; pause; return 1; }
    local pkg="${list[$((ch-1))]}"
    warn "恢复会把备份内容合并回 ${UHOME}(覆盖同名文件)"
    confirm "确认恢复 $(basename "$pkg") ?" no || { info "已取消"; pause; return 0; }
    backup_create pre-restore || true

    step "校验并解包"
    local staged; staged="$(mktemp -d)"
    local rc=0
    set +e; tar tzf "$pkg" >/dev/null 2>&1; rc=$?; set -e
    if [[ $rc -ne 0 ]]; then rm -rf "$staged"; err "备份包损坏(rc=$rc)"; return 1; fi
    local need_mb; need_mb="$(du -sm "$pkg" | awk '{print $1*3}')"
    local free_mb; free_mb="$(df -Pm "$HHOME" 2>/dev/null | awk 'NR==2{print $4}')" || free_mb=0
    if [[ "$free_mb" -lt "$need_mb" ]]; then rm -rf "$staged"; err "空间不足(需约 ${need_mb}MB,可用 ${free_mb}MB)"; return 1; fi

    systemctl stop hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
    set +e
    tar xzf "$pkg" -C "$staged" 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -gt 1 ]]; then
        rm -rf "$staged"; warn "解包异常(rc=$rc),已中止;服务将拉回"
        systemctl start hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
        return 1
    fi
    local rdir="$staged/$(basename "$UHOME")"
    if [[ -d "$rdir" ]]; then
        install -d "$UHOME/unpacked.bak" 2>/dev/null || true
        # 就地合并:只把将被覆盖的部分挪走,避免破坏安装
        set +e
        ( cd "$rdir" && find . -type f -print0 | while IFS= read -r -d '' rel; do
            dst="$UHOME/$rel"
            if [[ -f "$dst" ]]; then
                mkdir -p "$UHOME/unpacked.bak/$(dirname "$rel")" 2>/dev/null || true
                cp -p "$dst" "$UHOME/unpacked.bak/$rel" 2>/dev/null || true
            fi
            mkdir -p "$(dirname "$dst")" 2>/dev/null || true
            cp -p "$rel" "$dst" 2>/dev/null || true
          done ) 2>/dev/null
        set -e
        chown -R "$HUSER:$HUSER" "$UHOME" 2>/dev/null || true
        ok "配置与数据已合并回 $UHOME"
    fi
    [[ -d "$staged/etc" ]] && {
        [[ -f "$staged/etc/state.env" ]] && cp -p "$staged/etc/state.env" "$STATE_FILE" 2>/dev/null || true
        [[ -f "$staged/etc/Caddyfile" ]] && cp -p "$staged/etc/Caddyfile" "$CADDYFILE" 2>/dev/null || true
        ok "状态与 Caddy 配置已恢复"
    }
    [[ -d "$staged/systemd" ]] && cp -p "$staged"/systemd/*.service /etc/systemd/system/ 2>/dev/null || true
    rm -rf "$staged"
    systemctl daemon-reload 2>/dev/null || true
    systemctl start hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
    systemctl is-active caddy >/dev/null 2>&1 || systemctl start caddy >/dev/null 2>&1 || true
    sleep 2
    ok "已恢复并拉起服务:$(service_brief)"
    dim "被覆盖的旧文件存于 $UHOME/unpacked.bak(确认无误后可自行删除)"
    pause
}

auto_update_install() {
    require_root
    cat >/etc/systemd/system/hermes-vps-autoupdate.service <<EOF
[Unit]
Description=Hermes Agent auto update (managed by hermes-vps)
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF update --yes --no-restart
EOF
    cat >/etc/systemd/system/hermes-vps-autoupdate.timer <<'EOF'
[Unit]
Description=Daily Hermes Agent update check

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 644 /etc/systemd/system/hermes-vps-autoupdate.service /etc/systemd/system/hermes-vps-autoupdate.timer
    systemctl daemon-reload
    systemctl enable --now hermes-vps-autoupdate.timer >/dev/null 2>&1 || true
    local next; next="$(systemctl list-timers hermes-vps-autoupdate.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')"
    ok "已启用每日自动更新(04:30 左右)${next:+ · 下次:$next}"
}
auto_update_remove() {
    systemctl disable --now hermes-vps-autoupdate.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/hermes-vps-autoupdate.timer /etc/systemd/system/hermes-vps-autoupdate.service
    systemctl daemon-reload 2>/dev/null || true
    ok "已关闭自动更新"
}
auto_update_status() {
    if systemctl is-enabled hermes-vps-autoupdate.timer >/dev/null 2>&1; then
        local next; next="$(systemctl list-timers hermes-vps-autoupdate.timer --no-pager 2>/dev/null | awk 'NR==2{print $1,$2,$3}')"
        printf 'enabled%s' "${next:+ · 下次 $next}"
    else
        printf 'disabled'
    fi
}

# ---------------------------------------------------------------------------
# 自检 / 诊断
# ---------------------------------------------------------------------------
DIAG_ITEMS=(); DIAG_OK=0; DIAG_FAIL=0
diag_add() { # diag_add <状态 ok|fail|warn|info> <文本>
    local st="$1"; shift
    case "$st" in
        ok)   printf '    %s %s\n' "$OK_SYM" "$*"; DIAG_OK=$((DIAG_OK+1)) ;;
        fail) printf '    %s %s\n' "$NO_SYM" "$*"; DIAG_FAIL=$((DIAG_FAIL+1)) ;;
        warn) printf '    %s %s\n' "$WARN_SYM" "$*" ;;
        *)    printf '    %s %s\n' "$(printf '%s·%s' "$DM" "$N")" "$*" ;;
    esac
}

diagnose() {
    require_root
    clear_screen
    header "自检 / 诊断"
    DIAG_OK=0; DIAG_FAIL=0

    printf '\n  %s系统%s\n' "$BD" "$N"
    diag_add info "系统:$OS_NAME · $ARCH · ${CORES} 核 · 内存 ${MEM_MB}MB · 磁盘剩余 ${DISK_MB}MB"
    [[ "${MEM_MB:-0}" -lt 1500 && "$(swap_total_mb)" -lt 512 ]] && diag_add warn "内存偏小且无 swap,安装/更新可能 OOM" || diag_add ok "内存/swap 充足"

    printf '\n  %s安装%s\n' "$BD" "$N"
    if hermes_installed; then diag_add ok "Hermes:$(hermes_version 2>/dev/null || echo 未知)"; else diag_add fail "Hermes 未安装(菜单 1 一键部署)"; fi
    [[ -d "$UHOME/hermes-agent/hermes_cli/web_dist" ]] && diag_add ok "界面产物存在(web_dist)" || diag_add warn "界面产物缺失(重新部署会自动修复)"
    local perms; perms="$(stat -c '%a' "$UHOME/.env" 2>/dev/null || echo "-")"
    [[ "$perms" == "600" ]] && diag_add ok ".env 权限 600" || diag_add fail ".env 权限异常($perms)"

    printf '\n  %s服务%s\n' "$BD" "$N"
    local s st
    for s in hermes-gateway hermes-dashboard caddy; do
        st="$(svc_state "$s")"
        if [[ "$st" == "active" ]]; then
            local en; en="$(svc_enabled "$s")"
            diag_add ok "$s:$st($en)"
        else
            diag_add fail "$s:$st"
        fi
    done

    printf '\n  %s端口%s\n' "$BD" "$N"
    port_listening "$DASH_PORT" && diag_add ok "面板端口 ${DASH_PORT} 监听中" || diag_add fail "面板端口 ${DASH_PORT} 未监听"
    port_listening "$API_PORT" && diag_add ok "API 端口 ${API_PORT} 监听中" || diag_add info "API 端口 ${API_PORT} 未监听(未开启则正常)"
    port_listening 80 && diag_add ok "80 端口监听(Caddy)" || diag_add warn "80 端口未监听(证书签发需要)"
    port_listening 443 && diag_add ok "443 端口监听(Caddy)" || diag_add warn "443 端口未监听(HTTPS 未生效)"

    printf '\n  %s面板认证门%s\n' "$BD" "$N"
    case "$(dashboard_verify_gate)" in
        ok) diag_add ok "未登录访问被拦截(认证门生效)" ;;
        open) diag_add fail "未登录可直接访问(认证门未生效!)" ;;
        down) diag_add fail "面板无响应" ;;
        other:*) diag_add info "面板返回 $(dashboard_verify_gate)" ;;
    esac

    printf '\n  %s模型%s\n' "$BD" "$N"
    local cur; cur="$(model_current 2>/dev/null || echo '-|-')"
    diag_add info "当前:${cur%%|*} / ${cur##*|}"
    local pid envv key haskey=0
    pid="${cur%%|*}"; envv="$(prov_env "$pid" 2>/dev/null || true)"
    [[ -n "$envv" ]] && key="$(env_get "$envv")" || key=""
    [[ -n "$key" ]] && haskey=1
    [[ $haskey -eq 1 ]] && diag_add ok "密钥已配置($envv)" || diag_add fail "密钥未配置(菜单 2 配置提供商)"
    if [[ -n "$(st_get MODEL_VERIFIED)" ]]; then diag_add ok "上次验证:$(st_get MODEL_VERIFIED)"; else diag_add info "尚未做过模型连通验证(菜单 2 → v / test)"; fi

    printf '\n  %s消息平台%s\n' "$BD" "$N"
    local l id nm live conf=0
    for l in "${PLATFORMS[@]}"; do
        id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"
        plat_configured "$id" || continue
        conf=$((conf+1))
        live="$(plat_live_state "$id" 2>/dev/null || echo unknown)"
        case "$live" in
            connected) diag_add ok "$nm:已连接" ;;
            failed) diag_add fail "$nm:连接失败(看 journalctl -u hermes-gateway)" ;;
            seen) diag_add warn "$nm:已配置,日志暂无明确结论" ;;
            *) diag_add warn "$nm:已配置,未观测到连接记录" ;;
        esac
    done
    [[ $conf -eq 0 ]] && diag_add info "未配置任何消息平台(菜单 3)"

    printf '\n  %s域名与证书%s\n' "$BD" "$N"
    local domain; domain="$(st_get DOMAIN)"
    if [[ -n "$domain" ]]; then
        local rc=0; set +e; domain_points_here "$domain"; rc=$?; set -e
        case "$rc" in
            0) diag_add ok "$domain 解析指向本机" ;;
            1) diag_add fail "$domain 解析不指向本机(证书会失败)" ;;
            *) diag_add info "$domain 解析无法确认" ;;
        esac
        local days; days="$(cert_days_left "$domain" 2>/dev/null || echo "")"
        if [[ -n "$days" ]]; then
            if [[ "$days" -gt 20 ]]; then diag_add ok "证书有效,剩余 ${days} 天(到期 $(cert_expire_date "$domain" 2>/dev/null))"
            else diag_add warn "证书剩余 ${days} 天(注意续期)"; fi
        else
            diag_add warn "未找到证书文件(可能刚启动,或签发失败)"
        fi
        local code; code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && diag_add ok "HTTPS 探活 https://${domain}/healthz → 200" || diag_add fail "HTTPS 探活返回 ${code}"
        if [[ "$(st_api_enabled)" == "1" ]]; then
            local ac; ac="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
            [[ "$ac" == "401" || "$ac" == "403" ]] && diag_add ok "API 鉴权生效(无 key → ${ac})" || diag_add warn "API 无 key 返回 ${ac}(期望 401)"
        fi
    else
        diag_add warn "尚未配置域名(菜单 4)"
    fi

    printf '\n  %s访问凭据%s\n' "$BD" "$N"
    if [[ -f "$CRED_FILE" ]]; then
        local cperm; cperm="$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo '-')"
        [[ "$cperm" == "600" ]] && diag_add ok "$CRED_FILE(600)" || diag_add fail "$CRED_FILE 权限 $cperm"
    else
        diag_add warn "凭据文件不存在(配置面板后生成)"
    fi

    printf '\n  %s数据安全%s\n' "$BD" "$N"
    local n; n="$(ls -1 "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null | wc -l)" || n=0
    [[ "$n" -gt 0 ]] && diag_add ok "已有 ${n} 份备份" || diag_add warn "没有备份(菜单 8 建议先备一份)"
    diag_add info "自动更新:$(auto_update_status)"
    diag_add info "防火墙:$(st_get FIREWALL unknown)"

    rule
    if [[ $DIAG_FAIL -eq 0 ]]; then printf '    %s全部检查通过(%d 项)%s\n' "$G" "$DIAG_OK" "$N"
    else printf '    %s%d 项需要处理%s,%d 项正常\n' "$R" "$DIAG_FAIL" "$N" "$DIAG_OK"; fi
    rule
    pause
}

# ---------------------------------------------------------------------------
# 卸载(逐项列出,逐项确认,绝不批量静默删)
# ---------------------------------------------------------------------------
uninstall_preview() {
    printf '\n  %s将被处理的路径(逐项确认,可单独跳过):%s\n' "$BD" "$N"
    local items=(
      "systemd 单元|/etc/systemd/system/hermes-gateway.service|停用并删除网关服务"
      "systemd 单元|/etc/systemd/system/hermes-dashboard.service|停用并删除面板服务"
      "systemd 单元|/etc/systemd/system/hermes-dashboard.service.d|服务覆盖配置目录"
      "systemd 单元|/etc/systemd/system/hermes-vps-autoupdate.timer|自动更新定时器"
      "systemd 单元|/etc/systemd/system/hermes-vps-autoupdate.service|自动更新服务"
      "数据目录|$UHOME|Hermes 配置/会话/技能/密钥"
      "服务用户|$HHOME|hermes 用户家目录"
      "配置目录|$ETC_DIR|本工具状态与凭据"
      "程序目录|$TOOL_LOG_DIR|本工具日志"
      "Caddy|$CADDYFILE|反代配置"
      "Caddy|/etc/systemd/system/caddy.service|仅当由本工具安装二进制时"
    )
    local it
    for it in "${items[@]}"; do
        local kind path note
        kind="$(cut -d'|' -f1 <<<"$it")"; path="$(cut -d'|' -f2 <<<"$it")"; note="$(cut -d'|' -f3 <<<"$it")"
        if [[ -e "$path" ]]; then printf '    %s[%s]%s %s  %s(%s)%s\n' "$Y" "$kind" "$N" "$path" "$DM" "$note" "$N"
        else printf '    %s[跳过]%s %s  %s(不存在)%s\n' "$DM" "$N" "$path" "$DM" "$N"; fi
    done
    printf '    %s[保留]%s /var/backups/hermes-vps/ (备份永远保留)\n' "$G" "$N"
    printf '    %s[保留]%s 防火墙规则、swap、系统依赖(不还原)\n' "$G" "$N"
}

uninstall_run() {
    require_root
    clear_screen
    header "卸载 Hermes 与服务"
    warn "此操作会删除 Hermes 的配置、会话、密钥与技能(备份目录保留)"
    uninstall_preview
    rule
    confirm "确定继续吗?" no || { info "已取消"; pause; return 0; }
    if confirm "卸载前先创建一个备份?" yes; then backup_create pre-uninstall || warn "备份失败,继续?" ; fi
    confirm "最后确认:开始逐项删除?" no || { info "已取消"; pause; return 0; }

    local steps=(
      "hermes-gateway:stop|systemctl stop hermes-gateway; systemctl disable hermes-gateway; rm -f /etc/systemd/system/hermes-gateway.service; rm -rf /etc/systemd/system/hermes-gateway.service.d"
      "hermes-dashboard:stop|systemctl stop hermes-dashboard; systemctl disable hermes-dashboard; rm -f /etc/systemd/system/hermes-dashboard.service; rm -rf /etc/systemd/system/hermes-dashboard.service.d"
      "autoupdate|systemctl disable --now hermes-vps-autoupdate.timer; rm -f /etc/systemd/system/hermes-vps-autoupdate.timer /etc/systemd/system/hermes-vps-autoupdate.service"
      "caddy:stop|systemctl disable --now caddy"
    )
    local st
    for st in "${steps[@]}"; do
        local label="${st%%|*}"; local cmd="${st#*|}"
        if confirm "执行:${label}?" yes; then set +e; eval "$cmd" >/dev/null 2>&1; set -e; ok "$label 完成"; else info "跳过 $label"; fi
    done
    systemctl daemon-reload 2>/dev/null || true

    local paths=(
      "$UHOME|Hermes 数据(配置/会话/技能/密钥)"
      "$HHOME|hermes 用户家目录"
      "$ETC_DIR|本工具状态与凭据"
      "$TOOL_LOG_DIR|本工具日志"
      "$CADDYFILE|Caddy 反代配置"
    )
    local p
    for p in "${paths[@]}"; do
        local path="${p%%|*}" note="${p#*|}"
        [[ -e "$path" ]] || { info "$path 不存在,跳过"; continue; }
        local size; size="$(du -sh "$path" 2>/dev/null | awk '{print $1}')"
        if confirm "删除 ${path}(${size} · ${note})?" no; then
            rm -rf "$path"; ok "已删除 $path"
        else
            info "保留 $path"
        fi
    done
    if id "$HUSER" >/dev/null 2>&1 && confirm "删除系统用户 ${HUSER}?" no; then
        userdel "$HUSER" 2>/dev/null || warn "userdel 失败(可能有进程占用)"
        ok "已删除用户 $HUSER"
    fi
    if [[ -x "$CADDY_BIN" && ! -d /etc/apt/sources.list.d ]] && confirm "删除由本工具安装的 Caddy 二进制?" no; then
        rm -f "$CADDY_BIN"; ok "已删除 $CADDY_BIN"
    fi
    rule
    ok "卸载流程结束"
    dim "保留:$BACKUP_DIR(备份)、防火墙规则、swap、系统依赖"
    dim "如需彻底清理,可再手工检查 /etc/systemd/system 下是否残留 hermes-vps 相关单元"
    pause
}

# =============================================================================
#  界面:横幅 / 状态面板 / 主菜单 / 子菜单
# =============================================================================

clear_screen() { [[ -t 1 ]] && clear || printf '\n'; }
rule() { printf '  %s%s%s\n' "$DM" "$(printf '─%.0s' $(seq 1 74))" "$N"; }
rule_thin() { printf '  %s%s%s\n' "$DM" "$(printf '·%.0s' $(seq 1 74))" "$N"; }

# 显示宽度:只有东亚宽字符算 2 列(制表符 ─ │、圆点 ● ○ 算 1 列)
declare -A _DISP_CACHE=()
_is_wide_cp() {
    local cp="$1"
    (( cp >= 0x1100 && cp <= 0x115F )) && return 0
    (( cp >= 0x2E80 && cp <= 0x303E )) && return 0
    (( cp >= 0x3041 && cp <= 0x33FF )) && return 0
    (( cp >= 0x3400 && cp <= 0x4DBF )) && return 0
    (( cp >= 0x4E00 && cp <= 0x9FFF )) && return 0
    (( cp >= 0xA000 && cp <= 0xA4CF )) && return 0
    (( cp >= 0xAC00 && cp <= 0xD7A3 )) && return 0
    (( cp >= 0xF900 && cp <= 0xFAFF )) && return 0
    (( cp >= 0xFE30 && cp <= 0xFE6F )) && return 0
    (( cp >= 0xFF00 && cp <= 0xFF60 )) && return 0
    (( cp >= 0xFFE0 && cp <= 0xFFE6 )) && return 0
    (( cp >= 0x1F300 && cp <= 0x1FAFF )) && return 0
    (( cp >= 0x20000 && cp <= 0x3FFFD )) && return 0
    return 1
}
disp_len() {
    local s="$1" w=0 i ch cp
    if [[ -n "${_DISP_CACHE[$s]:-}" ]]; then printf '%s' "${_DISP_CACHE[$s]}"; return 0; fi
    for (( i=0; i<${#s}; i++ )); do
        ch="${s:i:1}"
        if [[ "$ch" == [[:ascii:]] ]]; then w=$((w+1)); continue; fi
        cp="$(printf '%d' "'$ch" 2>/dev/null)" || cp=0
        [[ -z "$cp" ]] && cp=0
        if _is_wide_cp "$cp"; then w=$((w+2)); else w=$((w+1)); fi
    done
    _DISP_CACHE["$s"]="$w"
    printf '%s' "$w"
}
BOXW=74
box_top()  { printf '  %s╭%s╮%s\n' "$C" "$(printf '─%.0s' $(seq 1 $BOXW))" "$N"; }
box_bot()  { printf '  %s╰%s╯%s\n' "$C" "$(printf '─%.0s' $(seq 1 $BOXW))" "$N"; }
box_sep()  { printf '  %s├%s┤%s\n' "$C" "$(printf '─%.0s' $(seq 1 $BOXW))" "$N"; }
box_line() { # box_line <纯文本用于测宽> [带色文本]
    local plain="$1" colored="${2:-$1}" w pad
    w="$(disp_len "$plain")"; pad=$(( BOXW - w ))
    (( pad < 0 )) && pad=0
    printf '  %s│%s%s%*s%s│%s\n' "$C" "$N" "$colored" "$pad" '' "$C" "$N"
    return 0
}

header() {
    local title="${1:-}"
    local os_line="${OS_NAME:-} ${ARCH:-}"
    printf '\n'
    box_top
    box_line "  Hermes Agent · VPS 一键部署与管理" "  ${BD}${M}Hermes Agent${N} · VPS 一键部署与管理"
    box_line "  模型 / QQ / 微信 / 域名 HTTPS / 自检备份" "  ${DM}模型 / QQ / 微信 / 域名 HTTPS / 自检备份${N}"
    box_line "  v$V  ·  $os_line  ·  ${CORES}C / ${MEM_MB}MB" "  ${DM}v$V  ·  $os_line  ·  ${CORES}C / ${MEM_MB}MB${N}"
    box_bot
    if [[ -n "$title" ]]; then printf '\n  %s%s%s\n' "$BD$W" "$title" "$N"; fi
    return 0
}

# 顶部状态面板
status_panel() {
    local hv gw dash cd dom days cur l id plats_ok=0 plats_conf=0
    hv="$(st_get HERMES_VERSION "$(hermes_version 2>/dev/null || echo '')")"
    [[ -z "$hv" ]] && hv="未安装"
    gw="$(svc_state hermes-gateway)"; dash="$(svc_state hermes-dashboard)"; cd="$(svc_state caddy)"
    dom="$(st_get DOMAIN)"
    cur="$(model_current 2>/dev/null || echo '-|-')"
    for l in "${PLATFORMS[@]}"; do
        id="${l%%|*}"
        plat_configured "$id" || continue
        plats_conf=$((plats_conf+1))
        [[ "$(plat_live_state "$id" 2>/dev/null || echo unknown)" == "connected" ]] && plats_ok=$((plats_ok+1))
    done

    local -a P=() CL=()
    row() { P+=("$1"); CL+=("$2"); }

    if hermes_installed; then
        row "  Hermes      ● $hv" "  Hermes      $(printf '%s' "$DOT_ON") $hv"
    else
        row "  Hermes      ○ 未安装" "  Hermes      $(printf '%s' "$DOT_OFF") 未安装(菜单 1 一键部署)"
    fi
    row "  服务        网关 $(svc_mark_plain "$gw")  面板 $(svc_mark_plain "$dash")  Caddy $(svc_mark_plain "$cd")" \
        "  服务        网关 $(svc_mark "$gw")  面板 $(svc_mark "$dash")  Caddy $(svc_mark "$cd")"
    if [[ -n "$dom" ]]; then
        days="$(cert_days_left "$dom" 2>/dev/null || echo '')"
        if [[ -n "$days" ]]; then
            row "  域名        $dom(证书剩 ${days} 天)" "  域名        ${G}$dom${N}${DM}(证书剩 ${days} 天)${N}"
        else
            row "  域名        $dom" "  域名        ${G}$dom${N}"
        fi
    else
        row "  域名        未配置(菜单 4 可配 Caddy + 自动 HTTPS)" "  域名        ${DM}未配置(菜单 4 可配 Caddy + 自动 HTTPS)${N}"
    fi
    if [[ -n "$(st_get MODEL_VERIFIED)" ]]; then
        row "  模型        ${cur%%|*} / ${cur##*|}(已验证)" "  模型        ${cur%%|*} / ${cur##*|} ${G}(已验证)${N}"
    else
        row "  模型        ${cur%%|*} / ${cur##*|}" "  模型        ${cur%%|*} / ${cur##*|}"
    fi
    if [[ $plats_conf -eq 0 ]]; then
        row "  平台        无已配置平台(菜单 3 接入 QQ/微信等)" "  平台        ${DM}无已配置平台(菜单 3 接入 QQ/微信等)${N}"
    else
        row "  平台        已配置 $plats_conf 个,已连接 $plats_ok 个" \
            "  平台        ${DM}已配置${N} $plats_conf 个${G},已连接 $plats_ok 个${N}"
    fi

    printf '\n'
    printf '  %s运行状态%s %s%s%s\n' "$BD$W" "$N" "$DM" "$(printf '─%.0s' $(seq 1 62))" "$N"
    local i
    for i in "${!P[@]}"; do printf '%s\n' "${CL[$i]}"; done
    printf '  %s%s%s\n' "$DM" "$(printf '─%.0s' $(seq 1 74))" "$N"
    return 0
}

# 菜单项:左列宽度按显示宽度补齐,描述列对得齐
menu_item() { # menu_item <编号> <名称> <描述>
    local num="$1" name="$2" desc="${3:-}"
    local left; left="$(printf '%2s) %s' "$num" "$name")"
    local pad=$(( 30 - $(disp_len "$left") ))
    (( pad < 1 )) && pad=1
    if [[ -z "$desc" ]]; then printf '    %s%s%s\n' "$BD" "$left" "$N"
    else printf '    %s%s%s%*s%s%s%s\n' "$BD" "$left" "$N" "$pad" '' "$DM" "$desc" "$N"; fi
    return 0
}
svc_mark() { case "$1" in active) printf '%s' "$DOT_ON" ;; failed) printf '%s✘%s' "$R" "$N" ;; *) printf '%s◐%s' "$Y" "$N" ;; esac; }
svc_mark_plain() { case "$1" in active) printf '●' ;; failed) printf '✘' ;; *) printf '◐' ;; esac; }

main_menu() {
    while :; do
        clear_screen
        header
        status_panel
        printf '\n  %s主菜单%s\n' "$BD$W" "$N"
        rule
        menu_item 1  "一键部署 / 重新部署" "安装 Hermes、面板、域名、平台接入"
        menu_item 2  "模型提供商"         "填 API Key,并真实验证能否对话"
        menu_item 3  "消息平台"           "QQ / 微信 / 企业微信 / 飞书 / 钉钉 / TG"
        menu_item 4  "域名与反向代理"     "Caddy 自动 HTTPS、证书状态"
        menu_item 5  "面板与 API"         "登录密码、公网地址、/v1 开关"
        menu_item 6  "服务管理"           "启动 / 停止 / 重启 / 看日志"
        menu_item 7  "自检与诊断"         "服务、端口、认证门、API、证书、备份"
        menu_item 8  "备份与恢复"         "打包配置与密钥,可一键回滚"
        menu_item 9  "更新"               "立即更新 / 每日自动更新"
        menu_item 10 "防火墙与安全"       "只放行 SSH / 80 / 443"
        menu_item 11 "网络加速探测"       "GitHub / PyPI 国内镜像自动选优"
        menu_item 12 "使用说明 / 帮助"    "常用命令与路径"
        menu_item 13 "卸载"               "逐项确认,绝不静默批量删"
        rule
        menu_item 0 "退出" ""
        rule
        local ch=""; menu_choice ch "请输入编号"
        case "$ch" in
            1) deploy_all ;;
            2) model_menu ;;
            3) plat_menu ;;
            4) domain_configure ;;
            5) panel_menu ;;
            6) service_menu ;;
            7) diagnose ;;
            8) backup_menu ;;
            9) update_menu ;;
            10) firewall_setup; pause ;;
            11) mirror_probe 1; mirror_apply_user; pause ;;
            12) show_help ;;
            13) uninstall_run ;;
            0|q|exit|quit) printf '\n  %s再见 👋%s\n\n' "$C" "$N"; return 0 ;;
            "") if [[ "${HV_EOF:-0}" == "1" || ! -t 0 ]]; then printf '\n  %s输入已结束,退出。%s\n\n' "$C" "$N"; return 0; fi ;;
            *) warn "无效编号:$ch"; sleep 1 ;;
        esac
    done
}

panel_menu() {
    while :; do
        clear_screen
        header "面板与 API"
        dashboard_show_info
        printf '    %s1)%s 查看访问信息与凭据路径\n' "$BD" "$N"
        printf '    %s2)%s 重置面板密码(随机生成)\n' "$BD" "$N"
        printf '    %s3)%s 自定义面板用户名/密码\n' "$BD" "$N"
        printf '    %s4)%s 开启 / 关闭 OpenAI 兼容 API(/v1)\n' "$BD" "$N"
        printf '    %s5)%s 验证认证门与登录(真发一次登录请求)\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) credentials_write "$(st_get DOMAIN)"; info "凭据已写入 $CRED_FILE"; pause ;;
            2) env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$(random_str 20)"; ok "密码已重置"; restart_service hermes-dashboard; credentials_write "$(st_get DOMAIN)"; dim "新密码在 $CRED_FILE"; pause ;;
            3) local u p; ask u "用户名" "$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"; ask_secret p "新密码(回车随机生成)"; [[ -z "$p" ]] && p="$(random_str 20)"; env_set HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$u"; env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$p"; restart_service hermes-dashboard; credentials_write "$(st_get DOMAIN)"; ok "账号已更新"; pause ;;
            4) if [[ "$(st_api_enabled)" == "1" ]]; then api_server_disable; else api_server_enable; fi; dashboard_webui "$(st_get DOMAIN)"; caddy_write_config "$(st_get DOMAIN)" "$(st_get ACME_EMAIL)" "$(st_api_enabled)" 2>/dev/null || true; pause ;;
            5) printf '\n'; dim "认证门:$(dashboard_verify_gate)"; dashboard_login_test; pause ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

service_menu() {
    while :; do
        clear_screen
        header "服务管理"
        printf '    %s当前状态:%s%s\n\n' "$BD" "$N" "$(service_brief)"
        printf '    %s1)%s 启动全部(gateway + dashboard + caddy)\n' "$BD" "$N"
        printf '    %s2)%s 停止全部\n' "$BD" "$N"
        printf '    %s3)%s 重启全部%s(改完配置常用)%s\n' "$BD" "$N" "$DM" "$N"
        printf '    %s4)%s 重启网关(消息平台配置生效)\n' "$BD" "$N"
        printf '    %s5)%s 重启面板\n' "$BD" "$N"
        printf '    %s6)%s 重载 Caddy(改反代后)\n' "$BD" "$N"
        printf '    %s7)%s 实时日志:网关\n' "$BD" "$N"
        printf '    %s8)%s 实时日志:面板\n' "$BD" "$N"
        printf '    %s9)%s 实时日志:Caddy\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) start_service gateway; start_service dashboard; start_service caddy; pause ;;
            2) stop_service dashboard; stop_service gateway; if confirm "同时停止 Caddy(将无法通过域名访问)?" no; then stop_service caddy; fi; pause ;;
            3) restart_all_services; pause ;;
            4) restart_service hermes-gateway; sleep 3; printf '\n'; dim "网关最近日志:"; journalctl -u hermes-gateway -n 15 --no-pager 2>/dev/null | sed 's/^/      /' | tail -n 15; pause ;;
            5) restart_service hermes-dashboard; pause ;;
            6) caddy_write_config "$(st_get DOMAIN)" "$(st_get ACME_EMAIL)" "$(st_api_enabled)" || true; pause ;;
            7) service_logs hermes-gateway ;;
            8) service_logs hermes-dashboard ;;
            9) service_logs caddy ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

update_menu() {
    while :; do
        clear_screen
        header "更新"
        printf '    Hermes 当前版本:%s%s%s\n' "$BD" "$(hermes_version 2>/dev/null || echo 未安装)" "$N"
        printf '    每日自动更新  :%s\n\n' "$(auto_update_status)"
        printf '    %s1)%s 立即更新 Hermes(先自动备份)\n' "$BD" "$N"
        printf '    %s2)%s 开启每日自动更新(04:30 左右)\n' "$BD" "$N"
        printf '    %s3)%s 关闭自动更新\n' "$BD" "$N"
        printf '    %s4)%s 更新前备份\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) hermes_update; pause ;;
            2) auto_update_install; pause ;;
            3) auto_update_remove; pause ;;
            4) backup_create manual; pause ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

backup_menu() {
    while :; do
        clear_screen
        header "备份与恢复"
        backup_list
        printf '    %s1)%s 立即备份\n' "$BD" "$N"
        printf '    %s2)%s 从备份恢复\n' "$BD" "$N"
        printf '    %s3)%s 清理旧备份(保留最近 7 份)\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) backup_create manual; pause ;;
            2) backup_restore ;;
            3) local old; old="$(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null | tail -n +8)" || old=""
               if [[ -z "$old" ]]; then info "没有需要清理的旧备份"; else
                   printf '\n  将删除:\n'; while read -r f; do [[ -n "$f" ]] && printf '    %s\n' "$f"; done <<<"$old"
                   if confirm "确认删除以上文件?" no; then while read -r f; do [[ -n "$f" ]] && rm -f "$f"; done <<<"$old"; ok "已清理"; fi
               fi; pause ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 一键部署
# ---------------------------------------------------------------------------
deploy_all() {
    require_root
    clear_screen
    header "一键部署"
    detect_os
    printf '    系统:%s · %s · %s 核 · 内存 %sMB · 磁盘剩余 %sMB\n' "$OS_NAME" "$ARCH" "$CORES" "$MEM_MB" "$DISK_MB"
    if [[ "$PKG" == "" ]]; then die "不支持的发行版(需要 Debian/Ubuntu 系;其他系统请手工装依赖)"; fi
    if [[ "$INIT" != "systemd" ]]; then die "需要 systemd(未检测到 /run/systemd/system)"; fi
    if [[ "${MEM_MB:-0}" -lt 700 ]]; then warn "内存 ${MEM_MB}MB 偏小,建议 >=1GB"; fi
    if [[ "${DISK_MB:-0}" -lt 2000 ]]; then die "磁盘剩余不足 2GB(当前 ${DISK_MB}MB)"; fi
    rule

    # 域名 / 模型 / 平台:先收集意图,再一口气跑
    local domain email want_model=1 want_platform=0
    domain="$(st_get DOMAIN)"
    ask domain "域名(用于公网访问,留空=只在本机访问)" "$domain"
    if [[ -n "$domain" ]]; then ask email "证书通知邮箱(可留空)" "$(st_get ACME_EMAIL)"; fi
    if [[ "$(st_get MODEL_PROVIDER)" == "" ]]; then
        confirm "现在配置模型提供商(填 API Key,自动验证)?" yes && want_model=1 || want_model=0
    fi
    confirm "现在接入消息平台(QQ/微信等)(稍后可做)?" no && want_platform=1 || want_platform=0
    confirm "开始部署?" yes || { info "已取消"; pause; return 0; }

    local total=10 n=0
    progress() { n=$((n+1)); printf '\n  %s[%d/%d] %s%s\n' "$BD$C" "$n" "$total" "$*" "$N"; }

    progress "系统与依赖"
    deps_install

    progress "内存保护(小内存自动补 swap)"
    ensure_swap || warn "swap 步骤失败,继续"

    progress "网络加速探测(GitHub / PyPI)"
    mirror_probe || warn "未找到可用加速通道,继续用直连"
    mirror_apply_user

    progress "创建服务用户与目录"
    ensure_user
    hermes_ensure_config
    write_runners

    progress "安装 Hermes Agent"
    hermes_install

    progress "配置面板认证门"
    dashboard_ensure_auth
    [[ -n "$domain" ]] && dashboard_webui "$domain" || dashboard_webui ""

    progress "安装并启动服务(systemd)"
    service_gateway_install
    service_dashboard_install
    if dashboard_wait_ready; then ok "面板已就绪(127.0.0.1:${DASH_PORT})"; else warn "面板未在 60 秒内就绪,看日志:journalctl -u hermes-dashboard -n 50"; fi

    progress "配置 Caddy 反向代理与 HTTPS"
    if [[ -n "$domain" ]]; then
        caddy_install
        caddy_write_config "$domain" "$email" "$(st_api_enabled)"
        sleep 2
        local code; code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && ok "HTTPS 生效:https://${domain}/" || warn "域名探活 $code(证书可能还在签发)"
    else
        info "未提供域名,跳过 Caddy 配置(菜单 4 可随时补配)"
    fi
    credentials_write "$domain"

    progress "模型提供商"
    if [[ $want_model -eq 1 ]]; then model_menu; else info "跳过(菜单 2 随时可配)"; fi

    progress "防火墙与收尾"
    firewall_setup || true

    if [[ $want_platform -eq 1 ]]; then plat_menu; fi

    rule
    printf '\n  %s部署完成%s\n' "$BD$G" "$N"
    rule
    dashboard_show_info
    status_panel
    printf '\n'
    if [[ -n "$domain" ]]; then
        dim "浏览器打开:https://${domain}/  账号密码见 ${CRED_FILE}"
    else
        dim "面板在本机 127.0.0.1:${DASH_PORT}(配域名后可用公网访问)"
    fi
    dim "接下来:菜单 2 配模型 → 菜单 3 接平台 → 菜单 7 自检"
    pause
}

# ---------------------------------------------------------------------------
# 使用说明
# ---------------------------------------------------------------------------
show_help() {
    clear_screen
    header "使用说明"
    printf '  %s常用命令%s(等价于菜单操作,可脚本化)\n' "$BD" "$N"
    rule
    printf '    bash %s                    %s打开本菜单%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s install --yes      %s无人值守部署%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s diagnose           %s自检(服务/端口/认证门/API/证书)%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s backup             %s立即备份%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s service restart    %s重启服务%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s selftest           %s检查脚本自身%s\n' "${SELF##*/}" "$DM" "$N"
    rule
    printf '  %s路径%s\n' "$BD" "$N"
    rule
    printf '    Hermes 数据 : %s(配置/.env/skills/会话/日志)\n' "$UHOME"
    printf '    本工具状态  : %s\n' "$STATE_FILE"
    printf '    访问凭据    : %s(600)\n' "$CRED_FILE"
    printf '    备份目录    : %s\n' "$BACKUP_DIR"
    printf '    Caddy 配置  : %s\n' "$CADDYFILE"
    printf '    工具日志    : %s\n' "$LOG_FILE"
    rule
    printf '  %s常看命令%s\n' "$BD" "$N"
    rule
    printf '    网关日志: journalctl -u hermes-gateway -f\n'
    printf '    面板日志: journalctl -u hermes-dashboard -f\n'
    printf '    Caddy  : journalctl -u caddy -f\n'
    printf '    改模型  : 菜单 2(或 hermes model)\n'
    printf '    改平台  : 菜单 3;改完记得重启网关(菜单 6 → 4)\n'
    rule
    pause
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF

  Hermes Agent · VPS 一键部署与管理  v$V

  用法:
    bash ${SELF##*/}                 打开交互菜单(推荐)
    bash ${SELF##*/} <命令> [参数]    直接执行,适合脚本化

  命令:
    install           一键部署(等价菜单 1)
    model             模型提供商配置(install 后可随时执行)
    platform          消息平台接入
    domain <域名>     配置 Caddy + 自动 HTTPS
    panel             面板凭据/API 开关
    service <动作>    start|stop|restart|status|logs [gateway|dashboard|caddy]
    diagnose          自检与诊断
    backup            立即备份;restore 恢复
    update            更新 Hermes;auto-update on|off|status
    firewall          配置防火墙
    mirror [--force]  探测并应用国内加速通道
    uninstall         卸载(逐项确认)
    selftest          自检脚本自身(语法/数据表/渲染)
    self-install      把自己装成命令 /usr/local/bin/hermes-vps
    version           版本

  通用参数:
    -y, --yes            全部确认自动回答“是”
    --non-interactive    非交互(不提问,用默认值/已有配置)
    --force              强制重装等
    --skip-browser       安装时跳过浏览器组件(省内存/时间)
    --no-color           关闭颜色
    --debug              打开 bash -x
EOF
}


main() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes) ASSUME_YES=1 ;;
            --non-interactive|--no-interactive) NONINTERACTIVE=1 ;;
            --force) FORCE=1 ;;
            --skip-browser) SKIP_BROWSER=1 ;;
            --no-color) NO_COLOR=1; R=""; G=""; Y=""; B=""; C=""; M=""; W=""; BD=""; DM=""; N="" ;;
            --debug) DEBUG_ON=1 ;;
            *) args+=("$1") ;;
        esac
        shift
    done
    [[ "$DEBUG_ON" == "1" ]] && set -x

    detect_os
    state_init
    load_mirror_env

    local cmd="${args[0]:-}"
    if [[ -z "$cmd" ]]; then
        if [[ -t 0 && -t 1 ]]; then require_root; main_menu
        else usage; fi
        return 0
    fi
    set -- "${args[@]}"
    shift || true

    case "$cmd" in
        help|-h|--help) usage ;;
        version|-V|--version) printf 'hermes-vps %s\n' "$V" ;;
        install|deploy) deploy_all ;;
        model) model_menu ;;
        platform|platforms) plat_menu ;;
        domain) domain_configure ;;
        panel) panel_menu ;;
        service)
            local action="${1:-status}"; shift || true
            case "$action" in
                start) start_service "${1:-gateway}" ;;
                stop) stop_service "${1:-gateway}" ;;
                restart) local t="${1:-all}"; if [[ "$t" == "all" ]]; then restart_all_services; else restart_service "$t"; fi ;;
                status) printf 'Hermes: %s\n' "$(hermes_version 2>/dev/null || echo 未安装)"; printf '服务: %s\n' "$(service_brief)" ;;
                logs) service_logs "${1:-hermes-gateway}" ;;
                *) usage; exit 1 ;;
            esac ;;
        diagnose|diag|doctor) diagnose ;;
        backup) backup_create "${1:-manual}" ;;
        restore) backup_restore ;;
        update) 
            if [[ "${1:-}" == "auto-update" ]]; then
                case "${2:-status}" in on) auto_update_install;; off) auto_update_remove;; *) auto_update_status; echo;; esac
            else hermes_update; fi ;;
        firewall) firewall_setup ;;
        mirror) mirror_probe "${1:+--force}"; mirror_apply_user; mirror_show ;;
        uninstall) uninstall_run ;;
        selftest) selftest ;;
        self-install|selfinstall)
            require_root
            install -m 755 "$SELF" /usr/local/bin/hermes-vps
            ok "已安装命令:/usr/local/bin/hermes-vps(任意目录输入 hermes-vps 即可打开菜单)" ;;
        *) err "未知命令:$cmd"; usage; exit 1 ;;
    esac
}

load_mirror_env() {
    [[ -f "$MIRROR_FILE" ]] || return 0
    set +u
    # shellcheck disable=SC1090
    . "$MIRROR_FILE" 2>/dev/null || true
    set -u
    return 0
}

# ---------------------------------------------------------------------------
# 自检脚本自身
# ---------------------------------------------------------------------------
selftest() {
    local fails=0
    printf '\n  hermes-vps 自检 v%s\n' "$V"
    rule
    local f; f="$SELF"
    if bash -n "$f" 2>/dev/null; then printf '    %s 语法检查通过\n' "$OK_SYM"; else printf '    %s 语法检查失败\n' "$NO_SYM"; bash -n "$f"; fails=$((fails+1)); fi
    printf '    %s 文件:%s\n' "$(printf '%s·%s' "$DM" "$N")" "$f"
    printf '    %s 行数:%s\n' "$(printf '%s·%s' "$DM" "$N")" "$(wc -l <"$f")"

    local n=0 l
    for l in "${PROVIDERS[@]}"; do n=$((n+1)); [[ "$(awk -F'|' '{print NF}' <<<"$l")" -eq 6 ]] || { printf '    %s 提供商表字段数异常:%s\n' "$NO_SYM" "$l"; fails=$((fails+1)); }; done
    printf '    %s 提供商数据表:%s 条\n' "$OK_SYM" "$n"
    n=0
    for l in "${PLATFORMS[@]}"; do n=$((n+1)); [[ "$(awk -F'|' '{print NF}' <<<"$l")" -eq 6 ]] || { printf '    %s 平台表字段数异常:%s\n' "$NO_SYM" "$l"; fails=$((fails+1)); }; done
    printf '    %s 平台数据表:%s 个\n' "$OK_SYM" "$n"

    local tmpd; tmpd="$(mktemp -d)"
    kv_set "$tmpd/x.env" FOO "bar baz"
    [[ "$(kv_get "$tmpd/x.env" FOO)" == "bar baz" ]] && printf '    %s 键值存储读写正常\n' "$OK_SYM" || { printf '    %s 键值存储异常\n' "$NO_SYM"; fails=$((fails+1)); }
    kv_set "$tmpd/x.env" FOO "qux"
    [[ "$(kv_get "$tmpd/x.env" FOO)" == "qux" ]] && printf '    %s 键值覆盖更新正常\n' "$OK_SYM" || { printf '    %s 键值覆盖异常\n' "$NO_SYM"; fails=$((fails+1)); }
    rm -rf "$tmpd"

    local cf; cf="$(caddy_render "example.com" "a@b.c" 1)"
    if printf '%s' "$cf" | grep -q 'reverse_proxy 127.0.0.1:9119'; then printf '    %s Caddyfile 渲染(含 API):面板路由正常\n' "$OK_SYM"; else printf '    %s Caddyfile 渲染异常\n' "$NO_SYM"; fails=$((fails+1)); fi
    cf="$(caddy_render "example.com" "" 0)"
    if printf '%s' "$cf" | grep -q '/v1/' ; then printf '    %s Caddyfile 关闭 API 时仍有 /v1 路由\n' "$NO_SYM"; fails=$((fails+1)); else printf '    %s Caddyfile 渲染(无 API):符合预期\n' "$OK_SYM"; fi
    if caddy_installed; then
        if caddy_validate "$(caddy_render "example.com" "a@b.c" 1)"; then printf '    %s 真实 caddy validate 通过\n' "$OK_SYM"; else printf '    %s caddy validate 失败\n' "$NO_SYM"; fails=$((fails+1)); fi
    else
        printf '    %s 未安装 caddy,跳过真机校验\n' "$(printf '%s·%s' "$DM" "$N")"
    fi
    rule
    if [[ $fails -eq 0 ]]; then printf '    %s全部通过%s\n\n' "$G" "$N"; else printf '    %s%d 项失败%s\n\n' "$R" "$fails" "$N"; return 1; fi
}

main "$@"

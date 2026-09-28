#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/common.sh
# 公共基础设施:常量、路径、日志、错误处理、状态读写、以服务用户身份执行命令。
# 所有模块都 source 本文件,并且只使用这里提供的原语。
# =============================================================================

[[ -n "${HV_COMMON_LOADED:-}" ]] && return 0
HV_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# 版本与目录布局
# ---------------------------------------------------------------------------
HV_VERSION="${HV_VERSION:-1.0.0}"
HV_NAME="hermes-vps"

# 脚本自身的安装位置(用于文档/自更新;/opt/hermes-vps 是 install.sh 的默认落点)
HV_SELF_DIR="${HV_SELF_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# 受管系统目录
HV_ETC="${HV_ETC:-/etc/hermes-vps}"              # 状态、镜像选择、凭证
HV_STATE_FILE="${HV_ETC}/state.env"              # 安装状态(键值)
HV_MIRROR_FILE="${HV_ETC}/mirror.env"            # 镜像/加速选择(可被 shell source)
HV_CRED_FILE="${HV_ETC}/credentials.txt"         # 自动生成的面板密码等(0600)
HV_LOG_DIR="${HV_LOG_DIR:-/var/log/hermes-vps}"
HV_BACKUP_DIR="${HV_BACKUP_DIR:-/var/backups/hermes-vps}"

# Hermes 服务用户与数据目录
HV_USER="${HV_USER:-hermes}"
HV_USER_HOME="${HV_USER_HOME:-/opt/hermes}"
HV_UHOME="${HV_UHOME:-${HV_USER_HOME}/.hermes}"  # = HERMES_HOME
HV_HERMES_BIN="${HV_HERMES_BIN:-${HV_USER_HOME}/.local/bin/hermes}"

# 端口
HV_DASH_PORT="${HV_DASH_PORT:-9119}"
HV_API_PORT="${HV_API_PORT:-8642}"

# 官方资源
HV_OFFICIAL_INSTALL_URL="https://hermes-agent.nousresearch.com/install.sh"
HV_REPO_URL="https://github.com/NousResearch/hermes-agent.git"
HV_SELF_REPO="${HV_SELF_REPO:-}"                 # 本脚本仓库(install.sh 自举时用)

# 运行模式
HV_NONINTERACTIVE="${HV_NONINTERACTIVE:-0}"      # 1 = 不提问,全部走默认/参数
HV_ASSUME_YES="${HV_ASSUME_YES:-0}"              # 1 = 危险操作直接确认(仅显式 flag)

# ---------------------------------------------------------------------------
# 输出样式
# ---------------------------------------------------------------------------
if [[ -t 1 && "${HV_NO_COLOR:-0}" != "1" ]]; then
    HV_C_RED=$'\033[31m';   HV_C_GREEN=$'\033[32m'; HV_C_YELLOW=$'\033[33m'
    HV_C_BLUE=$'\033[34m';  HV_C_DIM=$'\033[2m';    HV_C_BOLD=$'\033[1m'
    HV_C_CYAN=$'\033[36m';  HV_C_RESET=$'\033[0m'
else
    HV_C_RED=""; HV_C_GREEN=""; HV_C_YELLOW=""; HV_C_BLUE=""
    HV_C_DIM=""; HV_C_BOLD=""; HV_C_CYAN=""; HV_C_RESET=""
fi

_hv_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_hv_logfile() {
    [[ -n "${HV_LOG_DIR:-}" ]] || return 0
    [[ -d "$HV_LOG_DIR" ]] || mkdir -p "$HV_LOG_DIR" 2>/dev/null || return 0
    printf '%s\n' "${HV_LOG_FILE:-$HV_LOG_DIR/${HV_NAME}.log}"
}

# 同时进终端和日志文件
hv_log() {
    local level="$1"; shift
    local line; line="$(_hv_ts) [$level] $*"
    local f; f="$(_hv_logfile)"
    [[ -n "$f" ]] && printf '%s\n' "$line" >>"$f" 2>/dev/null || true
    case "$level" in
        info) printf '%s\n' "${HV_C_BLUE}·${HV_C_RESET} $*" ;;
        ok)   printf '%s\n' "${HV_C_GREEN}✔${HV_C_RESET} $*" ;;
        warn) printf '%s\n' "${HV_C_YELLOW}!${HV_C_RESET} $*" >&2 ;;
        err)  printf '%s\n' "${HV_C_RED}✘${HV_C_RESET} $*" >&2 ;;
        step) printf '\n%s\n' "${HV_C_BOLD}▶ $*${HV_C_RESET}" ;;
        raw)  printf '%s\n' "$*" ;;
    esac
}

hv_info() { hv_log info "$@"; }
hv_ok()   { hv_log ok "$@"; }
hv_warn() { hv_log warn "$@"; }
hv_err()  { hv_log err "$@"; }
hv_step() { hv_log step "$@"; }
hv_dim()  { printf '%s\n' "${HV_C_DIM}$*${HV_C_RESET}"; }

hv_die() { hv_err "$*"; exit 1; }

# 错误定位:打印模块 + 行号 + 日志路径,便于用户回报
# 重要:只在 errexit(set -e)开启时才终止。
# 代码里用 `set +e; cmd; rc=$?` 主动容错的片段(例如服务安装的多级回退、
# 探测类命令)不能因为 ERR 陷阱直接退出,否则回退逻辑永远走不到。
hv_on_error() {
    local code=$? line=${1:-?} cmd=${2:-?}
    [[ $code -eq 0 ]] && return 0
    case "$-" in
        *e*) : ;;
        *)   return 0 ;;   # errexit 已关闭 = 调用方自己处理返回值
    esac
    hv_err "执行失败(退出码 ${code})"
    hv_err "位置: ${BASH_SOURCE[2]:-?}:${line}  →  ${cmd}"
    local f; f="$(_hv_logfile)"
    [[ -n "$f" ]] && hv_err "完整日志: $f"
    exit "$code"
}

hv_install_trap() {
    if [[ "${HV_DEBUG:-0}" == "1" ]]; then
        set -x
    fi
    trap 'hv_on_error "$LINENO" "$BASH_COMMAND"' ERR
}

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------
hv_have() { command -v "$1" >/dev/null 2>&1; }

hv_require_root() {
    [[ "$(id -u)" -eq 0 ]] || hv_die "需要 root 权限。请用 sudo 运行,例如: sudo ${HV_NAME}${*:+ $*}"
}

hv_require_cmd() {
    local c
    for c in "$@"; do
        hv_have "$c" || hv_die "缺少必需命令: $c"
    done
}

# 只在前景有 tty 时才认为可以交互
hv_can_interact() {
    [[ "${HV_NONINTERACTIVE}" == "1" ]] && return 1
    [[ -t 0 && -t 1 ]] || return 1
    return 0
}

# 随机串:优先 openssl,退回 /dev/urandom
# head 提前关闭管道会让上游收到 SIGPIPE,在 pipefail 下会算失败,所以统一兜住
hv_random() {
    local n="${1:-16}" out=""
    if hv_have openssl; then
        out="$(openssl rand -base64 96 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$n" 2>/dev/null)" || out=""
    fi
    if [[ -z "$out" ]]; then
        out="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" 2>/dev/null)" || out=""
    fi
    printf '%s' "$out"
}

hv_random_hex() {
    local n="${1:-32}" out=""
    if hv_have openssl; then
        out="$(openssl rand -hex "$n" 2>/dev/null)" || out=""
    fi
    if [[ -z "$out" ]]; then
        out="$(head -c "$n" /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')" || out=""
    fi
    printf '%s' "$out"
}

# 备份一个文件(改动前调用),保留最近 5 份
hv_backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local d="${f%/*}/.bak"; mkdir -p "$d"
    cp -p "$f" "$d/$(basename "$f").$(date +%Y%m%d%H%M%S)"
    ls -1t "$d" 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$d/$old"; done
}

# 幂等写 KEY=VALUE 到文件(存在则替换)
hv_kv_set() {
    local file="$1" key="$2" val="$3"
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || : >"$file"
    chmod 600 "$file" 2>/dev/null || true
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file"; then
        # 用临时文件替换,避免 sed -i 在符号链接/权限上的差异
        local tmp; tmp="$(mktemp)"
        sed -E "s|^[[:space:]]*(export[[:space:]]+)?${key}=.*|${key}=${val}|" "$file" >"$tmp"
        cat "$tmp" >"$file"; rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$val" >>"$file"
    fi
}

hv_kv_get() {
    local file="$1" key="$2" def="${3:-}"
    local v="" line=""
    if [[ -f "$file" ]]; then
        # 注意:入口脚本开了 set -o pipefail,grep 无匹配会返回 1,
        # 因此这里必须显式兜住,否则"读不存在的键"会直接中止整个脚本。
        line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1)" || line=""
        if [[ -n "$line" ]]; then
            v="${line#*=}"
            v="${v%\"}"; v="${v#\"}"
            v="${v%\'}"; v="${v#\'}"
        fi
    fi
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$def"
}

hv_kv_unset() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp; tmp="$(mktemp)"
    grep -vE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" >"$tmp" || true
    cat "$tmp" >"$file"; rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 安装状态(/etc/hermes-vps/state.env)
# ---------------------------------------------------------------------------
hv_state_init() {
    mkdir -p "$HV_ETC" "$HV_LOG_DIR" "$HV_BACKUP_DIR"
    chmod 755 "$HV_ETC"
    [[ -f "$HV_STATE_FILE" ]] || { : >"$HV_STATE_FILE"; chmod 600 "$HV_STATE_FILE"; }
}

hv_state_set() { hv_state_init; hv_kv_set "$HV_STATE_FILE" "$1" "$2"; }
hv_state_get() { hv_kv_get "$HV_STATE_FILE" "$1" "${2:-}"; }

# 载入状态到环境(前缀 HVS_)
hv_state_load() {
    [[ -f "$HV_STATE_FILE" ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        printf -v "HVS_${k}" '%s' "$v"
    done <"$HV_STATE_FILE"
}

# ---------------------------------------------------------------------------
# 以服务用户身份执行(hermes 命令、git 等)
# ---------------------------------------------------------------------------
# 用法: hv_run_as_user_env <user> [KEY=VAL ...] -- <命令> [参数...]
hv_run_as_user_env() {
    local user="$1"; shift
    local home; home="$(getent passwd "$user" | cut -d: -f6)"
    [[ -n "$home" ]] || hv_die "用户不存在: $user"

    # 载入镜像相关的环境变量,确保 hermes/git/uv 都走同一个加速方案
    local env_args=("HOME=$home" "PATH=${home}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "TERM=xterm")
    local extra_args=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do extra_args+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift

    if [[ -f "$HV_MIRROR_FILE" ]]; then
        local k v
        while IFS='=' read -r k v; do
            [[ -z "$k" || "$k" == \#* ]] && continue
            env_args+=("$k=$v")
        done <"$HV_MIRROR_FILE"
    fi
    env_args+=("${extra_args[@]}")

    env -i "${env_args[@]}" \
        su -s /bin/bash "$user" -c "$(printf '%q ' "$@")"
}

hv_run_as_user() {
    local user="$1"; shift
    hv_run_as_user_env "$user" -- "$@"
}

# 把镜像环境导成本 shell 变量的数组,供需要 export 的场景使用
hv_mirror_env_array() {
    local -n _out="$1"
    [[ -f "$HV_MIRROR_FILE" ]] || return 0
    local k v
    while IFS='=' read -r k v; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        _out+=("$k=$v")
    done <"$HV_MIRROR_FILE"
}

# 运行 hermes 子命令(自动带上 HERMES_HOME)
hv_hermes() {
    local uhome="${1:-}"; shift || true
    if [[ "$uhome" == /* ]]; then
        hv_run_as_user "$HV_USER" env "HERMES_HOME=$uhome" "$HV_HERMES_BIN" "$@"
    else
        [[ -n "$uhome" ]] && set -- "$uhome" "$@"
        hv_run_as_user "$HV_USER" env "HERMES_HOME=$HV_UHOME" "$HV_HERMES_BIN" "$@"
    fi
}

# hermes 是否已安装可用
hv_hermes_installed() {
    [[ -x "$HV_HERMES_BIN" ]] || return 1
    return 0
}

# 写 hermes 配置(永远走 hermes config set,不手改 YAML)
hv_hermes_config_set() {
    local key="$1" val="$2"
    hv_state_load
    hv_hermes config set "$key" "$val" >/dev/null 2>&1 || {
        hv_warn "config set 失败: $key"
        return 1
    }
    hv_info "配置已写入: ${key} = ${val}"
}

# 写密钥到 $HERMES_HOME/.env(仅密钥,settings 走 config set)
hv_hermes_env_set() {
    local key="$1" val="$2"
    hv_kv_set "${HV_UHOME}/.env" "$key" "$val"
}

# ---------------------------------------------------------------------------
# systemd 辅助
# ---------------------------------------------------------------------------
hv_has_systemd() {
    [[ -d /run/systemd/system ]] && hv_have systemctl
}

hv_systemd_reload() { hv_has_systemd && systemctl daemon-reload; }

hv_service_exists() { [[ -f "/etc/systemd/system/$1" ]] || systemctl list-unit-files "$1" >/dev/null 2>&1; }

# 打印分隔线
hv_rule() { printf '%s\n' "${HV_C_DIM}────────────────────────────────────────────────────────────${HV_C_RESET}"; }

hv_banner() {
    printf '%s\n' "${HV_C_CYAN}${HV_C_BOLD}"
    cat <<'EOF'
  ╭──────────────────────────────────────────────╮
  │   Hermes Agent VPS 一键部署与管理 (hermes-vps) │
  ╰──────────────────────────────────────────────╯
EOF
    printf '%s' "${HV_C_RESET}"
    hv_dim "  版本 ${HV_VERSION} · 服务用户 ${HV_USER} · HERMES_HOME ${HV_UHOME}"
}

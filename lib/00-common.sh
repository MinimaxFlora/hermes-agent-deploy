# =============================================================================
#  Hermes Agent · VPS 一键部署与管理
#
#  这是模块化源码的一部分(源码布局见仓库 README):
#    lib/*.sh        按职责分块的实现,编号即加载顺序
#    bin/hermes-vps  入口:开发时直接运行会自动载入 lib/
#    build.sh        把 lib/ 与入口拼装成发布用的单文件 dist/hermes-vps.sh
#  发布产物不提交仓库,由 GitHub Actions 构建后上传到 Release。
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "需要 bash >= 4(当前 $BASH_VERSION)" >&2; exit 1; fi

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 路径与常量
# ---------------------------------------------------------------------------
V="__HV_VERSION__"                 # 由 build.sh 注入
[[ "$V" == __HV_* ]] && V="dev"     # 未构建(开发模式)时显示 dev
SELF="${BASH_SOURCE[0]}"
SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"

# ---------------------------------------------------------------------------
# 运行模式
#   root        → 系统级:专用服务用户、systemd 系统服务、/etc 配置、Caddy 80/443
#   普通用户    → 用户态:一切落在 $HOME、systemd --user(不可用时后台进程)、
#                需要特权的能力会提示用 sudo 重新执行同一命令
# 可用 HV_FORCE_MODE=system|user 覆盖(测试/容器用)
# ---------------------------------------------------------------------------
RUN_UID="$(id -u)"
HV_MODE="${HV_FORCE_MODE:-$([[ "$RUN_UID" -eq 0 ]] && echo system || echo user)}"
HV_ARGV=("$@")                                   # 原始参数:提权重新执行时原样传递

# 服务的用户:系统级是专用用户 hermes;用户态就是当前登录用户
if [[ "$HV_MODE" == "system" ]]; then
    SERVICE_USER="${HV_SERVICE_USER:-hermes}"
else
    SERVICE_USER="${HV_SERVICE_USER:-$(id -un)}"
fi
USER_HOME="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)" || USER_HOME=""
[[ -n "$USER_HOME" ]] || USER_HOME="$HOME"

# 路径:两种模式各一套;所有路径都可用 HV_* 重定位(测试沙箱/自定义部署)
if [[ "$HV_MODE" == "system" ]]; then
    ETC_DIR="${HV_ETC_DIR:-/etc/hermes-vps}"
    TOOL_LOG_DIR="${HV_LOG_DIR:-/var/log/hermes-vps}"
    BACKUP_DIR="${HV_BACKUP_DIR:-/var/backups/hermes-vps}"
    HUSER="hermes"                                        # 专用服务用户
    HHOME="${HV_HHOME:-/opt/hermes}"
    CADDYFILE="${HV_CADDYFILE:-/etc/caddy/Caddyfile}"
    CADDY_LOG_DIR="${HV_CADDY_LOG_DIR:-/var/log/caddy}"
    CADDY_BIN="${HV_CADDY_BIN:-/usr/local/bin/caddy}"
else
    ETC_DIR="${HV_ETC_DIR:-$USER_HOME/.config/hermes-vps}"
    TOOL_LOG_DIR="${HV_LOG_DIR:-$USER_HOME/.local/state/hermes-vps}"
    BACKUP_DIR="${HV_BACKUP_DIR:-$USER_HOME/.local/share/hermes-vps/backups}"
    HUSER="$SERVICE_USER"                                 # 不创建用户,就是自己
    HHOME="${HV_HHOME:-$USER_HOME}"
    CADDYFILE="${HV_CADDYFILE:-$USER_HOME/.config/caddy/Caddyfile}"
    CADDY_LOG_DIR="${HV_CADDY_LOG_DIR:-$USER_HOME/.local/state/caddy}"
    CADDY_BIN="${HV_CADDY_BIN:-$USER_HOME/.local/bin/caddy}"
fi
STATE_FILE="$ETC_DIR/state.env"
MIRROR_FILE="$ETC_DIR/mirror.env"
CRED_FILE="$ETC_DIR/credentials.txt"
UHOME="${HV_HERMES_HOME:-$HHOME/.hermes}"      # HERMES_HOME
HBIN="${HV_HERMES_BIN:-$HHOME/.local/bin/hermes}"

DASH_PORT="${DASH_PORT:-9119}"
API_PORT="${API_PORT:-8642}"

# 注意:CADDYFILE / CADDY_LOG_DIR / CADDY_BIN 已在上面的「运行模式」块里按模式设置,
# 这里不要再赋值(否则会把用户态的 ~/.config/caddy、~/.local/state/caddy 覆盖回系统路径)。

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
    if mkdir -p "$TOOL_LOG_DIR" 2>/dev/null; then printf '%s\n' "$line" 2>/dev/null >>"$LOG_FILE" || true; fi
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
is_root() { [[ "$RUN_UID" -eq 0 ]]; }
have_sudo() { command -v sudo >/dev/null 2>&1; }
mode_label() { if [[ "$HV_MODE" == "system" ]]; then printf '系统级(root)'; else printf '用户态(%s)' "$(id -un)"; fi; }

# 需要特权时:root 直接过;普通用户有 sudo 就提示并原样提权重跑
require_root() {
    is_root && return 0
    warn "该操作需要系统级权限(root):$(printf '%s ' "$@")"
    if have_sudo; then
        if confirm "用 sudo 以 root 身份重新执行同一命令?" yes; then
            info "正在提权:sudo bash $SELF ${HV_ARGV[*]:-}"
            exec sudo -E bash "$SELF" "${HV_ARGV[@]}"
        fi
        return 1
    fi
    die "需要 root 权限,且系统里没有 sudo。请用 root 登录执行,或安装 sudo 后重试(也可以选择用户态模式的功能)"
}

# 菜单里的特权入口:root 直接过;普通用户有 sudo 就征询后原样提权重跑;否则提示并返回 1(不退出脚本)
escalate_or_skip() { # escalate_or_skip <能力说明>
    is_root && return 0
    if have_sudo; then
        if confirm "「$1」需要系统级权限(root),用 sudo 重新执行整条命令?" yes; then
            info "正在提权:sudo bash $SELF ${HV_ARGV[*]:-}"
            exec sudo -E bash "$SELF" "${HV_ARGV[@]}"
        fi
    else
        warn "「$1」仅系统级(root)可用:当前是用户态且系统里没有 sudo"
        dim "可以先部署用户态实例(全部落在 \$HOME),或换 root 登录执行"
    fi
    return 1
}

# 菜单里遇到仅 root 可做的能力时调用:普通用户就提示(可提权),而不是悄悄失败
require_root_for() { # require_root_for <能力说明>
    is_root && return 0
    warn "「$1」需要系统级权限(root):涉及系统用户、systemd 系统服务、防火墙或 80/443 端口"
    dim "普通用户可以先部署用户态实例(全部落在 \$HOME),或改用 sudo 运行本工具"
    return 1
}
interactive() { [[ "$NONINTERACTIVE" == "1" ]] && return 1; [[ -t 0 && -t 1 ]]; }

random_str() { # random_str [长度]  —— 注意:`|| true` 而非 `|| out=""`:管道可能因 head 提前退出而返回非零,
    local n="${1:-16}" out=""        # 但内容已经抓到了,不能把它清空(否则生成空密码,真机上踩过)
    if have openssl; then
        out="$(openssl rand -base64 96 2>/dev/null | tr -dc 'A-Za-z0-9')" || true
    fi
    if [[ -z "$out" ]]; then
        out="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$((n * 4))" 2>/dev/null)" || true
    fi
    printf '%s' "${out:0:n}"
}
random_hex() { # random_hex [字节数]
    local n="${1:-32}" out=""
    if have openssl; then
        out="$(openssl rand -hex "$n" 2>/dev/null)" || true
    fi
    if [[ -z "$out" ]]; then
        out="$(head -c "$((n * 2))" /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')" || true
    fi
    printf '%s' "${out:0:$((n * 2))}"
}

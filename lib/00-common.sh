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

# 路径可用环境变量重定位(便于测试/沙箱以非 root 运行;生产用默认值)
ETC_DIR="${HV_ETC_DIR:-/etc/hermes-vps}"
STATE_FILE="$ETC_DIR/state.env"
MIRROR_FILE="$ETC_DIR/mirror.env"
CRED_FILE="$ETC_DIR/credentials.txt"
TOOL_LOG_DIR="${HV_LOG_DIR:-/var/log/hermes-vps}"
BACKUP_DIR="${HV_BACKUP_DIR:-/var/backups/hermes-vps}"

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

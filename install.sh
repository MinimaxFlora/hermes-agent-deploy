#!/usr/bin/env bash
# =============================================================================
# hermes-vps bootstrap(用于 curl | bash 一键拉起)
#
#   curl -fsSL https://raw.githubusercontent.com/<你的仓库>/main/install.sh | bash -s -- install
#   curl -fsSL .../install.sh | bash -s -- install --domain hermes.example.com --email me@example.com
#
# 行为:
#   1. 如果就在本地仓库里跑,直接用仓库里的 bin/hermes-vps;
#   2. 否则把仓库下载到 /opt/hermes-vps,并软链 /usr/local/bin/hermes-vps;
#   3. 之后把参数原样交给 hermes-vps(第一条默认是 install)。
# 网络:GitHub 直连失败时自动尝试几个国内可达的加速前缀。
# =============================================================================

set -Eeuo pipefail

# 改成你自己的仓库地址(或用环境变量 HV_SELF_REPO 覆盖)
HV_SELF_REPO="${HV_SELF_REPO:-https://github.com/MinimaxFlora/hermes-vps}"
HV_SELF_REF="${HV_SELF_REF:-main}"
HV_SELF_DIR_DEFAULT="/opt/hermes-vps"

HV_GH_MIRRORS=("" "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/" "https://gh.llkk.cc/")

_c() { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
info() { _c "34" "· $*"; }
ok()   { _c "32" "✔ $*"; }
warn() { _c "33" "! $*" >&2; }
die()  { _c "31" "✘ $*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v tar  >/dev/null 2>&1 || die "需要 tar"

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARGS=("$@")
# 默认动作
[[ ${#ARGS[@]} -eq 0 ]] && ARGS=(install)

# 解析本脚本自己的参数
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
    case "${ARGS[$i]}" in
        --repo) HV_SELF_REPO="${ARGS[$((i+1))]:-}"; ARGS=("${ARGS[@]:0:$i}" "${ARGS[@]:$((i+2))}") ;;
        --ref)  HV_SELF_REF="${ARGS[$((i+1))]:-}";  ARGS=("${ARGS[@]:0:$i}" "${ARGS[@]:$((i+2))}") ;;
        --dir)  HV_SELF_DIR_DEFAULT="${ARGS[$((i+1))]:-}"; ARGS=("${ARGS[@]:0:$i}" "${ARGS[@]:$((i+2))}") ;;
        *) i=$((i+1)) ;;
    esac
done

# --- 情况 1:本地仓库 ------------------------------------------------------
if [[ -x "${SELF_DIR}/bin/hermes-vps" ]]; then
    ok "使用本地仓库:${SELF_DIR}"
    HV_SELF_DIR="${SELF_DIR}" exec "${SELF_DIR}/bin/hermes-vps" "${ARGS[@]}"
fi

# --- 情况 2:需要下载 ------------------------------------------------------
command -v tar >/dev/null 2>&1 || die "需要 tar"
if [[ "$(id -u)" -eq 0 ]]; then
    TARGET="${HV_SELF_DIR_DEFAULT}"
    LINK="/usr/local/bin/hermes-vps"
else
    TARGET="${HOME}/.hermes-vps"
    LINK="${HOME}/.local/bin/hermes-vps"
fi
mkdir -p "$TARGET"
install -d "$(dirname "$LINK")" 2>/dev/null || true

# github.com/NousResearch/hermes-agent → codeload 用的 owner/repo
_slug() { printf '%s' "$1" | sed -E 's#^https?://github\.com/##; s#\.git$##'; }
SLUG="$(_slug "$HV_SELF_REPO")"
info "仓库:$SLUG (分支 $HV_SELF_REF) → $TARGET"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fetched=0
for p in "${HV_GH_MIRRORS[@]}"; do
    url="${p}https://codeload.github.com/${SLUG}/tar.gz/refs/heads/${HV_SELF_REF}"
    if [[ -z "$p" ]]; then url="https://codeload.github.com/${SLUG}/tar.gz/refs/heads/${HV_SELF_REF}"; fi
    info "尝试下载:$([[ -z $p ]] && echo 直连 || echo "$p")"
    if curl -fsSL --max-time 120 -o "$TMP/src.tgz" "$url" && [[ -s "$TMP/src.tgz" ]] && tar tzf "$TMP/src.tgz" >/dev/null 2>&1; then
        fetched=1; break
    fi
done
[[ $fetched -eq 1 ]] || die "下载失败,请检查网络或用 git clone 后本地执行:bash bin/hermes-vps install"

tar xzf "$TMP/src.tgz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -n1)"
[[ -n "$SRC" ]] || die "解包失败"
cp -a "${SRC}/." "$TARGET/"
chmod +x "${TARGET}/bin/hermes-vps" "${TARGET}/install.sh"
ok "已安装到 $TARGET"
ln -sf "${TARGET}/bin/hermes-vps" "$LINK"
ok "已创建命令:$LINK"

exec "$LINK" "${ARGS[@]}"

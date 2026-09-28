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

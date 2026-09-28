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
# 注意:403/429 是"被挡",绝不能算可用 —— 真机踩过:探活 403 的通道被选中当加速,
# 结果 git 克隆 403 失败,官方安装脚本直接挂掉。只有 2xx(及不支持 Range 的 416)算可用。
_probe_ok() { [[ "${1%% *}" =~ ^(200|206|416)$ ]]; }

mirror_probe() {
    local force="${1:-0}"
    if [[ "$force" != "1" && -f "$MIRROR_FILE" ]]; then
        info "已有加速配置($MIRROR_FILE);重新测速: mirror probe --force"
        return 0
    fi
    local probe="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md"
    local p url res t best="" bestt=99 direct_ok=0
    step "探测 GitHub 通道"
    for p in "${GH_PREFIX_CANDIDATES[@]}"; do
        if [[ -z "$p" ]]; then url="$probe"; else url="${p}${probe}"; fi
        res="$(_probe "$url" 8)"; t="${res##* }"
        if _probe_ok "$res"; then
            [[ -z "$p" ]] && direct_ok=1
            if awk -v a="$t" -v b="$bestt" 'BEGIN{exit !(a<b)}'; then best="$p"; bestt="$t"; fi
        fi
        dim "$([[ -z $p ]] && echo 直连 || echo "$p") → HTTP ${res%% *} / ${t}s"
    done
    # 直连能用就不折腾代理前缀:代理对 git 克隆经常不友好(403/改写失效,真机踩过)
    if [[ $direct_ok -eq 1 ]]; then best=""; fi
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
    if id "$HUSER" >/dev/null 2>&1; then
        # 先清掉以前可能写入的各家前缀(避免留下失效改写)
        local c
        for c in "${GH_PREFIX_CANDIDATES[@]}"; do
            [[ -z "$c" ]] && continue
            run_as_user "$HUSER" git config --global --unset-all "url.${c}https://github.com/.insteadOf" >/dev/null 2>&1 || true
        done
        if [[ -n "${HV_MIRROR_GH_PREFIX:-}" ]]; then
            # 探活通过 ≠ 能克隆:必须实测(真机踩过探活返回 403 的通道让 git clone 全挂)
            if run_as_user "$HUSER" timeout 45 git ls-remote --exit-code \
                   "${HV_MIRROR_GH_PREFIX}https://github.com/NousResearch/hermes-agent.git" HEAD >/dev/null 2>&1; then
                run_as_user "$HUSER" git config --global \
                    "url.${HV_MIRROR_GH_PREFIX}https://github.com/.insteadOf" "https://github.com/" >/dev/null 2>&1 \
                    && info "已为 $HUSER 配置 git GitHub 加速(已实测可克隆)"
            else
                warn "通道 ${HV_MIRROR_GH_PREFIX} 无法用于 git 克隆,已跳过 git 改写(直连不受影响)"
            fi
        fi
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
    # 系统级环境变量文件:只有 root 能写。用户态跳过(原来会在这里 Permission denied 并把
    # 整个部署打断 —— 真机 [2/8] 就栽在这)。写失败也只提示,绝不让部署失败。
    if [[ "$HV_MODE" == "system" ]]; then
        if { printf '# hermes-vps 网络加速(自动生成)\n'
             [[ -n "${UV_DEFAULT_INDEX:-}" ]] && printf 'export UV_DEFAULT_INDEX="%s"\n' "$UV_DEFAULT_INDEX"
             [[ -n "${UV_INDEX_URL:-}" ]] && printf 'export UV_INDEX_URL="%s"\n' "$UV_INDEX_URL"
             [[ -n "${UV_PYTHON_INSTALL_MIRROR:-}" ]] && printf 'export UV_PYTHON_INSTALL_MIRROR="%s"\n' "$UV_PYTHON_INSTALL_MIRROR"; } 2>/dev/null >/etc/profile.d/hermes-vps-mirror.sh; then
            chmod 644 /etc/profile.d/hermes-vps-mirror.sh 2>/dev/null || true
            info "已写入全局加速环境变量:/etc/profile.d/hermes-vps-mirror.sh"
        else
            warn "写入 /etc/profile.d 失败(已跳过,不影响本工具与 uv 的加速)"
        fi
    else
        dim "用户态:跳过 /etc/profile.d(仅系统级);加速已对本工具与 uv 生效"
    fi
    return 0
}

mirror_show() {
    if [[ ! -f "$MIRROR_FILE" ]]; then info "尚未探测(菜单里选“网络加速探测”即可)"; return 0; fi
    rule
    grep -vE '^\s*#' "$MIRROR_FILE" | sed 's/^/    /'
    rule
}

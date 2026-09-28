#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/mirror.sh
# 网络加速探测与落地:
#   1) 逐个测速 GitHub 直连 vs 各加速前缀,选最快可用的;
#   2) 选一个可用的 PyPI 镜像;
#   3) 把结果写进 /etc/hermes-vps/mirror.env,并落成 hermes 用户的
#      git insteadOf / uv.toml —— 这样 hermes update、PM 装依赖也自动走加速。
# 全部失败时不报错,退回直连(海外 VPS 的正常路径)。
# =============================================================================

[[ -n "${HV_MIRROR_LOADED:-}" ]] && return 0
HV_MIRROR_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# 候选加速前缀(空字符串 = 直连)
HV_GH_PREFIX_CANDIDATES=(
    ""
    "https://gh-proxy.com/"
    "https://ghfast.top/"
    "https://ghproxy.net/"
    "https://gh.llkk.cc/"
    "https://github.moeyy.xyz/"
)
HV_PYPI_CANDIDATES=(
    "https://pypi.tuna.tsinghua.edu.cn/simple"
    "https://mirrors.aliyun.com/pypi/simple"
    "https://mirrors.cloud.tencent.com/pypi/simple"
    "https://mirrors.ustc.edu.cn/pypi/simple"
    "https://pypi.org/simple"
)

_hv_http_probe() {
    # 返回 "<http_code> <time_total>";失败返回 "000 99"
    # 用 Range 只取前 64KB,避免为了测速把整个索引页拉下来
    local url="$1" timeout="${2:-8}"
    local out
    out="$(curl -sSL -o /dev/null -m "$timeout" -w '%{http_code} %{time_total}' \
              -r 0-65536 "$url" 2>/dev/null)" || out="000 99"
    [[ -z "$out" ]] && out="000 99"
    printf '%s' "$out"
}

_hv_probe_ok() { [[ "${1%% *}" =~ ^(200|206|301|302|403|416)$ ]]; }

# 探测 GitHub 通道:用 raw 上的一个固定小文件作为探针
hv_mirror_probe_github() {
    local probe_path="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/README.md"
    local best="" best_time=99 t url res
    hv_info "探测 GitHub 通道(直连 + 加速镜像)…"
    for p in "${HV_GH_PREFIX_CANDIDATES[@]}"; do
        if [[ -z "$p" ]]; then url="$probe_path"; else url="${p}${probe_path}"; fi
        res="$(_hv_http_probe "$url" 8)"; t="${res##* }"
        if _hv_probe_ok "$res" && awk -v a="$t" -v b="$best_time" 'BEGIN{exit !(a<b)}'; then
            best="$p"; best_time="$t"
        fi
        hv_dim "   $([[ -z $p ]] && echo 直连 || echo "$p") → HTTP ${res%% *} / ${t}s"
    done
    if [[ -z "$best" && "$best_time" == "99" ]]; then
        hv_warn "所有 GitHub 通道都不可用(离线/被墙):安装可能失败,稍后可重试 hermes-vps mirror"
        return 1
    fi
    hv_ok "GitHub 通道: $([[ -z $best ]] && echo "直连" || echo "$best")(约 ${best_time}s)"
    HV_MIRROR_GH_PREFIX="$best"
    return 0
}

# 探测 PyPI 镜像(uv 用)
hv_mirror_probe_pypi() {
    local best="" best_time=99 res t
    hv_info "探测 Python 包索引…"
    for u in "${HV_PYPI_CANDIDATES[@]}"; do
        res="$(_hv_http_probe "${u%/}/pip/" 8)"; t="${res##* }"
        if _hv_probe_ok "$res" && awk -v a="$t" -v b="$best_time" 'BEGIN{exit !(a<b)}'; then
            best="$u"; best_time="$t"
        fi
        hv_dim "   $u → HTTP ${res%% *} / ${t}s"
    done
    if [[ -z "$best" ]]; then
        hv_warn "PyPI 镜像均不可达,依赖安装可能失败"
        return 1
    fi
    hv_ok "包索引: $best(约 ${best_time}s)"
    HV_MIRROR_PYPI_INDEX="$best"
    return 0
}

# 主入口:测速 → 写文件。HV_MIRROR_FORCE=1 时忽略缓存重测。
hv_mirror_probe() {
    local force="${1:-0}"
    if [[ "$force" != "1" && -f "$HV_MIRROR_FILE" ]]; then
        hv_info "已有镜像配置:$HV_MIRROR_FILE(用 'hermes-vps mirror probe --force' 重新测速)"
        return 0
    fi
    hv_mirror_probe_github || true
    hv_mirror_probe_pypi   || true
    hv_mirror_write
}

hv_mirror_write() {
    hv_state_init
    local gh="${HV_MIRROR_GH_PREFIX:-}" pypi="${HV_MIRROR_PYPI_INDEX:-}"
    local pb_mirror=""
    [[ -n "$gh" ]] && pb_mirror="${gh}https://github.com/astral-sh/python-build-standalone/releases/download"

    {
        printf '# hermes-vps 网络加速配置(由 hermes-vps mirror probe 生成)\n'
        printf 'HV_MIRROR_GH_PREFIX=%s\n' "$gh"
        printf 'HV_MIRROR_PYPI_INDEX=%s\n' "$pypi"
    } >"$HV_MIRROR_FILE"

    # 供 hermes 用户的过程使用(uv / pip / git 都读这些变量)
    if [[ -n "$pypi" ]]; then
        hv_kv_set "$HV_MIRROR_FILE" UV_DEFAULT_INDEX "$pypi"
        hv_kv_set "$HV_MIRROR_FILE" UV_INDEX_URL "$pypi"
        hv_kv_set "$HV_MIRROR_FILE" PIP_INDEX_URL "$pypi"
    fi
    if [[ -n "$pb_mirror" ]]; then
        hv_kv_set "$HV_MIRROR_FILE" UV_PYTHON_INSTALL_MIRROR "$pb_mirror"
    fi
    hv_kv_set "$HV_MIRROR_FILE" UV_HTTP_TIMEOUT "120"
    hv_kv_set "$HV_MIRROR_FILE" GIT_TERMINAL_PROMPT "0"
    chmod 644 "$HV_MIRROR_FILE"
    hv_ok "镜像配置已写入 $HV_MIRROR_FILE"
}

# 把镜像选择落到 hermes 用户的 git / uv 配置(幂等,不覆盖用户已有配置)
hv_mirror_apply_user() {
    [[ -f "$HV_MIRROR_FILE" ]] || return 0
    # shellcheck disable=SC1090
    . "$HV_MIRROR_FILE"

    if [[ -n "${HV_MIRROR_GH_PREFIX:-}" ]] && id "$HV_USER" >/dev/null 2>&1; then
        hv_run_as_user "$HV_USER" git config --global \
            "url.${HV_MIRROR_GH_PREFIX}https://github.com/.insteadOf" "https://github.com/" >/dev/null 2>&1 \
            && hv_info "已为 ${HV_USER} 配置 git GitHub 加速: ${HV_MIRROR_GH_PREFIX}"
    fi

    if [[ -n "${HV_MIRROR_PYPI_INDEX:-}" ]] && id "$HV_USER" >/dev/null 2>&1; then
        local udir="${HV_USER_HOME}/.config/uv"
        install -d -o "$HV_USER" -g "$HV_USER" -m 755 "$udir"
        local toml="${udir}/uv.toml"
        if [[ -f "$toml" ]] && grep -q '^\[\[index\]\]' "$toml"; then
            hv_info "已有 $toml,保留用户配置不动"
        else
            {
                printf '# 由 hermes-vps 写入:加速 Python 依赖安装\n'
                printf '[[index]]\nurl = "%s"\ndefault = true\n' "$HV_MIRROR_PYPI_INDEX"
                printf 'python-install-mirror = "%s"\n' "${UV_PYTHON_INSTALL_MIRROR:-}"
            } >"$toml"
            chown "$HV_USER:$HV_USER" "$toml"; chmod 644 "$toml"
            hv_info "已写入 $toml"
        fi
    fi

    # 全局 profile:让后续 root/其它 shell 的 hermes 调用也带上
    local pd=/etc/profile.d/hermes-vps-mirror.sh
    {
        printf '# hermes-vps 网络加速(自动生成)\n'
        [[ -n "${UV_DEFAULT_INDEX:-}" ]] && printf 'export UV_DEFAULT_INDEX="%s"\n' "$UV_DEFAULT_INDEX"
        [[ -n "${UV_INDEX_URL:-}" ]] && printf 'export UV_INDEX_URL="%s"\n' "$UV_INDEX_URL"
        [[ -n "${UV_PYTHON_INSTALL_MIRROR:-}" ]] && printf 'export UV_PYTHON_INSTALL_MIRROR="%s"\n' "$UV_PYTHON_INSTALL_MIRROR"
    } >"$pd"
    chmod 644 "$pd"
}

hv_mirror_show() {
    if [[ ! -f "$HV_MIRROR_FILE" ]]; then hv_info "尚未探测(执行: hermes-vps mirror probe)"; return 0; fi
    hv_rule
    grep -vE '^\s*#' "$HV_MIRROR_FILE" | sed 's/^/  /'
    hv_rule
}

#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/hermes.sh
# Hermes 本体生命周期:官方安装脚本执行、更新、体检、配置读写封装。
# 关键约定:
#   * 一切 hermes 命令都以服务用户身份执行(hv_run_as_user_*);
#   * settings 一律走 `hermes config set`,密钥一律写 $HERMES_HOME/.env;
#   * 安装过程全程落日志,失败时把日志尾部打给用户。
# =============================================================================

[[ -n "${HV_HERMES_LOADED:-}" ]] && return 0
HV_HERMES_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

HV_INSTALL_LOG="${HV_UHOME}/logs/install.log"

hv_hermes_version() {
    hv_hermes_installed || return 1
    local out=""
    out="$(hv_run_as_user "$HV_USER" env "HERMES_HOME=$HV_UHOME" "$HV_HERMES_BIN" --version 2>/dev/null | head -n1)" || out=""
    [[ -n "$out" ]] && printf '%s' "$out"
}

hv_hermes_installed() { [[ -x "$HV_HERMES_BIN" ]]; }

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
# 用法: hv_hermes_install [extra install.sh 参数...]
hv_hermes_install() {
    local extra=("$@")
    hv_require_root
    hv_have curl || hv_die "缺少 curl"

    if hv_hermes_installed; then
        hv_ok "Hermes 已安装($(hv_hermes_version 2>/dev/null))"
        if ! hv_confirm "重新跑一次官方安装脚本?(更新/修复用,幂等)" no; then return 0; fi
    fi

    hv_step "获取官方安装脚本"
    local script; script="$(mktemp /tmp/hermes-install-XXXXXX.sh)"
    if ! curl -fsSL --max-time 60 "$HV_OFFICIAL_INSTALL_URL" -o "$script"; then
        hv_die "下载安装脚本失败:$HV_OFFICIAL_INSTALL_URL(检查 VPS 到该域名的网络)"
    fi
    chmod 755 "$script"

    # 让 hermes 用户能读脚本(临时文件权限收紧时)
    chmod 644 "$script"

    hv_step "以 ${HV_USER} 身份执行官方安装脚本(首次约 3-10 分钟)"
    hv_info "安装日志:$HV_INSTALL_LOG"
    mkdir -p "$(dirname "$HV_INSTALL_LOG")" 2>/dev/null || true
    chown -R "$HV_USER:$HV_USER" "$HV_UHOME" 2>/dev/null || true

    local -a flags=(--non-interactive)
    [[ "${HV_SKIP_BROWSER:-0}" == "1" ]] && flags+=(--skip-browser)
    [[ ${#extra[@]} -gt 0 ]] && flags+=("${extra[@]}")

    local rc=0
    set +e
    hv_run_as_user_env "$HV_USER" \
        "HERMES_HOME=$HV_UHOME" \
        "HERMES_REPO_URL=${HERMES_REPO_URL:-$HV_REPO_URL}" \
        "DEBIAN_FRONTEND=noninteractive" \
        -- bash "$script" "${flags[@]}"
    rc=$?
    set -e

    rm -f "$script"

    if [[ $rc -ne 0 ]]; then
        hv_err "官方安装脚本退出码 $rc"
        [[ -f "$HV_INSTALL_LOG" ]] && { hv_err "安装日志尾部:"; tail -n 30 "$HV_INSTALL_LOG" | sed 's/^/    /' >&2; }
        return $rc
    fi

    # 官方脚本写日志在 HERMES_HOME/logs/install.log;把关键行回显给用户
    if [[ -f "$HV_INSTALL_LOG" ]]; then
        tail -n 5 "$HV_INSTALL_LOG" | sed 's/^/    /' || true
    fi

    if hv_hermes_installed; then
        hv_ok "Hermes 安装完成:$(hv_hermes_version 2>/dev/null)"
        hv_state_set HERMES_VERSION "$(hv_hermes_version 2>/dev/null || echo unknown)"
        hv_state_set INSTALLED_AT "$(date -Is)"
    else
        hv_err "未找到 launcher:$HV_HERMES_BIN"
        return 1
    fi
}

# 确保 $HERMES_HOME/.env 与 config.yaml 存在(官方安装脚本通常会建)
hv_hermes_ensure_config() {
    local uhome="$HV_UHOME"
    [[ -d "$uhome" ]] || install -d -o "$HV_USER" -g "$HV_USER" -m 700 "$uhome"
    [[ -f "$uhome/.env" ]] || { : >"$uhome/.env"; }
    chown "$HV_USER:$HV_USER" "$uhome/.env"; chmod 600 "$uhome/.env"
    if [[ ! -f "$uhome/config.yaml" ]]; then
        local ex="${uhome}/hermes-agent/cli-config.yaml.example"
        if [[ -f "$ex" ]]; then
            cp "$ex" "$uhome/config.yaml"
        else
            : >"$uhome/config.yaml"
        fi
        chown "$HV_USER:$HV_USER" "$uhome/config.yaml"
    fi
}

# ---------------------------------------------------------------------------
# 更新 / 体检
# ---------------------------------------------------------------------------
hv_hermes_update() {
    hv_hermes_installed || hv_die "Hermes 未安装"
    hv_step "更新 Hermes(hermes update)"
    hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" update
    hv_ok "更新结束,当前版本:$(hv_hermes_version 2>/dev/null)"
}

hv_hermes_doctor() {
    hv_hermes_installed || hv_die "Hermes 未安装"
    hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" doctor || true
}

# 管道友好的体检输出(给客户端解析)
hv_hermes_doctor_capture() {
    local out; out="$(hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" doctor 2>&1 || true)"
    printf '%s\n' "$out"
}

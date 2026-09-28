#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/account.sh
# 服务用户与目录布局:
#   /opt/hermes                服务用户家目录(= 数据落点)
#   /opt/hermes/.hermes        HERMES_HOME(config.yaml / .env / state.db ...)
#   /opt/hermes/.local/bin     launcher(/opt/hermes/.local/bin/hermes)
# 账号不能交互登录(无密码 + 锁定),只能由 root 通过 su 调用。
# =============================================================================

[[ -n "${HV_ACCOUNT_LOADED:-}" ]] && return 0
HV_ACCOUNT_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

hv_ensure_user() {
    hv_require_root
    if id "$HV_USER" >/dev/null 2>&1; then
        local existing_home; existing_home="$(getent passwd "$HV_USER" | cut -d: -f6)"
        if [[ "$existing_home" != "$HV_USER_HOME" ]]; then
            hv_warn "用户 $HV_USER 已存在但家目录为 $existing_home(期望 $HV_USER_HOME)"
            if hv_confirm "是否把 $HV_USER 的家目录改到 $HV_USER_HOME ?(会 usermod -d,不搬动文件)" no; then
                usermod -d "$HV_USER_HOME" "$HV_USER"
            else
                HV_USER_HOME="$existing_home"
                HV_UHOME="${existing_home}/.hermes"
                hv_info "改用现有家目录:$HV_USER_HOME"
            fi
        fi
        hv_info "服务用户已存在:$HV_USER($(id -u "$HV_USER"))"
    else
        hv_step "创建服务用户 $HV_USER"
        # 系统用户 + 家目录;shell 用 bash 以便 su 调用 hermes 命令
        useradd --system --create-home --home-dir "$HV_USER_HOME" \
                --shell /bin/bash --comment "Hermes Agent service account" "$HV_USER" 2>/dev/null \
            || useradd -r -m -d "$HV_USER_HOME" -s /bin/bash "$HV_USER"
        passwd -l "$HV_USER" >/dev/null 2>&1 || true   # 禁止密码登录
        hv_ok "已创建 $HV_USER(禁止交互登录,仅 root 可用 su 调用)"
    fi

    install -d -o "$HV_USER" -g "$HV_USER" -m 755 "$HV_USER_HOME"
    install -d -o "$HV_USER" -g "$HV_USER" -m 700 "$HV_UHOME"
    install -d -o "$HV_USER" -g "$HV_USER" -m 755 "$HV_USER_HOME/.local" "$HV_USER_HOME/.local/bin"
}

hv_ensure_dirs() {
    hv_require_root
    install -d -m 755 "$HV_ETC"
    install -d -m 750 "$HV_LOG_DIR"
    install -d -m 700 "$HV_BACKUP_DIR"
    # 让 hermes 用户能读日志目录不必要,日志由 root 写、hermes 也可写自己的
    install -d -o "$HV_USER" -g "$HV_USER" -m 755 "${HV_UHOME}/logs" 2>/dev/null || true
}

hv_user_env_file() { printf '%s/.env' "${HV_UHOME}"; }

# 保证 .env 权限正确(含密钥)
hv_fix_env_perms() {
    local f; f="$(hv_user_env_file)"
    [[ -f "$f" ]] || return 0
    chown "$HV_USER:$HV_USER" "$f" 2>/dev/null || true
    chmod 600 "$f"
}

# 写一条密钥到 .env 并修正权限
hv_env_set() {
    local key="$1" val="$2"
    hv_kv_set "$(hv_user_env_file)" "$key" "$val"
    hv_fix_env_perms
}

hv_env_get() { hv_kv_get "$(hv_user_env_file)" "$1" "${2:-}"; }
hv_env_unset() { hv_kv_unset "$(hv_user_env_file)" "$1"; hv_fix_env_perms; }

# ---------------------------------------------------------------------------
# 服务用户侧的 hermes 启动器
# 交互式命令(hermes gateway setup 等)需要继承 TTY,不能走 env -i,
# 所以生成一个固定环境的小包装脚本,由 su 直接调用。
# ---------------------------------------------------------------------------
hv_write_user_runner() {
    local dir="${HV_UHOME}/bin" runner="${HV_UHOME}/bin/hermes-run"
    install -d -o "$HV_USER" -g "$HV_USER" -m 755 "$dir"
    cat >"$runner" <<'EOS'
#!/bin/sh
# 由 hermes-vps 生成:固定 HOME/HERMES_HOME/PATH 后调用官方 hermes
HOME=__HV_USER_HOME__
HERMES_HOME=__HV_UHOME__
PATH=__HV_USER_HOME__/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME HERMES_HOME PATH
if [ -f /etc/hermes-vps/mirror.env ]; then
    set -a
    . /etc/hermes-vps/mirror.env
    set +a
fi
exec __HV_HERMES_BIN__ "$@"
EOS
    sed -i "s|__HV_USER_HOME__|${HV_USER_HOME}|g; s|__HV_UHOME__|${HV_UHOME}|g; s|__HV_HERMES_BIN__|${HV_HERMES_BIN}|g" "$runner"
    chown "$HV_USER:$HV_USER" "$runner"
    chmod 755 "$runner"
}

# 以服务用户身份交互式执行(TTY 透传),用于官方向导/扫码
hv_run_interactive() {
    hv_write_user_runner
    su -s /bin/bash "$HV_USER" -c "$(printf '%q ' "$@")"
}

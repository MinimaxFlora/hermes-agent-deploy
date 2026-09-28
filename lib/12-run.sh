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
    if [[ "$user" == "$(id -un)" ]]; then
        # 用户态:要跑的就是自己,无需 su(也就不会因缺权限而失败)
        env -i "${env_args[@]}" bash -c "$(printf '%q ' "$@")"
    else
        env -i "${env_args[@]}" su -s /bin/bash "$user" -c "$(printf '%q ' "$@")"
    fi
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

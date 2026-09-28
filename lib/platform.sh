#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/platform.sh
# 消息平台配置 —— 由 data/platforms.conf 驱动。
#   env   : 填密钥即可(本脚本直接写 .env + platforms.<id>.enabled)
#   meter : 需要额外公网/回调参数(如飞书 webhook),本脚本写基础项并打印后续步骤
#   qr    : 需要交互式登录(个人微信扫码、WhatsApp 扫码),由 hermes gateway setup 完成
# 密钥写 .env,开关写 config.yaml,一律不手改 YAML。
# =============================================================================

[[ -n "${HV_PLATFORM_LOADED:-}" ]] && return 0
HV_PLATFORM_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

hv_platform_conf() { printf '%s/data/platforms.conf' "$HV_SELF_DIR"; }

hv_platform_rows() {
    local f; f="$(hv_platform_conf)"
    [[ -f "$f" ]] || hv_die "缺少数据文件:$f"
    grep -vE '^[[:space:]]*(#|$)' "$f"
}

hv_platform_line() { hv_platform_rows | awk -F'|' -v id="$1" '$1==id{print; exit}'; }
hv_platform_name() { hv_platform_line "$1" | awk -F'|' '{print $2}'; }
hv_platform_mode() { hv_platform_line "$1" | awk -F'|' '{print $3}'; }
hv_platform_required() { hv_platform_line "$1" | awk -F'|' '{print $4}'; }
hv_platform_optional() { hv_platform_line "$1" | awk -F'|' '{print $5}'; }
hv_platform_desc() { hv_platform_line "$1" | awk -F'|' '{print $6}'; }

hv_platform_list() {
    local id name mode req desc
    hv_rule
    printf '  %-14s %-28s %-6s %s\n' "ID" "名称" "模式" "必需变量"
    hv_rule
    while IFS='|' read -r id name mode req _opt _desc; do
        printf '  %-14s %-28s %-6s %s\n' "$id" "$name" "$mode" "${req:--}"
    done < <(hv_platform_rows)
    hv_rule
    printf '  模式说明: env=填密钥即可  meter=需额外公网参数  qr=需扫码/交互登录\n'
}

hv_platform_enabled() {
    local id="$1"
    local v; v="$(hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" config get "platforms.${id}.enabled" 2>/dev/null | tr -d '\r' | tail -n1)"
    [[ "$v" == *true* ]]
}

hv_platform_is_configured() {
    local id="$1" v
    local req; req="$(hv_platform_required "$id")"
    [[ -z "$req" ]] && return 1
    local IFS=','
    for v in $req; do
        [[ -n "$(hv_env_get "$v")" ]] || return 1
    done
    return 0
}

# 启用平台(写 config.yaml 开关)
hv_platform_enable() {
    local id="$1" on="${2:-true}"
    hv_hermes_config_set "platforms.${id}.enabled" "$on" || return 1
    hv_state_set "PLATFORM_${id}" "$on"
}

# 询问并写入变量(required 全部必填,optional 选填)
hv_platform_ask_vars() {
    local id="$1" ask_optional="${2:-1}"
    local req opt v cur val
    req="$(hv_platform_required "$id")"
    opt="$(hv_platform_optional "$id")"

    if [[ -n "$req" ]]; then
        local IFS=','
        for v in $req; do
            cur="$(hv_env_get "$v")"
            if [[ -n "$cur" ]]; then
                hv_info "$v 已配置,保持不变"
                continue
            fi
            hv_ask_secret val "$(printf '%s 的值(%s)' "$v" "$(hv_platform_name "$id")")"
            if [[ -z "$val" ]]; then
                hv_warn "$v 为空,该平台可能无法启动"
            else
                hv_env_set "$v" "$val"
                hv_ok "已写入 $v"
            fi
        done
    fi

    if [[ "$ask_optional" == "1" && -n "$opt" && "$(_hv_ui_kind_cached)" == "whiptail" ]]; then
        if hv_confirm "是否继续配置可选参数(访问白名单、首页频道等)?" no; then
            local IFS=','
            for v in $opt; do
                cur="$(hv_env_get "$v")"
                hv_ask val "${v}(留空=保持${cur:-未设置})" ""
                [[ -n "$val" ]] && { hv_env_set "$v" "$val"; hv_ok "已写入 $v"; }
            done
        fi
    fi
}

# 非交互直写:hermes-vps platform set <id> KEY=VALUE [KEY=VALUE ...]
# 适合脚本化/CI:写 .env 并启用平台,值不回显
hv_platform_set() {
    local id="$1"; shift
    hv_platform_line "$id" >/dev/null || hv_die "未知平台:$id(可用 hermes-vps platform list 查看)"
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        if [[ -z "$k" || "$k" == "$kv" ]]; then
            hv_die "参数格式应为 KEY=VALUE,收到:$kv"
        fi
        hv_env_set "$k" "$v"
        hv_ok "已写入 $k($(hv_platform_name "$id"))"
    done
    hv_platform_enable "$id" true
    hv_dim "   重启网关后生效:hermes-vps service restart gateway"
}

hv_platform_unset() {
    local id="$1"; shift
    hv_platform_line "$id" >/dev/null || hv_die "未知平台:$id"
    local k
    for k in "$@"; do
        hv_env_unset "$k"
        hv_ok "已移除 $k"
    done
}

# 交互式配置一个平台
hv_platform_configure() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        hv_platform_list
        hv_ask id "输入要配置的平台 ID" ""
        [[ -n "$id" ]] || return 0
    fi
    hv_platform_line "$id" >/dev/null || hv_die "未知平台:$id(可用 hermes-vps platform list 查看)"

    local name mode desc
    name="$(hv_platform_name "$id")"; mode="$(hv_platform_mode "$id")"; desc="$(hv_platform_desc "$id")"
    hv_step "配置 ${name}(${id})"
    [[ -n "$desc" ]] && hv_dim "   $desc"

    case "$mode" in
        env|meter)
            hv_platform_ask_vars "$id" 1
            hv_platform_enable "$id" true
            hv_ok "${name} 已启用(网关重启后生效)"
            if [[ "$mode" == "meter" ]]; then
                hv_warn "该平台还需要公网回调/额外参数,请对照官方文档补齐:"
                hv_dim "   https://hermes-agent.nousresearch.com/docs/user-guide/messaging/${id}"
            fi
            ;;
        qr)
            hv_warn "${name} 需要交互式登录(扫码),无法在无人值守模式下完成"
            if hv_confirm "现在启动交互式登录?(返回后继续,失败可重跑)" yes; then
                hv_platform_interactive_setup "$id"
            else
                hv_dim "   稍后手动执行: hermes-vps platform setup ${id}"
            fi
            ;;
        *)
            hv_warn "未知模式 $mode,按 env 处理"
            hv_platform_ask_vars "$id" 1
            hv_platform_enable "$id" true
            ;;
    esac
}

# 交互式向导(qr 类平台走这里):接通当前 TTY,以 hermes 用户身份跑官方 setup
hv_platform_interactive_setup() {
    local id="${1:-}"
    hv_hermes_installed || hv_die "Hermes 未安装"
    hv_write_user_runner
    hv_step "启动官方平台配置向导(按提示扫码/粘贴凭据)"
    hv_dim "   提示:向导结束用 Ctrl+C 或选择退出返回本脚本"
    local cmd="${HV_UHOME}/bin/hermes-run gateway setup"
    if [[ -n "$id" ]]; then hv_dim "   目标平台: $id"; fi
    set +e
    su -s /bin/bash "$HV_USER" -c "$cmd"
    local rc=$?
    set -e
    [[ $rc -ne 0 ]] && hv_warn "向导退出码 $rc(可能是用户中断)"
    # 扫码后凭据落在 .env / hermes 的账号文件里,这里只做校验与开关
    local req v
    req="$(hv_platform_required "$id")"
    local IFS=','
    for v in $req; do
        if [[ -n "$(hv_env_get "$v")" ]]; then hv_ok "$v 已配置"; else hv_warn "$v 仍未配置"; fi
    done
    hv_platform_enable "$id" true || true
}

# 批量配置(install 流程用):传入 id 列表
hv_platform_configure_many() {
    local id
    for id in "$@"; do
        [[ -n "$id" ]] || continue
        hv_platform_configure "$id"
    done
}

# 平台状态概览:用 hermes gateway 的状态输出做粗判
hv_platform_status() {
    hv_platform_list
    hv_rule
    local id name mode
    while IFS='|' read -r id name mode _r _o _d; do
        local mark="${HV_C_RED}未配置${HV_C_RESET}"
        if hv_platform_is_configured "$id"; then
            if hv_platform_enabled "$id"; then mark="${HV_C_GREEN}已启用${HV_C_RESET}"; else mark="${HV_C_YELLOW}已存凭据未启用${HV_C_RESET}"; fi
        fi
        printf '  %-14s %-28s %s\n' "$id" "$name" "$mark"
    done < <(hv_platform_rows)
    hv_rule
}

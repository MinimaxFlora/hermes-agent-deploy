# ---------------------------------------------------------------------------
# 配对审批(pairing):平台默认「陌生人需批准」——这里把批准做成脚本内的自动/一键操作
#   官方接口:hermes pairing list|approve <platform> <request-id|code>|revoke|clear-pending
#   待批准数据:$HERMES_HOME/platforms/pairing/<platform>-pending.json
#   官方 DM 策略:platforms.<id>.dm_policy=pairing(需批准)/ open(都放行)/ allowlist(仅名单)
# ---------------------------------------------------------------------------
pairing_cli() { hh pairing "$@"; }

# 列出待批准请求,输出 "platform<TAB>request_id" 行(解析 `pairing list` 的表格)
pairing_pending_rows() {
    hermes_installed || { warn "请先部署(菜单 1)"; return 0; }
    hh pairing list 2>/dev/null | awk '
        /Pending Pairing Requests/ { on=1; next }
        on && /Platform[[:space:]]+Request ID/ { next }
        on && /^[[:space:]]*-+/ { next }
        on && NF >= 2 && $1 !~ /^(Approve|The|No)$/ { print $1 "\t" $2; next }
        on && /^[[:space:]]*$/ { exit }
    '
}

pairing_pending_count() {
    local rows; rows="$(pairing_pending_rows || true)"
    [[ -z "$rows" ]] && { printf '0'; return 0; }
    printf '%s' "$rows" | grep -c . || printf '0'
}

pairing_show() {
    hermes_installed || { warn "请先部署(菜单 1)"; return 0; }
    local rows; rows="$(pairing_pending_rows)"
    if [[ -z "$rows" ]]; then
        ok "当前没有待批准的配对请求"
    else
        printf '\n  %s待批准的配对请求:%s\n' "$BD" "$N"
        while IFS=$'\t' read -r p id; do
            [[ -n "$p" ]] && printf '    %s%-10s%s %s\n' "$C" "$p" "$N" "$id"
        done <<<"$rows"
    fi
    printf '\n'
    dim "已批准名单:"
    hh pairing list 2>/dev/null | sed -n '/Approved/,$p' | head -12 | sed 's/^/    /'
    return 0
}

pairing_approve_all() { # 批准所有待批准请求(这就是原来要手工敲的那步)
    hermes_installed || { warn "请先部署(菜单 1)"; return 0; }
    local rows; rows="$(pairing_pending_rows)"
    [[ -z "$rows" ]] && { ok "没有待批准的配对请求"; return 0; }
    local n=0 p id
    while IFS=$'\t' read -r p id; do
        [[ -n "$p" && -n "$id" ]] || continue
        if hh pairing approve "$p" "$id" >/dev/null 2>&1; then
            ok "已放行:${p} / ${id}"; n=$((n + 1))
        else
            warn "放行失败:${p} / ${id}(可让对方把机器人发给他的 8 位配对码告诉你,用菜单里的「输入配对码」放行)"
        fi
    done <<<"$rows"
    [[ $n -gt 0 ]] && info "共放行 $n 个 —— 让对方重新发一条消息即可开始对话"
    return 0
}

pairing_approve_code() { # 用对方发给你的 8 位配对码放行
    local platform="${1:-}" code="${2:-}"
    if [[ -z "$platform" ]]; then
        read -r -p "  平台(如 weixin/telegram/whatsapp): " platform || platform=""
    fi
    if [[ -z "$code" ]]; then
        read -r -p "  配对码(如 W6FFKXYC): " code || code=""
    fi
    [[ -n "$platform" && -n "$code" ]] || { warn "平台与配对码都需要"; return 0; }
    if hh pairing approve "$platform" "$code" >/dev/null 2>&1; then
        ok "已放行:${platform} / ${code}"
    else
        warn "放行失败:检查平台名与配对码是否正确(配对码 1 小时有效)"
        return 0
    fi
    return 0
}

pairing_watch() { # 监听并自动放行(默认 180 秒):对方发消息 → 立刻批准
    local secs="${1:-180}" t=0 found=0
    hermes_installed || { warn "请先部署(菜单 1)"; return 0; }
    step "自动批准配对(监听 ${secs} 秒)"
    dim "现在让对方(或你自己)给机器人发一条消息:一出现请求就自动放行,无需手工敲命令"
    while [[ $t -lt $secs ]]; do
        if [[ -n "$(pairing_pending_rows)" ]]; then
            pairing_approve_all && found=1
        fi
        sleep 5; t=$((t + 5))
        printf '  %s· 监听中 %s/%ss(已放行:%s)%s\r' "$DM" "$t" "$secs" "$found" "$N"
        [[ $found -eq 1 && -z "$(pairing_pending_rows)" ]] || true
    done
    printf '\n'
    [[ $found -eq 1 ]] && ok "监听结束:已完成放行,让对方发消息即可" || dim "监听结束:期间没有新的配对请求"
    return 0
}

pairing_policy_set() { # pairing_policy_set pairing|open|allowlist|closed
    local mode="$1" id
    for id in qqbot weixin; do
        plat_configured "$id" || continue
        case "$mode" in
            pairing)   if [[ "$id" == "weixin" ]]; then env_set WEIXIN_DM_POLICY pairing; env_set WEIXIN_ALLOW_ALL_USERS false
                       else env_set QQ_ALLOW_ALL_USERS false; fi
                       ok "$id:陌生人需批准(配对)" ;;
            open)      if [[ "$id" == "weixin" ]]; then env_set WEIXIN_DM_POLICY open; env_set WEIXIN_ALLOW_ALL_USERS true
                       else env_set QQ_ALLOW_ALL_USERS true; fi
                       warn "$id:任何人都能私聊机器人(仅测试用)" ;;
            closed)    if [[ "$id" == "weixin" ]]; then env_set WEIXIN_DM_POLICY closed
                       else env_set QQ_ALLOW_ALL_USERS false; fi
                       ok "$id:已关闭私聊" ;;
        esac
    done
    # 全局开关:pairing=false 直接不要求配对(官方向导同样做法)
    if [[ "$mode" == "open" ]]; then
        hcfg pairing false >/dev/null 2>&1 || true
        warn "已关闭全局配对要求(platforms.*.dm_policy 仍生效)"
    else
        hcfg pairing true >/dev/null 2>&1 || true
    fi
    svc_ctl restart hermes-gateway >/dev/null 2>&1 || true
    return 0
}

pairing_menu() {
    while :; do
        clear_screen
        header "配对审批(陌生人放行)"
        local cnt; cnt="$(pairing_pending_count)"
        printf '    待批准请求 : %s%s%s 个\n' "$( [[ "$cnt" == "0" ]] && printf '%s' "$G" || printf '%s' "$Y")" "$cnt" "$N"
        dim "说明:平台默认「陌生人先申请、由你批准」;这里可以自动/一键批准,不必手敲 hermes pairing approve"
        rule
        menu_item 1 "查看待批准与已放行名单" "逐个列出 platform / request-id"
        menu_item 2 "立即放行全部待批准" "等于批量执行 pairing approve"
        menu_item 3 "自动放行(监听 3 分钟)" "对方发消息 → 立刻自动批准,推荐"
        menu_item 4 "输入对方发来的配对码放行" "例如 weixin + W6FFKXYC"
        menu_item 5 "策略:重新开启「需批准」" "dm_policy=pairing(最安全)"
        menu_item 6 "策略:允许所有人私聊" "dm_policy=open(不推荐)"
        rule
        menu_item 0 "返回" ""
        rule
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) pairing_show; pause ;;
            2) pairing_approve_all; pause ;;
            3) pairing_watch 180; pause ;;
            4) pairing_approve_code "" ""; pause ;;
            5) pairing_policy_set pairing; pause ;;
            6) confirm "确定允许任何人私聊机器人?" no && { pairing_policy_set open; } ; pause ;;
            0|"") return 0 ;;
            *) warn "无效选择:$ch"; sleep 1 ;;
        esac
    done
}

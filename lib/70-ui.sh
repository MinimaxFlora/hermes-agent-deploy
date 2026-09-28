# =============================================================================
#  界面:横幅 / 状态面板 / 主菜单 / 子菜单
# =============================================================================

clear_screen() { [[ -t 1 ]] && clear || printf '\n'; }
rule() { printf '  %s%s%s\n' "$DM" "$(printf '─%.0s' $(seq 1 74))" "$N"; }
rule_thin() { printf '  %s%s%s\n' "$DM" "$(printf '·%.0s' $(seq 1 74))" "$N"; }

# 显示宽度:只有东亚宽字符算 2 列(制表符 ─ │、圆点 ● ○ 算 1 列)
declare -A _DISP_CACHE=()
_is_wide_cp() {
    local cp="$1"
    (( cp >= 0x1100 && cp <= 0x115F )) && return 0
    (( cp >= 0x2E80 && cp <= 0x303E )) && return 0
    (( cp >= 0x3041 && cp <= 0x33FF )) && return 0
    (( cp >= 0x3400 && cp <= 0x4DBF )) && return 0
    (( cp >= 0x4E00 && cp <= 0x9FFF )) && return 0
    (( cp >= 0xA000 && cp <= 0xA4CF )) && return 0
    (( cp >= 0xAC00 && cp <= 0xD7A3 )) && return 0
    (( cp >= 0xF900 && cp <= 0xFAFF )) && return 0
    (( cp >= 0xFE30 && cp <= 0xFE6F )) && return 0
    (( cp >= 0xFF00 && cp <= 0xFF60 )) && return 0
    (( cp >= 0xFFE0 && cp <= 0xFFE6 )) && return 0
    (( cp >= 0x1F300 && cp <= 0x1FAFF )) && return 0
    (( cp >= 0x20000 && cp <= 0x3FFFD )) && return 0
    return 1
}
disp_len() {
    local s="${1-}" w=0 i ch cp
    [[ -z "$s" ]] && { printf '0'; return 0; }   # 空串直接返回 0(关联数组不允许空下标)
    if [[ -n "${_DISP_CACHE[$s]:-}" ]]; then printf '%s' "${_DISP_CACHE[$s]}"; return 0; fi
    for (( i=0; i<${#s}; i++ )); do
        ch="${s:i:1}"
        if [[ "$ch" == [[:ascii:]] ]]; then w=$((w+1)); continue; fi
        cp="$(printf '%d' "'$ch" 2>/dev/null)" || cp=0
        [[ -z "$cp" ]] && cp=0
        if _is_wide_cp "$cp"; then w=$((w+2)); else w=$((w+1)); fi
    done
    _DISP_CACHE["$s"]="$w"
    printf '%s' "$w"
}
BOXW=74
box_top()  { printf '  %s╭%s╮%s\n' "$C" "$(printf '─%.0s' $(seq 1 $BOXW))" "$N"; }
box_bot()  { printf '  %s╰%s╯%s\n' "$C" "$(printf '─%.0s' $(seq 1 $BOXW))" "$N"; }
box_sep()  { printf '  %s├%s┤%s\n' "$C" "$(printf '─%.0s' $(seq 1 $BOXW))" "$N"; }
box_line() { # box_line <纯文本用于测宽> [带色文本]
    local plain="$1" colored="${2:-$1}" w pad
    w="$(disp_len "$plain")"; pad=$(( BOXW - w ))
    (( pad < 0 )) && pad=0
    printf '  %s│%s%s%*s%s│%s\n' "$C" "$N" "$colored" "$pad" '' "$C" "$N"
    return 0
}

header() {
    local title="${1:-}"
    local os_line="${OS_NAME:-} ${ARCH:-}"
    printf '\n'
    box_top
    box_line "  Hermes Agent · VPS 一键部署与管理" "  ${BD}${M}Hermes Agent${N} · VPS 一键部署与管理"
    box_line "  模型 / QQ / 微信 / 域名 HTTPS / 自检备份" "  ${DM}模型 / QQ / 微信 / 域名 HTTPS / 自检备份${N}"
    box_line "  v$V  ·  $os_line  ·  ${CORES}C / ${MEM_MB}MB" "  ${DM}v$V  ·  $os_line  ·  ${CORES}C / ${MEM_MB}MB${N}"
    box_bot
    if [[ -n "$title" ]]; then printf '\n  %s%s%s\n' "$BD$W" "$title" "$N"; fi
    return 0
}

# 顶部状态面板
status_panel() {
    local hv gw dash cd dom days cur l id plats_ok=0 plats_conf=0
    hv="$(st_get HERMES_VERSION "$(hermes_version 2>/dev/null || echo '')")"
    [[ -z "$hv" ]] && hv="未安装"
    gw="$(svc_state hermes-gateway)"; dash="$(svc_state hermes-dashboard)"; cd="$(svc_state caddy)"
    dom="$(st_get DOMAIN)"
    cur="$(model_current 2>/dev/null || echo '-|-')"
    for l in "${PLATFORMS[@]}"; do
        id="${l%%|*}"
        plat_configured "$id" || continue
        plats_conf=$((plats_conf+1))
        [[ "$(plat_live_state "$id" 2>/dev/null || echo unknown)" == "connected" ]] && plats_ok=$((plats_ok+1))
    done

    local -a P=() CL=()
    row() { P+=("$1"); CL+=("$2"); }

    if hermes_installed; then
        row "  Hermes      ● $hv" "  Hermes      $(printf '%s' "$DOT_ON") $hv"
    else
        row "  Hermes      ○ 未安装" "  Hermes      $(printf '%s' "$DOT_OFF") 未安装(菜单 1 一键部署)"
    fi
    row "  服务        网关 $(svc_mark_plain "$gw")  面板 $(svc_mark_plain "$dash")  Caddy $(svc_mark_plain "$cd")" \
        "  服务        网关 $(svc_mark "$gw")  面板 $(svc_mark "$dash")  Caddy $(svc_mark "$cd")"
    if [[ -n "$dom" ]]; then
        days="$(cert_days_left "$dom" 2>/dev/null || echo '')"
        if [[ -n "$days" ]]; then
            row "  域名        $dom(证书剩 ${days} 天)" "  域名        ${G}$dom${N}${DM}(证书剩 ${days} 天)${N}"
        else
            row "  域名        $dom" "  域名        ${G}$dom${N}"
        fi
    else
        row "  域名        未配置(菜单 4 可配 Caddy + 自动 HTTPS)" "  域名        ${DM}未配置(菜单 4 可配 Caddy + 自动 HTTPS)${N}"
    fi
    if [[ -n "$(st_get MODEL_VERIFIED)" ]]; then
        row "  模型        ${cur%%|*} / ${cur##*|}(已验证)" "  模型        ${cur%%|*} / ${cur##*|} ${G}(已验证)${N}"
    else
        row "  模型        ${cur%%|*} / ${cur##*|}" "  模型        ${cur%%|*} / ${cur##*|}"
    fi
    if [[ $plats_conf -eq 0 ]]; then
        row "  平台        无已配置平台(菜单 3 接入 QQ/微信等)" "  平台        ${DM}无已配置平台(菜单 3 接入 QQ/微信等)${N}"
    else
        row "  平台        已配置 $plats_conf 个,已连接 $plats_ok 个" \
            "  平台        ${DM}已配置${N} $plats_conf 个${G},已连接 $plats_ok 个${N}"
    fi

    printf '\n'
    printf '  %s运行状态%s %s%s%s\n' "$BD$W" "$N" "$DM" "$(printf '─%.0s' $(seq 1 62))" "$N"
    local i
    for i in "${!P[@]}"; do printf '%s\n' "${CL[$i]}"; done
    printf '  %s%s%s\n' "$DM" "$(printf '─%.0s' $(seq 1 74))" "$N"
    return 0
}

# 菜单项:左列宽度按显示宽度补齐,描述列对得齐
menu_item() { # menu_item <编号> <名称> <描述>
    local num="$1" name="$2" desc="${3:-}"
    local left; left="$(printf '%2s) %s' "$num" "$name")"
    local pad=$(( 30 - $(disp_len "$left") ))
    (( pad < 1 )) && pad=1
    if [[ -z "$desc" ]]; then printf '    %s%s%s\n' "$BD" "$left" "$N"
    else printf '    %s%s%s%*s%s%s%s\n' "$BD" "$left" "$N" "$pad" '' "$DM" "$desc" "$N"; fi
    return 0
}
svc_mark() { case "$1" in active) printf '%s' "$DOT_ON" ;; failed) printf '%s✘%s' "$R" "$N" ;; *) printf '%s◐%s' "$Y" "$N" ;; esac; }
svc_mark_plain() { case "$1" in active) printf '●' ;; failed) printf '✘' ;; *) printf '◐' ;; esac; }

main_menu() {
    check_copy_drift
    while :; do
        clear_screen
        header
        status_panel
        printf '\n  %s主菜单%s\n' "$BD$W" "$N"
        rule
        menu_item 1  "一键部署 / 重新部署" "安装 Hermes、面板、域名、平台接入"
        menu_item 2  "模型提供商"         "填 API Key,并真实验证能否对话"
        menu_item 3  "消息平台"           "QQ / 微信 / 企业微信 / 飞书 / 钉钉 / TG"
        menu_item 4  "域名与反向代理"     "Caddy 自动 HTTPS、证书状态"
        menu_item 5  "面板与 API"         "登录密码、公网地址、/v1 开关"
        menu_item 6  "服务管理"           "启动 / 停止 / 重启 / 看日志"
        menu_item 7  "自检与诊断"         "服务、端口、认证门、API、证书、备份"
        menu_item 8  "备份与恢复"         "打包配置与密钥,可一键回滚"
        menu_item 9  "更新"               "立即更新 / 每日自动更新"
        menu_item 10 "防火墙与安全"       "只放行 SSH / 80 / 443"
        menu_item 11 "网络加速探测"       "GitHub / PyPI 国内镜像自动选优"
        menu_item 12 "使用说明 / 帮助"    "常用命令与路径"
        menu_item 13 "卸载"               "逐项确认,绝不静默批量删"
        rule
        menu_item 0 "退出" ""
        rule
        local ch=""; menu_choice ch "请输入编号"
        case "$ch" in
            1) deploy_all ;;
            2) model_menu ;;
            3) plat_menu ;;
            4) domain_configure ;;
            5) panel_menu ;;
            6) service_menu ;;
            7) diagnose ;;
            8) backup_menu ;;
            9) update_menu ;;
            10) firewall_setup; pause ;;
            11) mirror_probe 1; mirror_apply_user; pause ;;
            12) show_help ;;
            13) uninstall_run ;;
            0|q|exit|quit) printf '\n  %s再见 👋%s\n\n' "$C" "$N"; return 0 ;;
            "") if [[ "${HV_EOF:-0}" == "1" || ! -t 0 ]]; then printf '\n  %s输入已结束,退出。%s\n\n' "$C" "$N"; return 0; fi ;;
            *) warn "无效编号:$ch"; sleep 1 ;;
        esac
    done
}

panel_menu() {
    while :; do
        clear_screen
        header "面板与 API"
        dashboard_show_info
        printf '    %s1)%s 查看访问信息与凭据路径\n' "$BD" "$N"
        printf '    %s2)%s 重置面板密码(随机生成)\n' "$BD" "$N"
        printf '    %s3)%s 自定义面板用户名/密码\n' "$BD" "$N"
        printf '    %s4)%s 开启 / 关闭 OpenAI 兼容 API(/v1)\n' "$BD" "$N"
        printf '    %s5)%s 验证认证门与登录(真发一次登录请求)\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) credentials_write "$(st_get DOMAIN)"; info "凭据已写入 $CRED_FILE"; pause ;;
            2) env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$(random_str 20)"; ok "密码已重置"; restart_service hermes-dashboard; credentials_write "$(st_get DOMAIN)"; dim "新密码在 $CRED_FILE"; pause ;;
            3) local u p; ask u "用户名" "$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"; ask_secret p "新密码(回车随机生成)"; [[ -z "$p" ]] && p="$(random_str 20)"; env_set HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$u"; env_set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$p"; restart_service hermes-dashboard; credentials_write "$(st_get DOMAIN)"; ok "账号已更新"; pause ;;
            4) if [[ "$(st_api_enabled)" == "1" ]]; then api_server_disable; else api_server_enable; fi; dashboard_webui "$(st_get DOMAIN)"; caddy_write_config "$(st_get DOMAIN)" "$(st_get ACME_EMAIL)" "$(st_api_enabled)" 2>/dev/null || true; pause ;;
            5) printf '\n'; dim "认证门:$(dashboard_verify_gate)"; dashboard_login_test; pause ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

service_menu() {
    while :; do
        clear_screen
        header "服务管理"
        printf '    %s当前状态:%s%s\n\n' "$BD" "$N" "$(service_brief)"
        printf '    %s1)%s 启动全部(gateway + dashboard + caddy)\n' "$BD" "$N"
        printf '    %s2)%s 停止全部\n' "$BD" "$N"
        printf '    %s3)%s 重启全部%s(改完配置常用)%s\n' "$BD" "$N" "$DM" "$N"
        printf '    %s4)%s 重启网关(消息平台配置生效)\n' "$BD" "$N"
        printf '    %s5)%s 重启面板\n' "$BD" "$N"
        printf '    %s6)%s 重载 Caddy(改反代后)\n' "$BD" "$N"
        printf '    %s7)%s 实时日志:网关\n' "$BD" "$N"
        printf '    %s8)%s 实时日志:面板\n' "$BD" "$N"
        printf '    %s9)%s 实时日志:Caddy\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) start_service gateway; start_service dashboard; start_service caddy; pause ;;
            2) stop_service dashboard; stop_service gateway; if confirm "同时停止 Caddy(将无法通过域名访问)?" no; then stop_service caddy; fi; pause ;;
            3) restart_all_services; pause ;;
            4) restart_service hermes-gateway; sleep 3; printf '\n'; dim "网关最近日志:"; journalctl -u hermes-gateway -n 15 --no-pager 2>/dev/null | sed 's/^/      /' | tail -n 15; pause ;;
            5) restart_service hermes-dashboard; pause ;;
            6) caddy_write_config "$(st_get DOMAIN)" "$(st_get ACME_EMAIL)" "$(st_api_enabled)" || true; pause ;;
            7) service_logs hermes-gateway ;;
            8) service_logs hermes-dashboard ;;
            9) service_logs caddy ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

update_menu() {
    while :; do
        clear_screen
        header "更新"
        printf '    Hermes 当前版本:%s%s%s\n' "$BD" "$(hermes_version 2>/dev/null || echo 未安装)" "$N"
        printf '    每日自动更新  :%s\n\n' "$(auto_update_status)"
        printf '    %s1)%s 立即更新 Hermes(先自动备份)\n' "$BD" "$N"
        printf '    %s2)%s 开启每日自动更新(04:30 左右)\n' "$BD" "$N"
        printf '    %s3)%s 关闭自动更新\n' "$BD" "$N"
        printf '    %s4)%s 更新前备份\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) hermes_update; pause ;;
            2) auto_update_install; pause ;;
            3) auto_update_remove; pause ;;
            4) backup_create manual; pause ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

backup_menu() {
    while :; do
        clear_screen
        header "备份与恢复"
        backup_list
        printf '    %s1)%s 立即备份\n' "$BD" "$N"
        printf '    %s2)%s 从备份恢复\n' "$BD" "$N"
        printf '    %s3)%s 清理旧备份(保留最近 7 份)\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            1) backup_create manual; pause ;;
            2) backup_restore ;;
            3) local old; old="$(ls -1t "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null | tail -n +8)" || old=""
               if [[ -z "$old" ]]; then info "没有需要清理的旧备份"; else
                   printf '\n  将删除:\n'; while read -r f; do [[ -n "$f" ]] && printf '    %s\n' "$f"; done <<<"$old"
                   if confirm "确认删除以上文件?" no; then while read -r f; do [[ -n "$f" ]] && rm -f "$f"; done <<<"$old"; ok "已清理"; fi
               fi; pause ;;
            0|"") return 0 ;;
            *) warn "无效编号"; sleep 1 ;;
        esac
    done
}

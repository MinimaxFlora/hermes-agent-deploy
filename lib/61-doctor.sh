# ---------------------------------------------------------------------------
# 自检 / 诊断
# ---------------------------------------------------------------------------
DIAG_ITEMS=(); DIAG_OK=0; DIAG_FAIL=0
diag_add() { # diag_add <状态 ok|fail|warn|info> <文本>
    local st="$1"; shift
    case "$st" in
        ok)   printf '    %s %s\n' "$OK_SYM" "$*"; DIAG_OK=$((DIAG_OK+1)) ;;
        fail) printf '    %s %s\n' "$NO_SYM" "$*"; DIAG_FAIL=$((DIAG_FAIL+1)) ;;
        warn) printf '    %s %s\n' "$WARN_SYM" "$*" ;;
        *)    printf '    %s %s\n' "$(printf '%s·%s' "$DM" "$N")" "$*" ;;
    esac
}

diagnose() {
    clear_screen
    header "自检 / 诊断"
    DIAG_OK=0; DIAG_FAIL=0

    printf '\n  %s系统%s\n' "$BD" "$N"
    diag_add info "系统:$OS_NAME · $ARCH · ${CORES} 核 · 内存 ${MEM_MB}MB · 磁盘剩余 ${DISK_MB}MB"
    [[ "${MEM_MB:-0}" -lt 1500 && "$(swap_total_mb)" -lt 512 ]] && diag_add warn "内存偏小且无 swap,安装/更新可能 OOM" || diag_add ok "内存/swap 充足"

    printf '\n  %s安装%s\n' "$BD" "$N"
    if hermes_installed; then diag_add ok "Hermes:$(hermes_version 2>/dev/null || echo 未知)"; else diag_add fail "Hermes 未安装(菜单 1 一键部署)"; fi
    [[ -d "$UHOME/hermes-agent/hermes_cli/web_dist" ]] && diag_add ok "界面产物存在(web_dist)" || diag_add warn "界面产物缺失(重新部署会自动修复)"
    local perms; perms="$(stat -c '%a' "$UHOME/.env" 2>/dev/null || echo "-")"
    [[ "$perms" == "600" ]] && diag_add ok ".env 权限 600" || diag_add fail ".env 权限异常($perms)"

    printf '\n  %s服务%s\n' "$BD" "$N"
    local s st
    for s in hermes-gateway hermes-dashboard caddy; do
        st="$(svc_state "$s")"
        if [[ "$st" == "active" ]]; then
            local en; en="$(svc_enabled "$s")"
            diag_add ok "$s:$st($en)"
        else
            diag_add fail "$s:$st"
        fi
    done

    printf '\n  %s端口%s\n' "$BD" "$N"
    port_listening "$DASH_PORT" && diag_add ok "面板端口 ${DASH_PORT} 监听中" || diag_add fail "面板端口 ${DASH_PORT} 未监听"
    port_listening "$API_PORT" && diag_add ok "API 端口 ${API_PORT} 监听中" || diag_add info "API 端口 ${API_PORT} 未监听(未开启则正常)"
    port_listening 80 && diag_add ok "80 端口监听(Caddy)" || diag_add warn "80 端口未监听(证书签发需要)"
    port_listening 443 && diag_add ok "443 端口监听(Caddy)" || diag_add warn "443 端口未监听(HTTPS 未生效)"

    printf '\n  %s面板认证门%s\n' "$BD" "$N"
    case "$(dashboard_verify_gate)" in
        ok) diag_add ok "未登录访问被拦截(认证门生效)" ;;
        open) diag_add fail "未登录可直接访问(认证门未生效!)" ;;
        down) diag_add fail "面板无响应" ;;
        other:*) diag_add info "面板返回 $(dashboard_verify_gate)" ;;
    esac

    printf '\n  %s模型%s\n' "$BD" "$N"
    local cur; cur="$(model_current 2>/dev/null || echo '-|-')"
    diag_add info "当前:${cur%%|*} / ${cur##*|}"
    local pid envv key haskey=0
    pid="${cur%%|*}"; envv="$(prov_env "$pid" 2>/dev/null || true)"
    [[ -n "$envv" ]] && key="$(env_get "$envv")" || key=""
    [[ -n "$key" ]] && haskey=1
    [[ $haskey -eq 1 ]] && diag_add ok "密钥已配置($envv)" || diag_add fail "密钥未配置(菜单 2 配置提供商)"
    if [[ -n "$(st_get MODEL_VERIFIED)" ]]; then diag_add ok "上次验证:$(st_get MODEL_VERIFIED)"; else diag_add info "尚未做过模型连通验证(菜单 2 → v / test)"; fi

    printf '\n  %s消息平台%s\n' "$BD" "$N"
    local l id nm live conf=0
    for l in "${PLATFORMS[@]}"; do
        id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"
        plat_configured "$id" || continue
        conf=$((conf+1))
        live="$(plat_live_state "$id" 2>/dev/null || echo unknown)"
        case "$live" in
            connected) diag_add ok "$nm:已连接" ;;
            failed) diag_add fail "$nm:连接失败(看 $UHOME/logs/gateway.log)" ;;
            seen) diag_add warn "$nm:已配置,日志暂无明确结论" ;;
            *) diag_add warn "$nm:已配置,未观测到连接记录" ;;
        esac
    done
    [[ $conf -eq 0 ]] && diag_add info "未配置任何消息平台(菜单 3)"

    printf '\n  %s域名与证书%s\n' "$BD" "$N"
    local domain; domain="$(st_get DOMAIN)"
    if [[ -n "$domain" ]]; then
        local rc=0; set +e; domain_points_here "$domain"; rc=$?; set -e
        case "$rc" in
            0) diag_add ok "$domain 解析指向本机" ;;
            1) diag_add fail "$domain 解析不指向本机(证书会失败)" ;;
            *) diag_add info "$domain 解析无法确认" ;;
        esac
        local days; days="$(cert_days_left "$domain" 2>/dev/null || echo "")"
        if [[ -n "$days" ]]; then
            if [[ "$days" -gt 20 ]]; then diag_add ok "证书有效,剩余 ${days} 天(到期 $(cert_expire_date "$domain" 2>/dev/null))"
            else diag_add warn "证书剩余 ${days} 天(注意续期)"; fi
        else
            diag_add warn "未找到证书文件(可能刚启动,或签发失败)"
        fi
        local code; code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && diag_add ok "HTTPS 探活 https://${domain}/healthz → 200" || diag_add fail "HTTPS 探活返回 ${code}"
        if [[ "$(st_api_enabled)" == "1" ]]; then
            local ac; ac="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
            [[ "$ac" == "401" || "$ac" == "403" ]] && diag_add ok "API 鉴权生效(无 key → ${ac})" || diag_add warn "API 无 key 返回 ${ac}(期望 401)"
        fi
    else
        diag_add warn "尚未配置域名(菜单 4)"
    fi

    printf '\n  %s访问凭据%s\n' "$BD" "$N"
    if [[ -f "$CRED_FILE" ]]; then
        local cperm; cperm="$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo '-')"
        [[ "$cperm" == "600" ]] && diag_add ok "$CRED_FILE(600)" || diag_add fail "$CRED_FILE 权限 $cperm"
    else
        diag_add warn "凭据文件不存在(配置面板后生成)"
    fi

    printf '\n  %s数据安全%s\n' "$BD" "$N"
    local n; n="$(ls -1 "$BACKUP_DIR"/hermes-*.tar.gz 2>/dev/null | wc -l)" || n=0
    [[ "$n" -gt 0 ]] && diag_add ok "已有 ${n} 份备份" || diag_add warn "没有备份(菜单 8 建议先备一份)"
    diag_add info "自动更新:$(auto_update_status)"
    diag_add info "防火墙:$(st_get FIREWALL unknown)"

    rule
    if [[ $DIAG_FAIL -eq 0 ]]; then printf '    %s全部检查通过(%d 项)%s\n' "$G" "$DIAG_OK" "$N"
    else printf '    %s%d 项需要处理%s,%d 项正常\n' "$R" "$DIAG_FAIL" "$N" "$DIAG_OK"; fi
    rule
    pause
}

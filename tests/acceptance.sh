#!/usr/bin/env bash
# =============================================================================
#  acceptance.sh —— 真机验收(不在 CI 跑,需在已部署的 VPS 上以 root 执行)
#  只做只读检查 + 一次备份,不改动服务配置。
#    在 VPS 上:bash tests/acceptance.sh
#  若未部署,会自动跳过并提示。
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap - ERR

section "真机验收"

if [[ "$(id -u)" -ne 0 ]]; then
    c_info "需要 root,跳过(用法: sudo bash tests/acceptance.sh)"
    summary; exit 0
fi
if [[ "$(uname -s)" != "Linux" ]] || ! have systemctl; then
    c_info "非 Linux/systemd 环境,跳过"
    summary; exit 0
fi
if [[ ! -x "$HBIN" ]]; then
    c_info "未检测到已安装的 Hermes($HBIN),跳过(先执行一键部署)"
    summary; exit 0
fi

section "服务"
for s in hermes-gateway hermes-dashboard caddy; do
    st="$(svc_state "$s")"; en="$(svc_enabled "$s")"
    [[ "$st" == "active" ]] && c_ok "$s 运行中" || c_bad "$s 状态 $st"
    [[ "$en" == "enabled" ]] && c_ok "$s 开机自启" || c_bad "$s 未设置自启($en)"
done
gw_user="$(awk -F= '/^User=/{gsub(/ /,"",$2); print $2}' /etc/systemd/system/hermes-gateway.service 2>/dev/null || true)"
[[ "$gw_user" == "$HUSER" ]] && c_ok "网关以专用用户 $HUSER 运行" || c_bad "网关运行用户异常:${gw_user:-未设置}"

section "端口与暴露面"
port_listening "$DASH_PORT" && c_ok "面板端口 $DASH_PORT 监听中" || c_bad "面板端口未监听"
port_listening "$API_PORT" && c_ok "API 端口 $API_PORT 监听中" || c_bad "API 端口未监听"
if have ss; then
    for p in "$DASH_PORT" "$API_PORT"; do
        addrs="$(ss -lntH "sport = :$p" 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"
        if [[ "$addrs" == *"0.0.0.0:$p"* || "$addrs" == *"[::]:$p"* ]]; then
            c_bad "端口 $p 暴露到公网($addrs)"
        else
            c_ok "端口 $p 仅本机($addrs)"
        fi
    done
fi
port_listening 80 && c_ok "80 端口监听(Caddy)" || c_bad "80 端口未监听"
port_listening 443 && c_ok "443 端口监听(Caddy)" || c_bad "443 端口未监听"

section "面板认证门与登录"
gate="$(dashboard_verify_gate)"
case "$gate" in
    ok) c_ok "未登录访问被拦截(认证门生效)" ;;
    open) c_bad "未登录可直接访问 —— 认证门未生效!" ;;
    down) c_bad "面板无响应" ;;
    *) c_info "面板状态:$gate" ;;
esac
perms="$(stat -c '%a' "$UHOME/.env" 2>/dev/null || echo "-")"
[[ "$perms" == "600" ]] && c_ok ".env 权限 600" || c_bad ".env 权限 $perms"
cperms="$(stat -c '%a' "$CRED_FILE" 2>/dev/null || echo "-")"
[[ "$cperms" == "600" ]] && c_ok "凭据文件权限 600" || c_bad "凭据文件权限 $cperms"
if [[ -f "$CRED_FILE" ]]; then
    jar="$(mktemp)"; u="$(env_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"; p="$(env_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
    code="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -c "$jar" -X POST -H 'Content-Type: application/json' \
        -d "{\"username\":\"$u\",\"password\":\"$p\"}" "http://127.0.0.1:${DASH_PORT}/api/login" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && c_ok "正确凭据登录 200 并下发会话" || c_bad "登录失败(HTTP $code)"
    bad="$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
        -d "{\"username\":\"$u\",\"password\":\"wrong-password-xyz\"}" "http://127.0.0.1:${DASH_PORT}/api/login" 2>/dev/null || echo 000)"
    [[ "$bad" == "401" || "$bad" == "403" ]] && c_ok "错误密码被拒(HTTP $bad)" || c_bad "错误密码未被拒(HTTP $bad)"
    rm -f "$jar"
fi

section "API 鉴权"
c1="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
[[ "$c1" == "401" || "$c1" == "403" ]] && c_ok "无 key 访问 API 被拒(HTTP $c1)" || c_bad "无 key 访问返回 $c1(期望 401)"
k="$(env_get API_SERVER_KEY)"
c2="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $k" "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
[[ "$c2" == "200" ]] && c_ok "带 key 访问 API 200" || c_bad "带 key 访问返回 $c2"

section "域名与证书"
domain="$(st_get DOMAIN)"
if [[ -n "$domain" ]]; then
    rc=0; domain_points_here "$domain" || rc=$?
    [[ $rc -eq 0 ]] && c_ok "$domain 解析指向本机" || c_bad "$domain 解析不指向本机"
    code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${domain}/healthz" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && c_ok "HTTPS 探活 200(https://$domain/healthz)" || c_bad "HTTPS 探活返回 $code"
    days="$(cert_days_left "$domain" 2>/dev/null || echo '')"
    if [[ -n "$days" && "$days" -gt 0 ]]; then c_ok "证书剩余 ${days} 天"; else c_bad "未读到有效证书"; fi
    issuer="$(openssl x509 -in "$(find /var/lib/caddy -name "${domain}.crt" 2>/dev/null | head -n1)" -noout -issuer 2>/dev/null || true)"
    [[ "$issuer" == *"Let's Encrypt"* || "$issuer" == *"R"* ]] && c_ok "证书签发者:$issuer" || c_info "签发者:${issuer:-未知}"
else
    c_info "未配置域名,跳过"
fi

section "消息平台"
conf=0
for l in "${PLATFORMS[@]}"; do
    id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"
    plat_configured "$id" || continue
    conf=$((conf + 1))
    live="$(plat_live_state "$id" 2>/dev/null || echo unknown)"
    case "$live" in
        connected) c_ok "$nm:已连接" ;;
        failed) c_bad "$nm:连接失败" ;;
        *) c_info "$nm:状态 $live" ;;
    esac
done
[[ $conf -eq 0 ]] && c_info "未配置任何平台"

section "备份"
bdir="$BACKUP_DIR"
if [[ -d "$bdir" ]]; then
    n="$(ls -1 "$bdir"/hermes-*.tar.gz 2>/dev/null | wc -l)"
    [[ "$n" -gt 0 ]] && c_ok "已有 $n 份备份" || c_info "尚无备份"
    out="$(backup_create acceptance 2>&1 | tail -n1)" || out=""
    if [[ "$out" == *"备份完成"* ]]; then
        last="$(ls -1t "$bdir"/hermes-*.tar.gz 2>/dev/null | head -n1)"
        if tar tzf "$last" >/dev/null 2>&1 && [[ -s "$last" ]]; then
            c_ok "新建备份可读:$(basename "$last")($(du -h "$last" | awk '{print $1}'))"
            if tar tzf "$last" 2>/dev/null | grep -q '\.hermes/config\.yaml'; then c_ok "备份含 config.yaml"; else c_bad "备份缺 config.yaml"; fi
            if tar tzf "$last" 2>/dev/null | grep -q '\.hermes/tools/'; then c_bad "备份混入了可重装的运行时(体积会失控)"; else c_ok "备份已排除运行时/源码树"; fi
        else
            c_bad "备份包不可读"
        fi
    else
        c_bad "备份命令未成功:$out"
    fi
else
    c_bad "备份目录不存在:$bdir"
fi

section "已安装命令"
if [[ -x /usr/local/bin/hermes-vps ]]; then
    c_ok "/usr/local/bin/hermes-vps 已安装 → $(bash /usr/local/bin/hermes-vps version 2>/dev/null || echo '版本未知')"
else
    c_info "/usr/local/bin/hermes-vps 未安装(可跑 self-install)"
fi

section "卸载预览(不得删除任何东西)"
before="$(ls -1 "$ETC_DIR" 2>/dev/null | wc -l)"
preview="$(uninstall_preview 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')" || preview=""
after="$(ls -1 "$ETC_DIR" 2>/dev/null | wc -l)"
assert_contains "$preview" "$UHOME" "预览列出了数据目录"
assert_eq "$before" "$after" "预览不产生副作用(文件数不变)"

section "自检项(调用生产 diagnose)"
diag="$(diagnose 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')" || diag=""
if [[ "$diag" == *"全部检查通过"* ]]; then
    c_ok "diagnose:$(printf '%s' "$diag" | grep -o '全部检查通过([0-9]* 项)' || echo '全部通过')"
else
    c_bad "diagnose 有未通过项:"
    printf '%s\n' "$diag" | grep -E "✘" | sed 's/^/      /' | head -10
fi

summary

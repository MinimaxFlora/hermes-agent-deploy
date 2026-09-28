#!/usr/bin/env bash
# =============================================================================
# tests/acceptance.sh —— 真机验收(在 VPS 上以 root 运行)
#
# 检查:安装完整性 / 三个常驻服务 / 端口 / 面板认证门 / API 鉴权 /
#       域名 HTTPS 与证书 / 反代路由 / 服务重启存活 / 备份可用 / 卸载预览
#
# 用法:
#   bash tests/acceptance.sh                    # 从 /etc/hermes-vps/state.env 读域名
#   bash tests/acceptance.sh hermes.example.com # 指定域名
#   SKIP_RESTART=1 bash tests/acceptance.sh      # 跳过服务重启存活检查
# =============================================================================
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# 只为了拿 hv_creds_get / hv_state_get(纯函数,无副作用)
# shellcheck source=/dev/null
source "${ROOT}/lib/webui.sh"

DOMAIN="${1:-$(hv_state_get DOMAIN "")}"
HV_INSTALLED_BIN="${HV_INSTALLED_BIN:-/usr/local/bin/hermes-vps}"
export HV_INSTALLED_BIN
pass=0; fail=0; skip=0
ok()   { printf '\033[32m✔\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '\033[31m✘\033[0m %s\n' "$1"; fail=$((fail+1)); }
skip_() { printf '\033[33m-\033[0m %s\n' "$1"; skip=$((skip+1)); }
head_() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

[[ "$(id -u)" == "0" ]] || { echo "需要 root 运行"; exit 2; }

head_ "1. 安装完整性"
if [[ -x "$HV_HERMES_BIN" ]]; then
    ok "hermes launcher 存在:$HV_HERMES_BIN($("$HV_HERMES_BIN" --version 2>/dev/null | head -n1 || echo 版本未知))"
else
    bad "hermes launcher 不存在:$HV_HERMES_BIN"
fi
if [[ -f "${HV_UHOME}/config.yaml" ]]; then ok "config.yaml 存在"; else bad "config.yaml 缺失"; fi
if [[ -f "${HV_UHOME}/.env" ]]; then
    perm="$(stat -c %a "${HV_UHOME}/.env")"
    [[ "$perm" == "600" ]] && ok ".env 权限 600" || bad ".env 权限为 $perm(应为 600)"
else
    bad ".env 缺失"
fi
id "$HV_USER" >/dev/null 2>&1 && ok "服务用户 $HV_USER 存在" || bad "服务用户 $HV_USER 不存在"

head_ "2. systemd 常驻服务"
for u in hermes-gateway.service hermes-dashboard.service caddy.service; do
    if ! systemctl list-unit-files "$u" >/dev/null 2>&1; then skip_ "$u 未安装"; continue; fi
    state="$(systemctl is-active "$u" 2>/dev/null)"
    en="$(systemctl is-enabled "$u" 2>/dev/null)"
    if [[ "$state" == "active" && "$en" == "enabled" ]]; then ok "$u active + enabled(开机自启)"
    else bad "$u 状态异常:active=$state enabled=$en(action: hermes-vps service logs ${u%%.*})"; fi
done
gw_user="$(systemctl show -p User --value hermes-gateway.service 2>/dev/null | tr -d '\r')"
[[ "$gw_user" == "$HV_USER" ]] && ok "网关以 $HV_USER 身份运行" || bad "网关运行用户是 '${gw_user:-root}',不是 $HV_USER"

# Caddy 常以非 root 用户运行;日志目录不可写会让它启动即退出(真机踩过)
caddy_user="$(systemctl show -p User --value caddy.service 2>/dev/null | tr -d '\r')"
[[ -z "$caddy_user" || "$caddy_user" == "root" ]] && caddy_user="caddy"
if id "$caddy_user" >/dev/null 2>&1; then
    if su -s /bin/sh "$caddy_user" -c 'test -w /var/log/caddy' 2>/dev/null; then
        ok "Caddy 运行用户 $caddy_user 可写 /var/log/caddy"
    else
        bad "Caddy 运行用户 $caddy_user 无法写 /var/log/caddy —— 服务会启动失败(hermes-vps domain apply 可修复)"
    fi
fi

head_ "3. 端口绑定(只应绑回环)"
for p in "$HV_DASH_PORT" "$HV_API_PORT"; do
    if ss -lntH "sport = :$p" 2>/dev/null | grep -q .; then
        addr="$(ss -lntH "sport = :$p" 2>/dev/null | awk '{print $4}' | head -n1)"
        if [[ "$addr" == 127.0.0.1:* ]]; then ok "端口 $p 绑定在 $addr(仅本机)"
        else bad "端口 $p 绑定在 $addr —— 面板/API 不应监听公网!"; fi
    else
        skip_ "端口 $p 未监听"
    fi
done

head_ "4. 面板认证门"
status_body="$(curl -sS -m 8 "http://127.0.0.1:${HV_DASH_PORT}/api/status" 2>/dev/null | tr -d ' \n')"
if [[ -n "$status_body" ]]; then
    if [[ "$status_body" == *'"auth_required":true'* ]]; then
        ok "本机 /api/status:auth_required=true"
    else
        if [[ -n "$DOMAIN" ]]; then bad "声明了公网域名但 auth_required≠true(危险)"; else skip_ "未配域名,面板为本机模式"; fi
    fi
    if [[ "$status_body" == *'"basic"'* ]]; then ok "认证提供方包含 basic(用户名/密码)"; else bad "未发现 basic 提供方"; fi
else
    bad "无法访问面板 /api/status(端口未监听或服务异常)"
fi

head_ "5. OpenAI 兼容 API 鉴权"
if [[ "$(hv_state_get API_SERVER off)" == "on" ]]; then
    code_no_key="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HV_API_PORT}/v1/models" 2>/dev/null || echo 000)"
    case "$code_no_key" in
        401|403) ok "无 key 访问 /v1/models → $code_no_key(鉴权生效)" ;;
        000)     bad "API 端口无响应" ;;
        *)       bad "无 key 访问 /v1/models → $code_no_key(期望 401/403)" ;;
    esac
    api_key="$(hv_creds_get API_SERVER_KEY "")"
    if [[ -n "$api_key" ]]; then
        code_key="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${api_key}" "http://127.0.0.1:${HV_API_PORT}/v1/models" 2>/dev/null || echo 000)"
        case "$code_key" in
            200) ok "带 key 访问 /v1/models → 200" ;;
            *)   bad "带 key 访问 /v1/models → $code_key(检查 API_SERVER_KEY 与网关)" ;;
        esac
    else
        skip_ "无 API key 可测"
    fi
else
    skip_ "API server 未启用"
fi

head_ "6. 域名 / 证书 / 反向代理"
if [[ -z "$DOMAIN" ]]; then
    skip_ "未配置域名"
else
    h_code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${DOMAIN}/healthz" 2>/dev/null || echo 000)"
    [[ "$h_code" == "200" ]] && ok "https://${DOMAIN}/healthz → 200" || bad "https://${DOMAIN}/healthz → $h_code"
    # 证书信息
    cert_info="$(echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -subject -enddate 2>/dev/null)"
    if [[ -n "$cert_info" ]]; then
        echo "$cert_info" | sed 's/^/      /'
        grep -qi "issuer.*Let's Encrypt\|issuer.*R1[0-3]\|issuer.*E[0-9]" <<<"$cert_info" && ok "证书由 ACME(Let's Encrypt)签发" || skip_ "证书签发者非 Let's Encrypt(可能是自签)"
    else
        bad "无法读取 TLS 证书"
    fi
    # 面板路径应被认证门拦住(不能 200 直开)
    p_code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null || echo 000)"
    case "$p_code" in
        200) bad "https://${DOMAIN}/ → 200 —— 请确认是登录页(未认证不应看到面板内容)" ;;
        302|401|403) ok "https://${DOMAIN}/ → $p_code(被认证门拦截)" ;;
        *) bad "https://${DOMAIN}/ → $p_code" ;;
    esac
    # /v1 应转到 API(未带 key → 401/403)
    if [[ "$(hv_state_get API_SERVER off)" == "on" ]]; then
        v1_code="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "https://${DOMAIN}/v1/models" 2>/dev/null || echo 000)"
        case "$v1_code" in
            401|403) ok "https://${DOMAIN}/v1/models → $v1_code(反代到 API 成功)" ;;
            *) bad "https://${DOMAIN}/v1/models → $v1_code(期望 401/403)" ;;
        esac
    fi
fi

head_ "7. 服务重启存活"
if [[ "${SKIP_RESTART:-0}" == "1" ]]; then
    skip_ "SKIP_RESTART=1"
else
    systemctl restart hermes-dashboard.service hermes-gateway.service 2>/dev/null
    sleep 8
    d_ok=0; g_ok=0
    systemctl is-active --quiet hermes-dashboard.service && d_ok=1
    systemctl is-active --quiet hermes-gateway.service && g_ok=1
    [[ $d_ok -eq 1 ]] && ok "重启后面板仍在运行" || bad "重启后面板未起来(hermes-vps service logs dashboard)"
    [[ $g_ok -eq 1 ]] && ok "重启后网关仍在运行" || bad "重启后网关未起来(hermes-vps service logs gateway)"
    sleep 3
    curl -sS -m 8 -o /dev/null "http://127.0.0.1:${HV_DASH_PORT}/api/status" 2>/dev/null \
        && ok "重启后面板端口可访问" || bad "重启后面板端口无响应"
fi

head_ "8. 备份"
if "$HV_INSTALLED_BIN" backup create --label acceptance --yes >/tmp/hv-backup.out 2>&1; then
    last="$(hv_state_get LAST_BACKUP "")"
    if [[ -n "$last" && -s "$last" ]]; then ok "备份成功:$(du -h "$last" | awk '{print $1}') $last"
    else ok "备份命令成功"; fi
else
    bad "备份失败(见 /tmp/hv-backup.out)"
fi

head_ "9. 卸载预览(不执行)"
"$HV_INSTALLED_BIN" uninstall </dev/null >/tmp/hv-uninstall-preview.out 2>&1 || true
grep -q "卸载预览" /tmp/hv-uninstall-preview.out && ok "卸载流程能列出待处理路径并等待确认(不会误删)" \
    || bad "卸载预览异常(见 /tmp/hv-uninstall-preview.out)"

printf '\n\033[1m结果: ✔ %d 通过 / ✘ %d 失败 / - %d 跳过\033[0m\n' "$pass" "$fail" "$skip"
[[ $fail -eq 0 ]] || exit 1

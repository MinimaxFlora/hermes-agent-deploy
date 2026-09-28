#!/usr/bin/env bash
# =============================================================================
# tests/smoke.sh —— 不需要 root 的逻辑冒烟测试
# 覆盖:状态读写、数据表解析、Caddyfile 渲染、CLI 子命令可执行性。
# 用法: bash tests/smoke.sh
# =============================================================================
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export HV_SELF_DIR="$ROOT"
export HV_ETC="$SANDBOX/etc"
export HV_LOG_DIR="$SANDBOX/log"
export HV_BACKUP_DIR="$SANDBOX/backup"
export HV_USER_HOME="$SANDBOX/home"
export HV_UHOME="$SANDBOX/home/.hermes"
export HV_HERMES_BIN="$SANDBOX/home/.local/bin/hermes"
export HV_NONINTERACTIVE=1
export HV_NO_COLOR=1
mkdir -p "$HV_UHOME"

fail=0
ok()  { printf '\033[32m✔\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✘\033[0m %s\n' "$1"; fail=$((fail+1)); }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (未找到: $2)"; fi; }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (得到 '$1',期望 '$2')"; fi; }

# shellcheck source=/dev/null
for m in common ui detect account provider platform webui caddy service backup lifecycle doctor; do
    source "${ROOT}/lib/${m}.sh"
done

echo "── 键值/状态读写 ──"
hv_kv_set "$SANDBOX/t.env" FOO bar
hv_kv_set "$SANDBOX/t.env" FOO baz
assert_eq "$(hv_kv_get "$SANDBOX/t.env" FOO)" "baz" "同名键覆盖而不是追加"
hv_kv_set "$SANDBOX/t.env" QUOTED '"a b"'
assert_eq "$(hv_kv_get "$SANDBOX/t.env" QUOTED)" "a b" "带引号的值能读回"
hv_kv_unset "$SANDBOX/t.env" FOO
assert_eq "$(hv_kv_get "$SANDBOX/t.env" FOO default)" "default" "删除键后取默认值"

hv_state_set DOMAIN test.example.com
assert_eq "$(hv_state_get DOMAIN)" "test.example.com" "状态文件读写"
if [[ "$(uname -s)" == "Linux" ]]; then
    [[ "$(stat -c %a "$HV_STATE_FILE" 2>/dev/null || echo 600)" == "600" ]] && ok "状态文件权限 600" || bad "状态文件权限不是 600"
else
    printf '\033[33m!\033[0m 非 Linux,跳过权限位断言(MSYS 不反映真实权限)\n'
fi

echo "── 随机串 ──"
p1="$(hv_random 16)"; p2="$(hv_random 16)"
[[ ${#p1} -eq 16 && "$p1" != "$p2" ]] && ok "随机密码长度与唯一性" || bad "随机密码异常: $p1 / $p2"
hex="$(hv_random_hex 32)"
assert_eq "${#hex}" "64" "随机 hex 长度"

echo "── 提供商表 ──"
assert_eq "$(hv_provider_envkey deepseek)" "DEEPSEEK_API_KEY" "deepseek 密钥变量名"
assert_eq "$(hv_provider_model anthropic)" "claude-sonnet-4-6" "anthropic 示例模型"
assert_eq "$(hv_provider_name __custom__)" "自定义 OpenAI 兼容端点" "自定义端点行存在"
n="$(hv_provider_rows | wc -l)"
[[ "$n" -ge 15 ]] && ok "提供商表解析出 $n 行" || bad "提供商表行数异常: $n"

echo "── 平台表 ──"
assert_eq "$(hv_platform_mode weixin)" "qr" "微信标记为扫码类"
assert_eq "$(hv_platform_required qqbot)" "QQ_APP_ID,QQ_CLIENT_SECRET" "QQ 必需变量"
assert_eq "$(hv_platform_mode telegram)" "env" "Telegram 为 env 类"
n="$(hv_platform_rows | wc -l)"
[[ "$n" -ge 10 ]] && ok "平台表解析出 $n 行" || bad "平台表行数异常: $n"

echo "── Caddyfile 渲染 ──"
render() { hv_caddy_render "hermes.example.com" "me@example.com" "$1" "${2:-}"; }
f="$(render 1)"
assert_contains "$(cat "$f")" "hermes.example.com {" "域名站点块"
assert_contains "$(cat "$f")" "reverse_proxy 127.0.0.1:9119" "面板反代到 9119"
assert_contains "$(cat "$f")" "reverse_proxy 127.0.0.1:8642" "API 反代到 8642"
assert_contains "$(cat "$f")" "email me@example.com" "ACME 邮箱"
assert_contains "$(cat "$f")" '/healthz' "健康检查端点"
if grep -qE '@[A-Z_]+@' "$f"; then bad "渲染后仍残留占位符"; else ok "占位符已全部替换"; fi
f2="$(render 0)"
if grep -q 'reverse_proxy 127.0.0.1:8642' "$f2"; then bad "关闭 API 时仍生成 /v1 反代"; else ok "关闭 API 时不生成 /v1 反代"; fi
f3="$(render 1 "https://acme-staging-v02.api.letsencrypt.org/directory")"
assert_contains "$(cat "$f3")" "acme_ca https://acme-staging" "自定义 ACME CA"
rm -f "$f" "$f2" "$f3"

echo "── Caddy 配置写入流程(用桩 caddy 验证:校验→备份→写入→状态)──"
# 测试桩:本段只写沙箱目录,不需要真实 root
hv_require_root() { :; }
mkdir -p "$SANDBOX/bin" "$SANDBOX/caddy"
cat >"$SANDBOX/bin/caddy" <<'EOS'
#!/usr/bin/env bash
# 桩:模拟 caddy 的 fmt/validate/version 行为
case "${1:-}" in
    fmt)      exit 0 ;;
    validate) [[ "${FAKE_CADDY_VALIDATE_FAIL:-0}" == "1" ]] && { echo "Error: unrecognized directive: bogus"; exit 1; }; exit 0 ;;
    version)  echo "v2.10.0 (stub)"; exit 0 ;;
    *)        exit 0 ;;
esac
EOS
chmod +x "$SANDBOX/bin/caddy"
export PATH="$SANDBOX/bin:$PATH"
export HV_CADDYFILE="$SANDBOX/caddy/Caddyfile"
export HV_CADDY_ETC="$SANDBOX/caddy"
export HV_CADDY_LOG_DIR="$SANDBOX/caddy/logs"

if hv_caddy_write_config "hermes.example.com" "me@example.com" 1 "" >/dev/null 2>&1; then
    ok "写入 Caddyfile 成功"
else
    bad "写入 Caddyfile 失败"
fi
grep -q "managed-by: hermes-vps" "$HV_CADDYFILE" && ok "带 managed-by 标记" || bad "缺少 managed-by 标记"
assert_eq "$(hv_state_get DOMAIN)" "hermes.example.com" "写入后状态记录了域名"

# 二次写入(改域名)应产生备份,而不是覆盖丢失
hv_caddy_write_config "new.example.com" "me@example.com" 0 "" >/dev/null 2>&1
if ls "$SANDBOX/caddy/.bak"/Caddyfile.* >/dev/null 2>&1; then ok "改配置前自动备份旧 Caddyfile"; else bad "没有生成备份"; fi
assert_contains "$(cat "$HV_CADDYFILE")" "new.example.com" "域名已更新"
if grep -q 'reverse_proxy 127.0.0.1:8642' "$HV_CADDYFILE"; then bad "关闭 API 时仍写入 /v1 反代"; else ok "关闭 API 时不写 /v1 反代"; fi

# 校验失败必须拒绝写入
before_hash="$(md5sum "$HV_CADDYFILE" 2>/dev/null | awk '{print $1}')"
if FAKE_CADDY_VALIDATE_FAIL=1 hv_caddy_write_config "bad.example.com" "me@example.com" 1 "" >/dev/null 2>&1; then
    bad "校验失败时仍然写入了配置(危险)"
else
    ok "校验失败时拒绝写入"
fi
after_hash="$(md5sum "$HV_CADDYFILE" 2>/dev/null | awk '{print $1}')"
assert_eq "$after_hash" "$before_hash" "校验失败后原配置未被改动"

echo "── 服务单元生成(不落盘系统目录)──"
unit="$(sed -n '1,200p' /dev/null)"
# 直接校验生成逻辑里的关键片段
grep -q 'RestartPreventExitStatus=78' "${ROOT}/lib/service.sh" && ok "面板单元带 78 退出码保护" || bad "面板单元缺少 78 保护"
grep -q 'dashboard --host 127.0.0.1' "${ROOT}/lib/service.sh" && ok "面板固定绑回环" || bad "面板未固定回环绑定"

echo "── CLI 子命令 ──"
for c in "version" "help" "model list" "platform list"; do
    if bash "${ROOT}/bin/hermes-vps" $c >/dev/null 2>&1; then ok "hermes-vps $c"; else bad "hermes-vps $c 失败"; fi
done

# 通用开关必须真的被入口解析(--debug 会打开 set -x,能观察到)
# 注意:不能用 `cmd | grep -q`,grep 提前退出会让上游 SIGPIPE,pipefail 下误判
_sw_out="$(bash "${ROOT}/bin/hermes-vps" mirror show --debug 2>&1 || true)"
if grep -q '^+' <<<"$_sw_out"; then
    ok "入口解析通用开关(--debug 已生效)"
else
    bad "入口未解析通用开关(--debug/--yes/--non-interactive 会变成空操作)"
fi

echo "── 配置文件示例可被 source ──"
if ( set -u; . "${ROOT}/etc/hermes-vps.conf.example" ) 2>/dev/null; then
    ok "etc/hermes-vps.conf.example 语法正确"
else
    bad "etc/hermes-vps.conf.example 无法 source"
fi

echo
if [[ $fail -eq 0 ]]; then printf '\033[32m全部冒烟测试通过\033[0m\n'; else printf '\033[31m%d 项失败\033[0m\n' "$fail"; fi
exit "$fail"

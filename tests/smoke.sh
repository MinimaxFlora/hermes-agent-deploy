#!/usr/bin/env bash
# =============================================================================
#  smoke.sh —— 纯逻辑冒烟(不碰系统、不需要 root)
#    载入 lib 后直接调用生产函数,验证原语与数据表行为
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "键值存储"
d="$(tmpdir)"; f="$d/x.env"
kv_set "$f" FOO "bar baz"
assert_eq "bar baz" "$(kv_get "$f" FOO)" "写入与读取(含空格)"
kv_set "$f" FOO "qux"
assert_eq "qux" "$(kv_get "$f" FOO)" "同键覆盖"
kv_set "$f" SECOND "2"
assert_eq "2" "$(kv_get "$f" SECOND)" "第二个键"
assert_eq "def" "$(kv_get "$f" NOPE "def")" "缺省值"
kv_del "$f" FOO
assert_eq "" "$(kv_get "$f" FOO)" "删除键"
assert_eq "2" "$(kv_get "$f" SECOND)" "删除不影响其它键"
if [[ "$(uname -s)" == "Linux" ]]; then
    if [[ "$(stat -c '%a' "$f" 2>/dev/null || echo 600)" == "600" ]]; then c_ok "存储文件权限 600"; else c_bad "存储文件权限不是 600"; fi
else
    c_info "非 Linux,跳过文件权限断言"
fi
rm -rf "$d"

section "状态与凭据"
d="$(tmpdir)"; STATE_FILE="$d/state.env"; CRED_FILE="$d/cred.txt"
st_set DOMAIN panel.example.com
assert_eq "panel.example.com" "$(st_get DOMAIN)" "状态读写"
cred_set PANEL_PASSWORD secret123
assert_eq "secret123" "$(cred_get PANEL_PASSWORD)" "凭据读写"
st_set API_ENABLED 1
assert_eq "1" "$(st_api_enabled)" "API 开关读取"
state_bak="$d/state2.env"; STATE_FILE="$state_bak"
st_set API_SERVER on
assert_eq "1" "$(st_api_enabled)" "兼容旧版 API_SERVER=on"
STATE_FILE="$d/state3.env"; st_set API_SERVER off
assert_eq "0" "$(st_api_enabled)" "旧版 API_SERVER=off"
rm -rf "$d"

section "数据表"
assert_eq "19" "$(printf '%s\n' "${#PROVIDERS[@]}")" "提供商数量"
if [[ ${#PLATFORMS[@]} -ge 12 ]]; then c_ok "平台数量 ${#PLATFORMS[@]} 个"; else c_bad "平台数量异常"; fi
assert_eq "DeepSeek 官方" "$(prov_name deepseek)" "provider 名称解析"
assert_eq "DEEPSEEK_API_KEY" "$(prov_env deepseek)" "provider 密钥变量"
assert_eq "https://api.deepseek.com/v1" "$(prov_base deepseek)" "provider base_url"
assert_eq "QQ 机器人(官方 API v2)" "$(plat_name qqbot)" "平台名称解析"
assert_eq "qr" "$(plat_mode qqbot)" "平台模式(qr=扫码)"
assert_eq "env" "$(plat_mode feishu)" "平台模式(env=填凭据)"
assert_eq "" "$(prov_name notexist 2>/dev/null || true)" "未知 provider 返回空"
d="$(tmpdir)"; UHOME="$d"
if plat_configured qqbot; then c_bad "未配置时 plat_configured 应为假"; else c_ok "未配置平台判定"; fi
env_set QQ_APP_ID 123
env_set QQ_CLIENT_SECRET abc
if plat_configured qqbot; then c_ok "凭据齐全后判定为已配置"; else c_bad "凭据齐全仍判定未配置"; fi
rm -rf "$d"

section "文本宽度与菜单对齐"
assert_eq "2" "$(disp_len "中")" "中文算 2 列"
assert_eq "2" "$(disp_len "ab")" "ASCII 算 1 列(ab=2)"
assert_eq "4" "$(disp_len "abcd")" "ASCII 四字符(=4)"
assert_eq "1" "$(disp_len "─")" "制表符算 1 列"
assert_eq "1" "$(disp_len "●")" "状态点算 1 列(避免错位)"
assert_eq "6" "$(disp_len "中文ab")" "混排宽度(中文4+ab2=6)"

section "Caddyfile 渲染"
html="$(caddy_render "panel.example.com" "admin@example.com" 1)"
assert_contains "$html" "panel.example.com {" "包含站点地址"
assert_contains "$html" "reverse_proxy 127.0.0.1:9119" "面板反代"
assert_contains "$html" "reverse_proxy 127.0.0.1:8642" "API 反代(开启时)"
assert_contains "$html" "handle /v1/*" "API 路由"
assert_contains "$html" "admin@example.com" "ACME 邮箱"
assert_contains "$html" "$CADDY_LOG_DIR/hermes-access.log" "访问日志路径(跟随可重定位的日志目录)"
off="$(caddy_render "panel.example.com" "" 0)"
assert_not_contains "$off" "handle /v1/*" "关闭 API 时不生成 /v1 路由"
assert_not_contains "$off" "email" "无邮箱时不写 email 指令"
assert_contains "$off" "reverse_proxy 127.0.0.1:9119" "关闭 API 时面板仍反代"
# 端口覆盖:用户态实例的面板端口不一定是 9119(真机踩过 9120),root 侧助手必须按传入端口渲染,
# 否则证书配好了、反代却打到 9119(别的实例或空门)
ovr="$(HV_RENDER_DASH_PORT=9120 HV_RENDER_API_PORT=8643 caddy_render "panel.example.com" "" 1)"
assert_contains "$ovr" "reverse_proxy 127.0.0.1:9120" "面板端口可覆盖(用户态实例)"
assert_contains "$ovr" "reverse_proxy 127.0.0.1:8643" "API 端口可覆盖"
assert_not_contains "$ovr" "127.0.0.1:9119" "覆盖后不再出现默认端口"

section "JSON 取值"
d="$(tmpdir)"; j="$d/r.json"
printf '{"app_id":"1904084256","client_secret":"s3cr3t+/-=","user_openid":"332CA3"}' >"$j"
assert_eq "1904084256" "$(json_get "$j" app_id)" "json_get 基本取值"
assert_eq "s3cr3t+/-=" "$(json_get "$j" client_secret)" "json_get 含特殊字符"
assert_eq "" "$(json_get "$j" nothing)" "json_get 缺键返回空"
rm -rf "$d"

section "CLI 分发(用构建产物)"
bash "$ROOT/build.sh" "$DIST" >/dev/null
assert_eq "hermes-vps $(tr -d '[:space:]' <"$ROOT/VERSION")" "$(bash "$DIST" version)" "version 子命令"
assert_contains "$(bash "$DIST" help)" "install" "help 输出含子命令"
assert_contains "$(bash "$DIST" --help)" "用法" "长帮助可用"
out="$(bash "$DIST" 2>&1 || true)"
assert_contains "$out" "用法" "无参数且无 TTY 时打印用法(不进菜单)"
# 仓库外跑自检:失败时把 selftest 的完整输出打出来,便于在 CI 日志里定位
st_rc=0
st_out="$(cd /tmp && bash "$DIST" selftest 2>&1)" || st_rc=$?
if [[ "${st_rc:-0}" -eq 0 ]]; then
    c_ok "selftest 在仓库外也能跑"
else
    c_bad "selftest 在仓库外失败(退出码 ${st_rc:-?})"
    printf '%s\n' "$st_out" | sed 's/^/      /'
fi

# domain-root 参数解析:真机踩过 CLI 多 shift 一次 → 域名位置拿到 --port → Caddyfile 站点地址错
domain_root_parse panel.example.com --port 9120 --api-port 8643 --email a@b.c --api 1
assert_eq "panel.example.com" "$DR_DOMAIN" "domain-root:域名解析正确"
assert_eq "9120" "$DR_PORT" "domain-root:--port 解析"
assert_eq "8643" "$DR_APIPORT" "domain-root:--api-port 解析"
assert_eq "a@b.c" "$DR_EMAIL" "domain-root:--email 解析"
assert_eq "1" "$DR_API" "domain-root:--api 解析"
domain_root_parse panel.example.com
assert_eq "9119" "$DR_PORT" "domain-root:未给端口时用本实例默认端口"

# 其他用户实例探测(root 模式下提醒"别又装一套")
_tu="$(mktemp -d)"; mkdir -p "$_tu/alice/.config/hermes-vps" "$_tu/bob/.config"; : >"$_tu/alice/.config/hermes-vps/state.env"
assert_eq "alice" "$(HV_HOME_ROOT="$_tu" other_user_instances_users)" "探测其他用户的用户态实例"
assert_eq "1" "$(HV_HOME_ROOT="$_tu" other_user_instances | wc -l | tr -d ' ')" "实例条数正确"
_tu2="$(mktemp -d)"; mkdir -p "$_tu2/carol"
assert_eq "" "$(HV_HOME_ROOT="$_tu2" other_user_instances_users)" "无实例时输出为空"
rm -rf "$_tu" "$_tu2"

# root 侧助手:非 root 调用只提示、不崩(它本来就是给 sudo 用的)
dr_out="$(bash "$DIST" domain-root panel.example.com 2>&1)" || true
assert_contains "$dr_out" "root 侧助手" "domain-root 子命令存在,非 root 时给出提示而非报错崩掉"

summary

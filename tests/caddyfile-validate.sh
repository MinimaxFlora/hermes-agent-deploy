#!/usr/bin/env bash
# =============================================================================
#  caddyfile-validate.sh —— 用**真实 caddy** 校验生产函数渲染出来的配置
#  直接调 caddy_render(不另写渲染路径);caddy 不存在则跳过(CI 会先装)。
#  用法: HV_CADDY_BIN=/path/to/caddy bash tests/caddyfile-validate.sh
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap - ERR

section "真实 caddy 校验 Caddyfile"

# 注意:lib 加载时会把 CADDY_BIN 重置为默认值,所以测试用 HV_CADDY_BIN 覆盖
CADDY="${HV_CADDY_BIN:-}"
[[ -z "$CADDY" && -x "${CADDY_BIN:-/nonexistent}" ]] && CADDY="$CADDY_BIN"
if [[ -z "$CADDY" ]]; then
    for c in caddy /usr/local/bin/caddy /usr/bin/caddy; do
        if command -v "$c" >/dev/null 2>&1; then CADDY="$(command -v "$c")"; break; fi
        [[ -x "$c" ]] && { CADDY="$c"; break; }
    done
fi
if [[ -z "$CADDY" || ! -x "$CADDY" ]]; then
    c_info "未找到 caddy 二进制,跳过(CI 会先下载;本地可设 HV_CADDY_BIN=/path/to/caddy)"
    summary
    exit 0
fi
c_info "使用 caddy:$("$CADDY" version 2>/dev/null | head -n1)"

# 工作目录放在仓库内并 cd 进去:用相对路径,避免把 MSYS 风格绝对路径交给原生二进制
work="$ROOT/.hv-caddytest-$$"
mkdir -p "$work"
cleanup() { cd "$ROOT" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
cd "$work"

validate() { # validate <说明> <域名> <邮箱> <API开关>
    local desc="$1" domain="$2" email="$3" api="$4"
    local f="Caddyfile.$$.$RANDOM"
    caddy_render "$domain" "$email" "$api" >"$f"
    if "$CADDY" validate --adapter caddyfile --config "$f" >out.log 2>&1; then
        c_ok "$desc"
    else
        c_bad "$desc"
        sed 's/^/      /' out.log | head -20
        sed 's/^/      | /' "$f" | head -30
    fi
    rm -f "$f"
}

validate "域名 + 邮箱 + 开 API" "panel.example.com" "admin@example.com" 1
validate "域名 + 无邮箱 + 开 API" "panel.example.com" "" 1
validate "域名 + 邮箱 + 关 API" "panel.example.com" "admin@example.com" 0
validate "纯 IP 访问(无 ACME)" "203.0.113.10" "" 1
validate "子域较深 + 开 API" "hermes.panel.example.com" "a@example.com" 1
validate "含连字符域名" "my-hermes-1.example.com" "a@example.com" 0

section "渲染内容要点"
out="$(caddy_render "a.example.com" "" 1)"
assert_contains "$out" "admin 127.0.0.1:2019" "包含 admin 管理接口(仅回环)"
assert_contains "$out" "encode zstd gzip" "开启压缩"
assert_contains "$out" "handle /healthz" "健康检查由 Caddy 自身应答"
assert_contains "$out" "handle /v1/*" "开 API 时有 /v1 路由"
assert_not_contains "$(caddy_render "a.example.com" "" 0)" "handle /v1/*" "关 API 时无 /v1 路由"

summary

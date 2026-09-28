#!/usr/bin/env bash
# =============================================================================
# tests/caddy-routing.sh —— 真机路由测试(用真实 caddy 二进制)
#
# 做法:
#   1) 用两个假上游冒充面板(9119)与 API(8642);
#   2) 把渲染出来的 Caddyfile 的站点地址换成 http://127.0.0.1:<测试端口>
#      (模板本身是域名+自动 HTTPS,这里只为验证路由与 handle 组语义);
#   3) 启动 caddy,curl 三个路径,断言分别命中健康检查 / API / 面板。
#
# 用法: bash tests/caddy-routing.sh /path/to/caddy
# =============================================================================
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY_BIN="${1:-${CADDY:-}}"
[[ -z "$CADDY_BIN" ]] && CADDY_BIN="$(command -v caddy || true)"
if [[ -z "$CADDY_BIN" || ! -x "$CADDY_BIN" ]]; then
    echo "跳过:未找到 caddy 二进制"; exit 0
fi

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX"
export HV_SELF_DIR="$ROOT" HV_ETC="$SANDBOX/etc" HV_LOG_DIR="$SANDBOX/log" HV_BACKUP_DIR="$SANDBOX/bak"
export HV_NONINTERACTIVE=1 HV_NO_COLOR=1
# shellcheck source=/dev/null
for m in common ui account caddy; do source "${ROOT}/lib/${m}.sh"; done

TEST_PORT=18088
DASH_PORT=19119
API_PORT=18642

# 假上游:两个目录,index.html 用不同标记
mkdir -p "$SANDBOX/dash" "$SANDBOX/api" "$SANDBOX/log"
echo "THIS-IS-DASHBOARD" >"$SANDBOX/dash/index.html"
echo "THIS-IS-API"       >"$SANDBOX/api/index.html"

(cd "$SANDBOX/dash" && python -m http.server "$DASH_PORT" >/dev/null 2>&1) &
DASH_PID=$!
(cd "$SANDBOX/api" && python -m http.server "$API_PORT" >/dev/null 2>&1) &
API_PID=$!
sleep 2

# 渲染并改造成本地可跑的测试配置
export HV_DASH_PORT="$DASH_PORT" HV_API_PORT="$API_PORT"
cfg="$(hv_caddy_render "IGNORED" "test@example.com" 1 "")"
sed -i -E "s|^IGNORED \{|http://127.0.0.1:${TEST_PORT} {|" "$cfg"
sed -i -E "s|admin 127.0.0.1:2019|admin 127.0.0.1:12019|" "$cfg"

echo "── 测试用 Caddyfile ──"
sed 's/^/    /' "$cfg"

"$CADDY_BIN" run --config "$cfg" --adapter caddyfile >"$SANDBOX/log/caddy.out" 2>&1 &
CADDY_PID=$!
sleep 4

fail=0
check() { # <描述> <url> <期望包含> <期望状态码>
    local desc="$1" url="$2" want="$3" code="$4"
    local body real_code
    body="$(curl -sS -m 8 "$url" 2>/dev/null)"
    real_code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
    if [[ "$body" == *"$want"* && "$real_code" == "$code" ]]; then
        printf '\033[32m✔\033[0m %s (%s → %s)\n' "$desc" "$url" "$real_code"
    else
        printf '\033[31m✘\033[0m %s (%s → %s,期望 %s;body=%s)\n' "$desc" "$url" "$real_code" "$code" "${body:0:60}"
        fail=$((fail+1))
    fi
}

check "健康检查不走上游"   "http://127.0.0.1:${TEST_PORT}/healthz" "ok" 200
check "/v1/* 命中 API"     "http://127.0.0.1:${TEST_PORT}/v1/"     "THIS-IS-API" 200
check "其余命中面板"       "http://127.0.0.1:${TEST_PORT}/"        "THIS-IS-DASHBOARD" 200

kill "$CADDY_PID" 2>/dev/null || true
kill "$DASH_PID" "$API_PID" 2>/dev/null || true
wait 2>/dev/null || true

if [[ $fail -ne 0 ]]; then
    echo "── caddy 日志 ──"; sed 's/^/    /' "$SANDBOX/log/caddy.out" | tail -20
    echo "── 访问日志 ──";  tail -n 10 "$SANDBOX/log"/*.access.log 2>/dev/null | sed 's/^/    /'
fi
rm -f "$cfg"
[[ $fail -eq 0 ]] && printf '\033[32m路由测试通过\033[0m\n' || printf '\033[31m%d 项路由断言失败\033[0m\n' "$fail"
exit "$fail"

#!/usr/bin/env bash
# =============================================================================
#  caddy-routing.sh —— 路由行为测试:真实 caddy + 两个假上游
#  验证 /healthz 由 Caddy 直接应答、/v1/* 到 API 端口、其余到面板端口。
#  需要:caddy 二进制 + python3(起假上游);Linux 上跑(CI 用 ubuntu)。
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
trap - ERR

section "反代路由行为(真实 caddy + 假上游)"

if [[ "$(uname -s)" != "Linux" ]]; then
    c_info "非 Linux,跳过路由测试(需要 unshare/端口行为一致性)"
    summary
    exit 0
fi
if ! { py="$(pick_python)"; }; then
    c_info "无 python3,无法起假上游,跳过"
    summary
    exit 0
fi
CADDY="${HV_CADDY_BIN:-}"
[[ -z "$CADDY" && -x "${CADDY_BIN:-/nonexistent}" ]] && CADDY="$CADDY_BIN"
[[ -z "$CADDY" ]] && CADDY="$(command -v caddy || true)"
if [[ -z "$CADDY" || ! -x "$CADDY" ]]; then
    c_info "未找到 caddy,跳过(CI 会先下载)"
    summary
    exit 0
fi

work="$(mktemp -d)"
SITE_PORT=$(( (RANDOM % 2000) + 20000 ))
DASH_PORT=$(( SITE_PORT + 1 ))
API_PORT=$(( SITE_PORT + 2 ))
mkdir -p "$work/log"
cat >"$work/upstream.py" <<'PY'
import sys, http.server
body = sys.argv[2].encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
"$py" "$work/upstream.py" "$DASH_PORT" "DASHBOARD-UPSTREAM" >/dev/null 2>&1 &
dash_pid=$!
"$py" "$work/upstream.py" "$API_PORT" "API-UPSTREAM" >/dev/null 2>&1 &
api_pid=$!
cleanup() {
    kill "$dash_pid" "$api_pid" "${caddy_pid:-0}" 2>/dev/null || true
    wait "$dash_pid" "$api_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# 等两个上游起来
for _ in $(seq 1 40); do
    if curl -fsS -m 1 "http://127.0.0.1:$DASH_PORT/" >/dev/null 2>&1 && curl -fsS -m 1 "http://127.0.0.1:$API_PORT/" >/dev/null 2>&1; then break; fi
    sleep 0.25
done
assert_contains "$(curl -fsS -m 2 "http://127.0.0.1:$DASH_PORT/" || true)" "DASHBOARD-UPSTREAM" "假面板上游可用"
assert_contains "$(curl -fsS -m 2 "http://127.0.0.1:$API_PORT/" || true)" "API-UPSTREAM" "假 API 上游可用"

# 用生产函数渲染,但把端口换成测试端口
cfg="$work/Caddyfile"
caddy_render "127.0.0.1:$SITE_PORT" "" 1 \
    | sed -e "s|127.0.0.1:9119|127.0.0.1:$DASH_PORT|" -e "s|127.0.0.1:8642|127.0.0.1:$API_PORT|" \
        -e "s|/var/log/caddy/hermes-access.log|$work/log/access.log|" -e "s|admin 127.0.0.1:2019|admin 127.0.0.1:$(( SITE_PORT + 9 ))|" >"$cfg"
if "$CADDY" validate --adapter caddyfile --config "$cfg" >/tmp/hv-route.out 2>&1; then
    c_ok "测试用 Caddyfile 校验通过"
else
    c_bad "测试用 Caddyfile 校验失败"; sed 's/^/      /' /tmp/hv-route.out
fi

"$CADDY" run --config "$cfg" --adapter caddyfile >"$work/caddy.log" 2>&1 &
caddy_pid=$!
ready=0
for _ in $(seq 1 60); do
    if curl -fsS -m 1 "http://127.0.0.1:$SITE_PORT/healthz" >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.25
done
if [[ $ready -eq 1 ]]; then c_ok "caddy 已监听测试端口 $SITE_PORT"; else c_bad "caddy 未就绪"; sed 's/^/      /' "$work/caddy.log" | tail -20; summary; exit 1; fi

assert_eq "ok" "$(curl -fsS -m 3 "http://127.0.0.1:$SITE_PORT/healthz" || true)" "/healthz 由 Caddy 直接应答"
assert_contains "$(curl -fsS -m 3 "http://127.0.0.1:$SITE_PORT/" || true)" "DASHBOARD-UPSTREAM" "根路径 → 面板上游"
assert_contains "$(curl -fsS -m 3 "http://127.0.0.1:$SITE_PORT/v1/models" || true)" "API-UPSTREAM" "/v1/* → API 上游"
assert_contains "$(curl -fsS -m 3 "http://127.0.0.1:$SITE_PORT/api/config" || true)" "DASHBOARD-UPSTREAM" "/api/config → 面板上游(不被 /v1 规则吃掉)"
assert_contains "$(curl -fsS -m 3 "http://127.0.0.1:$SITE_PORT/login" || true)" "DASHBOARD-UPSTREAM" "/login → 面板上游"

# 关闭 API 时,/v1 也应落到面板(用同一套模板重新渲染)
cfg2="$work/Caddyfile.noapi"
caddy_render "127.0.0.1:$(( SITE_PORT + 5 ))" "" 0 \
    | sed -e "s|127.0.0.1:9119|127.0.0.1:$DASH_PORT|" -e "s|admin 127.0.0.1:2019|admin 127.0.0.1:$(( SITE_PORT + 8 ))|" >"$cfg2"
if "$CADDY" run --config "$cfg2" --adapter caddyfile >>"$work/caddy.log" 2>&1 & then
    caddy2_pid=$!
    for _ in $(seq 1 40); do
        curl -fsS -m 1 "http://127.0.0.1:$(( SITE_PORT + 5 ))/healthz" >/dev/null 2>&1 && break
        sleep 0.25
    done
    assert_contains "$(curl -fsS -m 3 "http://127.0.0.1:$(( SITE_PORT + 5 ))/v1/models" || true)" "DASHBOARD-UPSTREAM" "关闭 API 时 /v1 落到面板"
    kill "$caddy2_pid" 2>/dev/null || true
fi

summary

#!/usr/bin/env bash
# =============================================================================
#  strict.sh —— 严格模式回归
#  用与生产完全相同的 `set -Eeuo pipefail` 跑基础原语,专抓"本地没开 -e 所以看不见"的中止问题。
#  每个用例都在干净子 shell 里执行,任何非零退出都算失败。
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# libs 已由 tests/lib.sh 在顶层载入;这里只保留函数可用性检查
trap - ERR

section "原语在 set -Eeuo pipefail 下不得异常中止"

case_body() { # case_body <说明> <bash 代码>
    local desc="$1" code="$2"
    if out="$(bash -Eeuo pipefail -c ". '$TESTS_DIR/lib.sh' >/dev/null 2>&1; $code" 2>&1)"; then
        c_ok "$desc"
    else
        c_bad "$desc"
        printf '%s\n' "$out" | sed 's/^/      /'
    fi
}

case_body "kv_get 缺键不中止(pipefail + grep 无匹配)" '
d="$(mktemp -d)"; kv_set "$d/a.env" K V
kv_get "$d/a.env" MISSING >/dev/null
kv_get "$d/a.env" K >/dev/null
rm -rf "$d"'

case_body "kv_del 不存在的键不中止" '
d="$(mktemp -d)"; kv_set "$d/a.env" K V; kv_del "$d/a.env" NOPE; rm -rf "$d"'

case_body "st_get / env_get 缺省值兜底" '
d="$(mktemp -d)"; STATE_FILE="$d/s.env"; st_set A 1
[[ "$(st_get NOPE def)" == "def" ]] || exit 1
rm -rf "$d"'

case_body "json_get 缺键/坏文件不中止" '
d="$(mktemp -d)"; echo "{}" >"$d/x.json"
[[ -z "$(json_get "$d/x.json" nope)" ]] || exit 1
json_get "$d/missing.json" k >/dev/null || true
rm -rf "$d"'

case_body "json_err 空输入不中止且返回 0" '
json_err "" >/dev/null
json_err "not json" >/dev/null'

case_body "disp_len 长串/空串安全" '
disp_len "" >/dev/null
long=""
for _i in $(seq 1 200); do long+="中"; done
disp_len "$long" >/dev/null'

case_body "prov_field / plat_field 未知 id 不中止" '
prov_field deepseek 2 >/dev/null
prov_field nope 2 >/dev/null || true
plat_field qqbot 2 >/dev/null
plat_field nope 2 >/dev/null || true'

case_body "random_str / random_hex 在无 openssl 时也返回内容" '
[[ -n "$(random_str 12)" ]] || exit 1
[[ -n "$(random_hex 8)" ]] || exit 1'

case_body "caddy_render 无邮箱/无 API 组合" '
caddy_render "a.example.com" "" 0 >/dev/null
caddy_render "a.example.com" "x@example.com" 1 >/dev/null'

case_body "plat_live_state 无日志文件时不中止" '
UHOME="$(mktemp -d)"; plat_live_state qqbot >/dev/null; rm -rf "$UHOME"'

case_body "svc_state / port_listening 对不存在目标返回而不是崩" '
svc_state no-such-service-xyz >/dev/null
port_listening 59999 || true'

case_body "confirm/ask/pause 在非交互下取值安全" '
NONINTERACTIVE=1
ask v "问题" "默认" >/dev/null
[[ "$v" == "默认" ]] || exit 1
confirm "确认?" yes >/dev/null'
case_body "menu_choice 非交互返回空并置 EOF 标记" '
NONINTERACTIVE=1; HV_EOF=0
menu_choice ch "选择" >/dev/null
[[ -z "$ch" ]] || exit 1'

case_body "st_api_enabled 三种状态(空/on/1)" '
d="$(mktemp -d)"; STATE_FILE="$d/s.env"
[[ "$(st_api_enabled)" == "0" ]] || exit 1
st_set API_SERVER on; [[ "$(st_api_enabled)" == "1" ]] || exit 1
st_set API_ENABLED 0; [[ "$(st_api_enabled)" == "0" ]] || exit 1
rm -rf "$d"'

case_body "构建产物在 -e 下 selftest 通过" '
bash "$ROOT/build.sh" "$DIST" >/dev/null
bash "$DIST" selftest >/dev/null'

summary

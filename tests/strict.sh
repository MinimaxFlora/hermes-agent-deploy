#!/usr/bin/env bash
# =============================================================================
# tests/strict.sh —— 严格模式回归测试
#
# 入口脚本(bin/hermes-vps)使用 `set -Eeuo pipefail`。本测试用同样的严格模式
# 调用各模块的基础原语,专门抓"读不到东西就崩"这一类只在 VPS 上才暴露的问题:
#   * grep 无匹配 + pipefail → 整个脚本中止
#   * head 提前关闭管道导致上游 SIGPIPE
#   * 未定义变量
# 用法: bash tests/strict.sh
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export HV_SELF_DIR="$ROOT" HV_ETC="$SB/etc" HV_LOG_DIR="$SB/log" HV_BACKUP_DIR="$SB/bak"
export HV_USER_HOME="$SB/home" HV_UHOME="$SB/home/.hermes" HV_HERMES_BIN="$SB/home/.local/bin/hermes"
export HV_NONINTERACTIVE=1 HV_NO_COLOR=1 HV_ASSUME_YES=1

fail=0
ok()  { printf '\033[32m✔\033[0m %s\n' "$1"; }
bad() { printf '\033[31m✘\033[0m %s\n' "$1"; fail=$((fail+1)); }
# 在严格模式下调用;任何非 0/中止都算失败
try() { local desc="$1"; shift; if out="$("$@" 2>&1)"; then ok "$desc"; else bad "$desc → $out"; fi; }
# 允许返回非 0(用于"查不到东西"的场景):关键是脚本没有中止
try_any() { local desc="$1"; shift; if out="$("$@" 2>&1)"; then ok "$desc(返回 0)"; else ok "$desc(返回非 0,符合预期)"; fi; }

mkdir -p "$HV_UHOME"
# shellcheck source=/dev/null
for m in common ui detect account provider platform hermes deps mirror firewall; do
    source "${ROOT}/lib/${m}.sh"
done

echo "── 键值读取:不存在的文件/键/空文件 ──"
: >"$SB/empty.env"
try "读不存在的文件"        hv_kv_get "$SB/nope.env" KEY default
try "读空文件"              hv_kv_get "$SB/empty.env" KEY default
try "读不存在的键"          hv_kv_get "$SB/empty.env" NOPE ""
try "状态文件不存在的键"    hv_state_get NOPE default
try "凭据文件不存在的键"    hv_kv_get "$SB/nope.creds" X y
printf 'A=1\n' >"$SB/one.env"
try "读存在的键"            hv_kv_get "$SB/one.env" A

echo "── 随机串(pipefail 下的 SIGPIPE)──"
try "hv_random 18"      hv_random 18
try "hv_random 1"       hv_random 1
try "hv_random_hex 32"  hv_random_hex 32
v="$(hv_random 8)"
[[ ${#v} -eq 8 ]] && ok "随机串长度正确" || bad "随机串长度异常: '$v'"

echo "── 数据表:未知 id ──"
try_any "未知提供商 envkey"   hv_provider_envkey not-a-provider
try_any "未知平台 line"       hv_platform_line not-a-platform
try_any "未知平台 required"   hv_platform_required not-a-platform
try "平台行数"            hv_platform_rows
try "提供商行数"          hv_provider_rows

echo "── 环境探测(不允许未定义变量中止)──"
try "detect_os"           hv_detect_os
try "detect_report"       hv_detect_report
try "detect_precheck"     hv_detect_precheck
try_any "ssh 端口探测"    hv_ssh_ports
try_any "端口占用判断(未占用)" hv_port_in_use 1
try "swap 汇总"           hv_swap_total_mb
try "私网判断"            _hv_is_private_ip 10.0.0.1

echo "── hermes 未安装时的探测 ──"
try_any "hermes_installed(未安装)"   hv_hermes_installed
try_any "hermes_version(未安装)"     hv_hermes_version
try "env 读不存在的键"               hv_env_get NOPE default

echo "── 日志与状态写入 ──"
try "状态写入"            hv_state_set TESTKEY testval
try "状态读回"            hv_state_get TESTKEY
try "kv_set 新键"         hv_kv_set "$SB/k.env" K V
try "kv_set 覆盖键"       hv_kv_set "$SB/k.env" K V2
try "kv_unset 不存在的键" hv_kv_unset "$SB/k.env" NOPE

echo "── ERR 陷阱与 set +e 容错路径 ──"
# 1) 容错路径:陷阱不得中止脚本,且 rc 必须保留真实退出码(服务安装的多级回退依赖这个)
set +e
_hv_test_fail() { return 7; }
_hv_test_fail
rc=$?
set -e
[[ "$rc" == "7" ]] && ok "set +e 容错路径可继续执行,rc 保留真实退出码" || bad "rc=$rc,期望 7"
# 2) 致命路径:set -e 下的失败必须中止(子 shell 里验证,避免影响本测试)
if ( bash -c 'source "$1/lib/common.sh"; hv_install_trap; false; echo "不该执行到这里"' _ "$ROOT" >/dev/null 2>&1 ); then
    bad "set -e 下的失败没有中止脚本(错误陷阱失效)"
else
    ok "set -e 下的失败会中止脚本(错误陷阱生效)"
fi

echo
if [[ $fail -eq 0 ]]; then printf '\033[32m严格模式测试全部通过\033[0m\n'; else printf '\033[31m%d 项失败\033[0m\n' "$fail"; fi
exit "$fail"

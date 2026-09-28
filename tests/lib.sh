#!/usr/bin/env bash
# 测试公共工具:定位仓库、载入 lib、断言函数
# 用法: . "$(dirname "$0")/lib.sh"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$ROOT/lib"
DIST="$ROOT/dist/hermes-vps.sh"

PASS=0
FAIL=0
FAILED_NAMES=()

c_ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
c_bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); FAILED_NAMES+=("$*"); }
c_info() { printf '  \033[2m·\033[0m %s\n' "$*"; }
section() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# 载入全部 lib(与入口的开发模式一致)
# ⚠️ 必须在**顶层** source:若在函数里 source,`declare -A` 会变成函数局部变量,
#    导致 disp_len 的缓存数组退化成索引数组(真机踩过:arithmetic syntax error)。
for _hv_f in "$LIB_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$_hv_f"
done
unset _hv_f

# 测试期间不要继承生产代码的 ERR 陷阱(断言失败时它会打印误导性的回溯)
trap - ERR

assert_eq() { # assert_eq <期望> <实际> <说明>
    if [[ "$1" == "$2" ]]; then c_ok "$3"; else c_bad "$3(期望 [$1] 实际 [$2])"; fi
}
assert_contains() { # assert_contains <文本> <子串> <说明>
    if [[ "$1" == *"$2"* ]]; then c_ok "$3"; else c_bad "$3(未包含 [$2])"; fi
}
assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then c_ok "$3"; else c_bad "$3(不应包含 [$2])"; fi
}
assert_true() { # assert_true <命令…> <说明>
    local msg="${*: -1}"
    local -a cmd=("${@:1:$#-1}")
    if "${cmd[@]}" >/dev/null 2>&1; then c_ok "$msg"; else c_bad "$msg"; fi
}

summary() {
    printf '\n'
    if [[ $FAIL -eq 0 ]]; then
        printf '    \033[32m全部通过\033[0m(%d 项)\n\n' "$PASS"
        return 0
    fi
    printf '    \033[31m%d 项失败\033[0m,%d 项通过\n' "$FAIL" "$PASS"
    local n
    for n in "${FAILED_NAMES[@]}"; do printf '      - %s\n' "$n"; done
    printf '\n'
    return 1
}

need() { command -v "$1" >/dev/null 2>&1; }

# 挑一个"真能跑"的 python(Windows 上 python3 可能是应用商店的空壳,退出码 49)
pick_python() {
    local c
    for c in python3 python; do
        if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
            command -v "$c"
            return 0
        fi
    done
    return 1
}

# 生成一个隔离的临时目录(每个测试用)
tmpdir() { mktemp -d "${TMPDIR:-/tmp}/hv-test-XXXXXX"; }

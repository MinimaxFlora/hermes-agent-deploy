#!/usr/bin/env bash
# =============================================================================
# tests/lint.sh —— 静态检查:bash 语法 + (可选)shellcheck + 数据文件格式
# 用法: bash tests/lint.sh
# =============================================================================
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

pass() { printf '\033[32m✔\033[0m %s\n' "$1"; }
bad()  { printf '\033[31m✘\033[0m %s\n' "$1"; fail=$((fail+1)); }

# 1) 语法检查
for f in "$ROOT"/lib/*.sh "$ROOT"/bin/hermes-vps "$ROOT"/install.sh "$ROOT"/tests/*.sh; do
    [[ -e "$f" ]] || continue
    if bash -n "$f" 2>/tmp/hv-lint.err; then
        pass "语法 OK: ${f#"$ROOT"/}"
    else
        bad  "语法错误: ${f#"$ROOT"/}
$(sed 's/^/      /' /tmp/hv-lint.err)"
    fi
done

# 2) shellcheck(装了就跑)
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S warning -x "$ROOT"/lib/*.sh "$ROOT"/bin/hermes-vps "$ROOT"/install.sh; then
        pass "shellcheck 通过"
    else
        bad "shellcheck 有告警(见上)"
    fi
else
    printf '\033[33m!\033[0m 未安装 shellcheck,跳过(可选:apt install shellcheck)\n'
fi

# 3) 数据文件格式:每行必须 6/7 个字段
check_data() {
    local file="$1" want="$2" n=0 bad_line=""
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        n=$((n+1))
        local fields; fields="$(awk -F'|' '{print NF}' <<<"$line")"
        [[ "$fields" -eq "$want" ]] || bad_line+=" 字段数 ${fields}(期望 ${want}): ${line}"$'\n'
    done <"$file"
    if [[ -n "$bad_line" ]]; then bad "数据文件格式错误:$file"$'\n'"$bad_line"; else pass "数据文件 OK:$file($n 行)"; fi
}
check_data "$ROOT/data/providers.conf" 7
check_data "$ROOT/data/platforms.conf" 6

# 4) 每个 lib 都被 bin/hermes-vps 加载
for f in "$ROOT"/lib/*.sh; do
    m="$(basename "$f" .sh)"
    if grep -q "\b${m}\b" "$ROOT/bin/hermes-vps"; then
        pass "模块被入口加载: ${m}"
    else
        bad "模块未被入口加载: ${m}"
    fi
done

# 5) 禁止手改 config.yaml / 危险的批量删除
if grep -rnE '\brm -rf? +(/|/etc|/usr|/var|/opt)( |$)' "$ROOT"/lib "$ROOT"/bin | grep -v '拒绝删除' >/dev/null 2>&1; then
    bad "发现可能删除系统目录的 rm 语句"
else
    pass "未发现删除系统目录的语句"
fi

# 5) 管道 + pipefail 陷阱:命令替换里用 "| head" 会让上游收到 SIGPIPE 而整体失败
#    带 `|| 兜底` 的行不算(例如 out="$(... | head -c 32)" || out="")
if grep -rnE '\$\([^)]*\| *head( |$)' "$ROOT"/lib "$ROOT"/bin 2>/dev/null | grep -v '||' >/dev/null 2>&1; then
    bad "发现命令替换里未兜底的 '| head'(pipefail 下会被 SIGPIPE 判为失败),改用 sed -n '1p'"
    grep -rnE '\$\([^)]*\| *head( |$)' "$ROOT"/lib "$ROOT"/bin 2>/dev/null | grep -v '||' | sed 's/^/      /'
else
    pass "未发现命令替换里未兜底的 '| head' 隐患"
fi

echo
if [[ $fail -eq 0 ]]; then
    printf '\033[32m全部检查通过\033[0m\n'
else
    printf '\033[31m%d 项检查失败\033[0m\n' "$fail"
fi
exit "$fail"

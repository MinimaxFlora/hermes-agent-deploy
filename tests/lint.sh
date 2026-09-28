#!/usr/bin/env bash
# =============================================================================
#  lint.sh —— 静态检查(不需要真机,CI 第一道关)
#    · 所有 shell 文件语法
#    · 源码/数据表无 CRLF、以 LF 提交
#    · VERSION 语义化版本,且能被 build.sh 正确注入
#    · 危险删除、命令替换里未兜底的 | head、函数末尾返回非零
#    · 数据表字段数、lib 编号与文件命名
#    · 构建可复现(两次构建逐字节一致)
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "语法检查"
shopt -s nullglob
shell_files=("$ROOT"/lib/*.sh "$ROOT/bin/hermes-vps" "$ROOT/build.sh" "$ROOT/install.sh" "$ROOT"/tests/*.sh)
[[ -f "$ROOT/install.sh" ]] || shell_files=("$ROOT"/lib/*.sh "$ROOT/bin/hermes-vps" "$ROOT/build.sh" "$ROOT"/tests/*.sh)
for f in "${shell_files[@]}"; do
    if bash -n "$f" 2>/dev/null; then c_ok "bash -n ${f#"$ROOT"/}"; else c_bad "bash -n ${f#"$ROOT"/}"; bash -n "$f" || true; fi
done

section "行尾与编码"
crlf=0
for f in "$ROOT"/lib/*.sh "$ROOT/bin/hermes-vps" "$ROOT"/tests/*.sh "$ROOT/build.sh" "$ROOT/install.sh" "$ROOT/VERSION"; do
    [[ -f "$f" ]] || continue
    if grep -qU $'\r' "$f" 2>/dev/null; then c_bad "含 CRLF:${f#"$ROOT"/}"; crlf=1; fi
done
[[ $crlf -eq 0 ]] && c_ok "源码全部为 LF"

section "版本与构建"
if [[ -s "$ROOT/VERSION" ]]; then
    ver="$(tr -d '[:space:]' <"$ROOT/VERSION")"
    if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        c_ok "VERSION 语义化:$ver(Release 标签应为 v$ver)"
    else
        c_bad "VERSION 格式不是 x.y.z:$ver"
    fi
else
    c_bad "缺少 VERSION 文件"
fi
tmp1="$(tmpdir)/a.sh"; tmp2="$(tmpdir)/b.sh"
bash "$ROOT/build.sh" "$tmp1" >/dev/null
bash "$ROOT/build.sh" "$tmp2" >/dev/null
if cmp -s "$tmp1" "$tmp2"; then c_ok "构建可复现(两次构建一致)"; else c_bad "构建不可复现(两次结果不同)"; fi
if grep -q '__HV_VERSION__' "$tmp1"; then c_bad "构建产物里仍有版本占位符"; else c_ok "版本号已注入产物"; fi
if grep -q 'dev-source' "$tmp1"; then c_bad "产物里残留开发模式加载块"; else c_ok "产物已剥离开发模式代码"; fi
if bash -n "$tmp1" 2>/dev/null; then c_ok "产物语法通过"; else c_bad "产物语法错误"; fi
rm -rf "$(dirname "$tmp1")" "$(dirname "$tmp2")"

section "危险写法扫描"
rm_bad="$(grep -rnE 'rm -rf[[:space:]]+\$[A-Za-z_]*[[:space:]]*$' "$ROOT"/lib/*.sh 2>/dev/null || true)"
if [[ -z "$rm_bad" ]]; then c_ok "无未加引号的 rm -rf \$VAR"; else c_bad "发现未加引号的 rm -rf:"; printf '%s\n' "$rm_bad" | sed 's/^/      /'; fi

# 切用户执行必须在目标用户家目录里起:su 继承调用者 cwd,从 /root 跑会让服务用户的进程站在
# 无权限目录里 → 官方安装脚本内部的 find 报 "Failed to restore initial working directory: /root"
if grep -qF 'su -s /bin/bash "$user" -c "cd ' "$ROOT/lib/12-run.sh"; then
    c_ok "run_as_user_env 在目标用户家目录里执行"
else
    c_bad "run_as_user_env 未切到目标用户家目录(会继承 /root 等不可读 cwd)"
fi

head_bad="$(grep -rnE '\$\([^)]*\|[[:space:]]*head([[:space:]]|\))' "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh 2>/dev/null | grep -v '|| ' | grep -v '2>/dev/null' || true)"
if [[ -z "$head_bad" ]]; then c_ok "命令替换里的 | head 都已兜底"; else c_bad "命令替换里可能有未兜底的 | head:"; printf '%s\n' "$head_bad" | sed 's/^/      /'; fi

if py="$(pick_python)"; then
    # 注意:用 cd + 相对路径调用,Windows 上的原生 python 认不出 MSYS 风格绝对路径
    if (cd "$ROOT" && "$py" tests/check-tail.py lib/*.sh bin/hermes-vps) >"${TMPDIR:-/tmp}/hv-tail.out" 2>&1; then
        c_ok "函数末尾语句无返回非零风险"
        sed -n '2p' "${TMPDIR:-/tmp}/hv-tail.out" | sed 's/^/    /'
    else
        c_bad "函数末尾语句存在返回非零风险"
        sed 's/^/      /' "${TMPDIR:-/tmp}/hv-tail.out"
    fi
else
    c_info "未找到 python,跳过末尾语句扫描"
fi

section "源码结构"
lib_count=0
bad_name=0
for f in "$ROOT"/lib/*.sh; do
    lib_count=$((lib_count + 1))
    base="$(basename "$f")"
    [[ "$base" =~ ^[0-9]{2}-[a-z0-9-]+\.sh$ ]] || { c_bad "lib 命名不符合 NN-name.sh:$base"; bad_name=1; }
done
[[ $bad_name -eq 0 ]] && c_ok "lib 命名规范($lib_count 个,编号即加载顺序)"
if [[ -x "$ROOT/bin/hermes-vps" ]]; then c_ok "入口可执行(bin/hermes-vps)"; else c_info "bin/hermes-vps 无执行位(用 bash 调用亦可)"; fi
if grep -q '^main "\$@"' "$ROOT/bin/hermes-vps"; then c_ok "入口以 main \"\$@\" 结束"; else c_bad "入口缺少 main 调用"; fi

section "数据表"
prov_n="$(bash -c ". '$ROOT/lib/31-model.sh' 2>/dev/null; for l in \"\${PROVIDERS[@]}\"; do echo \"\$l\"; done | awk -F'|' 'NF!=6' | wc -l")"
assert_eq "0" "$prov_n" "模型提供商表字段数(应为 6)"
plat_n="$(bash -c ". '$ROOT/lib/40-platform.sh' 2>/dev/null; for l in \"\${PLATFORMS[@]}\"; do echo \"\$l\"; done | awk -F'|' 'NF!=6' | wc -l")"
assert_eq "0" "$plat_n" "消息平台表字段数(应为 6)"

summary

#!/usr/bin/env bash
# =============================================================================
#  build.sh —— 把模块化源码拼装成发布用的单文件
#
#    lib/*.sh        按职责分块(文件名编号 = 加载顺序)
#    bin/hermes-vps  入口(开发时直接运行,会自动载入 lib/)
#          ↓
#    dist/hermes-vps.sh   自包含单文件(Actions 会把它上传到 Release)
#
#  用法:
#    bash build.sh                 构建到 dist/hermes-vps.sh
#    bash build.sh /tmp/out.sh     指定输出路径
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$ROOT/dist/hermes-vps.sh}"
VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
[[ -n "$VERSION" ]] || { echo "VERSION 文件为空" >&2; exit 1; }

[[ -f "$ROOT/bin/hermes-vps" ]] || { echo "缺少 bin/hermes-vps" >&2; exit 1; }
libs=("$ROOT"/lib/*.sh)
[[ -f "${libs[0]}" ]] || { echo "缺少 lib/*.sh" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
TMP="$(mktemp)"

{
    printf '#!/usr/bin/env bash\n'
    printf '# %s\n' "由 build.sh 自动生成,请勿直接编辑;源码见 lib/ 与 bin/hermes-vps · v${VERSION}"
    for f in "${libs[@]}"; do
        cat "$f"
        printf '\n'
    done
    cat "$ROOT/bin/hermes-vps"
} >"$TMP"

# 统一 LF(Windows 上编辑过也不会带 CR)并注入版本号
sed -i -e 's/\r$//' -e "s/__HV_VERSION__/${VERSION}/g" "$TMP"
# 删掉入口里的"开发模式加载 lib"块:构建产物是自包含的,留着反而会在仓库内误加载源码
sed -i '/^# >>> dev-source/,/^# <<< dev-source/d' "$TMP"
cp "$TMP" "$OUT"
rm -f "$TMP"
chmod +x "$OUT"

# 构建产物必须能通过语法检查
bash -n "$OUT" || { echo "构建产物语法错误" >&2; exit 1; }

lines="$(wc -l <"$OUT")"
sum="$(sha256sum "$OUT" 2>/dev/null | cut -c1-16 || shasum -a 256 "$OUT" | cut -c1-16)"
echo "已生成 $OUT"
echo "  版本   : v$VERSION"
echo "  模块   : ${#libs[@]} 个 lib + 入口"
echo "  行数   : $lines"
echo "  sha256 : ${sum}…"
echo "  自检   : bash $OUT selftest"

#!/usr/bin/env bash
# =============================================================================
# tests/caddyfile-validate.sh —— 用真实 caddy 校验生成的 Caddyfile 语法
#
# 用法:
#   bash tests/caddyfile-validate.sh /usr/bin/caddy
#   CADDY=/usr/local/bin/caddy bash tests/caddyfile-validate.sh
# 没给二进制时会尝试 PATH 上的 caddy;找不到就跳过(退出码 0)。
# =============================================================================
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY_BIN="${1:-${CADDY:-}}"
[[ -z "$CADDY_BIN" ]] && CADDY_BIN="$(command -v caddy || true)"
if [[ -z "$CADDY_BIN" || ! -x "$CADDY_BIN" ]]; then
    echo "跳过:未找到 caddy 二进制(用法: bash tests/caddyfile-validate.sh /path/to/caddy)"
    exit 0
fi

SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export TMPDIR="$SANDBOX"
export HV_SELF_DIR="$ROOT" HV_ETC="$SANDBOX/etc" HV_LOG_DIR="$SANDBOX/log" HV_BACKUP_DIR="$SANDBOX/bak"
export HV_NONINTERACTIVE=1 HV_NO_COLOR=1
# shellcheck source=/dev/null
for m in common ui account caddy; do source "${ROOT}/lib/${m}.sh"; done

fail=0
for with_api in 1 0; do
    for ca in "" "https://acme-staging-v02.api.letsencrypt.org/directory"; do
        f="$(hv_caddy_render "hermes.example.com" "me@example.com" "$with_api" "$ca")"
        if out="$("$CADDY_BIN" validate --config "$f" --adapter caddyfile 2>&1)"; then
            printf '\033[32m✔\033[0m caddy validate 通过 (API=%s, 自定义ACME=%s)\n' "$with_api" "$([[ -n $ca ]] && echo yes || echo no)"
        else
            printf '\033[31m✘\033[0m caddy validate 失败 (API=%s, 自定义ACME=%s)\n%s\n' "$with_api" "$([[ -n $ca ]] && echo yes || echo no)" "$(sed 's/^/    /' <<<"$out")"
            fail=$((fail+1))
        fi
        echo "    --- 生成的 Caddyfile(${with_api}) ---"
        sed 's/^/    /' "$f"
        rm -f "$f"
    done
done

[[ $fail -eq 0 ]] && printf '\033[32mCaddyfile 语法全部通过\033[0m\n' || printf '\033[31m%d 份配置未通过\033[0m\n' "$fail"
exit "$fail"

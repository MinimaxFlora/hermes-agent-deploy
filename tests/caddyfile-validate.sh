#!/usr/bin/env bash
# =============================================================================
# tests/caddyfile-validate.sh —— 用真实 caddy 校验"生产过程"写出的 Caddyfile
#
# 重要:这里调用的是生产函数 hv_caddy_write_config(渲染 → fmt → 校验 → 备份 → 写入),
# 不是另写一条并行路径 —— 否则测试通过而线上失败(曾被真机抓到:生产代码漏了
# --adapter caddyfile,而测试脚本自己加了这个参数)。
#
# 用法:
#   bash tests/caddyfile-validate.sh /usr/bin/caddy
#   CADDY=/usr/local/bin/caddy bash tests/caddyfile-validate.sh
# 找不到 caddy 二进制时跳过(退出码 0)。
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
export HV_CADDYFILE="$SANDBOX/caddy/Caddyfile" HV_CADDY_ETC="$SANDBOX/caddy" HV_CADDY_LOG_DIR="$SANDBOX/caddy/logs"
mkdir -p "$SANDBOX/caddy" "$SANDBOX/bin"
# 让 hv_caddy_cmd 找到被测二进制(PATH 优先)
ln -sf "$CADDY_BIN" "$SANDBOX/bin/caddy"
export PATH="$SANDBOX/bin:$PATH"

# shellcheck source=/dev/null
for m in common ui account caddy; do source "${ROOT}/lib/${m}.sh"; done
hv_require_root() { :; }   # 测试只写沙箱目录

fail=0
for with_api in 1 0; do
    for ca in "" "https://acme-staging-v02.api.letsencrypt.org/directory"; do
        desc="API=$with_api ACME=$([[ -n $ca ]] && echo 自定义 || echo 默认)"
        if hv_caddy_write_config "hermes.example.com" "me@example.com" "$with_api" "$ca" >"$SANDBOX/out" 2>&1; then
            # 再用显式 adapter 独立校验一次写盘结果
            if "$CADDY_BIN" validate --config "$HV_CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
                printf '\033[32m✔\033[0m 写入并通过 caddy validate(%s)\n' "$desc"
            else
                printf '\033[31m✘\033[0m 写盘结果无法通过 caddy validate(%s)\n' "$desc"; fail=$((fail+1))
            fi
        else
            printf '\033[31m✘\033[0m hv_caddy_write_config 失败(%s)\n' "$desc"
            sed 's/^/    /' "$SANDBOX/out"; fail=$((fail+1))
        fi
        # 关键内容断言
        grep -q "managed-by: hermes-vps" "$HV_CADDYFILE" || { printf '\033[31m✘\033[0m 缺少 managed-by 标记\n'; fail=$((fail+1)); }
        grep -q "hermes.example.com {" "$HV_CADDYFILE" || { printf '\033[31m✘\033[0m 缺少站点块\n'; fail=$((fail+1)); }
        if [[ "$with_api" == "1" ]]; then
            grep -q "handle /v1/\*" "$HV_CADDYFILE" || { printf '\033[31m✘\033[0m 缺少 /v1 路由\n'; fail=$((fail+1)); }
        else
            grep -q "handle /v1/\*" "$HV_CADDYFILE" && { printf '\033[31m✘\033[0m 关闭 API 时仍写入 /v1 路由\n'; fail=$((fail+1)); }
        fi
    done
done

# 校验失败必须拒绝写入
before="$(md5sum "$HV_CADDYFILE" | awk '{print $1}')"
rm -f "$SANDBOX/bin/caddy"   # 先摘掉指向真实 caddy 的软链,否则写同名文件会 "Text file busy"
cat >"$SANDBOX/bin/caddy" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
    fmt) exit 0 ;;
    validate) echo "Error: unrecognized directive: bogus" >&2; exit 1 ;;
    *) exit 0 ;;
esac
EOS
chmod +x "$SANDBOX/bin/caddy"
if hv_caddy_write_config "bad.example.com" "me@example.com" 1 "" >/dev/null 2>&1; then
    printf '\033[31m✘\033[0m 校验失败时仍然写入配置(危险)\n'; fail=$((fail+1))
else
    after="$(md5sum "$HV_CADDYFILE" | awk '{print $1}')"
    if [[ "$before" == "$after" ]]; then
        printf '\033[32m✔\033[0m 校验失败时拒绝写入,原配置未被改动\n'
    else
        printf '\033[31m✘\033[0m 校验失败但仍改动了配置文件\n'; fail=$((fail+1))
    fi
fi

[[ $fail -eq 0 ]] && printf '\033[32mCaddyfile 生产写入路径全部通过\033[0m\n' || printf '\033[31m%d 项失败\033[0m\n' "$fail"
exit "$fail"

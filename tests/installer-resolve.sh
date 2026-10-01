#!/usr/bin/env bash
# =============================================================================
#  installer-resolve.sh —— install.sh「取最新版本」的离线回归(不联网)
#
#  真机事故(Debian 13 新机,`curl …/install.sh | bash`):
#      ✘ 无法获取最新版本(检查网络,或用 --version vX.Y.Z 指定)
#  根因不是网络:旧解析写法 `grep -m1 '"tag_name"' | sed …` 命中第一行就退出,
#  上游 curl 还在往管道里写 → EPIPE(curl 退出码 23);脚本开着 `set -o pipefail`,
#  整条管道被判失败,调用方的 `|| tag=""` 又把**已经解析出来的 tag** 清空。
#  响应刚好一次塞进管道缓冲区(约 64K)时侥幸通过 → 表现为偶发:同一台机器
#  同一条命令,前一次成功、后一次失败(真机上就是这么复现的)。
#
#  测试用假 curl 精确复刻这个退出码(写完响应体后 exit 23),因此不依赖平台信号
#  语义、可离线跑,CI 与 Windows 开发机都能拦:
#    A) 旧写法必须复现失败 —— 证明测试确实有牙
#    B) api.github.com 被墙/限流,github.com 通  → 必须拿到版本(新的免 API 路径)
#    C) github.com 302 不通,api.github.com 通    → 必须拿到版本(EPIPE 回归点)
#    D) 两个来源都不通                          → 必须报错并提示 --version
#    E) 显式 --version 不打网络
# =============================================================================
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/install.sh"
TMP="$(tmpdir)"
trap 'rm -rf "$TMP"' EXIT

section "假 curl + 大响应体"

FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
# 假 curl:按 URL 分派;api 的三种状态对应真机上观察到的三种结果
#   up    → 正常返回响应体
#   epipe → 响应体照写,但像真 curl 那样以 23 退出(write error)
#   其他   → 22(HTTP 403,被限流/被墙)
cat >"$FAKE/curl" <<'FAKE_EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *api.github.com*)
        case "${HV_FAKE_API:-up}" in
            up) exec cat "$HV_FAKE_BODY" ;;
            epipe)
                cat "$HV_FAKE_BODY"
                printf 'curl: (23) client returned ERROR on write of 12413 bytes\n' >&2
                exit 23
                ;;
            *)
                printf 'curl: (22) The requested URL returned error: 403\n' >&2
                exit 22
                ;;
        esac
        ;;
    *github.com/*)
        [[ "${HV_FAKE_GH:-up}" == up ]] || { printf 'curl: (28) Connection timed out\n' >&2; exit 28; }
        printf '%s' "${HV_FAKE_TAG_URL:-https://github.com/x/y/releases/tag/v9.9.9}"
        ;;
    *)
        printf 'fake-curl: 没预料到的调用:%s\n' "$args" >&2
        exit 2
        ;;
esac
FAKE_EOF
chmod +x "$FAKE/curl"

BODY="$TMP/latest.json"
{
    printf '{\n  "tag_name": "v9.9.9",\n  "assets": [\n'
    i=0
    while ((i < 4000)); do
        printf '    { "name": "filler-%05d", "size": 1048576 },\n' "$i"
        i=$((i + 1))
    done
    printf '  ]\n}\n'
} >"$BODY"
export HV_FAKE_BODY="$BODY"
c_info "API 响应体 $(wc -c <"$BODY") 字节(> 管道缓冲区 64K,与真机同规模)"

# 在干净的子 bash 里只加载 install.sh 的函数(HV_INSTALL_LIB=1 → 不执行 main),
# 这样 install.sh 里的 info/ok/die 不会盖掉 lib.sh 的同名函数。
run_in_installer() { # run_in_installer <表达式>
    PATH="$FAKE:$PATH" HV_INSTALL_LIB=1 EXPR="$1" bash -c 'f="$1"; set --; . "$f" >/dev/null 2>&1; eval "$EXPR"' _ "$INSTALLER"
}

# 旧写法(真机 bug 的最小复现):解析后调用方 `|| tag=""` 把值清空
# 这里调的就是假 curl:它写完响应体后像真 curl 一样以 23 退出 → pipefail 判失败
FAKE_API_LATEST="https://api.github.com/repos/MinimaxFlora/hermes-agent-deploy/releases/latest"
old_resolve() {
    local tag=""
    tag="$(PATH="$FAKE:$PATH" curl -fsSL --max-time 20 "$FAKE_API_LATEST" 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')" || tag=""
    printf '%s' "$tag"
}

section "A) 旧写法必须复现失败(测试有效性)"
assert_eq "" "$(HV_FAKE_API=epipe old_resolve)" "上游以 23 退出时,旧写法把已解析的 tag 清空"

section "B) api.github.com 不可用(403),github.com 通"
out="$(HV_FAKE_API=down run_in_installer 'resolve_version' | tail -n1 || true)"
assert_eq "v9.9.9" "$out" "无需 api.github.com 即可取到最新版本(302 跳转)"

section "C) github.com 302 不可用,api.github.com 通但以 23 退出"
out="$(HV_FAKE_GH=down HV_FAKE_API=epipe run_in_installer 'resolve_version' | tail -n1 || true)"
assert_eq "v9.9.9" "$out" "回落到 API 且不再被 EPIPE/pipefail 清空"

section "D) 两个来源都不通"
err="$(HV_FAKE_GH=down HV_FAKE_API=down run_in_installer 'resolve_version' 2>&1 >/dev/null || true)"
assert_contains "$err" "--version" "报错并提示可用 --version 指定版本"
assert_contains "$err" "无法获取最新版本" "报错文案保持可读"

section "E) 显式 --version 不打网络"
out="$(HV_FAKE_GH=down HV_FAKE_API=down run_in_installer 'WANT_VERSION=v1.2.3; resolve_version' | tail -n1 || true)"
assert_eq "v1.2.3" "$out" "--version 优先,完全不依赖网络"

summary

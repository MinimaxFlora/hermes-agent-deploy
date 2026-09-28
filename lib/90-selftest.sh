# ---------------------------------------------------------------------------
# 自检脚本自身
# ---------------------------------------------------------------------------
selftest() {
    local fails=0
    printf '\n  hermes-vps 自检 v%s\n' "$V"
    rule
    local f; f="$SELF"
    if bash -n "$f" 2>/dev/null; then printf '    %s 语法检查通过\n' "$OK_SYM"; else printf '    %s 语法检查失败\n' "$NO_SYM"; bash -n "$f"; fails=$((fails+1)); fi
    printf '    %s 文件:%s\n' "$(printf '%s·%s' "$DM" "$N")" "$f"
    printf '    %s 行数:%s\n' "$(printf '%s·%s' "$DM" "$N")" "$(wc -l <"$f")"

    local n=0 l
    for l in "${PROVIDERS[@]}"; do n=$((n+1)); [[ "$(awk -F'|' '{print NF}' <<<"$l")" -eq 6 ]] || { printf '    %s 提供商表字段数异常:%s\n' "$NO_SYM" "$l"; fails=$((fails+1)); }; done
    printf '    %s 提供商数据表:%s 条\n' "$OK_SYM" "$n"
    n=0
    for l in "${PLATFORMS[@]}"; do n=$((n+1)); [[ "$(awk -F'|' '{print NF}' <<<"$l")" -eq 6 ]] || { printf '    %s 平台表字段数异常:%s\n' "$NO_SYM" "$l"; fails=$((fails+1)); }; done
    printf '    %s 平台数据表:%s 个\n' "$OK_SYM" "$n"

    local tmpd; tmpd="$(mktemp -d)"
    kv_set "$tmpd/x.env" FOO "bar baz"
    [[ "$(kv_get "$tmpd/x.env" FOO)" == "bar baz" ]] && printf '    %s 键值存储读写正常\n' "$OK_SYM" || { printf '    %s 键值存储异常\n' "$NO_SYM"; fails=$((fails+1)); }
    kv_set "$tmpd/x.env" FOO "qux"
    [[ "$(kv_get "$tmpd/x.env" FOO)" == "qux" ]] && printf '    %s 键值覆盖更新正常\n' "$OK_SYM" || { printf '    %s 键值覆盖异常\n' "$NO_SYM"; fails=$((fails+1)); }
    rm -rf "$tmpd"

    local cf; cf="$(caddy_render "example.com" "a@b.c" 1)"
    if printf '%s' "$cf" | grep -q 'reverse_proxy 127.0.0.1:9119'; then printf '    %s Caddyfile 渲染(含 API):面板路由正常\n' "$OK_SYM"; else printf '    %s Caddyfile 渲染异常\n' "$NO_SYM"; fails=$((fails+1)); fi
    cf="$(caddy_render "example.com" "" 0)"
    if printf '%s' "$cf" | grep -q '/v1/' ; then printf '    %s Caddyfile 关闭 API 时仍有 /v1 路由\n' "$NO_SYM"; fails=$((fails+1)); else printf '    %s Caddyfile 渲染(无 API):符合预期\n' "$OK_SYM"; fi
    if caddy_installed; then
        if caddy_validate "$(caddy_render "example.com" "a@b.c" 1)"; then printf '    %s 真实 caddy validate 通过\n' "$OK_SYM"; else printf '    %s caddy validate 失败\n' "$NO_SYM"; fails=$((fails+1)); fi
    else
        printf '    %s 未安装 caddy,跳过真机校验\n' "$(printf '%s·%s' "$DM" "$N")"
    fi
    rule
    if [[ $fails -eq 0 ]]; then printf '    %s全部通过%s\n\n' "$G" "$N"; else printf '    %s%d 项失败%s\n\n' "$R" "$fails" "$N"; return 1; fi
}

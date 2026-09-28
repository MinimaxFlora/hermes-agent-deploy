# ---------------------------------------------------------------------------
# 键值存储(.env / 状态 / 凭据)
# ---------------------------------------------------------------------------
kv_set() {
    local file="$1" key="$2" val="$3"
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || : >"$file"
    chmod 600 "$file" 2>/dev/null || true
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null; then
        local tmp; tmp="$(mktemp)"; sed -E "s|^[[:space:]]*(export[[:space:]]+)?${key}=.*|${key}=${val}|" "$file" >"$tmp"
        cat "$tmp" >"$file"; rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$val" >>"$file"
    fi
}
kv_get() {
    local file="$1" key="$2" def="${3:-}" v="" line=""
    if [[ -f "$file" ]]; then
        line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1)" || line=""
        if [[ -n "$line" ]]; then
            v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        fi
    fi
    if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$def"; fi
    return 0
}
kv_del() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp; tmp="$(mktemp)"; grep -vE "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" >"$tmp" || true
    cat "$tmp" >"$file"; rm -f "$tmp"
}
state_init() { # 建目录失败不再致命(非 root/只读系统下也应能给出清晰后续错误,而不是在此处崩)
    mkdir -p "$ETC_DIR" "$TOOL_LOG_DIR" "$BACKUP_DIR" 2>/dev/null || true
    if [[ ! -f "$STATE_FILE" ]]; then : >"$STATE_FILE" 2>/dev/null || true; fi
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    return 0
}
st_set() { state_init; kv_set "$STATE_FILE" "$1" "$2"; }
st_get() { kv_get "$STATE_FILE" "$1" "${2:-}"; }
# API 开关:兼容旧版 state 里的 API_SERVER=on
st_api_enabled() {
    local v; v="$(st_get API_ENABLED)"
    if [[ -z "$v" ]]; then
        local o; o="$(st_get API_SERVER)"
        case "$o" in on|1|true|yes) v=1 ;; *) v=0 ;; esac
    fi
    printf '%s' "$v"
    return 0
}
cred_set() { mkdir -p "$ETC_DIR"; kv_set "$CRED_FILE" "$1" "$2"; chmod 600 "$CRED_FILE"; }
cred_get() { kv_get "$CRED_FILE" "$1" "${2:-}"; }

env_file() { printf '%s/.env' "$UHOME"; }
env_set() { kv_set "$(env_file)" "$1" "$2"; chown "$HUSER:$HUSER" "$(env_file)" 2>/dev/null || true; chmod 600 "$(env_file)"; }
env_get() { kv_get "$(env_file)" "$1" "${2:-}"; }
env_del() { kv_del "$(env_file)" "$1"; }

# 改动前备份文件(保留 5 份)
backup_file() {
    local f="$1"; [[ -f "$f" ]] || return 0
    local d="${f%/*}/.bak"; mkdir -p "$d"
    cp -p "$f" "$d/$(basename "$f").$(date +%Y%m%d%H%M%S)"
    ls -1t "$d" 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$d/$old"; done
}

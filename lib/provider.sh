#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/provider.sh
# 模型提供商配置 —— 完全由 data/providers.conf 驱动。
# 约定:
#   * 密钥只写 $HERMES_HOME/.env(hv_env_set);
#   * 其余设置一律 `hermes config set`,不手改 YAML;
#   * 写完后读回校验,失败立即报错而不是留着半套配置。
# =============================================================================

[[ -n "${HV_PROVIDER_LOADED:-}" ]] && return 0
HV_PROVIDER_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"

hv_provider_conf() { printf '%s/data/providers.conf' "$HV_SELF_DIR"; }

# 输出: id|名称|env_key|示例模型|base_url|api_mode|说明(跳过注释/空行)
hv_provider_rows() {
    local f; f="$(hv_provider_conf)"
    [[ -f "$f" ]] || hv_die "缺少数据文件:$f"
    grep -vE '^[[:space:]]*(#|$)' "$f"
}

hv_provider_field() {
    local id="$1" idx="$2" line
    line="$(hv_provider_rows | awk -F'|' -v id="$id" '$1==id{print; exit}')"
    [[ -n "$line" ]] || return 1
    awk -F'|' -v i="$idx" '{print $i}' <<<"$line"
}

hv_provider_name()  { hv_provider_field "$1" 2; }
hv_provider_envkey(){ hv_provider_field "$1" 3; }
hv_provider_model(){ hv_provider_field "$1" 4; }
hv_provider_baseurl(){ hv_provider_field "$1" 5; }
hv_provider_apimode(){ hv_provider_field "$1" 6; }

hv_provider_list() {
    local id name key model
    hv_rule
    printf '  %-20s %-26s %s\n' "ID" "名称" "示例模型"
    hv_rule
    while IFS='|' read -r id name key model _rest; do
        printf '  %-20s %-26s %s\n' "$id" "$name" "${model:--}"
    done < <(hv_provider_rows)
    hv_rule
}

# 选择提供商(菜单)
hv_provider_pick() {
    local __var="$1" args=() id name key model
    while IFS='|' read -r id name key model _rest; do
        [[ "$id" == "__custom__" ]] && continue
        args+=("$id" "$name")
    done < <(hv_provider_rows)
    args+=(__custom__ "自定义 OpenAI 兼容端点")
    hv_menu "$__var" "模型提供商" "选择要配置的模型提供商:" "${args[@]}"
}

# 应用配置: hv_provider_apply <id> <api_key> <model> [base_url] [api_mode]
hv_provider_apply() {
    local id="$1" key="$2" model="$3" base_url="${4:-}" api_mode="${5:-}"
    hv_hermes_installed || hv_die "请先安装 Hermes"
    hv_hermes_ensure_config 2>/dev/null || true

    if [[ "$id" == "__custom__" ]]; then
        id="custom"
    fi

    # 1) 密钥 -> .env
    local envkey; envkey="$(hv_provider_envkey "$id" 2>/dev/null || true)"
    if [[ -n "$key" && -n "$envkey" ]]; then
        hv_env_set "$envkey" "$key"
        hv_ok "密钥已写入 $(hv_user_env_file) → ${envkey}"
    fi

    # 2) 其余 -> config.yaml(一律走 hermes config set)
    hv_hermes_config_set model.provider "$id" || hv_die "写入 model.provider 失败"

    if [[ "$id" == "custom" ]]; then
        [[ -n "$base_url" ]] || hv_die "自定义端点必须提供 base_url"
        hv_hermes_config_set model.base_url "$base_url"
        [[ -n "$api_mode" ]] && hv_hermes_config_set model.api_mode "$api_mode"
        if [[ -n "$envkey" ]]; then
            hv_hermes_config_set model.key_env "$envkey"
        fi
    else
        [[ -n "$base_url" ]] && hv_hermes_config_set model.base_url "$base_url" || true
    fi

    if [[ -n "$model" ]]; then
        hv_hermes_config_set model.default "$model" || hv_die "写入 model.default 失败"
    else
        hv_warn "未指定模型,稍后可执行 'hermes-vps model set' 或 hermes model 选择"
    fi

    hv_state_set MODEL_PROVIDER "$id"
    [[ -n "$model" ]] && hv_state_set MODEL_NAME "$model"

    # 3) 读回校验
    local got
    got="$(hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" config get model.provider 2>/dev/null | tr -d '\r' | tail -n1)"
    if [[ "$got" == *"$id"* ]]; then
        hv_ok "当前模型提供商:$id$([[ -n $model ]] && echo " / 模型:$model")"
    else
        hv_warn "读回校验异常(model.provider 返回 '${got}',期望包含 '$id')"
    fi
}

# 交互式配置单个提供商
hv_provider_configure() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        hv_provider_pick id || return 0
        [[ -n "$id" ]] || return 0
    fi

    local name envkey demo base_url api_mode
    name="$(hv_provider_name "$id" || echo "$id")"
    envkey="$(hv_provider_envkey "$id" 2>/dev/null || echo "")"
    demo="$(hv_provider_model "$id" 2>/dev/null || echo "")"
    base_url="$(hv_provider_baseurl "$id" 2>/dev/null || echo "")"
    api_mode="$(hv_provider_apimode "$id" 2>/dev/null || echo "")"

    local key="" model=""
    if [[ "$id" == "__custom__" ]]; then
        hv_ask base_url "API Base URL(例: http://1.2.3.4:8000/v1)" ""
        [[ -z "$base_url" ]] && hv_die "base_url 不能为空"
        hv_ask model "模型名(端点上的模型 ID)" ""
        hv_ask_secret key "API Key(本地端点可留空)"
        hv_provider_apply "__custom__" "$key" "$model" "$base_url" "${api_mode:-chat_completions}"
        return 0
    fi

    if [[ -n "$envkey" ]]; then
        hv_ask_secret key "${name} 的 API Key(${envkey})"
        if [[ -z "$key" ]]; then
            hv_warn "未输入密钥,仅写入 provider 配置(密钥可稍后补)"
        fi
    fi
    hv_ask model "模型名${demo:+ (默认 ${demo})}" "$demo"

    hv_provider_apply "$id" "$key" "$model" "$base_url" "$api_mode"
}

hv_provider_show() {
    hv_hermes_installed || { hv_info "Hermes 未安装"; return 0; }
    local p m b
    p="$(hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" config get model.provider 2>/dev/null | tr -d '\r' | tail -n1)"
    m="$(hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" config get model.default 2>/dev/null | tr -d '\r' | tail -n1)"
    b="$(hv_run_as_user_env "$HV_USER" "HERMES_HOME=$HV_UHOME" -- "$HV_HERMES_BIN" config get model.base_url 2>/dev/null | tr -d '\r' | tail -n1)"
    hv_rule
    printf '  提供商 : %s\n  模型   : %s\n  端点   : %s\n' "${p:--}" "${m:--}" "${b:--}"
    hv_rule
}

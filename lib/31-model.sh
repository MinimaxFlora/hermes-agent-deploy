# ---------------------------------------------------------------------------
# 模型提供商表:id|名称|密钥变量|示例模型|base_url(为空=不直连验证)|备注
# ---------------------------------------------------------------------------
PROVIDERS=(
"deepseek|DeepSeek 官方|DEEPSEEK_API_KEY|deepseek-chat|https://api.deepseek.com/v1|国内直连,便宜"
"openrouter|OpenRouter 聚合|OPENROUTER_API_KEY|anthropic/claude-sonnet-4.6|https://openrouter.ai/api/v1|一个 key 多模型"
"zai|智谱 GLM (z.ai)|GLM_API_KEY|glm-5|https://open.bigmodel.cn/api/paas/v4|国产"
"kimi-coding-cn|Kimi 月之暗面(国内)|KIMI_CN_API_KEY|kimi-k2.5|https://api.moonshot.cn/v1|国产"
"alibaba|阿里云百炼 DashScope|DASHSCOPE_API_KEY|qwen3.5-plus|https://dashscope.aliyuncs.com/compatible-mode/v1|Qwen 系列"
"minimax-cn|MiniMax(中国端点)|MINIMAX_CN_API_KEY|MiniMax-M2.7||国产"
"openai-api|OpenAI 官方|OPENAI_API_KEY|gpt-5.4|https://api.openai.com/v1|需海外网络"
"anthropic|Anthropic 官方|ANTHROPIC_API_KEY|claude-sonnet-4-6||Claude 系列"
"gemini|Google Gemini|GEMINI_API_KEY|||API Key 方式"
"xai|xAI Grok|XAI_API_KEY|grok-4-fast-reasoning|https://api.x.ai/v1|Responses API"
"deepinfra|DeepInfra|DEEPINFRA_API_KEY||https://api.deepinfra.com/v1/openai|按目录发现"
"novita|NovitaAI|NOVITA_API_KEY|moonshotai/kimi-k2.5|https://api.novita.ai/openai/v1|200+ 模型"
"fireworks|Fireworks AI|FIREWORKS_API_KEY|accounts/fireworks/models/kimi-k2p6|https://api.fireworks.ai/inference/v1|slash 形式模型 ID"
"nvidia|NVIDIA Build|NVIDIA_API_KEY||https://integrate.api.nvidia.com/v1|NIM 托管"
"huggingface|Hugging Face|HF_TOKEN|Qwen/Qwen3.5-397B-A17B|https://router.huggingface.co/v1|开源模型路由"
"xiaomi|小米 MiMo|XIAOMI_API_KEY|mimo-v2-pro||国产"
"tencent-tokenhub|腾讯 TokenHub|TOKENHUB_API_KEY|hy4-preview||国产"
"stepfun|阶跃星辰 StepFun|STEPFUN_API_KEY|||国产"
"__custom__|自定义 OpenAI 兼容端点|CUSTOM_API_KEY|||vLLM / Ollama / One-API / 自建中转"
)

prov_line() { local id="$1" l; for l in "${PROVIDERS[@]}"; do [[ "${l%%|*}" == "$id" ]] && { printf '%s' "$l"; return 0; }; done; return 1; }
prov_field() { local l; l="$(prov_line "$1")" || return 1; awk -F'|' -v i="$2" '{print $i}' <<<"$l"; }
prov_name()   { prov_field "$1" 2; }
prov_env()    { prov_field "$1" 3; }
prov_model()  { prov_field "$1" 4; }
prov_base()   { prov_field "$1" 5; }
prov_note()   { prov_field "$1" 6; }

model_current() { # 输出 "provider|model"
    hermes_installed || return 1
    local p m
    p="$(hcfg_get model.provider)"; m="$(hcfg_get model.default)"
    printf '%s|%s' "${p:--}" "${m:--}"
    return 0
}

model_menu() {
    while :; do
        clear_screen
        header "模型提供商"
        local cur; cur="$(model_current 2>/dev/null || echo "-|-")"
        printf '    当前:%s%s / %s%s\n\n' "$BD" "${cur%%|*}" "${cur##*|}" "$N"
        local i=0 l id nm md note mark
        for l in "${PROVIDERS[@]}"; do
            i=$((i+1)); id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"; md="$(awk -F'|' '{print $4}' <<<"$l")"; note="$(awk -F'|' '{print $6}' <<<"$l")"
            mark="  "; [[ "${cur%%|*}" == "$id" ]] && mark="${G}●${N} "
            printf '    %s%2d)%s %-26s %s%s%s\n' "$mark" "$i" "$N" "$nm" "$DM" "${md:-—}  ${note}" "$N"
        done
        rule
        printf '    编号 = 配置并验证;  %sv<编号>%s = 只验证当前连接;  %stest%s = 用当前模型发一句话;  0) 返回\n' "$C" "$N" "$C" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            0|"") return 0 ;;
            v*) model_verify_menu "${ch#v}" ;;
            test) model_chat_test ;;
            *) if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#PROVIDERS[@]} )); then
                   local line="${PROVIDERS[$((ch-1))]}"; model_configure "${line%%|*}"
               else warn "无效选择:$ch"; pause; fi ;;
        esac
    done
}

model_configure() {
    local id="${1:-}"
    [[ -n "$id" ]] || { local ch=""; menu_choice ch "输入提供商编号或 id"; id="$ch"; }
    if ! prov_line "$id" >/dev/null 2>&1; then err "未知提供商 id:$id"; return 1; fi
    local nm key demo base envv
    nm="$(prov_name "$id" 2>/dev/null || echo "$id")" || true
    envv="$(prov_env "$id" 2>/dev/null || true)"
    demo="$(prov_model "$id" 2>/dev/null || true)"
    base="$(prov_base "$id" 2>/dev/null || true)"

    clear_screen
    header "配置 $nm"
    local keymodel=""
    if [[ "$id" == "__custom__" ]]; then
        ask base "API Base URL(例:http://1.2.3.4:8000/v1)" ""
        [[ -z "$base" ]] && { warn "base_url 不能为空"; pause; return 1; }
        ask keymodel "模型名" ""
        ask_secret key "API Key(本地端点可留空)"
        model_apply __custom__ "$key" "$keymodel" "$base"
        pause; return 0
    fi
    ask_secret key "${envv:-API Key} 的值"
    if [[ -z "$key" ]]; then
        warn "未输入密钥,只写提供商配置"
    fi
    ask keymodel "模型名${demo:+ (回车用 $demo)}" "$demo"
    model_apply "$id" "$key" "$keymodel" "$base"
    pause
}

model_apply() { # id key model base
    local id="$1" key="$2" model="$3" base="${4:-}"
    hermes_installed || { warn "请先部署(菜单 1)"; return 1; }
    [[ "$id" == "__custom__" ]] && id="custom"
    local envv; envv="$(prov_env "$id" 2>/dev/null || true)"
    [[ -n "$key" && -n "$envv" ]] && { env_set "$envv" "$key"; ok "密钥已写入 $UHOME/.env → $envv"; }
    hcfg model.provider "$id" || return 1
    if [[ "$id" == "custom" ]]; then
        [[ -n "$base" ]] && hcfg model.base_url "$base"
        hcfg model.api_mode "chat_completions"
        [[ -n "$envv" ]] && hcfg model.key_env "$envv"
    fi
    [[ -n "$model" ]] && hcfg model.default "$model"
    st_set MODEL_PROVIDER "$id"; [[ -n "$model" ]] && st_set MODEL_NAME "$model"
    info "已写入;下一步做一次真实连通验证"
    [[ -n "$key" && -n "$base" && -n "$model" ]] && model_verify_direct "$id" "$key" "$model" "$base"
    return 0
}

# 直连提供商 API 验证(不经过 agent,最快)
model_verify_direct() {
    local id="$1" key="$2" model="$3" base="$4"
    [[ -z "$base" || -z "$model" || -z "$key" ]] && { dim "该提供商不支持直连快速校验,可用菜单里的 test 发一句话验证"; return 0; }
    local url="${base%/}/chat/completions"
    local body; body="$(printf '{"model":"%s","messages":[{"role":"user","content":"ping"}],"max_tokens":1,"stream":false}' "$model")"
    local resp code payload
    resp="$(curl -sS -m 30 -w '\n__CODE__%{http_code}' -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' -d "$body" "$url" 2>&1)" || resp=""
    code="${resp##*__CODE__}"; payload="${resp%__CODE__*}"
    case "$code" in
        200) ok "接口连通:${url} → 200(密钥与模型均有效)" ;;
        401|403) err "密钥被拒绝(HTTP $code):$(json_err "$payload")" ;;
        402) err "账户余额/额度不足(HTTP 402):$(json_err "$payload")" ;;
        404) err "模型名或端点不对(HTTP 404):$(json_err "$payload")" ;;
        429) warn "请求过频或额度用尽(HTTP 429):$(json_err "$payload")" ;;
        000) err "网络不可达:$url(海外端点在国内 VPS 需代理)" ;;
        *) err "HTTP $code:$(json_err "$payload")" ;;
    esac
    return 0
}
json_err() { # 把厂商返回的错误信息压成一行(head/jq 可能提前关闭管道,故兜底并返回 0)
    local s="$1" msg=""
    if have jq; then
        msg="$(printf '%s' "$s" | jq -r '.error.message // .message // .error // empty' 2>/dev/null | sed -n '1p')" || msg=""
    fi
    if [[ -z "$msg" ]]; then
        msg="$(printf '%s' "$s" | tr -d '\n')" || msg=""
    fi
    printf '%s' "${msg:0:300}"
    return 0
}

model_verify_menu() {
    local id="${1:-}"; [[ -z "$id" ]] && id="$(st_get MODEL_PROVIDER "$(model_current 2>/dev/null | cut -d'|' -f1)")"
    local key model base envv
    envv="$(prov_env "$id" 2>/dev/null || true)"; key="$(env_get "$envv")"; model="$(hcfg_get model.default)"; base="$(prov_base "$id" 2>/dev/null || true)"
    [[ -z "$base" ]] && base="$(hcfg_get model.base_url)"
    printf '\n'
    dim "提供商:$id   模型:$model   端点:${base:-默认}"
    model_verify_direct "$id" "$key" "$model" "$base"
    pause
}

# 用当前模型真的发一句话(证明整条链路可用)
model_chat_test() {
    hermes_installed || { warn "Hermes 未安装"; pause; return 1; }
    clear_screen
    header "模型连通测试(真实对话)"
    dim "这会通过 Hermes 发一句“只回答:OK”,验证 模型 → 工具链 → 回复 全链路"
    local out rc=0
    set +e
    out="$(run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- timeout 150 "$HBIN" chat -q "只回答两个字:可用" -Q --max-turns 1 2>&1)"
    rc=$?
    set -e
    printf '\n'
    if [[ $rc -eq 0 && -n "$out" ]]; then
        local reply; reply="$(printf '%s' "$out" | tr -d '\n')" || reply=""
        ok "对话成功,模型回复:${reply:0:200}"
        st_set MODEL_VERIFIED "$(date '+%F %T')"
    else
        err "对话失败(退出码 $rc):"
        printf '%s\n' "$out" | tail -n 8 | sed 's/^/      /'
        dim "常见原因:key 无效 / 模型名不对 / 端点不可达 / 余额不足"
    fi
    pause
}

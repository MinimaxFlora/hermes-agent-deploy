# =============================================================================
#  消息平台(QQ / 微信 / 企业微信 / Telegram / 飞书 / 钉钉 …)
#  配置 → 写 .env + config.yaml → 立即做官方 API 级连通验证 → 重启网关 → 看日志
# =============================================================================

# id|名称|模式|必需env|可选env|说明
PLATFORMS=(
"qqbot|QQ 机器人(官方 API v2)|qr|QQ_APP_ID,QQ_CLIENT_SECRET|QQBOT_HOME_CHANNEL,QQBOT_HOME_CHANNEL_NAME,QQ_ALLOWED_USERS,QQ_GROUP_ALLOWED_USERS,QQ_ALLOW_ALL_USERS|扫码上线(推荐)或填 AppID/Secret;q.qq.com 建应用"
"weixin|个人微信(iLink 扫码)|qr|WEIXIN_ACCOUNT_ID|WEIXIN_TOKEN,WEIXIN_DM_POLICY,WEIXIN_ALLOWED_USERS,WEIXIN_HOME_CHANNEL|扫码登录;长轮询,无需公网"
"wecom|企业微信 AI 机器人|env|WECOM_BOT_ID,WECOM_SECRET|WECOM_DM_POLICY,WECOM_ALLOWED_USERS|WebSocket 网关"
"feishu|飞书 / Lark|env|FEISHU_APP_ID,FEISHU_APP_SECRET|FEISHU_CONNECTION_MODE,FEISHU_ALLOWED_USERS|长连接模式"
"dingtalk|钉钉机器人|env|DINGTALK_CLIENT_ID,DINGTALK_CLIENT_SECRET|DINGTALK_ALLOWED_USERS|Stream 模式"
"telegram|Telegram|env|TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS,TELEGRAM_HOME_CHANNEL|@BotFather 建机器人"
"discord|Discord|env|DISCORD_BOT_TOKEN|DISCORD_ALLOWED_USERS,DISCORD_HOME_CHANNEL|开发者后台建应用"
"slack|Slack|env|SLACK_BOT_TOKEN,SLACK_APP_TOKEN|SLACK_ALLOWED_USERS|Socket Mode"
"matrix|Matrix|env|MATRIX_HOMESERVER,MATRIX_USER_ID,MATRIX_ACCESS_TOKEN|MATRIX_HOME_ROOM|自建/托管 homeserver"
"whatsapp|WhatsApp|qr|WHATSAPP_ENABLED|WHATSAPP_ALLOWED_USERS|扫码登录"
"email|邮件助手|env|EMAIL_ADDRESS,EMAIL_PASSWORD,EMAIL_IMAP_HOST,EMAIL_SMTP_HOST|EMAIL_ALLOWED_USERS|IMAP + SMTP"
"api_server|OpenAI 兼容 API(给客户端)|env|API_SERVER_KEY|API_SERVER_PORT|OpenWebUI / LobeChat 等"
)

plat_line() { local id="$1" l; for l in "${PLATFORMS[@]}"; do [[ "${l%%|*}" == "$id" ]] && { printf '%s' "$l"; return 0; }; done; return 1; }
plat_field() { local l; l="$(plat_line "$1")" || return 1; awk -F'|' -v i="$2" '{print $i}' <<<"$l"; }
plat_name() { plat_field "$1" 2; }
plat_mode() { plat_field "$1" 3; }
plat_req()  { plat_field "$1" 4; }
plat_opt()  { plat_field "$1" 5; }
plat_note() { plat_field "$1" 6; }

plat_configured() { # 必需 env 是否齐
    local id="$1" req v
    req="$(plat_req "$id")"
    [[ -z "$req" ]] && return 1
    local IFS=','
    for v in $req; do [[ -n "$(env_get "$v")" ]] || return 1; done
    return 0
}
plat_enabled() { [[ "$(hcfg_get "platforms.$1.enabled")" == *true* ]]; }

# 网关日志里的平台连接状态
# 关键:连接结论写在 Hermes 自己的 $UHOME/logs/gateway.log 里,journald 只有零星告警;
# 且必须只看"本次启动之后"的日志,否则会被上一次运行的失败记录误导。
gw_current_run_log() {
    local log="$UHOME/logs/gateway.log"
    [[ -f "$log" ]] || return 1
    local start
    # 用"启动"标记(它一定在平台连接之前);不能用 "Gateway running with"(那是连完之后才写的)
    start="$(grep -n "Starting Hermes Gateway" "$log" 2>/dev/null | tail -n1 | cut -d: -f1)" || start=""
    [[ -z "$start" ]] && start="$(grep -n "Connecting to " "$log" 2>/dev/null | tail -n1 | cut -d: -f1)" || true
    if [[ -n "$start" ]]; then tail -n "+$start" "$log"; else tail -n 300 "$log"; fi
}

plat_live_state() {
    local id="$1" body="" verdict=""
    # api_server 直接看端口,别猜日志
    if [[ "$id" == "api_server" ]]; then
        if port_listening "$API_PORT"; then printf 'connected'; else printf 'failed'; fi
        return 0
    fi
    body="$(gw_current_run_log)" || { printf 'unknown'; return 0; }
    [[ -z "$body" ]] && { printf 'unknown'; return 0; }
    verdict="$(printf '%s
' "$body" | grep -iE "(^|[^a-zA-Z])${id}([^a-zA-Z]|$)"                 | grep -iE "connected|failed to connect|startup failed|✓|✗" | tail -n1)" || verdict=""
    [[ -z "$verdict" ]] && { printf 'unknown'; return 0; }
    if printf '%s' "$verdict" | grep -qiE "✓|connected" && ! printf '%s' "$verdict" | grep -qiE "failed|✗"; then
        printf 'connected'; return 0
    fi
    if printf '%s' "$verdict" | grep -qiE "failed|✗|error|invalid"; then
        printf 'failed'; return 0
    fi
    printf 'seen'
    return 0
}

# ---------------------------------------------------------------------------
# 脚本内扫码上线:直接调用官方适配器的扫码函数(不经过官方交互向导)
#   运行环境特殊:依赖装在 Hermes 自己的运行时里,只有官方启动器能装配好,
#   所以辅助模块写进 agent 目录,再用 `hermes --run-module <name>` 执行。
# ---------------------------------------------------------------------------
hermes_run_module() { # hermes_run_module <模块名> [参数…]
    local name="$1"; shift
    # PYTHONUNBUFFERED:非 TTY 时二维码/链接要立刻可见,不能被块缓冲吞掉
    run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" "PYTHONUNBUFFERED=1" "PYTHONIOENCODING=utf-8"         -- "$HBIN" --run-module "$name" "$@"
}
_qr_module_write() {
    local dir="$UHOME/hermes-agent" f
    [[ -d "$dir" ]] || { err "找不到 $dir(先部署)"; return 1; }
    f="$dir/hv_vps_onboard.py"
    cat >"$f" <<'PYEOF'
"""hermes-vps 扫码上线助手:直接调用官方适配器,不经过官方交互向导。"""
import asyncio
import json
import os
import sys


def _dump(path, data):
    """写结果文件;失败时退到 HERMES_HOME 下再试,最后把凭据打到终端。返回是否落盘成功。"""
    candidates = [path]
    home = os.environ.get("HERMES_HOME") or ""
    if home:
        candidates.append(os.path.join(home, os.path.basename(path)))
    for target in candidates:
        try:
            with open(target, "w", encoding="utf-8") as fh:
                json.dump(data or {}, fh, ensure_ascii=False)
            try:
                os.chmod(target, 0o600)
            except Exception:
                pass
            print("  结果已保存: %s" % target)
            return True
        except Exception as exc:
            print("  结果落盘失败(%s): %s" % (target, exc))
    print("  !! 无法自动保存,请手工记下以下内容,然后在菜单里选 2) 手填凭据:")
    for k, v in (data or {}).items():
        print("     %s = %s" % (k, v))
    return False


def run_qq(out_path, timeout):
    from gateway.platforms.qqbot import qr_register
    creds = qr_register(timeout)
    if not creds:
        print("\n  QQ 扫码未完成(超时 / 取消 / 二维码多次过期)")
        return 1
    _dump(out_path, creds)
    return 0


def run_weixin(out_path, timeout, hermes_home):
    from gateway.platforms.weixin import check_weixin_requirements, qr_login
    if not check_weixin_requirements():
        print("\n  缺少依赖:aiohttp / cryptography")
        return 2
    creds = asyncio.run(qr_login(hermes_home, timeout_seconds=timeout))
    if not creds:
        print("\n  微信扫码未完成(超时 / 取消)")
        return 1
    _dump(out_path, creds)
    return 0


def main():
    # 打开行缓冲:二维码/链接必须立刻可见(官方扫码函数内部 print 不主动 flush,
    # 非 TTY 时会被块缓冲吞掉,导致日志里看不到链接)
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(line_buffering=True)
        except Exception:
            pass
    if len(sys.argv) < 3:
        print("用法: hv_vps_onboard <qq|weixin> <结果文件> [超时秒]")
        return 2
    mode, out_path = sys.argv[1], sys.argv[2]
    timeout = int(sys.argv[3]) if len(sys.argv) > 3 else 600
    hermes_home = os.environ.get("HERMES_HOME", "")
    if mode in ("qq", "qqbot"):
        return run_qq(out_path, timeout)
    if mode in ("weixin", "wechat", "wx"):
        return run_weixin(out_path, timeout, hermes_home)
    print("未知平台: %s" % mode)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n已取消。")
        sys.exit(130)
PYEOF
    chown "$HUSER:$HUSER" "$f" 2>/dev/null || true
    chmod 644 "$f"
    printf '%s' "$f"
}
_qr_module_cleanup() { rm -f "$UHOME/hermes-agent/hv_vps_onboard.py"; }

json_get() { # json_get <文件> <键>
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    if have jq; then jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null | sed -n '1p'
    else grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | sed -n '1p'; fi
    return 0
}

# 二维码渲染需要官方 messaging extra(qrcode 等)
platform_qr_deps_ensure() {
    local dir="$UHOME/hermes-agent" out=""
    [[ "$(st_get QR_DEPS_OK)" == "1" ]] && return 0
    [[ -d "$dir" ]] || return 1
    cat >"$dir/hv_vps_check.py" <<'PYEOF'
try:
    import qrcode  # noqa: F401
    print("QR_OK")
except Exception:
    print("QR_MISSING")
PYEOF
    chown "$HUSER:$HUSER" "$dir/hv_vps_check.py" 2>/dev/null || true
    out="$(hermes_run_module hv_vps_check 2>/dev/null | tail -n1)" || out=""
    rm -f "$dir/hv_vps_check.py"
    [[ "$out" == *QR_OK* ]] && { st_set QR_DEPS_OK 1; return 0; }
    step "补齐二维码与消息平台依赖(官方:hermes pm install --extra messaging)"
    if run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- timeout 600 "$HBIN" pm install --extra messaging </dev/null; then
        st_set QR_DEPS_OK 1
        ok "依赖已就绪"
    else
        warn "依赖安装失败,二维码可能只显示链接(可直接在手机 QQ/微信里打开)"
        return 1
    fi
    return 0
}

# 脚本内扫码:QQ / 微信
platform_qr_onboard() {
    local id="$1"
    hermes_installed || { warn "请先部署(菜单 1)"; pause; return 1; }
    platform_qr_deps_ensure || true

    # 结果文件必须让 hermes 用户能写:放服务用户家目录($UHOME),root 读走后即删
    local out="$UHOME/onboard-${id}.json"
    rm -f "$out"
    local mod="" rc=0
    mod="$(_qr_module_write)" || { pause; return 1; }
    step "正在申请二维码(用手机扫码完成授权)"
    dim "二维码会显示在下面;按 Ctrl+C 可随时取消"
    printf '\n'
    set +e
    hermes_run_module hv_vps_onboard "$id" "$out" "${HV_QR_TIMEOUT:-600}"
    rc=$?
    set -e
    rm -f "$mod"
    printf '\n'
    if [[ $rc -ne 0 ]]; then
        warn "扫码流程未完成(退出码 $rc);可重试或改用手填凭据"
        rm -f "$out"
        pause
        return 0
    fi

    local v
    if [[ "$id" == "qqbot" ]]; then
        local app_id secret openid
        app_id="$(json_get "$out" app_id)"; secret="$(json_get "$out" client_secret)"; openid="$(json_get "$out" user_openid)"
        if [[ -z "$app_id" || -z "$secret" ]]; then
            warn "返回结果不完整,未写入"
            dim "若上面打印了 app_id / client_secret,可在本菜单选 2) 手填凭据写入"
            rm -f "$out"; pause; return 0
        fi
        env_set QQ_APP_ID "$app_id"
        env_set QQ_CLIENT_SECRET "$secret"
        ok "已写入 QQ_APP_ID / QQ_CLIENT_SECRET(AppID:$app_id)"
        local allow=""
        printf '    %s1)%s 配对审批(推荐,陌生人来申请你用 hermes pairing approve 放行)\n' "$BD" "$N"
        printf '    %s2)%s 允许所有人私聊\n' "$BD" "$N"
        printf '    %s3)%s 只允许指定 OpenID\n' "$BD" "$N"
        ask allow "选择(回车=1)" "1"
        case "$allow" in
            2) env_set QQ_ALLOW_ALL_USERS "true"; env_set QQ_ALLOWED_USERS ""; warn "已放开所有私聊" ;;
            3) local ids; ask ids "允许的 OpenID(逗号分隔)" "${openid:-}"; env_set QQ_ALLOW_ALL_USERS "false"; env_set QQ_ALLOWED_USERS "$ids" ;;
            *) env_set QQ_ALLOW_ALL_USERS "false"; env_set QQ_ALLOWED_USERS "${openid:-}"; ok "已启用配对审批" ;;
        esac
        if [[ -n "$openid" ]] && confirm "把你自己($openid)设为 home channel(定时任务/通知发这里)?" yes; then
            env_set QQBOT_HOME_CHANNEL "$openid"; ok "已设置 QQBOT_HOME_CHANNEL"
        fi
    elif [[ "$id" == "weixin" ]]; then
        local account token base user_id
        account="$(json_get "$out" account_id)"; token="$(json_get "$out" token)"
        base="$(json_get "$out" base_url)"; user_id="$(json_get "$out" user_id)"
        if [[ -z "$account" ]]; then
            warn "返回结果不完整,未写入"
            dim "若上面打印了 account_id / token,可在本菜单选 2) 手填凭据写入"
            rm -f "$out"; pause; return 0
        fi
        env_set WEIXIN_ACCOUNT_ID "$account"
        env_set WEIXIN_TOKEN "$token"
        [[ -n "$base" ]] && env_set WEIXIN_BASE_URL "$base"
        env_set WEIXIN_CDN_BASE_URL "$(env_get WEIXIN_CDN_BASE_URL "https://novac2c.cdn.weixin.qq.com/c2c")"
        ok "已写入 WEIXIN_ACCOUNT_ID / WEIXIN_TOKEN(account_id:$account)"
        local dm=""
        printf '    %s1)%s 配对审批(推荐)  %s2)%s 允许所有人  %s3)%s 只允许名单  %s4)%s 关闭私聊\n' "$BD" "$N" "$BD" "$N" "$BD" "$N" "$BD" "$N"
        ask dm "选择(回车=1)" "1"
        case "$dm" in
            2) env_set WEIXIN_DM_POLICY "open"; env_set WEIXIN_ALLOW_ALL_USERS "true"; warn "已放开所有私聊" ;;
            3) local ids; ask ids "允许的用户 ID(逗号分隔)" "${user_id:-}"; env_set WEIXIN_DM_POLICY "allowlist"; env_set WEIXIN_ALLOW_ALL_USERS "false"; env_set WEIXIN_ALLOWED_USERS "$ids" ;;
            4) env_set WEIXIN_DM_POLICY "disabled"; env_set WEIXIN_ALLOW_ALL_USERS "false"; warn "已关闭私聊" ;;
            *) env_set WEIXIN_DM_POLICY "pairing"; env_set WEIXIN_ALLOW_ALL_USERS "false"; ok "已启用配对审批" ;;
        esac
        env_set WEIXIN_GROUP_POLICY "disabled"
        if [[ -n "$user_id" ]] && confirm "把你自己($user_id)设为 home channel?" yes; then
            env_set WEIXIN_HOME_CHANNEL "$user_id"; ok "已设置 WEIXIN_HOME_CHANNEL"
        fi
        dim "注意:扫码得到的是 iLink 机器人身份(@im.bot),普通微信群通常拉不进去,私聊稳定可用"
    else
        warn "该平台暂不支持脚本内扫码"
        rm -f "$out"; pause; return 0
    fi

    rm -f "$out"
    hcfg "platforms.$id.enabled" "true" >/dev/null 2>&1 || true
    st_set "PLATFORM_$id" "true"
    ok "$(plat_name "$id") 已启用"
    plat_verify_api "$id"
    if confirm "重启网关让配置生效并查看连接日志?" yes; then
        restart_service hermes-gateway
        sleep 8
        local live; live="$(plat_live_state "$id")"
        [[ "$live" == "connected" ]] && ok "网关日志:$id 已连接" || warn "网关日志状态:$live"
        plat_show_log "$id"
    fi
    pause
}

plat_menu() {
    while :; do
        clear_screen
        header "消息平台"
        local i=0 l id nm md note mark live
        for l in "${PLATFORMS[@]}"; do
            i=$((i+1)); id="${l%%|*}"; nm="$(awk -F'|' '{print $2}' <<<"$l")"; md="$(awk -F'|' '{print $3}' <<<"$l")"; note="$(awk -F'|' '{print $6}' <<<"$l")"
            if plat_configured "$id"; then
                live="$(plat_live_state "$id" 2>/dev/null || echo unknown)"
                case "$live" in
                    connected) mark="$DOT_ON" ;;
                    failed)    mark="$DOT_OFF" ;;
                    *)         mark="$DOT_MID" ;;
                esac
                printf '    %s %2d) %-24s %s已配置%s  连接:%s\n' "$mark" "$i" "$nm" "$DM" "$N" "$live"
            else
                printf '    %s %2d) %-24s %s未配置%s  %s%s%s\n' "$DM$DOT_OFF" "$i" "$nm" "$DM" "$N" "$DM" "$note" "$N"
            fi
        done
        rule
        printf '    编号 = 配置(输完凭据立即验证);  %sv<编号>%s = 验证连接;  %st<编号>%s = 发测试消息;  0) 返回\n' "$C" "$N" "$C" "$N"
        printf '    提示:%sQQ / 微信 都支持官方扫码上线;飞书/钉钉/TG 等填凭据即可%s\n' "$DM" "$N"
        local ch=""; menu_choice ch "请选择"
        case "$ch" in
            0|"") return 0 ;;
            v*) plat_verify_menu "${ch#v}" ;;
            t*) plat_send_test "${ch#t}" ;;
            *) if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch>=1 && ch<=${#PLATFORMS[@]} )); then
                   plat_configure "${PLATFORMS[$((ch-1))]%%|*}"
               else warn "无效选择:$ch"; pause; fi ;;
        esac
    done
}

plat_configure() {
    local id="$1" nm mode req opt
    nm="$(plat_name "$id")"; mode="$(plat_mode "$id")"; req="$(plat_req "$id")"; opt="$(plat_opt "$id")"
    clear_screen
    header "配置 ${nm}"
    dim "$(plat_note "$id")"

    if [[ "$mode" == "qr" ]]; then
        printf '\n'
        printf '    %s1)%s 扫码授权%s(推荐:直接在本脚本里出二维码,扫完自动写好凭据)%s\n' "$BD" "$N" "$DM" "$N"
        printf '    %s2)%s 手填凭据写入 .env(已有 AppID/Secret 时用)\n' "$BD" "$N"
        printf '    %s0)%s 返回\n' "$BD" "$N"
        local q=""; menu_choice q "请选择"
        case "$q" in
            1) platform_qr_onboard "$id"; return 0 ;;
            2) : ;;
            *) return 0 ;;
        esac
    fi

    local v val
    local IFS=','
    for v in $req; do
        if [[ -n "$(env_get "$v")" ]]; then
            if confirm "$v 已配置,是否覆盖?" no; then :; else info "$v 保持原值"; continue; fi
        fi
        ask_secret val "$v 的值"
        if [[ -z "$val" ]]; then
            warn "$v 为空,跳过"
        else
            env_set "$v" "$val"; ok "已写入 $v"
        fi
    done
    if [[ -n "$opt" ]] && confirm "是否继续配置可选参数(白名单、首页频道等)?" no; then
        for v in $opt; do
            local cur; cur="$(env_get "$v")"
            ask val "$v${cur:+ (当前 $cur)}" ""
            [[ -n "$val" ]] && { env_set "$v" "$val"; ok "已写入 $v"; }
        done
    fi
    hcfg "platforms.$id.enabled" "true" >/dev/null 2>&1 || true
    st_set "PLATFORM_$id" "true"
    ok "${nm} 已启用"

    # 立即验证(官方 API 级)+ 重启网关看日志
    plat_verify_api "$id"
    if confirm "重启网关使配置生效并观察连接日志?" yes; then
        restart_service hermes-gateway
        sleep 8
        local live; live="$(plat_live_state "$id")"
        case "$live" in
            connected) ok "网关日志:${id} 已连接" ;;
            failed)    err "网关日志:${id} 连接失败(看下面的日志尾部)" ;;
            *)         dim "网关日志暂未见 ${id} 的明确结论,下面给最近日志" ;;
        esac
        plat_show_log "$id"
    fi
    pause
}

plat_verify_menu() {
    local id="${1:-}"
    if [[ -z "$id" || ! "$id" =~ ^[0-9]+$ ]]; then
        local ch=""; menu_choice ch "输入平台编号(1-${#PLATFORMS[@]})"; id="$ch"
    fi
    [[ "$id" =~ ^[0-9]+$ ]] && (( id>=1 && id<=${#PLATFORMS[@]} )) || { warn "无效编号"; pause; return 1; }
    id="${PLATFORMS[$((id-1))]%%|*}"
    clear_screen
    header "验证 $(plat_name "$id")"
    plat_configured "$id" || warn "尚未配置完整凭据,验证可能失败"
    plat_verify_api "$id"
    plat_show_log "$id"
    pause
}

# 官方 API 级验证(尽量用平台自己的接口拿到确定结论)
plat_verify_api() {
    local id="$1"
    case "$id" in
        qqbot)
            local aid asec resp
            aid="$(env_get QQ_APP_ID)"; asec="$(env_get QQ_CLIENT_SECRET)"
            [[ -z "$aid" || -z "$asec" ]] && { dim "缺 QQ_APP_ID / QQ_CLIENT_SECRET"; return 0; }
            resp="$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' \
                    -d "{\"appId\":\"$aid\",\"clientSecret\":\"$asec\"}" \
                    https://bots.qq.com/app/getAppAccessToken 2>&1)" || resp=""
            if [[ "$resp" == *access_token* ]]; then
                ok "QQ 官方接口已认账:拿到 access_token(凭据有效)"
                local exp; exp="$(json_field "$resp" expires_in)"
                [[ -n "$exp" ]] && dim "token 有效期 ${exp}s(网关会自动续)"
            else
                err "QQ 接口拒绝:$(json_err "$resp")"
                dim "常见:AppID/Secret 抄错、机器人未发布/未开启对应 intent"
            fi ;;
        telegram)
            local t; t="$(env_get TELEGRAM_BOT_TOKEN)"
            [[ -z "$t" ]] && { dim "缺 TELEGRAM_BOT_TOKEN"; return 0; }
            local r; r="$(curl -sS -m 20 "https://api.telegram.org/bot${t}/getMe" 2>&1)" || r=""
            if [[ "$r" == *'"ok":true'* ]]; then ok "Telegram 已认账:$(json_field "$r" result.username)"
            else err "Telegram 拒绝:$(json_err "$r")"; fi ;;
        discord)
            local t; t="$(env_get DISCORD_BOT_TOKEN)"
            [[ -z "$t" ]] && { dim "缺 DISCORD_BOT_TOKEN"; return 0; }
            local code; code="$(curl -sS -m 20 -o /tmp/.hv.disc -w '%{http_code}' -H "Authorization: Bot ${t}" https://discord.com/api/v10/users/@me 2>/dev/null || echo 000)"
            [[ "$code" == "200" ]] && ok "Discord 已认账(HTTP 200)" || err "Discord 拒绝(HTTP $code)" ;;
        slack)
            local t; t="$(env_get SLACK_BOT_TOKEN)"
            [[ -z "$t" ]] && { dim "缺 SLACK_BOT_TOKEN"; return 0; }
            local r; r="$(curl -sS -m 20 -H "Authorization: Bearer ${t}" https://slack.com/api/auth.test 2>&1)" || r=""
            [[ "$r" == *'"ok":true'* ]] && ok "Slack 已认账($(json_field "$r" team))" || err "Slack 拒绝:$(json_err "$r")" ;;
        feishu)
            local a s r
            a="$(env_get FEISHU_APP_ID)"; s="$(env_get FEISHU_APP_SECRET)"
            [[ -z "$a" || -z "$s" ]] && { dim "缺 FEISHU_APP_ID / FEISHU_APP_SECRET"; return 0; }
            r="$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -d "{\"app_id\":\"$a\",\"app_secret\":\"$s\"}" \
                 https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal 2>&1)" || r=""
            [[ "$r" == *tenant_access_token* ]] && ok "飞书已认账:拿到 tenant_access_token" || err "飞书拒绝:$(json_err "$r")" ;;
        dingtalk)
            local a s r
            a="$(env_get DINGTALK_CLIENT_ID)"; s="$(env_get DINGTALK_CLIENT_SECRET)"
            [[ -z "$a" || -z "$s" ]] && { dim "缺 DINGTALK_CLIENT_ID / DINGTALK_CLIENT_SECRET"; return 0; }
            r="$(curl -sS -m 20 -X POST -H 'Content-Type: application/json' -d "{\"appKey\":\"$a\",\"appSecret\":\"$s\"}" \
                 https://api.dingtalk.com/v1.0/oauth2/accessToken 2>&1)" || r=""
            [[ "$r" == *accessToken* ]] && ok "钉钉已认账:拿到 accessToken" || err "钉钉拒绝:$(json_err "$r")" ;;
        matrix)
            local hs tk r
            hs="$(env_get MATRIX_HOMESERVER)"; tk="$(env_get MATRIX_ACCESS_TOKEN)"
            [[ -z "$hs" || -z "$tk" ]] && { dim "缺 MATRIX_HOMESERVER / MATRIX_ACCESS_TOKEN"; return 0; }
            r="$(curl -sS -m 20 -H "Authorization: Bearer ${tk}" "${hs%/}/_matrix/client/v3/account/whoami" 2>&1)" || r=""
            [[ "$r" == *user_id* ]] && ok "Matrix 已认账:$(json_field "$r" user_id)" || err "Matrix 拒绝:$(json_err "$r")" ;;
        weixin)
            if [[ -n "$(env_get WEIXIN_ACCOUNT_ID)" ]]; then ok "已保存登录态(WEIXIN_ACCOUNT_ID 存在)"; else dim "尚未扫码登录"; fi ;;
        api_server)
            local k; k="$(env_get API_SERVER_KEY)"
            local c1 c2
            c1="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
            c2="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${k}" "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || echo 000)"
            [[ "$c1" == "401" || "$c1" == "403" ]] && ok "API 鉴权生效(无 key → $c1)" || warn "无 key 访问返回 $c1(期望 401)"
            [[ "$c2" == "200" ]] && ok "带 key 访问 → 200" || warn "带 key 访问返回 $c2" ;;
        *)
            dim "该平台没有可直连的校验接口,依赖网关连接日志判断(见下)" ;;
    esac
}

plat_show_log() {
    local id="$1" tail_n="${2:-12}" body="" lines=""
    body="$(gw_current_run_log)" || body=""
    if [[ -z "$body" ]]; then
        have journalctl && lines="$(journalctl -u hermes-gateway --since '-30 min' --no-pager 2>/dev/null | grep -iE "$id" | tail -n "$tail_n")" || lines=""
    else
        lines="$(printf '%s
' "$body" | grep -iE "$id" | tail -n "$tail_n")" || lines=""
    fi
    if [[ -n "$lines" ]]; then
        printf '
    %s网关日志(%s,本次启动以来)%s
' "$DM" "$id" "$N"
        printf '%s
' "$lines" | sed -E 's/^[0-9-]+ [0-9:,]+ //' | sed 's/^/      /' | cut -c1-190
    fi
    return 0
}

plat_send_test() {
    local id="${1:-}"
    if [[ -z "$id" || ! "$id" =~ ^[0-9]+$ ]]; then
        local ch=""; menu_choice ch "输入平台编号(1-${#PLATFORMS[@]})"; id="$ch"
    fi
    [[ "$id" =~ ^[0-9]+$ ]] && (( id>=1 && id<=${#PLATFORMS[@]} )) || { warn "无效编号"; pause; return 1; }
    local pid="${PLATFORMS[$((id-1))]%%|*}"
    clear_screen
    header "发送测试消息 → $(plat_name "$pid")"
    dim "用 hermes send 通过该平台发一条测试消息(需要平台的 home channel)"
    local out rc=0
    set +e
    out="$(run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" send -t "$pid" "hermes-vps 测试消息:如果你看到这条,说明 ${pid} 收发生了效。" 2>&1)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then ok "发送成功(通过 $pid 的 home channel)"
    else err "发送失败(退出码 $rc):"; printf '%s\n' "$out" | tail -n 10 | sed 's/^/      /'; fi
    dim "若提示需要 home channel:先在平台里给机器人发条消息,或 /sethome;也可指定目标 菜单不提供(用 hermes send -t ${pid}:chat_id)"
    pause
}

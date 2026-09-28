#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/lifecycle.sh
# 生命周期:更新(含自动更新定时器)、卸载。
# 卸载严格遵守用户规则:先列出将要删除的每一条路径,逐项确认,绝不批量静默删。
# =============================================================================

[[ -n "${HV_LIFECYCLE_LOADED:-}" ]] && return 0
HV_LIFECYCLE_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ui.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/account.sh"
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/hermes.sh"

# ---------------------------------------------------------------------------
# 更新
# ---------------------------------------------------------------------------
hv_update_all() {
    hv_require_root
    hv_hermes_installed || hv_die "Hermes 未安装,先跑 hermes-vps install"

    local before; before="$(hv_hermes_version 2>/dev/null || echo unknown)"
    hv_info "更新前版本:$before"

    # 更新前自动打一份备份,失败可回滚
    if [[ "${HV_SKIP_BACKUP:-0}" == "1" ]]; then
        hv_info "按 --no-backup 跳过更新前备份"
    elif hv_confirm "更新前先创建备份?" yes; then
        # shellcheck source=/dev/null
        source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/backup.sh"
        hv_backup_create pre-update
    fi

    hv_hermes_update

    hv_step "重启服务使其加载新版本"
    hv_has_systemd || { hv_warn "无 systemd,请手工重启 gateway/dashboard"; return 0; }
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/service.sh"
    hv_service_restart_all
    systemctl reload caddy 2>/dev/null || true

    local after; after="$(hv_hermes_version 2>/dev/null || echo unknown)"
    hv_state_set HERMES_VERSION "$after"
    hv_ok "更新完成:$before → $after"
}

hv_autoupdate_enable() {
    hv_require_root
    hv_has_systemd || { hv_warn "无 systemd,无法设定时更新"; return 1; }
    local self="${HV_INSTALLED_BIN:-/usr/local/bin/hermes-vps}"
    [[ -x "$self" ]] || hv_warn "未找到 $self(定时任务将按该路径调用,请先安装本工具)"

    cat >/etc/systemd/system/hermes-vps-update.service <<EOF
[Unit]
Description=hermes-vps 自动更新(Hermes + 服务重启)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=3600
ExecStart=${self} update --no-backup --yes
EOF
    cat >/etc/systemd/system/hermes-vps-update.timer <<'EOF'
[Unit]
Description=hermes-vps 每日自动更新
[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
    hv_systemd_reload
    systemctl enable --now hermes-vps-update.timer
    hv_ok "已启用每日 04:30 自动更新(带随机延迟,避免同一时刻集中拉取)"
}

hv_autoupdate_disable() {
    hv_has_systemd || return 0
    systemctl disable --now hermes-vps-update.timer >/dev/null 2>&1 || true
    hv_ok "已关闭自动更新"
}

hv_autoupdate_status() {
    if hv_has_systemd && systemctl is-enabled hermes-vps-update.timer >/dev/null 2>&1; then
        hv_info "自动更新:已启用"
        systemctl list-timers hermes-vps-update.timer --no-pager 2>/dev/null | head -n 3 | sed 's/^/    /'
    else
        hv_info "自动更新:未启用(hermes-vps update --auto enable 开启)"
    fi
}

# ---------------------------------------------------------------------------
# 卸载(逐项确认,先列后删)
# ---------------------------------------------------------------------------
hv_uninstall() {
    hv_require_root

    local -a targets=()
    targets+=("__unit__${HV_GW_UNIT:-hermes-gateway.service}")
    targets+=("__unit__hermes-dashboard.service")
    targets+=("__unit__hermes-vps-update.timer")
    targets+=("__unit__hermes-vps-backup.timer")
    targets+=("__path__/etc/systemd/system/hermes-gateway.service")
    targets+=("__path__/etc/systemd/system/hermes-gateway.service.d")
    targets+=("__path__/etc/systemd/system/hermes-dashboard.service")
    targets+=("__path__/etc/systemd/system/hermes-vps-update.service")
    targets+=("__path__/etc/systemd/system/hermes-vps-update.timer")
    targets+=("__path__/etc/systemd/system/hermes-vps-backup.service")
    targets+=("__path__/etc/systemd/system/hermes-vps-backup.timer")
    targets+=("__caddy__")                                    # 撤销 Caddy 站点(仅当由本工具生成)
    targets+=("__path__${HV_UHOME}")                          # 数据(config/记忆/技能/会话)
    targets+=("__path__${HV_ETC}")                            # 本工具状态与凭据
    targets+=("__path__/var/log/hermes-vps")
    targets+=("__path__/usr/local/bin/hermes-vps")
    targets+=("__path__/opt/hermes-vps")
    targets+=("__user__${HV_USER}")

    hv_step "卸载预览 —— 以下为将要处理的对象(逐条确认,未确认的不动)"
    printf '    %s\n' "${targets[@]}"
    hv_rule
    if ! hv_confirm "开始逐项卸载?" no; then hv_info "已取消,未做任何改动"; return 0; fi

    # 1) 停服务 + 删单元
    local u
    for u in "${HV_GW_UNIT:-hermes-gateway.service}" hermes-dashboard.service hermes-vps-update.timer hermes-vps-backup.timer; do
        systemctl disable --now "$u" >/dev/null 2>&1 || true
    done
    hv_systemd_reload

    local t
    for t in "${targets[@]}"; do
        case "$t" in
            __unit__*) : ;;  # 已在上一步处理
            __caddy__)
                if [[ -f /etc/caddy/Caddyfile ]] && grep -q "managed-by: hermes-vps" /etc/caddy/Caddyfile; then
                    if hv_confirm "删除本工具生成的 Caddy 站点配置 /etc/caddy/Caddyfile ?(Caddy 会随之失效)" no; then
                        cp -p /etc/caddy/Caddyfile "/root/Caddyfile.hermes-vps.$(date +%Y%m%d%H%M%S).bak" 2>/dev/null || true
                        rm -f /etc/caddy/Caddyfile
                        systemctl reload caddy 2>/dev/null || systemctl stop caddy 2>/dev/null || true
                        hv_dim "   已删除 /etc/caddy/Caddyfile(旧文件备份在 /root/)"
                    fi
                else
                    hv_info "Caddyfile 不是本工具生成,跳过"
                fi
                ;;
            __path__*)
                local p="${t#__path__}"
                [[ -e "$p" ]] || { hv_dim "   跳过(不存在):$p"; continue; }
                if hv_confirm "删除 $p ?" no; then
                    case "$p" in
                        /|/etc|/usr|/var|/opt|/root) hv_warn "拒绝删除系统目录:$p"; continue ;;
                    esac
                    rm -rf -- "$p" && hv_dim "   已删除 $p"
                else
                    hv_info "保留 $p"
                fi
                ;;
            __user__*)
                local user="${t#__user__}"
                if id "$user" >/dev/null 2>&1; then
                    if hv_confirm "删除系统用户 $user ?(必须先确认该用户的数据已备份/已删除)" no; then
                        userdel "$user" 2>/dev/null && hv_dim "   已删除用户 $user" || hv_warn "userdel 失败"
                    fi
                fi
                ;;
        esac
    done

    hv_ok "卸载流程结束。若保留了 /opt/hermes,数据仍在原处,可随时重装复用。"
}

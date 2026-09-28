# ---------------------------------------------------------------------------
# 使用说明
# ---------------------------------------------------------------------------
show_help() {
    clear_screen
    header "使用说明"
    printf '  %s常用命令%s(等价于菜单操作,可脚本化)\n' "$BD" "$N"
    rule
    printf '    bash %s                    %s打开本菜单%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s install --yes      %s无人值守部署%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s diagnose           %s自检(服务/端口/认证门/API/证书)%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s backup             %s立即备份%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s service restart    %s重启服务%s\n' "${SELF##*/}" "$DM" "$N"
    printf '    bash %s selftest           %s检查脚本自身%s\n' "${SELF##*/}" "$DM" "$N"
    rule
    printf '  %s路径%s\n' "$BD" "$N"
    rule
    printf '    Hermes 数据 : %s(配置/.env/skills/会话/日志)\n' "$UHOME"
    printf '    本工具状态  : %s\n' "$STATE_FILE"
    printf '    访问凭据    : %s(600)\n' "$CRED_FILE"
    printf '    备份目录    : %s\n' "$BACKUP_DIR"
    printf '    Caddy 配置  : %s\n' "$CADDYFILE"
    printf '    工具日志    : %s\n' "$LOG_FILE"
    rule
    printf '  %s常看命令%s\n' "$BD" "$N"
    rule
    printf '    网关日志: journalctl -u hermes-gateway -f\n'
    printf '    面板日志: journalctl -u hermes-dashboard -f\n'
    printf '    Caddy  : journalctl -u caddy -f\n'
    printf '    改模型  : 菜单 2(或 hermes model)\n'
    printf '    改平台  : 菜单 3;改完记得重启网关(菜单 6 → 4)\n'
    rule
    pause
}

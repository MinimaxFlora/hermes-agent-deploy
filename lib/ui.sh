#!/usr/bin/env bash
# =============================================================================
# hermes-vps :: lib/ui.sh
# 交互抽象层:whiptail 优先,text 回退,非交互模式自动取默认值。
# 任何模块都不直接读 stdin,统一走 hv_* 询问函数 —— 这样才能一份代码两用。
# =============================================================================

[[ -n "${HV_UI_LOADED:-}" ]] && return 0
HV_UI_LOADED=1
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

HV_UI_BACKTITLE="Hermes Agent VPS 部署工具"

HV_UI_KIND=""
hv_ui_init() {
    if [[ "${HV_NONINTERACTIVE}" == "1" ]]; then HV_UI_KIND="none"; return 0; fi
    if ! [[ -t 0 && -t 1 ]]; then HV_UI_KIND="none"; return 0; fi
    if hv_have whiptail; then HV_UI_KIND="whiptail"; return 0; fi
    HV_UI_KIND="text"
}

hv_ui_is_gui() { [[ "$(_hv_ui_kind_cached)" == "whiptail" ]]; }
_hv_ui_kind_cached() { [[ -n "$HV_UI_KIND" ]] || hv_ui_init; printf '%s' "$HV_UI_KIND"; }

# --- 提示 ---------------------------------------------------------------
hv_msg() {
    local title="$1" body="$2" h="${3:-18}" w="${4:-76}"
    case "$(_hv_ui_kind_cached)" in
        whiptail) whiptail --backtitle "$HV_UI_BACKTITLE" --title "$title" --msgbox "$body" "$h" "$w" 3>&1 1>&2 2>&3 || true ;;
        text)     printf '\n%s\n%s\n%s\n' "${HV_C_BOLD}== ${title} ==${HV_C_RESET}" "$body" ""; hv_pause ;;
        none)     printf '%s\n' "$body" ;;
    esac
}

hv_pause() {
    case "$(_hv_ui_kind_cached)" in
        whiptail) return 0 ;;
        text)     read -r -p "${HV_C_DIM}按回车继续...${HV_C_RESET}" _ || true ;;
        none)     return 0 ;;
    esac
}

# 确认(yes/no):默认 yes 时回车即为是
hv_confirm() {
    local prompt="$1" def="${2:-no}"
    if [[ "${HV_ASSUME_YES}" == "1" ]]; then hv_info "$prompt → 已按 --yes 自动确认"; return 0; fi
    case "$(_hv_ui_kind_cached)" in
        whiptail)
            if [[ "$def" == "yes" ]]; then
                whiptail --backtitle "$HV_UI_BACKTITLE" --title "确认" --yesno "$prompt" 14 76 3>&1 1>&2 2>&3
            else
                whiptail --backtitle "$HV_UI_BACKTITLE" --title "确认" --defaultno --yesno "$prompt" 14 76 3>&1 1>&2 2>&3
            fi
            ;;
        text)
            local hint="y/N"; [[ "$def" == "yes" ]] && hint="Y/n"
            local ans=""; read -r -p "${HV_C_BOLD}${prompt} [${hint}] ${HV_C_RESET}" ans || true
            if [[ -z "$ans" ]]; then [[ "$def" == "yes" ]]; return; fi
            [[ "$ans" =~ ^[Yy] ]]; return $?
            ;;
        none) [[ "$def" == "yes" ]]; return $? ;;
    esac
}
export -f hv_confirm 2>/dev/null || true

# 文本输入
# hv_ask VAR "提示" "默认值" [校验模式]
hv_ask() {
    local __var="$1" prompt="$2" def="${3:-}" pattern="${4:-}"
    local val=""
    while :; do
        case "$(_hv_ui_kind_cached)" in
            whiptail)
                val="$(whiptail --backtitle "$HV_UI_BACKTITLE" --title "输入" --inputbox "$prompt" 12 76 "$def" 3>&1 1>&2 2>&3)" || val="$def"
                ;;
            text)
                read -r -p "${HV_C_BOLD}${prompt}${def:+ [${def}]}: ${HV_C_RESET}" val || true
                [[ -z "$val" ]] && val="$def"
                ;;
            none) val="$def" ;;
        esac
        if [[ -n "$pattern" && -n "$val" ]] && ! [[ "$val" =~ $pattern ]]; then
            hv_warn "输入格式不正确: $val"
            [[ "$(_hv_ui_kind_cached)" == "none" ]] && break
            continue
        fi
        break
    done
    printf -v "$__var" '%s' "$val"
}

# 密码/密钥输入(不回显);非交互模式下必须自带默认值
hv_ask_secret() {
    local __var="$1" prompt="$2" def="${3:-}"
    local val=""
    case "$(_hv_ui_kind_cached)" in
        whiptail) val="$(whiptail --backtitle "$HV_UI_BACKTITLE" --title "输入(隐藏)" --passwordbox "$prompt" 12 76 "$def" 3>&1 1>&2 2>&3)" || val="$def" ;;
        text)     read -r -s -p "${HV_C_BOLD}${prompt}: ${HV_C_RESET}" val || true; echo ;;
        none)     val="$def" ;;
    esac
    [[ -z "$val" ]] && val="$def"
    printf -v "$__var" '%s' "$val"
}

# 单选菜单: hv_menu VAR "标题" "说明" tag1 "项1" tag2 "项2" ...
hv_menu() {
    local __var="$1" title="$2" text="$3"; shift 3
    local val=""
    case "$(_hv_ui_kind_cached)" in
        whiptail)
            val="$(whiptail --backtitle "$HV_UI_BACKTITLE" --title "$title" --menu "$text" 22 78 12 "$@" 3>&1 1>&2 2>&3)" || { printf -v "$__var" ''; return 1; }
            ;;
        text|none)
            local i=1 args=("$@")
            printf '\n%s\n' "${HV_C_BOLD}${title}${HV_C_RESET}" >&2
            [[ -n "$text" ]] && printf '%s\n' "$text" >&2
            while [[ $# -gt 0 ]]; do
                printf '  %s%2d)%s %s\n' "$HV_C_CYAN" "$i" "$HV_C_RESET" "$2" >&2
                shift 2; i=$((i+1))
            done
            if [[ "$(_hv_ui_kind_cached)" == "none" ]]; then val="${args[0]}"; else
                local ans=""; read -r -p "${HV_C_BOLD}选择编号: ${HV_C_RESET}" ans || true
                local idx=$(( ${ans:-1} ))
                [[ $idx -ge 1 && $idx -le $((i-1)) ]] || idx=1
                val="${args[$(( (idx-1)*2 ))]}"
            fi
            ;;
    esac
    printf -v "$__var" '%s' "$val"
}

# 多选菜单: hv_multi VAR "标题" "说明" tag1 "项1" state1 tag2 "项2" state2 ...
hv_multi() {
    local __var="$1" title="$2" text="$3"; shift 3
    local out=""
    case "$(_hv_ui_kind_cached)" in
        whiptail)
            out="$(whiptail --backtitle "$HV_UI_BACKTITLE" --title "$title" --checklist "$text" 24 78 14 "$@" 3>&1 1>&2 2>&3)" || { printf -v "$__var" ''; return 1; }
            out="${out//\"/}"
            ;;
        text|none)
            local args=("$@") selected=() i=1
            printf '\n%s\n' "${HV_C_BOLD}${title}${HV_C_RESET}" >&2
            while [[ $# -ge 3 ]]; do
                local mark=" "; [[ "$3" == "on" ]] && mark="*"
                printf '  %s%2d)%s [%s] %s\n' "$HV_C_CYAN" "$i" "$HV_C_RESET" "$mark" "$2" >&2
                shift 3; i=$((i+1))
            done
            if [[ "$(_hv_ui_kind_cached)" == "none" ]]; then
                # 非交互:取所有 on
                local j=0
                while [[ $j -lt ${#args[@]} ]]; do
                    [[ "${args[$((j+2))]}" == "on" ]] && selected+=("${args[$j]}")
                    j=$((j+3))
                done
            else
                local ans=""; read -r -p "${HV_C_BOLD}输入编号(空格分隔,回车=保持默认): ${HV_C_RESET}" ans || true
                if [[ -n "$ans" ]]; then
                    local n
                    for n in $ans; do
                        [[ "$n" =~ ^[0-9]+$ ]] && selected+=("${args[$(( (n-1)*3 ))]}")
                    done
                else
                    local j=0
                    while [[ $j -lt ${#args[@]} ]]; do
                        [[ "${args[$((j+2))]}" == "on" ]] && selected+=("${args[$j]}")
                        j=$((j+3))
                    done
                fi
            fi
            out="${selected[*]:-}"
            ;;
    esac
    printf -v "$__var" '%s' "$out"
}

# 长文本查看器
hv_show_text() {
    local title="$1" file="$2"
    case "$(_hv_ui_kind_cached)" in
        whiptail) whiptail --backtitle "$HV_UI_BACKTITLE" --title "$title" --scrolltext --textbox "$file" 24 90 3>&1 1>&2 2>&3 || true ;;
        *) less -R "$file" 2>/dev/null || cat "$file" ;;
    esac
}

# 进度:把一段命令的输出交给 whiptail 的 gauge 太脆弱,这里统一用「标题 + 日志尾随」
hv_run_step() {
    local title="$1"; shift
    hv_step "$title"
    if [[ "$(_hv_ui_kind_cached)" == "whiptail" ]]; then
        printf '%s\n' "$title" >&2
        ( "$@" ) 2>&1 | while IFS= read -r line; do
            printf '%s\n' "$line" >>"$(_hv_logfile 2>/dev/null || echo /dev/null)"
        done
        return "${PIPESTATUS[0]}"
    fi
    "$@"
}

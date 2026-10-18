# ---------------------------------------------------------------------------
# 输入原语(纯文本,无 whiptail)
# ---------------------------------------------------------------------------
pause() {
    interactive || return 0
    printf '\n  %s按回车返回菜单…%s' "$DM" "$N"
    read -r _ || true
}
ask() { # ask <变量名> <提示> [默认值]
    local __v="$1" prompt="$2" def="${3:-}" val=""
    if interactive; then
        if [[ -n "$def" ]]; then printf '  %s%s %s[%s]%s: ' "$BD" "$prompt" "$DM" "$def" "$N"
        else printf '  %s%s%s: ' "$BD" "$prompt" "$N"; fi
        read -r val || true
    fi
    [[ -z "$val" ]] && val="$def"
    printf -v "$__v" '%s' "$val"
}
# 逐字符读取并回显 *:终端里能看见"已经输入了多少",但看不到内容
_read_masked() { # _read_masked <变量名>
    local __out="" ch=""
    stty -echo 2>/dev/null || true
    trap 'stty echo 2>/dev/null || true; printf "\n"' INT TERM
    while IFS= read -rsn1 ch; do
        case "$ch" in
            $'\n'|$'\r'|'') break ;;
            $'\x7f'|$'\b')
                if [[ -n "$__out" ]]; then
                    __out="${__out%?}"
                    printf '\b \b'
                fi
                ;;
            $'\x03') # Ctrl-C
                stty echo 2>/dev/null || true
                printf '\n'
                trap - INT TERM
                exit 130
                ;;
            *)
                __out+="$ch"
                printf '*'
                ;;
        esac
    done || true
    stty echo 2>/dev/null || true
    trap - INT TERM
    printf -v "$1" '%s' "$__out"
    return 0
}

ask_secret() { # 隐藏输入,但用 * 回显输入长度
    local __v="$1" prompt="$2" val=""
    if interactive; then
        printf '  %s%s%s: ' "$BD" "$prompt" "$N"
        _read_masked val
        printf '\n'
    fi
    printf -v "$__v" '%s' "$val"
}
confirm() { # confirm <提示> [yes|no]
    local prompt="$1" def="${2:-no}"
    [[ "$ASSUME_YES" == "1" ]] && { info "$prompt → 已按 --yes 自动确认"; return 0; }
    interactive || { [[ "$def" == "yes" ]]; return $?; }
    local hint="y/N"; [[ "$def" == "yes" ]] && hint="Y/n"
    local a=""; printf '  %s%s [%s]: %s' "$BD" "$prompt" "$hint" "$N"; read -r a || true
    [[ -z "$a" ]] && { [[ "$def" == "yes" ]]; return $?; }
    [[ "$a" =~ ^[Yy] ]]
}
menu_choice() { # echo 用户输入;HV_EOF=1 表示输入流已结束(EOF)
    local __v="$1" prompt="${2:-请输入编号}"
    local a=""
    HV_EOF=0
    if interactive; then
        printf '  %s%s%s: ' "$BD" "$prompt" "$N"
        read -r a || { HV_EOF=1; a=""; }
    fi
    printf -v "$__v" '%s' "$a"
    return 0
}

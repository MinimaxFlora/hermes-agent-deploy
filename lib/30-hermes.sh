# =============================================================================
#  服务用户 · Hermes 安装 · 模型提供商(配置 + 真实连通验证)
# =============================================================================

ensure_user() {
    # Docker 模式:不创建系统用户,只准备数据目录;容器内固定以 UID 10000 运行
    if docker_backend; then
        step "准备数据目录(Docker)"
        if ! install -d -m 700 -o "$DOCKER_UID" -g "$DOCKER_GID" "$UHOME" 2>/dev/null; then
            mkdir -p "$UHOME" 2>/dev/null || true
            chown "$DOCKER_UID:$DOCKER_GID" "$UHOME" 2>/dev/null || true
            chmod 700 "$UHOME" 2>/dev/null || true
        fi
        ok "数据目录:$UHOME(属主 ${DOCKER_UID}:${DOCKER_GID})"
        return 0
    fi
    # 用户态:不创建任何系统用户,只准备目录(就是当前用户自己)
    if [[ "$HV_MODE" != "system" ]]; then
        info "用户态模式:数据放在 $HHOME(当前用户 $(id -un)),不创建系统用户"
        install -d -m 700 "$UHOME" 2>/dev/null || mkdir -p "$UHOME"
        install -d -m 755 "$HHOME/.local" "$HHOME/.local/bin" 2>/dev/null || mkdir -p "$HHOME/.local/bin"
        return 0
    fi
    require_root "创建服务用户 $HUSER"
    if id "$HUSER" >/dev/null 2>&1; then
        local cur; cur="$(getent passwd "$HUSER" | cut -d: -f6)"
        if [[ "$cur" != "$HHOME" ]]; then
            warn "用户 $HUSER 家目录为 $cur(期望 $HHOME)"
            if confirm "改为 $HHOME ?(usermod -d,不搬文件)" no; then usermod -d "$HHOME" "$HUSER"; else HHOME="$cur"; UHOME="${cur}/.hermes"; HBIN="${cur}/.local/bin/hermes"; info "改用现有家目录:$HHOME"; fi
        fi
        info "服务用户已存在:$HUSER(uid $(id -u "$HUSER"))"
    else
        step "创建服务用户 $HUSER"
        useradd --system --create-home --home-dir "$HHOME" --shell /bin/bash --comment "Hermes Agent service account" "$HUSER" 2>/dev/null \
            || useradd -r -m -d "$HHOME" -s /bin/bash "$HUSER"
        passwd -l "$HUSER" >/dev/null 2>&1 || true
        ok "已创建 $HUSER(禁止交互登录)"
    fi
    install -d -o "$HUSER" -g "$HUSER" -m 755 "$HHOME"
    install -d -o "$HUSER" -g "$HUSER" -m 700 "$UHOME"
    install -d -o "$HUSER" -g "$HUSER" -m 755 "$HHOME/.local" "$HHOME/.local/bin"
}

hermes_installed() {
    if docker_backend; then
        [[ -f "$COMPOSE_FILE" ]] || return 1
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'hermes-gateway' || return 1
        return 0
    fi
    [[ -x "$HBIN" ]]
}
hermes_version() {
    if docker_backend; then
        local v; v="$(docker_hermes_version)"
        [[ -n "$v" ]] || v="$(st_get HERMES_VERSION)"
        [[ -n "$v" ]] && printf '%s' "$v"
        return 0
    fi
    hermes_installed || return 1
    local out=""
    out="$(run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- "$HBIN" --version 2>/dev/null | sed -n '1p')" || out=""
    if [[ -n "$out" ]]; then printf '%s' "$out"; fi
    return 0
}

hermes_install() {
    # Docker 模式:只装 Docker Engine,镜像里已经带好 Python/Node/浏览器
    if docker_backend; then
        step "部署 Hermes Docker 容器"
        docker_install || return 1
        docker_compose_write || return 1
        docker_pull_image || return 1
        docker_compose_up || return 1
        if docker_wait_ready; then
            ok "容器已就绪:$(hermes_version 2>/dev/null || echo 版本未知)"
        else
            warn "容器启动较慢或未就绪;可稍后看日志:docker compose -f $COMPOSE_FILE logs gateway"
        fi
        st_set HERMES_VERSION "$(hermes_version 2>/dev/null || echo unknown)"
        st_set INSTALLED_AT "$(date -Is)"
        st_set DEPLOY_BACKEND docker
        return 0
    fi
    # 官方安装脚本是纯用户空间的:用户态直接装到自己的家目录,不需要 root
    if [[ "$HV_MODE" == "system" ]]; then require_root "安装 Hermes(系统级)"; fi
    if hermes_installed; then
        ok "Hermes 已安装($(hermes_version 2>/dev/null || echo 版本未知))"
        if [[ -d "$UHOME/hermes-agent/hermes_cli/web_dist" && "${FORCE:-0}" != "1" ]]; then
            info "已安装且产物完整,跳过重复安装(强制重装:安装时加 --force)"
            return 0
        fi
        [[ -d "$UHOME/hermes-agent/hermes_cli/web_dist" ]] || warn "上次安装不完整(缺界面产物),自动重跑修复"
    fi
    step "执行官方安装脚本(首次 3~10 分钟)"
    local script; script="$(mktemp /tmp/hermes-install-XXXXXX.sh)"
    chmod 644 "$script"
    if ! curl -fsSL --max-time 60 "$OFFICIAL_INSTALL" -o "$script"; then rm -f "$script"; die "下载安装脚本失败:$OFFICIAL_INSTALL"; fi
    install -d -o "$HUSER" -g "$HUSER" -m 700 "$UHOME" 2>/dev/null || mkdir -p "$UHOME"
    if [[ "$HV_MODE" == "system" ]]; then chown -R "$HUSER:$HUSER" "$UHOME" 2>/dev/null || true; fi

    # 显式指定 HERMES_HOME/代码目录:官方脚本默认 $HOME/.hermes,这里与我们管理的路径对齐
    # (官方布局:代码 $HERMES_HOME/hermes-agent、可执行 $HOME/.local/bin/hermes —— 两种模式一致)
    local -a flags=(--non-interactive --hermes-home "$UHOME" --dir "$UHOME/hermes-agent")
    [[ "$SKIP_BROWSER" == "1" ]] && flags+=(--skip-browser)

    local rc=0
    set +e
    run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" "HERMES_REPO_URL=$REPO_URL" "DEBIAN_FRONTEND=noninteractive" \
        -- bash "$script" "${flags[@]}" </dev/null
    rc=$?
    set -e
    rm -f "$script"
    if [[ $rc -ne 0 ]]; then
        err "官方安装脚本退出码 $rc"
        [[ -f "$UHOME/logs/install.log" ]] && { err "日志尾部:"; tail -n 20 "$UHOME/logs/install.log" | sed 's/^/      /' >&2; }
        return $rc
    fi
    hermes_installed || die "安装后找不到 launcher:$HBIN"
    ok "Hermes 安装完成:$(hermes_version 2>/dev/null || echo 未知)"
    st_set HERMES_VERSION "$(hermes_version 2>/dev/null || echo unknown)"
    st_set INSTALLED_AT "$(date -Is)"
}

hermes_ensure_config() {
    if docker_backend; then
        if ! install -d -m 700 -o "$DOCKER_UID" -g "$DOCKER_GID" "$UHOME" 2>/dev/null; then
            mkdir -p "$UHOME" 2>/dev/null || true
            chown "$DOCKER_UID:$DOCKER_GID" "$UHOME" 2>/dev/null || true
        fi
        # .env / config.yaml 由容器首次启动时从镜像内的示例种子生成;
        # 这里不预创建空 .env,否则 stage2 会跳过 .env.example 的默认项。
        if [[ -f "$UHOME/.env" ]]; then
            chown "$DOCKER_UID:$DOCKER_GID" "$UHOME/.env" 2>/dev/null || true
            chmod 600 "$UHOME/.env"
        fi
        return 0
    fi
    install -d -o "$HUSER" -g "$HUSER" -m 700 "$UHOME" 2>/dev/null || mkdir -p "$UHOME"
    [[ -f "$UHOME/.env" ]] || : >"$UHOME/.env"
    chown "$HUSER:$HUSER" "$UHOME/.env" 2>/dev/null || true; chmod 600 "$UHOME/.env"
    if [[ ! -f "$UHOME/config.yaml" ]]; then
        local ex="$UHOME/hermes-agent/cli-config.yaml.example"
        [[ -f "$ex" ]] && cp "$ex" "$UHOME/config.yaml" || : >"$UHOME/config.yaml"
        chown "$HUSER:$HUSER" "$UHOME/config.yaml" 2>/dev/null || true
    fi
}

hermes_update() {
    hermes_installed || die "Hermes 未安装,请先部署"
    if docker_backend; then
        step "更新 Hermes 镜像"
        local before; before="$(hermes_version 2>/dev/null || echo unknown)"
        if [[ "${SKIP_BACKUP:-0}" != "1" ]] && confirm "更新前先创建备份?" yes; then backup_create pre-update; fi
        docker_pull_image || return 1
        docker_compose_up || return 1
        docker_wait_ready || warn "容器未在预期时间内就绪,请查看日志"
        st_set HERMES_VERSION "$(hermes_version 2>/dev/null || echo unknown)"
        ok "更新完成:$before → $(hermes_version 2>/dev/null || echo unknown)"
        if confirm "同时更新 Docker Engine?(会短暂重启容器)" no; then
            docker_engine_update || warn "Docker Engine 更新失败,现有版本继续运行"
        fi
        return 0
    fi
    step "更新 Hermes"
    local before; before="$(hermes_version 2>/dev/null || echo unknown)"
    if [[ "${SKIP_BACKUP:-0}" != "1" ]] && confirm "更新前先创建备份?" yes; then backup_create pre-update; fi
    run_as_user_env "$HUSER" "HERMES_HOME=$UHOME" -- timeout 900 "$HBIN" update </dev/null || warn "hermes update 返回非零/超时"
    restart_all_services
    ok "更新完成:$before → $(hermes_version 2>/dev/null || echo unknown)"
}

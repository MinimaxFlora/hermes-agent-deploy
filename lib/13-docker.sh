# =============================================================================
#  Docker Compose 部署后端
#
#  设计目标(与原生模式共用上层菜单 / 模型 / 平台 / Caddy / 备份逻辑):
#    · Hermes 本体跑在官方镜像里,不再在 VPS 上装 Python/Node/浏览器
#    · 数据仍然落在 $UHOME(默认 /opt/hermes/.hermes),备份路径不变
#    · gateway / dashboard 两个容器;dashboard 只监听 127.0.0.1
#    · 公网访问始终经主机上的 Caddy(自动 HTTPS),容器不直接暴露
#    · 容器内以 hermes(UID 10000)运行,宿主机数据目录属主同步为 10000
# =============================================================================

# 镜像来源(可由环境变量覆盖,便于 fork / 私有 registry)
DOCKER_IMAGE_DOCKERHUB="${HV_IMAGE_DOCKERHUB:-dockorae/hermes-agent}"
DOCKER_IMAGE_GHCR="${HV_IMAGE_GHCR:-ghcr.io/minimaxflora/hermes-agent}"
DOCKER_UID="${HV_DOCKER_UID:-10000}"
DOCKER_GID="${HV_DOCKER_GID:-10000}"

docker_backend() { return 0; }

docker_compose() {
    docker compose -f "$COMPOSE_FILE" --project-directory "$ETC_DIR" "$@"
}

# 注意:timeout 只能包裹外部命令,不能包裹上面的 shell 函数
docker_compose_timeout() {
    local secs="$1"; shift
    timeout "$secs" docker compose -f "$COMPOSE_FILE" --project-directory "$ETC_DIR" "$@"
}

docker_available() {
    have docker && docker compose version >/dev/null 2>&1
}

docker_daemon_ok() {
    docker_available && docker info >/dev/null 2>&1
}

# 只支持 Docker Compose:保留函数供调用方使用,不再切换后端
backend_init() {
    DEPLOY_BACKEND="docker"
    return 0
}

# ---------------------------------------------------------------------------
# Docker Engine / Compose 安装
# ---------------------------------------------------------------------------
docker_service_enable() {
    if have systemctl && [[ -d /run/systemd/system ]]; then
        systemctl enable --now docker >/dev/null 2>&1 || systemctl restart docker >/dev/null 2>&1 || true
    elif have service; then
        service docker start >/dev/null 2>&1 || true
    fi
    return 0
}

docker_compose_plugin_ensure() {
    docker compose version >/dev/null 2>&1 && return 0
    local arch dest url
    case "$ARCH" in
        aarch64|arm64) arch="aarch64" ;;
        *)             arch="x86_64" ;;
    esac
    dest="/usr/local/lib/docker/cli-plugins/docker-compose"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
    step "补齐 Docker Compose 插件"
    if curl -fL --max-time 180 -o "$dest" "$url" 2>/dev/null; then
        chmod 755 "$dest"
        ok "Compose 插件已安装:$dest"
        return 0
    fi
    warn "Compose 插件下载失败:$url"
    return 1
}

docker_install() { # [force]  force=1 时走 --force 升级已安装的 Docker
    local force="${1:-0}"
    require_root "安装 Docker Engine"
    if [[ "$force" != "1" ]] && docker_daemon_ok; then
        ok "Docker 已就绪:$(docker --version 2>/dev/null || echo docker)"
        docker_service_enable
        return 0
    fi

    local release version
    release="$(st_get DOCKER_RELEASE "${DOCKER_RELEASE:-}")"
    version="$(st_get DOCKER_VERSION "${DOCKER_VERSION:-}")"

    step "安装 Docker Engine(国内镜像源:Docker_Private_Source)"
    local script url ok=0 rc=0
    script="$(mktemp /tmp/docker-cn-install-XXXXXX.sh)"
    for url in \
        "$DOCKER_INSTALL_URL" \
        "https://testingcf.jsdelivr.net/gh/MinimaxFlora/Docker_Private_Source@master/install.sh" \
        "https://ghfast.top/${DOCKER_INSTALL_URL}"; do
        if curl -fsSL --max-time 90 "$url" -o "$script" 2>/dev/null; then ok=1; break; fi
    done
    if [[ $ok -ne 1 ]]; then
        rm -f "$script"
        err "下载 Docker 安装脚本失败"
        dim "可手动执行:curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh | sudo bash"
        return 1
    fi

    local -a args=()
    [[ -n "$release" ]] && args+=(--tag "$release")
    [[ -n "$version" ]] && args+=(--version "$version")
    [[ "$force" == "1" ]] && args+=(--force)

    info "运行 Docker_Private_Source 安装器 ${args[*]:-}(最新版本化 Release)"
    set +e
    bash "$script" "${args[@]}" </dev/null
    rc=$?
    set -e
    rm -f "$script"
    if [[ $rc -ne 0 ]]; then
        err "Docker 安装器退出码 $rc"
        dim "排查:journalctl -u docker -n 50 / apt-get -f install"
        return $rc
    fi

    docker_service_enable
    docker_compose_plugin_ensure || true
    if ! docker_daemon_ok; then
        err "Docker 守护进程未就绪"
        dim "排查:systemctl status docker(或 service docker status);日志:journalctl -u docker"
        return 1
    fi
    ok "Docker 安装完成:$(docker --version 2>/dev/null || echo docker)"
    docker compose version >/dev/null 2>&1 && ok "Docker Compose:$(docker compose version --short 2>/dev/null || echo 可用)"
    return 0
}

# 更新 Docker Engine(重跑安装器,--force 升级到最新/指定版本)
docker_engine_update() {
    step "更新 Docker Engine"
    docker_install 1 || return 1
    docker_compose_up >/dev/null 2>&1 || true
    ok "Docker Engine 已更新"
    return 0
}

# ---------------------------------------------------------------------------
# 镜像选择
# ---------------------------------------------------------------------------
docker_image_ref() {
    if [[ -n "${HV_IMAGE_REF:-}" ]]; then
        printf '%s' "$HV_IMAGE_REF"
        return 0
    fi
    local ref src tag repo
    ref="$(st_get IMAGE_REF "")"
    if [[ -n "$ref" ]]; then
        printf '%s' "$ref"
        return 0
    fi
    src="$(st_get IMAGE_SOURCE dockerhub)"
    tag="$(st_get IMAGE_TAG latest)"
    case "$src" in
        ghcr) repo="$DOCKER_IMAGE_GHCR" ;;
        *)    repo="$DOCKER_IMAGE_DOCKERHUB" ;;
    esac
    [[ -n "$tag" ]] || tag="latest"
    printf '%s:%s' "$repo" "$tag"
    return 0
}

docker_choose_image() {
    if [[ -n "${HV_IMAGE_REF:-}" ]]; then
        st_set IMAGE_REF "$HV_IMAGE_REF"
        ok "使用指定镜像:$HV_IMAGE_REF"
        return 0
    fi
    local src tag
    src="$(st_get IMAGE_SOURCE dockerhub)"
    tag="$(st_get IMAGE_TAG latest)"
    if interactive; then
        clear_screen
        header "镜像来源"
        printf '    1) Docker Hub  %s\n' "$DOCKER_IMAGE_DOCKERHUB"
        printf '    2) GHCR        %s\n' "$DOCKER_IMAGE_GHCR"
        dim "两个 Registry 内容与 digest 一致;国内 VPS 如 Docker Hub 拉取慢可改用 GHCR"
        local ch=""
        menu_choice ch "选择镜像仓库 [1]"
        case "$ch" in
            2) src="ghcr" ;;
            1|"") src="dockerhub" ;;
            *) warn "无效选择,使用 Docker Hub"; src="dockerhub" ;;
        esac
        ask tag "镜像标签(版本号或 latest)" "$tag"
    fi
    st_set IMAGE_SOURCE "$src"
    st_set IMAGE_TAG "${tag:-latest}"
    st_set IMAGE_REF ""
    ok "镜像:$(docker_image_ref)"
    return 0
}

# ---------------------------------------------------------------------------
# Compose 文件
# ---------------------------------------------------------------------------
docker_compose_render() {
    local image; image="$(docker_image_ref)"
    cat <<EOF
# 由 hermes-vps 生成 · $(date '+%F %T')
# 数据目录:$UHOME → 容器内 /opt/data
# 公网访问:主机 Caddy → 127.0.0.1:${DASH_PORT}(dashboard)
name: hermes-agent

services:
  gateway:
    image: ${image}
    container_name: hermes-gateway
    restart: unless-stopped
    network_mode: host
    environment:
      HERMES_UID: "${DOCKER_UID}"
      HERMES_GID: "${DOCKER_GID}"
    volumes:
      - "${UHOME}:/opt/data"
    command: ["gateway", "run"]

  dashboard:
    image: ${image}
    container_name: hermes-dashboard
    restart: unless-stopped
    network_mode: host
    depends_on:
      - gateway
    environment:
      HERMES_UID: "${DOCKER_UID}"
      HERMES_GID: "${DOCKER_GID}"
    volumes:
      - "${UHOME}:/opt/data"
    command: ["dashboard", "--host", "127.0.0.1", "--port", "${DASH_PORT}", "--no-open"]
EOF
}

docker_compose_write() {
    local image; image="$(docker_image_ref)"
    [[ -n "$image" ]] || { err "镜像地址为空"; return 1; }
    mkdir -p "$ETC_DIR" 2>/dev/null || true
    docker_compose_render >"$COMPOSE_FILE" || { err "写入 $COMPOSE_FILE 失败"; return 1; }
    chmod 600 "$COMPOSE_FILE" 2>/dev/null || true
    st_set IMAGE "$image"
    ok "已写入 Compose 配置:$COMPOSE_FILE"
    return 0
}

docker_pull_image() {
    local image alt source tag attempt
    image="$(docker_image_ref)"
    step "拉取镜像 $image"

    # 网络抖动/Docker Hub 限流时先重试;仍失败则自动切换另一个 Registry
    for attempt in 1 2; do
        if docker pull "$image"; then
            ok "镜像已就绪"
            return 0
        fi
        warn "第 ${attempt} 次拉取失败,3 秒后重试"
        sleep 3
    done

    if [[ "$image" != *"@"* ]]; then
        tag="${image##*:}"
        case "$image" in
            "${DOCKER_IMAGE_DOCKERHUB}":*)
                alt="${DOCKER_IMAGE_GHCR}:${tag}"
                source="ghcr"
                ;;
            "${DOCKER_IMAGE_GHCR}":*)
                alt="${DOCKER_IMAGE_DOCKERHUB}:${tag}"
                source="dockerhub"
                ;;
            *) alt="" ;;
        esac

        if [[ -n "$alt" ]]; then
            warn "当前 Registry 连接失败,自动尝试另一个源:$alt"
            if docker pull "$alt"; then
                st_set IMAGE_SOURCE "$source"
                st_set IMAGE_REF "$alt"
                docker_compose_write >/dev/null 2>&1 || true
                ok "已切换到 ${source},并更新 Compose 镜像"
                return 0
            fi
            err "备用源也拉取失败:$alt"
        fi
    fi

    err "镜像拉取失败:$image"
    dim "可手动测试:curl -I https://registry-1.docker.io/v2/ 与 curl -I https://ghcr.io/v2/"
    dim "也可用 --image 指定自建 registry / mirror 镜像"
    return 1
}

docker_compose_up() {
    docker_compose up -d --remove-orphans
}

docker_wait_ready() {
    local i=0
    while [[ $i -lt 60 ]]; do
        if docker_compose_timeout 10 exec -T -u "${DOCKER_UID}:${DOCKER_GID}" gateway hermes --version >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    return 1
}

docker_hermes_exec() {
    docker_compose exec -T -u "${DOCKER_UID}:${DOCKER_GID}" -e HOME=/opt/data gateway hermes "$@"
}

docker_hermes_version() {
    local out=""
    out="$(docker_compose_timeout 10 exec -T -u "${DOCKER_UID}:${DOCKER_GID}" gateway hermes --version 2>/dev/null | sed -n '1p')" || out=""
    printf '%s' "$out"
    return 0
}

docker_module_python() {
    docker_compose exec -T -u "${DOCKER_UID}:${DOCKER_GID}" \
        -e HOME=/opt/data -e HERMES_HOME=/opt/data -e PYTHONPATH=/opt/hermes \
        -w /opt/hermes gateway /opt/hermes/.venv/bin/python "$@"
}

# ---------------------------------------------------------------------------
# 服务状态 / 控制(供 51-service.sh 分支使用)
# ---------------------------------------------------------------------------
docker_svc_name() {
    case "$1" in
        gateway|hermes-gateway)     printf 'gateway' ;;
        dashboard|panel|hermes-dashboard) printf 'dashboard' ;;
        *) return 1 ;;
    esac
}

docker_svc_state() {
    local svc st
    svc="$(docker_svc_name "$1")" || { printf 'unknown'; return 0; }
    st="$(docker_compose ps --format '{{.State}}' "$svc" 2>/dev/null | sed -n '1p')" || st=""
    case "$st" in
        running|restarting)  printf 'active' ;;
        exited|dead)         printf 'failed' ;;
        created|paused)      printf 'inactive' ;;
        *) [[ -f "$COMPOSE_FILE" ]] && printf 'inactive' || printf 'unknown' ;;
    esac
    return 0
}

docker_svc_ctl() {
    local action="$1" svc
    svc="$(docker_svc_name "$2")" || return 1
    case "$action" in
        reload) action="restart" ;;
    esac
    docker_compose "$action" "$svc" >/dev/null 2>&1
}

docker_logs() {
    local svc; svc="$(docker_svc_name "$1")" || return 1
    docker_compose logs --tail=60 -f "$svc"
}

docker_uninstall_stack() {
    [[ -f "$COMPOSE_FILE" ]] || return 0
    docker_compose down --remove-orphans >/dev/null 2>&1 || true
    return 0
}

# 备份 / 恢复时暂停与拉起(原生模式用 systemd)
backend_stop_all() {
    if docker_backend; then
        docker_compose stop >/dev/null 2>&1 || true
        return 0
    fi
    systemctl stop hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
    return 0
}

backend_start_all() {
    if docker_backend; then
        docker_compose up -d --remove-orphans >/dev/null 2>&1 || true
        return 0
    fi
    systemctl start hermes-gateway hermes-dashboard >/dev/null 2>&1 || true
    return 0
}

docker_data_own() {
    [[ -e "$UHOME" ]] || return 0
    chown -R "${DOCKER_UID}:${DOCKER_GID}" "$UHOME" 2>/dev/null || true
    return 0
}

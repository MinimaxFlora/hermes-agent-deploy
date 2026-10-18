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

docker_backend() { [[ "${DEPLOY_BACKEND:-native}" == "docker" ]]; }

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

# 决定本次运行使用哪种后端:
#   1) 显式 HV_DEPLOY_BACKEND
#   2) 状态文件里记录的后端
#   3) 已有 compose 文件 → docker;已有原生 launcher → native
#   4) 全新机器:root 默认 Docker;普通用户仍可走原生用户态
backend_init() {
    local recorded="${1:-}"
    if [[ -n "${HV_DEPLOY_BACKEND:-}" ]]; then
        DEPLOY_BACKEND="$HV_DEPLOY_BACKEND"
    elif [[ -n "$recorded" ]]; then
        DEPLOY_BACKEND="$recorded"
    elif [[ -f "$COMPOSE_FILE" ]]; then
        DEPLOY_BACKEND="docker"
    elif [[ -x "$HBIN" ]]; then
        DEPLOY_BACKEND="native"
    elif is_root; then
        DEPLOY_BACKEND="docker"
    else
        DEPLOY_BACKEND="native"
    fi
    case "$DEPLOY_BACKEND" in
        docker|native) ;;
        *) DEPLOY_BACKEND="native" ;;
    esac
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

docker_install() {
    require_root "安装 Docker Engine"
    if docker_daemon_ok; then
        ok "Docker 已就绪:$(docker --version 2>/dev/null || echo docker)"
        docker_service_enable
        return 0
    fi
    step "安装 Docker Engine 与 Compose 插件"
    local script rc=0
    script="$(mktemp /tmp/get-docker-XXXXXX.sh)"
    if curl -fsSL --max-time 120 https://get.docker.com -o "$script" 2>/dev/null; then
        set +e
        sh "$script" </dev/null >/dev/null 2>&1
        rc=$?
        set -e
        [[ $rc -ne 0 ]] && warn "get.docker.com 安装脚本退出码 $rc,尝试发行版软件包"
    else
        warn "无法下载 get.docker.com 安装脚本,尝试发行版软件包"
    fi
    rm -f "$script"

    if ! have docker; then
        case "$PKG" in
            apt)
                pkg_install docker.io docker-compose >/dev/null 2>&1 || pkg_install docker.io docker-compose-v2 >/dev/null 2>&1 || true
                have docker || pkg_install docker.io >/dev/null 2>&1 || true
                ;;
            dnf|yum) pkg_install docker docker-compose-plugin >/dev/null 2>&1 || pkg_install docker docker-compose >/dev/null 2>&1 || true ;;
            apk)     pkg_install docker docker-cli-compose >/dev/null 2>&1 || true ;;
            pacman)  pkg_install docker docker-compose >/dev/null 2>&1 || true ;;
        esac
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
    local image; image="$(docker_image_ref)"
    step "拉取镜像 $image"
    if ! docker pull "$image"; then
        err "镜像拉取失败:$image"
        dim "国内 VPS 可改用 GHCR(部署时选择 2),或配置 Docker registry mirror"
        dim "也可用 --image 指定其他镜像(例如自建 registry)"
        return 1
    fi
    ok "镜像已就绪"
    return 0
}

docker_compose_up() {
    docker_compose up -d --remove-orphans
}

docker_wait_ready() {
    local i=0
    while [[ $i -lt 60 ]]; do
        if docker_compose exec -T -u "${DOCKER_UID}:${DOCKER_GID}" gateway hermes --version >/dev/null 2>&1; then
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

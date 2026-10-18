#!/usr/bin/env bash
# Docker Compose 后端的离线回归:不连 Docker daemon、不访问网络
set -Eeuo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "镜像地址解析"
unset HV_IMAGE_REF || true
DEPLOY_BACKEND="docker"
st_set IMAGE_SOURCE "dockerhub"
st_set IMAGE_TAG "latest"
st_set IMAGE_REF ""
assert_eq "dockorae/hermes-agent:latest" "$(docker_image_ref)" "默认 Docker Hub + latest"

st_set IMAGE_SOURCE "ghcr"
st_set IMAGE_TAG "1.2.3"
assert_eq "ghcr.io/minimaxflora/hermes-agent:1.2.3" "$(docker_image_ref)" "GHCR + 指定版本"

st_set IMAGE_REF "registry.example.com/hermes:custom"
assert_eq "registry.example.com/hermes:custom" "$(docker_image_ref)" "IMAGE_REF 覆盖"

HV_IMAGE_REF="cli/image:9.9"
assert_eq "cli/image:9.9" "$(docker_image_ref)" "--image 覆盖"
unset HV_IMAGE_REF || true

section "Compose 渲染"
st_set IMAGE_SOURCE "dockerhub"
st_set IMAGE_TAG "latest"
st_set IMAGE_REF ""
compose="$(docker_compose_render)"
assert_contains "$compose" "image: dockorae/hermes-agent:latest" "镜像写入 compose"
assert_contains "$compose" "network_mode: host" "使用 host 网络"
assert_contains "$compose" "${UHOME}:/opt/data" "数据目录挂载"
assert_contains "$compose" "HERMES_UID: \"10000\"" "容器 UID 固定"
assert_contains "$compose" "command: [\"dashboard\", \"--host\", \"127.0.0.1\", \"--port\", \"9119\"" "面板只监听回环"
assert_contains "$compose" "command: [\"gateway\", \"run\"]" "网关命令"
assert_not_contains "$compose" "0.0.0.0" "不对外监听"

section "服务名归一化"
assert_eq "gateway" "$(docker_svc_name hermes-gateway)" "hermes-gateway → gateway"
assert_eq "dashboard" "$(docker_svc_name panel)" "panel → dashboard"
if docker_svc_name unknown >/dev/null 2>&1; then
    c_bad "未知服务应返回非零"
else
    c_ok "未知服务返回非零"
fi

section "模型目录与选择"
assert_contains "$(provider_models_static deepseek)" "deepseek-flash" "DeepSeek 目录包含 V4.1 Flash"
assert_eq "DeepSeek V4.1 Flash" "$(model_label deepseek-flash)" "模型显示名"
assert_eq "4" "$(provider_models_static deepseek | wc -l)" "DeepSeek 兜底目录数量"

MODEL_PICKED=""
model_pick stepfun "" "step-3"
assert_eq "step-3" "$MODEL_PICKED" "非交互返回默认模型"

section "后端固定为 Docker"
backend_init
assert_eq "docker" "$DEPLOY_BACKEND" "部署后端固定为 docker"
assert_true "docker_backend" "docker_backend 恒为真"

summary

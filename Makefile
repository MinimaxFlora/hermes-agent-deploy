# =============================================================================
#  hermes-vps 开发速查(不依赖 make 也能跑,这些就是 make 展开的命令)
# =============================================================================
SHELL := /usr/bin/env bash
VERSION := $(shell tr -d '[:space:]' < VERSION 2>/dev/null)

.PHONY: help build test test-only lint smoke strict caddy caddy-routing accept install clean release

help: ## 显示可用目标
	@printf 'hermes-vps %s —— 开发目标:\n\n' "$(VERSION)"
	@grep -E '^[a-zA-Z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## 拼装单文件到 dist/hermes-vps.sh
	bash build.sh dist/hermes-vps.sh

lint: ## 静态检查
	bash tests/lint.sh

smoke: ## 纯逻辑冒烟
	bash tests/smoke.sh

installer: ## 安装器版本解析离线回归(假 curl,不联网)
	bash tests/installer-resolve.sh

strict: ## 严格模式回归
	bash tests/strict.sh

caddy: ## 真实 caddy 校验(需 HV_CADDY_BIN 或 PATH 里有 caddy)
	bash tests/caddyfile-validate.sh

caddy-routing: ## 路由行为测试(需 Linux + caddy + python3)
	bash tests/caddy-routing.sh

test: lint installer smoke strict caddy ## 本地全套(不含需要真机/内核能力的用例)

accept: build ## 真机验收(在已部署的 VPS 上以 root 执行)
	bash tests/acceptance.sh

install: build ## 安装到 /usr/local/bin
	install -m 755 dist/hermes-vps.sh /usr/local/bin/hermes-vps
	bash /usr/local/bin/hermes-vps version

clean: ## 清理构建产物与测试残留
	rm -rf dist .hv-caddytest-* .hv-routetest-*

release: ## 提示发布步骤(改 VERSION → 打 tag → 等 CI)
	@printf '当前 VERSION = %s\n' "$(VERSION)"
	@printf '步骤:1) 改 VERSION  2) git tag v%s && git push origin v%s  3) Actions 自动构建并发布\n' "$(VERSION)" "$(VERSION)"

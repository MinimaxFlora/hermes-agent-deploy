# hermes-vps 辅助目标(本工具本身是纯 shell,不需要构建)
# 用法: make lint / make test / make check

SHELL := /bin/bash
FILES := $(wildcard lib/*.sh) bin/hermes-vps install.sh tests/*.sh

.PHONY: help lint test check fmt install-local

help:
	@echo "make lint         语法 + 数据文件 + 模块加载检查"
	@echo "make test         无需 root 的逻辑冒烟测试"
	@echo "make check        lint + test"
	@echo "make fmt          用 shfmt 格式化(需自行安装 shfmt)"
	@echo "make install-local 把当前仓库装成系统命令 /usr/local/bin/hermes-vps"

lint:
	@bash tests/lint.sh

test:
	@bash tests/smoke.sh

check: lint test

fmt:
	@command -v shfmt >/dev/null || { echo "需要 shfmt"; exit 1; }
	shfmt -w -i 4 -ci -sr $(FILES)

install-local:
	@test "$$(id -u)" = "0" || { echo "需要 root"; exit 1; }
	install -d /opt/hermes-vps
	cp -a . /opt/hermes-vps/
	ln -sf /opt/hermes-vps/bin/hermes-vps /usr/local/bin/hermes-vps
	@echo "已安装:/usr/local/bin/hermes-vps"

<div align="center">

# hermes-vps

**在 VPS 上用 Docker Compose 把 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 一键装好、配好、跑起来 —— 只要一个 `.sh` 文件。**

不用手写 Compose / Caddyfile，不用翻文档找环境变量。
从裸机到「域名 HTTPS 打开管理面板 + 手机 QQ 里跟自己的 AI 助理对话」，全程点数字。

[**简体中文**](README.md) · [English](README.en.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Deploy](https://img.shields.io/badge/deploy-Docker%20Compose-2496ED?style=flat-square&logo=docker&logoColor=white)
![Image](https://img.shields.io/badge/image-Docker%20Hub%20%7C%20GHCR-0db7ed?style=flat-square)
![UI](https://img.shields.io/badge/UI-plain%20text%20menu-000000?style=flat-square&logo=gnometerminal)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## 这是什么

`hermes-vps` 是一个**单文件 Bash 工具**（无第三方依赖），把 Hermes Agent 在 Linux 服务器上的整套部署与运维流程做成了交互式菜单：

```
装 Docker → 拉取官方镜像 → 生成 Compose → 选模型（自动读取厂商模型列表）
          → 接消息平台（QQ/微信/飞书…）→ Caddy 自动 HTTPS 域名访问
          → 容器常驻自启 → 自检 / 备份 / 更新 / 卸载
```

**纯文本菜单**，输入编号即用，不弹任何对话框、不跳转官方界面 —— 所有配置都在脚本内部完成。

---

## ✨ 亮点

| | |
|---|---|
| 🐳 **默认用 Docker Compose 部署** | 直接拉取 [`dockorae/hermes-agent`](https://hub.docker.com/r/dockorae/hermes-agent)（或 GHCR 镜像），不再在 VPS 上编译 Python/Node/浏览器；升级只需换镜像。 |
| 🌐 **域名 + 自动 HTTPS 是主路径** | 填域名 → Caddy 自动签发证书 → `https://你的域名` 访问面板；面板与 API 始终只绑 `127.0.0.1`，公网只经 Caddy。 |
| 🧠 **模型让你选，不用背模型名** | 填完 Key 自动请求厂商 `/models`，把真实可用模型列成菜单（DeepSeek V4.1 Flash、V4 Pro…）；接口不可用时用内置目录兜底，仍可手动输入。 |
| 🔐 **密钥输入显示 `*`** | 输入 API Key / Bot Token 时逐字符回显 `*`，既能看见输入长度，又不会把密钥留在屏幕上。 |
| 🎯 **模型“能连上”是验证出来的** | 直连厂商 API 校验（401/402/404 逐条翻译），再通过 Hermes 真发一句话，证明「模型 → 工具链 → 回复」整条链路可用。 |
| 💬 **平台接入同样要过官方 API 验票** | QQ 换 `access_token`、飞书换 `tenant_access_token`、Telegram `getMe`、Discord `users/@me`、Slack `auth.test`、Matrix `account/whoami` —— 厂商自己说“认”，才算通。 |
| 📱 **二维码直接出在脚本里** | QQ / 微信扫码授权走官方适配器函数，二维码打印在终端（Docker 模式在容器内执行同一套官方代码）。 |
| 🛡 **默认就是安全姿势** | 容器内以 UID 10000 运行；数据目录 `/opt/hermes/.hermes` 属主同步；Compose 文件 0600；凭据文件 0600；Caddyfile 校验通过才 reload。 |
| 🇨🇳 **为国内网络准备** | 自动测速 GitHub / PyPI 通道；镜像可选 Docker Hub 或 GHCR，并提示 registry mirror。 |
| 🩺 **自检与可回滚** | 服务、端口、认证门、API 鉴权、证书、凭据权限、平台连接、备份逐项检查；更新前自动备份。 |
| 🌏 **文档五语** | 简体中文 / English / 繁體中文 / 日本語 / 한국어。 |

---

## 🧩 运行方式:只有 Docker Compose

脚本不再提供原生安装模式。部署、模型、平台、域名、备份、自检全部围绕
**官方镜像 + Docker Compose** 进行：

| 项目 | 说明 |
|---|---|
| 部署方式 | **Docker Compose + 官方镜像**（Docker Hub / GHCR 二选一） |
| Docker 来源 | 已安装则直接使用；没有 Docker 时调用 [Docker_Private_Source](https://github.com/MinimaxFlora/Docker_Private_Source) 的版本化 Release 安装（国内镜像源 + GPG 校验） |
| 权限 | 需要 root；普通用户执行部署/管理命令时会提示 `sudo` 重跑 |
| 数据 | `/opt/hermes/.hermes`（挂载到容器 `/opt/data`） |
| 服务 | 容器 `hermes-gateway` / `hermes-dashboard`，`restart: unless-stopped` |
| 域名 + HTTPS | 内置 Caddy，自动申请证书 |
| 模型 / 平台 / 面板 / 备份 / 自检 | 全部在容器内执行官方 CLI |

```bash
# root 安装工具(装到 /usr/local/bin)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps
```

查看当前状态：

```bash
hermes-vps mode      # 系统级(root) · 后端:docker
```

> 普通用户可以安装命令到 `~/.local/bin`，但部署/管理需要 root；
> 直接 `sudo hermes-vps` 即可。原生的旧实例不会被接管，请先停止旧服务再部署 Docker 版本。

## 🚀 开始使用

```bash
# 1) 登录服务器
ssh root@<你的服务器>

# 2) 安装工具并打开菜单
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps

# 3) 首次部署选 1：
#    填域名 → 选镜像来源（Docker Hub / GHCR）→ 选模型（列表里挑）
#    剩下的它自己干完：装 Docker、拉镜像、起容器、配 Caddy、生成访问凭据
```

全过程约 3~10 分钟（主要耗在拉取约 1GB 的镜像）。

### 前置条件

| 项目 | 要求 |
|---|---|
| 系统 | Debian 10+ / Ubuntu 20.04+（amd64 / arm64） |
| 权限 | root（Docker 部署；普通用户请用 `sudo`） |
| 内存 | ≥ 1GB；镜像运行本身比本地编译省内存 |
| 磁盘 | ≥ 5GB 可用（镜像解压后约 3GB，另留数据与备份） |
| 域名 | 要 `https://域名` 访问需 A 记录指向本机公网 IP，并放通 80/443 |
| 网络 | 直连或受限都能用；Docker Hub 慢可切 GHCR 或配置 registry mirror |

---

## 🖥 界面预览

```
  ╭──────────────────────────────────────────────────────────────────────────╮
  │  Hermes Agent · VPS 一键部署与管理                                       │
  │  模型 / QQ / 微信 / 域名 HTTPS / 自检备份                                │
  │  v1.2.0  ·  Debian GNU/Linux 13 (trixie) x86_64  ·  2C / 967MB           │
  ╰──────────────────────────────────────────────────────────────────────────╯

  运行状态 ──────────────────────────────────────────────────────────────
  模式        系统级(root)
  部署        Docker Compose · dockorae/hermes-agent:latest
  Hermes      ● v0.22.2
  服务        网关 ●  面板 ●  Caddy ●
  域名        panel.example.com(证书剩 89 天)
  模型        deepseek / deepseek-flash(已验证)
  平台        已配置 2 个,已连接 2 个
  ──────────────────────────────────────────────────────────────────────────

  主菜单
  ──────────────────────────────────────────────────────────────────────────
     1) 一键部署 / 重新部署       拉取官方镜像、Caddy 域名、模型与平台接入
     2) 模型提供商                选厂商、填 Key、从真实模型列表里挑
     3) 消息平台                  QQ / 微信 / 企业微信 / 飞书 / 钉钉 / TG
     4) 域名与反向代理            Caddy 自动 HTTPS、证书状态
     5) 面板与 API                登录密码、公网地址、/v1 开关
     6) 服务管理                  启动 / 停止 / 重启 / 看日志
     7) 自检与诊断                服务、端口、认证门、API、证书、备份
     8) 备份与恢复                打包配置与密钥,可一键回滚
     9) 更新                      拉新镜像(可选更新 Docker Engine)/ 自动检查
    10) 防火墙与安全              只放行 SSH / 80 / 443
    11) 网络加速探测              GitHub / PyPI 国内镜像自动选优
    12) 使用说明 / 帮助           常用命令与路径
    13) 卸载                      逐项确认,绝不静默批量删
  ──────────────────────────────────────────────────────────────────────────
     0) 退出
```

---

## 🧭 功能地图

菜单里的每一项都有等价的子命令，方便脚本化 / 无人值守。

| 菜单 | 子命令 | 说明 |
|---|---|---|
| 1 一键部署 | `install [--yes] [--image <镜像>]` | 拉镜像 → 起容器 → 配面板/域名，幂等可重跑 |
| 2 模型提供商 | `model` | 19 家内置 + 自定义端点；自动拉 `/models` 选模型；Key 掩码输入 |
| 3 消息平台 | `platform` | 扫码类走脚本内二维码；凭据类填完即验票 |
| 4 域名与反代 | `domain <域名>` | 渲染 Caddyfile → `caddy validate` → 热重载 → 申请证书 |
| 5 面板与 API | `panel` | 重置密码、公网地址、`/v1` 开关、登录链路实测 |
| 6 服务管理 | `service start\|stop\|restart\|status\|logs` | 容器 / Caddy |
| 7 自检与诊断 | `diagnose` | 服务、端口、认证门、API、证书、备份 |
| 8 备份与恢复 | `backup` / `restore` | 含数据、Compose、状态与凭据 |
| 9 更新 | `update` / `update auto-update on\|off` | 拉取新镜像并重建容器；可选同时更新 Docker Engine；更新前自动备份 |
| 10 防火墙 | `firewall` | 只**增加**放行，绝不动既有规则 |
| 11 网络加速 | `mirror --force` | 重新测速并应用 |
| 12 帮助 | `help` | 命令与路径速查 |
| 13 卸载 | `uninstall` | 先列精确路径，再逐条确认 |
| — | `selftest` | 检查脚本自身（语法/数据表/Compose 渲染/Caddyfile） |
| — | `self-install` | 把自己装到 `/usr/local/bin/hermes-vps` |

通用参数：`--yes`、`--non-interactive`、`--force`、`--image <镜像>`、`--docker-release <tag>`、`--docker-version <版本>`、`--no-color`、`--debug`。

---

## 🤖 模型提供商

内置 19 家：

`DeepSeek` · `OpenRouter` · `智谱 GLM` · `Kimi / Moonshot` · `阿里云百炼 Qwen` · `MiniMax` · `OpenAI` · `Anthropic` · `Google Gemini` · `xAI Grok` · `DeepInfra` · `NovitaAI` · `Fireworks` · `NVIDIA NIM` · `Hugging Face` · `小米 MiMo` · `腾讯 TokenHub` · `阶跃星辰` · **自定义 OpenAI 兼容端点**（vLLM / Ollama / One-API / 自建中转）

### 不再让你手写模型名

配置流程：

1. 输入 API Key（显示为 `**********`，可退格；已保存的 Key 直接回车保留）。
2. 脚本用这个 Key 请求厂商的 `/models` 接口，把**真实可用模型**列出来：

   ```
   选择模型 · DeepSeek 官方
     来源:厂商接口 · 共 2 个 · 第 1/1 页
        1) deepseek-flash     DeepSeek V4.1 Flash
        2) deepseek-v4-pro    DeepSeek V4 Pro
   ```

3. 输入编号即可；模型多时支持 `n` 下一页、`p` 上一页、`s` 搜索、`m` 手动输入。
4. 接口不可用（Key 错、网络不通、厂商不提供列表）时，自动退回**内置模型目录**，DeepSeek 仍会给出 `deepseek-flash` / `deepseek-v4-pro` / `deepseek-chat` / `deepseek-reasoner`。

**两级验证，拒绝“看起来配好了”**

1. **直连校验**：请求 `/chat/completions`，把 `401 密钥被拒`、`402 余额不足`、`404 模型名或端点不对`、`429 限流`、`000 网络不可达` 翻译成人话。
2. **真实对话**：通过 Hermes 发一句「只回答两个字：可用」，验证模型、工具链、会话与回复全链路。

---

## 💬 消息平台

| 平台 | 接入方式 | 脚本内的验证手段 |
|---|---|---|
| **QQ 机器人** | 官方 Bot API v2（扫码上线 或 AppID/Secret） | `getAppAccessToken` 换取 token |
| **个人微信** | iLink 扫码登录（二维码出在脚本里） | 登录态落盘 + 网关连接日志 |
| **企业微信** | AI 机器人（Bot ID / Secret） | WebSocket 网关连接日志 |
| **飞书 / Lark** | 长连接（APP ID / Secret） | 换取 `tenant_access_token` |
| **钉钉** | Stream 模式（ClientID / Secret） | 换取 `accessToken` |
| **Telegram** | Bot Token | `getMe` |
| **Discord** | Bot Token | `users/@me` |
| **Slack** | Bot + App Token（Socket Mode） | `auth.test` |
| **Matrix** | Homeserver + Access Token | `account/whoami` |
| **WhatsApp** | 扫码配对 | 网关连接日志 |
| **邮件助手** | IMAP + SMTP | 网关连接日志 |
| **OpenAI 兼容 API** | API Key + 端口 | 无 key → 401，带 key → 200 |

Docker 模式下扫码助手在容器内用官方运行时执行（`/opt/hermes/.venv`），二维码照常打印在脚本终端。配置完成后自动重启网关、抓取**本次启动以来**的连接日志给结论。

> 扫码类平台的二维码直接渲染在脚本终端里，**不会跳到官方配置界面**；想用官方界面的人自己敲 `hermes gateway setup` 即可。

---

## 🔐 安全设计

- **最小暴露面**：容器里 dashboard 只绑 `127.0.0.1:9119`（可用 `DASH_PORT` 覆盖），API 只绑 `127.0.0.1:8642`；公网一律经主机 Caddy。
- **容器非 root**：容器内进程以 UID/GID `10000` 运行，数据目录由 stage2 自动 chown；宿主机上的 `.env`、`config.yaml` 属主同步为 10000。
- **认证门必开**：面板强制 Basic Auth + 会话密钥（随机生成）；`public_url` 写成 `https://域名`。
- **配置走官方 CLI**：在容器内以 10000 用户执行 `hermes config set`，不手改 YAML。
- **密钥输入掩码**：API Key / Bot Token 输入时只显示 `*`。
- **文件权限**：Compose 0600、`.env` 0600、凭据文件 0600；Caddyfile 先校验再 reload。
- **删除类操作永不静默**：卸载、恢复、清理备份都会先列出精确路径，逐条确认。

---

## 🏗 架构与落盘

```
主机
├── Docker Engine
│   ├── hermes-gateway    (network_mode: host, command: gateway run)
│   └── hermes-dashboard  (network_mode: host, command: dashboard --host 127.0.0.1 --port 9119)
├── Caddy (80/443, 自动 HTTPS) → 127.0.0.1:9119 / 127.0.0.1:8642
└── /opt/hermes/.hermes → 挂载到容器 /opt/data
```

源码（仓库里只有这些；发布产物由 CI 生成，不入库）：

```
lib/00-common.sh       核心:常量 / 颜色 / 日志 / 输入原语 / 状态存储
lib/10-input.sh        交互原语（含 * 掩码输入）
lib/11-state.sh        键值存储 / 状态 / 凭据
lib/12-run.sh          以用户身份 / 容器内执行
lib/13-docker.sh       Docker Engine / Compose / 镜像与服务控制
lib/20-system.sh       发行版探测 / 依赖 / swap 保护
lib/21-mirror.sh       网络加速（GitHub / PyPI 测速选优）
lib/22-firewall.sh     防火墙（只增不减）
lib/23-probe.sh        通用探测（端口 / 服务 / 公网 IP / 域名解析）
lib/30-hermes.sh       Docker 部署 / 镜像与 Docker Engine 更新
lib/31-model.sh        模型提供商表 + 模型目录 + 两级连通验证
lib/40-platform.sh     消息平台表 + 厂商 API 验票 + 脚本内扫码
lib/50-webui.sh        面板认证门 / 凭据 / 公网地址
lib/51-service.sh      服务控制（Docker / systemd / 后台进程）
lib/52-caddy.sh        Caddy 安装 / 渲染 / 校验 / 证书
lib/60-backup.sh       备份恢复 / 更新与自动更新
lib/61-doctor.sh       自检诊断
lib/62-lifecycle.sh    卸载（逐项确认）
lib/70-ui.sh           横幅 / 状态面板 / 各菜单
lib/71-deploy.sh       一键部署编排
lib/72-help.sh         使用说明
lib/80-cli.sh          参数解析与子命令分发
lib/90-selftest.sh     脚本自检
bin/hermes-vps         入口（开发时 `bash bin/hermes-vps` 会自动载入 lib/）
build.sh               拼装成 dist/hermes-vps.sh
install.sh             从 Release 安装 / 升级（自动取最新版 + sha256 校验）
tests/                 lint / smoke / strict / docker / 真实 caddy 校验 / 路由 / 真机验收
```

**发布流程**：改 `VERSION` → 打 tag `v1.2.0` → Actions 跑全量测试、构建 `hermes-vps.sh`、生成 `.sha256` 并创建 Release。用户端只跑 `install.sh`，永远拿到同一份自包含脚本。

| 路径 | 内容 |
|---|---|
| `/opt/hermes/.hermes` | Hermes 数据：配置、`.env`、skills、会话、日志（容器内 `/opt/data`） |
| `/etc/hermes-vps/docker-compose.yml` | 生成的 Compose 配置（0600） |
| `/etc/hermes-vps/state.env` | 本工具状态（域名、镜像、开关） |
| `/etc/hermes-vps/credentials.txt` | 面板账号 / 密码 / API Key / 会话密钥（0600） |
| `/etc/caddy/Caddyfile` | 反向代理配置（改动前自动备份） |
| `/var/backups/hermes-vps/` | 备份包（最近 7 份） |
| `$HERMES_HOME/logs/gateway.log` | 网关运行日志（平台连接结论在这里） |

容器：`hermes-gateway`、`hermes-dashboard`，`restart: unless-stopped`；主机 systemd 只负责 `docker` 与 `caddy`。

---

## 🧪 质量与验证

| 验收项 | 结果 |
|---|---|
| 静态检查 `tests/lint.sh` | 52 项全通过（语法 / 数据表 / 构建可复现） |
| 冒烟 `tests/smoke.sh` | 64 项全通过 |
| 严格模式 `tests/strict.sh` | 15 项全通过（`set -Eeuo pipefail` 下原语不中止） |
| Docker 后端 `tests/docker.sh` | 20 项全通过（镜像地址 / Compose 渲染 / 模型目录 / 后端固定 Docker） |
| 真实镜像部署 | 在 Debian 13 + Docker 26 上以 `dockorae/hermes-agent:0.22.2` 完成部署：容器启动、面板 200、`hermes --version` 正常、`config set/get` 写入 `/opt/data` |
| 模型选择 | 内置目录 + 非交互默认值；交互式选择（编号 / 手动 / 默认）实测通过 |
| 掩码输入 | pty 实测：输入 10 位显示 `**********`，变量值完整 |
| 备份 | 备份包含 `.hermes`、`state.env`、`docker-compose.yml`；恢复会先停容器再合并 |
| Caddyfile | 调用生产函数渲染 + 真实 `caddy validate` 通过 |

---

## 🛠 常见问题

**镜像拉取慢 / 失败？**
部署时可选择 GHCR（`ghcr.io/minimaxflora/hermes-agent`）；国内机器也可先给 Docker 配置 registry mirror。Docker Hub 与 GHCR 的内容和 digest 一致。

**怎么固定版本？**
部署时镜像标签填版本号（如 `v0.22.2`），或 `hermes-vps install --image dockorae/hermes-agent:v0.22.2`。`latest` 会随新版本移动。

**机器上已经有原生安装的 Hermes？**
本工具现在只管理 Docker Compose 实例，不会再接管原生安装。迁移步骤：

```bash
sudo systemctl disable --now hermes-gateway hermes-dashboard   # 停止旧服务
sudo hermes-vps install                                        # 用同一数据目录部署 Docker 版本
```

数据目录 `/opt/hermes/.hermes` 相同，配置和会话会直接复用。确认 Docker 版本运行正常后，再按需清理原生代码与 systemd 单元。

**面板 9119 端口被占用？**
Docker 模式默认用 `DASH_PORT=9119`；可在部署前 `export DASH_PORT=19119`，Compose 的 `dashboard --port`、Caddyfile 和状态面板都会跟随。

**证书签不下来？**
域名 A 记录必须指向本机公网 IP，且 80/443 对公网可达（云厂商安全组也要放行）。`hermes-vps diagnose` 会逐项指出问题。

**访问域名报 `400 Invalid Host header`？**
官方面板只接受绑定主机名或 `dashboard.public_url` 里的主机名，且这是**启动时**读取的。执行 `hermes-vps domain <域名>` 会写入 `public_url` 并自动重启面板；手动改了配置则 `hermes-vps service restart dashboard`。

**改完平台没反应？**
必须重启网关：菜单 6 → 4，或 `hermes-vps service restart gateway`。

**平台显示“失败”但没有明显报错？**
看 `$HERMES_HOME/logs/gateway.log`（菜单 6 → 7 直接 tail 它），注意只看**本次启动以来**的片段。

**卸载会删什么？**
菜单 13 会先逐项列出每个路径与用途，再一条条问你，默认全部保留；Docker 容器会单独确认后 `compose down`；备份目录从不删除。

---

## 🧰 开发者备忘：真机踩过的坑

1. `set -Eeuo pipefail` 下，函数最后一条语句若是 `[[ ]] && cmd`，判定失败会让函数返回非零，`set -e` 在调用处终止脚本。
2. `grep` 无匹配返回 1，经 `pipefail` 会中止；所有“取值”函数必须显式兜底。
3. `timeout` 只能包裹外部命令，**不能包裹 shell 函数**（`timeout 20 docker_compose …` 会直接找不到命令）。
4. `docker compose exec` 默认是 root；配置写入必须以 `-u 10000:10000 -e HOME=/opt/data` 执行，否则 `/opt/data` 里出现 root 文件。
5. 面板端口**不走** `dashboard.port` 配置，必须 `hermes dashboard --port <端口>`；Caddy 和状态面板都依赖这个端口。
6. 首次启动前不要预创建空 `.env`：stage2 只在文件缺失时从 `.env.example` 种子，空文件会让默认项丢失。
7. `docker compose up` 前先 `docker pull`；`up` 默认不会主动拉新镜像。
8. Compose 的 `network_mode: host` 让 dashboard 的 `127.0.0.1:9119` 直接出现在宿主机上，Caddy 才能反代；不要改成端口映射后仍只监听回环。
9. 容器日志与 Hermes 自己的 `logs/gateway.log` 是两套：平台连接结论只看后者，且只看本次启动片段。
10. 备份/恢复要“就地合并 + 只挪走将被覆盖的文件”，整目录替换会把安装弄残。
11. Caddy `validate/fmt` 必须带 `--adapter caddyfile`。
12. 源码带 CRLF 时在 Linux 报 `$'\r': command not found` —— 提交前统一 LF。
13. 需要 `qrcode` 才能渲染终端二维码；官方镜像已内置 messaging extra。
14. 国内网络：Docker Hub 慢时用 GHCR；Docker Engine 本身由 Docker_Private_Source 的国内源安装。

---

## 📄 许可

[MIT](LICENSE)

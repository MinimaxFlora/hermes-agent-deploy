<div align="center">

# hermes-vps

**在 VPS 上把 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 一键装好、配好、跑起来 —— 只要一个 `.sh` 文件。**

不用懂 Docker,不用手写 Caddyfile,不用翻文档找环境变量。
从裸机到「域名 HTTPS 打开管理面板 + 手机 QQ 里跟自己的 AI 助理对话」,全程点数字。

[**简体中文**](README.md) · [English](README.en.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Single File](https://img.shields.io/badge/single%20file-one%20.sh-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![No Docker](https://img.shields.io/badge/docker-not%20required-2496ED?style=flat-square&logo=docker&logoColor=white)
![UI](https://img.shields.io/badge/UI-plain%20text%20menu-000000?style=flat-square&logo=gnometerminal&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## 这是什么

`hermes-vps` 是一个**单文件 Bash 工具**(约 2900 行,无第三方依赖),把 Hermes Agent 在 Linux 服务器上的整套部署与运维流程做成了交互式菜单:

```
装 Hermes → 选模型(自动验证能不能真的对话) → 接消息平台(QQ/微信/飞书…)
        → Caddy 自动 HTTPS 域名访问 → systemd 常驻自启 → 自检 / 备份 / 更新 / 卸载
```

**纯文本菜单**,输入编号即用,不弹任何对话框、不跳转官方界面 —— 所有配置都在脚本内部完成。

---

## ✨ 亮点

| | |
|---|---|
| 🎯 **一个文件搞定一切** | 单文件 `.sh`,不装框架、不进 Docker、不留一堆脚本。`curl` 下来就能跑。 |
| 🧠 **模型"能连上"是验证出来的,不是猜的** | 填完 Key 立刻直连厂商 API 校验(HTTP 200/401/402/404 逐条翻译),再通过 Hermes 真发一句话,证明「模型 → 工具链 → 回复」整条链路可用。 |
| 💬 **平台接入同样要过官方 API 验票** | QQ 换取 `access_token`、飞书换 `tenant_access_token`、钉钉换 `accessToken`、Telegram `getMe`、Discord `users/@me`、Slack `auth.test`、Matrix `account/whoami` —— 厂商自己说"认",才算通。 |
| 📱 **二维码直接出在脚本里** | QQ / 微信扫码授权走官方适配器函数,二维码打印在自己的终端,扫完自动写凭据、启用、重启网关并抓连接日志。不弹官方配置界面。 |
| 🔐 **默认就是安全姿势** | 面板与 API **只监听 127.0.0.1**,公网一律经 Caddy;面板强制认证门;服务跑在专用系统用户 `hermes` 下;配置改动全部走官方 CLI(不手改 YAML);Caddyfile 校验通过才 reload。 |
| 🇨🇳 **为国内网络准备** | 自动测速选择 GitHub / PyPI 加速通道,并把结果写进 git `insteadOf` 与 `uv.toml`,让后续 `hermes update` 也走加速。 |
| 🩺 **自检与可回滚** | 22 项自检(服务/端口/认证门/API 鉴权/证书/凭据权限/平台连接/备份),备份恢复做过真机演练,一键更新带自动备份,卸载逐项列出路径逐条确认。 |
| 🌏 **文档五语** | 简体中文 / English / 繁體中文 / 日本語 / 한국어。 |

---

## 🧩 运行模式:root 与普通用户都支持

> **与官方安装脚本的布局完全一致**:官方脚本本身是纯用户空间的(不需要 root、不用 sudo/apt,也不碰系统目录)——
> 代码落在 `$HERMES_HOME/hermes-agent`、可执行文件是 `$HOME/.local/bin/hermes`、数据在 `$HERMES_HOME`(默认 `~/.hermes`)。
> 本工具两种模式都显式传 `--hermes-home` / `--dir`,路径与官方一致;系统级模式只是额外把它交给专用服务用户 `hermes`
> (家目录 `/opt/hermes`)运行,以便用 systemd 托管、与普通用户环境隔离。


脚本启动时**自动判断身份**,两种模式功能都能用,不需要额外参数:

| | **系统级(root)** | **用户态(普通用户)** |
|---|---|---|
| 配置/状态 | `/etc/hermes-vps` | `~/.config/hermes-vps` |
| 日志 | `/var/log/hermes-vps` | `~/.local/state/hermes-vps` |
| 备份 | `/var/backups/hermes-vps` | `~/.local/share/hermes-vps/backups` |
| Hermes 数据 | `/opt/hermes/.hermes`(专用用户 `hermes`) | `~/.hermes`(你自己的账号) |
| 服务 | `systemd` 系统服务(开机自启) | `systemd --user`;没有用户 DBus 时自动退回**后台进程 + PID 文件** |
| 域名 + HTTPS(80/443) | ✅ 内置 Caddy 自动签证书 | ⚠️ 需要特权:选到该功能会提示用 `sudo` 重新执行 |
| 防火墙 / swap / 系统依赖 | ✅ 自动 | ⚠️ 需要特权(会明确提示,不会静默失败) |
| 模型 / 平台(QQ、微信…)/ 面板 / 备份 / 自检 | ✅ | ✅ |

```bash
# 普通用户直接跑(用户态,不碰系统目录)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user

# root 直接跑(系统级,推荐:一台机器一个实例)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
```

想看当前是什么模式:`hermes-vps mode`。菜单顶部状态面板也会显示「模式:…」,仅 root 可用的条目会标注「需要 root」。

## 🚀 60 秒开始

```bash
# 1) 登录服务器(root 或普通用户都行:两种身份都支持)
ssh root@<你的服务器>

# 2) 安装并运行:root → 装到 /usr/local/bin;普通用户 → 装到 ~/.local/bin
#    root
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps                     # 打开交互菜单(首次部署选 1,系统级)

#    普通用户(不需要 root;全部落在 $HOME:数据 ~/.hermes、服务 systemd --user)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash
hermes-vps                          # 打开交互菜单(用户态)
```

安装器常用参数(管道形式要用 `bash -s --` 传参;已存到本地则直接 `bash install.sh …`):

```bash
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --check            # 只看已装版本 vs 最新版本
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --version v1.0.0   # 装指定版本
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user             # 明确装到 ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --system           # 明确装到 /usr/local/bin(需 root)
```

首次进入菜单选 `1` 一键部署 —— 填域名(可留空)、选模型提供商,剩下的它自己干完。
全过程约 5~15 分钟(取决于机器与网络)。

### 前置条件

| 项目 | 要求 |
|---|---|
| 系统 | Debian 10+ / Ubuntu 20.04+(amd64 / arm64) |
| 权限 | root |
| 内存 | ≥ 1GB(小于 1.8GB 且无 swap 时,脚本会自动创建 2GB swapfile 防 OOM) |
| 磁盘 | ≥ 2GB 可用 |
| 域名 | 可选。要 `https://域名` 访问需 A 记录指向本机公网 IP,并放通 80/443 |
| 网络 | 直连或受限都能用:自动探测加速通道 |

---

## 🖥 界面预览

```
  ╭──────────────────────────────────────────────────────────────────────────╮
  │  Hermes Agent · VPS 一键部署与管理                                       │
  │  模型 / QQ / 微信 / 域名 HTTPS / 自检备份                                │
  │  v1.0.0  ·  Debian GNU/Linux 13 (trixie) x86_64  ·  2C / 967MB           │
  ╰──────────────────────────────────────────────────────────────────────────╯

  运行状态 ──────────────────────────────────────────────────────────────
  Hermes      ● v0.21.5
  服务        网关 ●  面板 ●  Caddy ●
  域名        panel.example.com(证书剩 89 天)
  模型        deepseek / deepseek-chat(已验证)
  平台        已配置 2 个,已连接 2 个
  ──────────────────────────────────────────────────────────────────────────

  主菜单
  ──────────────────────────────────────────────────────────────────────────
     1) 一键部署 / 重新部署       安装 Hermes、面板、域名、平台接入
     2) 模型提供商                填 API Key,并真实验证能否对话
     3) 消息平台                  QQ / 微信 / 企业微信 / 飞书 / 钉钉 / TG
     4) 域名与反向代理            Caddy 自动 HTTPS、证书状态
     5) 面板与 API                登录密码、公网地址、/v1 开关
     6) 服务管理                  启动 / 停止 / 重启 / 看日志
     7) 自检与诊断                服务、端口、认证门、API、证书、备份
     8) 备份与恢复                打包配置与密钥,可一键回滚
     9) 更新                      立即更新 / 每日自动更新
    10) 防火墙与安全              只放行 SSH / 80 / 443
    11) 网络加速探测              GitHub / PyPI 国内镜像自动选优
    12) 使用说明 / 帮助           常用命令与路径
    13) 卸载                      逐项确认,绝不静默批量删
  ──────────────────────────────────────────────────────────────────────────
     0) 退出
```

---

## 🧭 功能地图

菜单里的每一项都有等价的子命令,方便脚本化 / 无人值守。

| 菜单 | 子命令 | 说明 |
|---|---|---|
| 1 一键部署 | `install [--yes]` | 10 步流水线,幂等可重跑 |
| 2 模型提供商 | `model` | 19 家内置 + 自定义 OpenAI 兼容端点;直连校验 + 真实对话验证 |
| 3 消息平台 | `platform` | 扫码类走脚本内二维码;凭据类填完即验票 |
| 4 域名与反代 | `domain <域名>` | 渲染 Caddyfile → `caddy validate` → 热重载 → 申请证书 |
| 5 面板与 API | `panel` | 重置密码、公网地址、`/v1` 开关、登录链路实测 |
| 6 服务管理 | `service start\|stop\|restart\|status\|logs` | 网关 / 面板 / Caddy |
| 7 自检与诊断 | `diagnose` | 22 项检查,逐条 ✔/✘ |
| 8 备份与恢复 | `backup` / `restore` | 含配置与凭据;恢复就地合并,不破坏安装 |
| 9 更新 | `update` / `update auto-update on\|off` | 更新前自动备份;每日 04:30 自动检查 |
| 10 防火墙 | `firewall` | 只**增加**放行,绝不动既有规则 |
| 11 网络加速 | `mirror --force` | 重新测速并应用 |
| 12 帮助 | `help` | 命令与路径速查 |
| 13 卸载 | `uninstall` | 先列精确路径,再逐条确认 |
| — | `selftest` | 检查脚本自身(语法/数据表/Caddyfile 渲染/真实 `caddy validate`) |
| — | `self-install` | 把自己装到 `/usr/local/bin/hermes-vps` |

通用参数:`--yes`(全部自动确认)、`--non-interactive`(不提问)、`--force`、`--skip-browser`(少装浏览器组件,省内存)、`--no-color`、`--debug`。

---

## 🤖 模型提供商

内置 19 家,填 Key 即用:

`DeepSeek` · `OpenRouter` · `智谱 GLM` · `Kimi / Moonshot` · `阿里云百炼 Qwen` · `MiniMax` · `OpenAI` · `Anthropic` · `Google Gemini` · `xAI Grok` · `DeepInfra` · `NovitaAI` · `Fireworks` · `NVIDIA NIM` · `Hugging Face` · `小米 MiMo` · `腾讯 TokenHub` · `阶跃星辰` · **自定义 OpenAI 兼容端点**(vLLM / Ollama / One-API / 自建中转)

**两级验证,拒绝"看起来配好了"**

1. **直连校验** —— 直接请求该厂商的 `/chat/completions`,2 秒内给结论,并把 HTTP 状态翻译成人话:
   `401 密钥被拒` / `402 余额不足` / `404 模型名或端点不对` / `429 限流或额度用尽` / `000 网络不可达`,并附厂商原始错误信息。
2. **真实对话** —— 通过 Hermes 发一句「只回答两个字:可用」,验证模型、工具链、会话与回复全链路。

---

## 💬 消息平台

| 平台 | 接入方式 | 脚本内的验证手段 |
|---|---|---|
| **QQ 机器人** | 官方 Bot API v2(扫码上线 或 AppID/Secret) | `getAppAccessToken` 换取 token,官方认账才通过 |
| **个人微信** | iLink 扫码登录(二维码出在脚本里) | 登录态落盘 + 网关连接日志 |
| **企业微信** | AI 机器人(Bot ID / Secret) | WebSocket 网关连接日志 |
| **飞书 / Lark** | 长连接(APP ID / Secret) | 换取 `tenant_access_token` |
| **钉钉** | Stream 模式(ClientID / Secret) | 换取 `accessToken` |
| **Telegram** | Bot Token | `getMe` |
| **Discord** | Bot Token | `users/@me` |
| **Slack** | Bot + App Token(Socket Mode) | `auth.test` |
| **Matrix** | Homeserver + Access Token | `account/whoami` |
| **WhatsApp** | 扫码配对 | 网关连接日志 |
| **邮件助手** | IMAP + SMTP | 网关连接日志 |
| **OpenAI 兼容 API** | API Key + 端口 | 无 key → 401,带 key → 200 |

配置完成后自动重启网关、抓取**本次启动以来**的连接日志给结论(面板顶部状态栏同步显示「已连接 / 失败」),还可以让机器人给你发一条测试消息验证收发。

> 扫码类平台的二维码直接渲染在本脚本的终端里(通过官方适配器函数),**不会跳到官方配置界面**;想用官方界面的人自己敲 `hermes gateway setup` 即可。

---

## 🔐 安全设计

- **最小暴露面**:管理面板(9119)与 OpenAI 兼容 API(8642)**只绑 `127.0.0.1`**;公网访问一律经 Caddy 反代。
- **认证门必开**:面板强制 Basic Auth + 会话密钥(随机生成),未登录访问被拦截;`public_url` 写成 `https://域名`,杜绝"声明了公网却无认证"的窗口。
- **独立服务用户**:网关与面板以系统用户 `hermes` 运行(非 root),`HERMES_HOME=/opt/hermes/.hermes`;家目录禁止交互登录。
- **配置改动走官方 CLI**:`hermes config set`(不手改 `config.yaml`,避免缩进破坏运行中的网关);密钥只写 `.env`(0600)。
- **改配置先校验再生效**:Caddyfile 先 `caddy validate --adapter caddyfile`,通过才 reload;原文件自动备份保留 5 份。
- **防火墙只做加法**:只放行 SSH(自动识别端口)+ 80 + 443,不删除、不改动任何既有规则。
- **凭据文件 0600**:面板账号、密码、API Key、会话密钥集中写在 `/etc/hermes-vps/credentials.txt`。
- **删除类操作永不静默**:卸载、恢复、清理备份都会先列出精确路径,逐条确认。

---

## 🏗 架构与落盘

```
源码(仓库里只有这些;发布产物由 CI 生成,不入库)
  lib/00-common.sh       核心:常量 / 颜色 / 日志 / 输入原语 / 状态存储 / 以服务用户执行
  lib/10-input.sh        交互原语(纯文本,无 whiptail)
  lib/11-state.sh        键值存储 / 状态 / 凭据
  lib/12-run.sh          以服务用户身份执行
  lib/20-system.sh       发行版探测 / 依赖 / swap 保护
  lib/21-mirror.sh       网络加速(GitHub / PyPI 测速选优)
  lib/22-firewall.sh     防火墙(只增不减)
  lib/23-probe.sh        通用探测(端口 / 服务 / 公网 IP / 域名解析)
  lib/30-hermes.sh       服务用户 + Hermes 安装与更新
  lib/31-model.sh        模型提供商表 + 两级连通验证
  lib/40-platform.sh     消息平台表 + 厂商 API 验票 + 脚本内扫码
  lib/50-webui.sh        面板认证门 / 凭据 / 公网地址
  lib/51-service.sh      systemd 单元与服务控制
  lib/52-caddy.sh        Caddy 安装 / 渲染 / 校验 / 证书
  lib/60-backup.sh       备份恢复 / 更新与自动更新
  lib/61-doctor.sh       自检诊断(22 项)
  lib/62-lifecycle.sh    卸载(逐项确认)
  lib/70-ui.sh           横幅 / 状态面板 / 各菜单
  lib/71-deploy.sh       一键部署编排
  lib/72-help.sh         使用说明
  lib/80-cli.sh          参数解析与子命令分发
  lib/90-selftest.sh     脚本自检
  bin/hermes-vps         入口(开发时 `bash bin/hermes-vps` 会自动载入 lib/)
  build.sh               拼装成 dist/hermes-vps.sh
  install.sh             从 Release 安装 / 升级(自动取最新版 + sha256 校验)
  tests/                 lint / smoke / strict / 真实 caddy 校验 / 路由行为 / 真机验收
  VERSION                版本号;打 tag 必须是 v$VERSION
  .github/workflows/     ci.yml(全量测试) + release.yml(打 tag 时构建并发布)
```

**发布流程**:改 `VERSION` → 打 tag `v1.0.0` → Actions 跑全量测试、构建 `hermes-vps.sh`、生成 `.sha256` 并创建 Release。用户端只跑 `install.sh`,永远拿到同一份自包含脚本(仓库里没有生成物,避免"源码与产物不一致")。

| 路径 | 内容 |
|---|---|
| `/opt/hermes/.hermes` | Hermes 数据:配置、`.env`(密钥)、skills、会话、日志 |
| `/opt/hermes` | 服务用户 `hermes` 的家目录(含运行时与虚拟环境) |
| `/etc/hermes-vps/state.env` | 本工具状态(域名、开关、版本) |
| `/etc/hermes-vps/credentials.txt` | 面板账号 / 密码 / API Key / 会话密钥(0600) |
| `/etc/hermes-vps/mirror.env` | 已选用的加速通道 |
| `/etc/caddy/Caddyfile` | 反向代理配置(改动前自动备份到 `.bak/`) |
| `/var/backups/hermes-vps/` | 备份包(最近 7 份) |
| `/var/log/hermes-vps/hermes-vps.log` | 本工具操作日志 |
| `$HERMES_HOME/logs/gateway.log` | 网关运行日志(**平台连接结论在这里**) |

systemd 单元:`hermes-gateway.service`、`hermes-dashboard.service`、`caddy.service`,全部开机自启。

---

## 🧪 质量与验证

本项目在**真实 VPS(Debian 13,2 核 / 967MB)上完成验收**,不是"本地跑通就算":

| 验收项 | 结果 |
|---|---|
| 一键部署 10 步流水线 | 全程 0 报错,幂等重跑亦干净 |
| 自检 `diagnose` | **22 项全通过**(服务 / 端口 / 认证门 / API 鉴权 / 证书 / 凭据权限 / 平台连接 / 备份) |
| Caddyfile | 调用生产函数渲染 + **真实 `caddy validate`** 通过,HTTPS 探活 200,证书自动签发 |
| 面板认证门 | 未登录 302/401 拦截;正确凭据登录 200 并下发会话 Cookie;错误密码 401;经域名 HTTPS 登录 200 |
| OpenAI 兼容 API | 无 key 401、带 key 200,反代路径可用 |
| 消息平台 | QQ 机器人完成**真实收发**(接收消息 → 3.7s 生成回复 → 成功投递) |
| 备份 / 恢复 | 备份 → 删除标记文件 → 恢复:标记回归、服务自动拉起、面板 200 |
| 卸载预览 | 逐项列出路径与用途,默认全部保留 |
| 脚本自检 | `selftest` 覆盖语法、数据表、Caddyfile 渲染与真实二进制校验 |

---

## 🛠 常见问题

**证书签不下来?**
域名 A 记录必须指向本机公网 IP,且 80/443 对公网可达(云厂商安全组也要放行)。`hermes-vps diagnose` 会逐项指出问题。

**1GB 小内存机器装不动?**
脚本检测到内存 < 1.8GB 且无 swap 时会自动创建 2GB swapfile。这是实测教训:官方安装器在 1GB 无 swap 的机器上被打包环节 OOM 杀过。

**国内机器下载慢 / 失败?**
菜单 11 会测速并选择 GitHub / PyPI 加速通道,同时写进 git `insteadOf` 与用户级 `uv.toml`,让后续 `hermes update` 也走加速。

**改完平台没反应?**
必须重启网关(菜单 6 → 4),或 `hermes-vps service restart gateway`。

**平台显示"失败"但没有明显报错?**
看 `$HERMES_HOME/logs/gateway.log`(菜单 6 → 7 直接 tail 它)。注意区分**本次启动以来**的日志与上一次运行的残留告警。

**卸载会删什么?**
菜单 13 会先逐项列出每个路径与用途,再一条条问你,默认全部保留;备份目录从不删除。

---

## 🧰 开发者备忘:真机踩过的坑

改这个脚本前值得一读(全部来自真实部署):

1. `set -Eeuo pipefail` 下,**函数最后一条语句**若是 `[[ ]] && cmd`,判定失败会让函数返回非零,`set -e` 在调用处终止脚本 —— 结尾统一 `return 0` 或改写成 `if`。
2. `grep` 无匹配返回 1,经 `pipefail` 会中止;所有"取值"函数必须显式兜底。
3. `openssl rand | tr | head` 会因 SIGPIPE 让上游报错;改用 `openssl rand -base64` 后截断。
4. `ERR` 陷阱要判断 `case "$-" in *e*)`,否则 `set +e` 的容错回退路径会被误判为致命错误。
5. `caddy validate/fmt` 必须带 `--adapter caddyfile`(临时文件名没有提示,会被当 JSON 解析)。
6. Caddy 运行前要准备好 `/var/log/caddy` 目录与属主,否则服务起不来。
7. 面板健康检查要等 `HERMES_DASHBOARD_READY`,固定 `sleep 2` 会误报。
8. `tar` 退出码 1 是无害警告,2 才是真失败;回退分支里别引用已删除的临时目录。
9. 恢复备份要「就地合并 + 只挪走将被覆盖的文件」,整目录替换会把安装弄残。
10. 中文字符在终端占 2 列,画对齐的菜单必须按**显示宽度**算;`case` 单行写法分支间必须是 `;;` 而非 `;`。
11. 源码带 CRLF 时在 Linux 报 `$'\r': command not found` —— 提交前统一 LF(`.gitattributes` 已锁)。
12. 平台的连接结论写在 Hermes 自己的 `logs/gateway.log`(不是 journald),且必须只看**本次启动以来**的片段,否则会被上一轮运行的失败告警误导。
13. 在自己脚本里跑官方 Python 逻辑,要用官方启动器的 `--run-module`(依赖装在工具自己的运行时里),并**以服务用户身份**执行。
14. 需要 `qrcode` 才能渲染终端二维码:官方 `hermes pm install --extra messaging`。
15. 备份要排除可重装内容(源码树、Python 运行时),否则体积从 ~100MB 涨到 ~800MB。

---

## 📄 许可

[MIT](LICENSE)

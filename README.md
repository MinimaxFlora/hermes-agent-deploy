# hermes-vps

在全新的 VPS 上一键装好 **Hermes Agent**(Nous Research 开源自改进 AI Agent),配好模型、
消息平台(QQ / 微信 / 企业微信 / Telegram / 飞书 / 钉钉 …)、Web 管理面板,
再用 **Caddy** 把它安全地挂到自己的域名上(自动 HTTPS),同时提供一套 **可维护的运维命令**。

一条命令开始:

```bash
curl -fsSL https://raw.githubusercontent.com/<你的仓库>/main/install.sh | sudo bash -s -- install
```

装完之后你拿到的是:

| 项 | 说明 |
|---|---|
| 管理面板 | `https://你的域名`(用户名 `admin`,密码自动生成并写入 `/etc/hermes-vps/credentials.txt`) |
| OpenAI 兼容 API | `https://你的域名/v1`(给 OpenWebUI / LobeChat / Cherry Studio 等) |
| 消息机器人 | 按你选的平台接入,网关开机自启 |
| 常驻服务 | `hermes-gateway.service`、`hermes-dashboard.service`、`caddy.service`(systemd 系统级) |
| 运维命令 | `hermes-vps status / doctor / logs / backup / update / domain …` |

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [快速开始](#快速开始)
- [部署后怎么用](#部署后怎么用)
- [命令速查](#命令速查)
- [域名与反向代理是怎么做的](#域名与反向代理是怎么做的)
- [消息平台接入](#消息平台接入)
- [模型提供商](#模型提供商)
- [无人值守部署](#无人值守部署)
- [安全设计](#安全设计)
- [备份 / 更新 / 卸载](#备份--更新--卸载)
- [架构与目录](#架构与目录)
- [常见问题](#常见问题)
- [与参考脚本的差异](#与参考脚本的差异)

---

## 它解决什么问题

Hermes Agent 官方提供的是一套通用安装器(`install.sh`),它负责装好程序本身,但
"在 VPS 上当成一个长期在线的服务来跑"这一层需要自己拼:

1. 用哪个系统用户跑、数据放哪、怎么开机自启;
2. 面板要暴露到公网就必须开认证门(Hermes 在非回环绑定/声明公网 URL 时是 fail-closed 的);
3. 反向代理怎么写才不让面板的 DNS-rebinding 防护把自己拦掉;
4. 国内 VPS 拉 GitHub / PyPI 经常超时,要挑加速通道;
5. QQ / 微信 / 企业微信 / 飞书 / 钉钉这些平台的凭据变量名各不相同;
6. 端口、防火墙、证书、备份、更新、卸载……一堆一次性的手工活。

本工具就是把这一层做成**可重复执行、可脚本化调用、出错能定位**的一套 shell 程序。

## 快速开始

```bash
# 1) 一键部署(交互向导:域名 → 模型 → 平台 → 确认)
curl -fsSL https://raw.githubusercontent.com/<你的仓库>/main/install.sh | sudo bash -s -- install

# 2) 已经有本机仓库时
sudo bash bin/hermes-vps install

# 3) 全屏菜单(喜欢点选的话)
sudo hermes-vps menu
```

前置条件:Debian 12/13 或 Ubuntu 20.04+(amd64 / arm64)、root 权限、
域名 A 记录已指向本机(要用域名访问的话)、开放 80/443。

部署流程会依次做这些事(每步幂等,可反复执行):

```
环境检查 → 基础依赖 → 网络加速探测 → 参数确认 → 服务用户/目录
→ 官方安装 Hermes → 配置模型 → 面板认证门 + API → 消息平台
→ systemd 常驻服务 → Caddy 域名与证书 → 防火墙 → 总结报告
```

## 部署后怎么用

```bash
hermes-vps status      # 一屏看清:版本/服务/端口/域名/HTTPS 探活
hermes-vps doctor      # 完整体检(含官方 hermes doctor)
hermes-vps logs gateway
```

面板里可以直接改配置(`Config` / `Channels` / `Keys` / `MCP` / `Sessions` 页),
命令行侧用 `hermes-vps model / platform / domain` 改,两边改的是同一份
`~/.hermes/config.yaml` 与 `.env`。

## 命令速查

```
部署
  install [--config 文件] [--domain d --email e --provider p --model m --platforms a,b]
  menu

配置
  model list|show|configure [供应商 id]
  platform list|status|configure <id>|setup <id>
  web show | web password | web api on|off
  domain set <域名> | domain apply | domain status
  mirror probe [--force] | mirror show

运维
  status | doctor | logs <gateway|dashboard|caddy|install|agent|access>
  service status|restart|stop|start|logs [gateway|dashboard]
  backup create|list|restore [文件]|prune
  update [--no-backup] | update --auto enable|disable|status
  firewall setup
  uninstall

通用
  -y/--yes  --non-interactive  --debug  --no-color  -v  -h
```

所有功能都是**子命令 + 可脚本化**的;菜单只是同一批函数的一层壳,不是唯一入口。

## 域名与反向代理是怎么做的

Hermes 面板在绑定非回环地址或声明了公网 URL 时会**强制开启认证门**,
并且有 DNS-rebinding 防护:`Host` 头必须和绑定地址/`public_url` 匹配。
官方文档给出的部署姿势是:

> 面板继续绑 `127.0.0.1`,设置 `dashboard.public_url=https://你的域名`,
> 让本机的 TLS 反代从回环来连它 —— **回环代理自动被信任**,不需要放宽
> `dashboard.trusted_proxies`。

本工具就是这么做的:

```
浏览器 ──https──> Caddy(80/443,自动 Let's Encrypt)──http──> 127.0.0.1:9119  面板
                                                        └──> 127.0.0.1:8642  OpenAI 兼容 API(/v1)
```

生成的 `/etc/caddy/Caddyfile` 结构:

- `https://你的域名/healthz|/health` → 直接回 `ok`(探活用,不经过 Hermes)
- `https://你的域名/v1/*` → `127.0.0.1:8642`(API,可随时 `web api off` 关掉)
- 其余全部 → `127.0.0.1:9119`(面板;WebSocket/SSE 流式输出 Caddy 原生支持)
- 统一压缩、HSTS、`-Server`、`X-Content-Type-Options` 等响应头

改域名只需要:

```bash
hermes-vps domain set new.example.com --email me@example.com
```

它会重渲染 Caddyfile → `caddy validate` 校验 → 备份旧文件 → 写入 → reload;
校验失败**绝不会** reload,现网配置不会被写坏。

## 消息平台接入

`hermes-vps platform list` 里的平台,分成三类处理:

| 模式 | 含义 | 例子 |
|---|---|---|
| `env` | 填密钥即可跑 | QQ 机器人、企业微信、钉钉、Telegram、Discord、Slack、Matrix、邮箱 |
| `meter` | 除密钥外还要公网回调/额外参数 | 飞书(webhook 模式)、Signal |
| `qr` | 需要扫码/交互登录,由官方向导完成 | **个人微信**(iLink)、WhatsApp |

微信的两种不同接法(官方是两个适配器,别搞混):

- `weixin` —— **个人微信**,走腾讯 iLink Bot API,**长轮询,不需要公网 webhook**;
  首次要扫码登录:`hermes-vps platform setup weixin`(SSH 里出二维码)。
- `wecom` —— **企业微信**,AI Bot WebSocket 网关,填 `WECOM_BOT_ID` + `WECOM_SECRET`。

QQ 机器人走官方 QQ Bot API v2(私聊 / 群 @ / 频道),在
[q.qq.com](https://q.qq.com) 建应用后填 `QQ_APP_ID` + `QQ_CLIENT_SECRET` 即可,
无需公网回调。

新增一个平台 = 在 `data/platforms.conf` 里加一行(格式见文件头注释),
脚本不用改。

## 模型提供商

`hermes-vps model list` 列出了 20+ 官方 provider id 与密钥变量名(OpenRouter / DeepSeek /
智谱 GLM / Kimi / 阿里云百炼 / MiniMax / xAI / Gemini / Anthropic / OpenAI …
以及自定义 OpenAI 兼容端点)。

```bash
hermes-vps model configure            # 菜单选择,依次问 key 和模型名
hermes-vps model configure deepseek   # 指定供应商
```

约定:**密钥只写 `$HERMES_HOME/.env`,其它设置一律 `hermes config set`**
(不手改 YAML,避免缩进把配置文件写坏),写完还会读回校验一次。

## 无人值守部署

```bash
sudo cp etc/hermes-vps.conf.example /etc/hermes-vps/hermes-vps.conf
sudo nano /etc/hermes-vps/hermes-vps.conf
sudo hermes-vps install --config /etc/hermes-vps/hermes-vps.conf --non-interactive --yes
```

或者全靠命令行参数:

```bash
sudo hermes-vps install \
  --domain hermes.example.com --email me@example.com \
  --provider deepseek --key "$DEEPSEEK_KEY" --model deepseek-chat \
  --platforms qqbot,wecom,telegram --with-api 1 --yes
```

`qr` 类平台(个人微信/WhatsApp)在无人值守模式下会自动跳过并打印后续步骤,之后
在 SSH 里执行一次 `hermes-vps platform setup weixin` 扫码即可。

## 安全设计

- **独立服务用户**:专用的系统用户 `hermes`(无密码、禁止交互登录),数据只在
  `/opt/hermes` 下,不污染 root 家目录。
- **强制认证门**:面板密码与签名密钥在部署时随机生成(`openssl rand`),
  写入 `/etc/hermes-vps/credentials.txt`(0600);面板永远绑回环,只经 Caddy 出去。
- **API 单独密钥**:`API_SERVER_KEY` 独立随机生成,API 端口同样只绑回环。
- **防火墙**:只**新增**放行 SSH(自动识别实际端口)/ 80 / 443,**不删任何现有规则**;
  nft/iptables 裸规则不乱动,只提示。云厂商安全组需你在控制台放行。
- **配置改动可回滚**:写 Caddyfile / `.env` 前自动备份,`caddy validate` 不通过就拒绝生效。
- **卸载先列后删**:卸载会打印**每一条**将处理的路径并逐项确认,
  不会静默批量删除;恢复备份也是"先改名挪走旧数据"而不是删除。

## 备份 / 更新 / 卸载

```bash
hermes-vps backup create            # 打包 config/记忆/技能/会话/配对/凭据 + Caddy + 本工具状态
hermes-vps backup list
hermes-vps backup restore <文件>    # 先停服务,旧数据改名为 .pre-restore-<时间戳>
hermes-vps backup create --label auto

hermes-vps update                   # 更新前自动备份 → 官方 hermes update → 重启服务
hermes-vps update --auto enable     # 每天 04:30 自动更新(systemd timer + 随机延迟)

hermes-vps uninstall                # 逐项确认式卸载
```

代码/缓存不打包(`.hermes/hermes-agent`、`.hermes/tools`、日志、音频缓存),
所以备份很小;这些内容官方安装器可以重建。

## 架构与目录

```
hermes-vps/
├── install.sh              # 引导脚本:curl | bash 用;本地仓库时直接转发给 bin/hermes-vps
├── bin/hermes-vps          # 唯一入口:参数解析 + 子命令分发 + 菜单入口
├── lib/
│   ├── common.sh           # 常量/路径/日志/错误陷阱/状态读写/以服务用户执行命令
│   ├── ui.sh               # 交互抽象层(whiptail ↔ 文本 ↔ 非交互),一份代码两用
│   ├── detect.sh           # 发行版/架构/init/资源/端口/域名解析探测
│   ├── deps.sh             # 基础依赖(幂等,按包管理器分支)
│   ├── mirror.sh           # GitHub/PyPI 加速探测与落地(git insteadOf / uv.toml)
│   ├── account.sh          # 服务用户、目录、.env 读写、服务用户侧启动器
│   ├── hermes.sh           # 官方安装/更新/doctor 封装
│   ├── provider.sh         # 模型提供商(数据驱动 data/providers.conf)
│   ├── platform.sh         # 消息平台(数据驱动 data/platforms.conf)
│   ├── webui.sh            # 面板认证门、public_url、OpenAI 兼容 API
│   ├── caddy.sh            # Caddy 安装、Caddyfile 渲染/校验/重载、证书检查
│   ├── service.sh          # systemd:网关服务(官方安装器)+ 面板服务(自建单元)
│   ├── firewall.sh         # ufw/firewalld 只放行必需端口
│   ├── backup.sh           # 备份/恢复/定时备份
│   ├── lifecycle.sh        # 更新、自动更新定时器、卸载
│   ├── doctor.sh           # 状态总览、诊断、日志查看
│   ├── deploy.sh           # 一键部署编排(10 步流水线)
│   └── menu.sh             # 交互菜单
├── data/
│   ├── providers.conf      # 提供商表(加一行 = 支持一个新提供商)
│   ├── platforms.conf      # 平台表(加一行 = 支持一个新平台)
│   └── templates/Caddyfile.tpl
├── etc/hermes-vps.conf.example
├── docs/ARCHITECTURE.md    # 设计说明与扩展指南
└── tests/                  # 语法检查 + 逻辑冒烟测试
```

运行时落点:

```
/opt/hermes              服务用户家目录
/opt/hermes/.hermes      HERMES_HOME:config.yaml / .env / state.db / skills / memories / sessions
/etc/hermes-vps          state.env(安装状态) mirror.env(加速选择) credentials.txt(0600)
/etc/caddy/Caddyfile     生成的站点配置(带 managed-by 标记)
/var/log/hermes-vps      本工具的日志
/var/backups/hermes-vps  备份
/usr/local/bin/hermes-vps 命令
```

扩展方式、错误处理约定、幂等性说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 常见问题

**HTTPS 打不开 / 证书签发失败**
1. `hermes-vps domain status` 看证书状态;
2. `hermes-vps doctor` 里有 `https://域名/healthz` 探活结果;
3. 依次排查:域名 A 记录是否指向本机 → 80/443 是否被云安全组挡住 →
   `hermes-vps logs caddy` 看 ACME 报错;
4. 调试期可用测试 CA(`--acme-ca https://acme-staging-v02.api.letsencrypt.org/directory`)避免触发正式环境限流。

**面板能打开但一直转圈 / 聊天连不上**
面板的实时聊天走 WebSocket(`/api/ws`、`/api/pty`)。Caddy 已原生支持;
若中间还串了别的代理(CDN、隧道),需要允许 WebSocket 与长连接。

**网关重启后收不到消息**
`hermes-vps logs gateway` 看平台连接日志;`hermes-vps platform status`
检查凭据是否齐全、是否已启用。Telegram/Discord 这类平台需要 `/new` 后重新对话。

**GitHub 拉取超时**
`hermes-vps mirror probe --force` 重新测速;它会同时配置 git 的 `insteadOf` 前缀与
uv/PyPI 索引,后续 `hermes update` 也走加速。

**装完想换域名**
`hermes-vps domain set new.example.com`(自动重写 Caddyfile 并重新签发证书)。

## 与参考脚本的差异

参考实现(`luci-app-openclaw` 的 `oc-config.sh`)是 3000+ 行单体脚本,靠一堆
`json_set` 直接改 JSON、再同步 UCI,功能全但难维护。本工具在设计上做了这些区分:

| 维度 | 参考脚本 | 本工具 |
|---|---|---|
| 结构 | 单文件 | 入口 + 18 个职责单一的模块 |
| 配置写入 | 自己拼 `json_set` 改 JSON | 一律调用官方 CLI(`hermes config set` / `hermes doctor` 等) |
| 平台/提供商 | 每个功能一段硬编码 | 数据表驱动(`data/*.conf`),加一行即扩展 |
| 交互 | 只有菜单 | 交互层抽象:菜单 / 文本 / 非交互三态,同一份逻辑可脚本化调用 |
| 幂等 | 部分 | 全流程幂等,可反复执行;写文件前备份,校验失败不回滚生效 |
| 网络 | 假定畅通 | 自动探测 GitHub/PyPI 加速通道并落地到 git/uv 配置 |
| 危险操作 | — | 删除/卸载先列清单逐项确认;防火墙只增不删 |
| 可观测 | 打印日志 | 统一日志文件 + `doctor` 总览 + `logs <模块>` |

---

## 验证状态(诚实说明)

| 内容 | 状态 |
|---|---|
| 全部脚本语法、数据表格式、模块加载、危险 `rm` 扫描 | 已在本机跑通(`bash tests/lint.sh`) |
| 键值/状态读写、提供商与平台表解析、Caddyfile 渲染、CLI 子命令 | 已有冒烟测试并通过(`bash tests/smoke.sh`) |
| 生成的 Caddyfile 能否被 Caddy 接受 | 需用真实 `caddy validate` 验证(见下) |
| 完整一键部署(装 Hermes、起服务、签证书、连机器人) | **需要在真实 VPS 上跑一遍才能算完成** |

本工具的目标平台是 Linux VPS(Debian/Ubuntu),开发机上无法完整验证的部分包括:
`useradd`、systemd 单元、apt 安装、Let's Encrypt 签发、消息平台连通性。
建议在目标 VPS 上按下面的顺序做一次真机验收:

```bash
# 1) 静态自检(不装任何东西)
bash tests/lint.sh && bash tests/smoke.sh

# 2) 无人值守部署(会真的装)
sudo hermes-vps install --config /etc/hermes-vps/hermes-vps.conf --non-interactive --yes

# 3) 验收清单
hermes-vps doctor                 # 版本/服务/端口/HTTPS 探活全绿
curl -s https://域名/api/status  # 应返回 302/401(认证门生效),而不是 200 直开
hermes-vps logs gateway           # 平台连接日志
hermes-vps backup create          # 备份可用
```

---

MIT License —— 见 [LICENSE](LICENSE)。

# hermes-vps · Hermes Agent 一键 VPS 部署与管理

**一个 `.sh` 文件**,在 Debian / Ubuntu VPS 上把 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 装好、配好、并跑起来:

- 安装 Hermes + 独立系统用户 `hermes`(不用 root 跑进程)
- 配好模型提供商(填 API Key → **立即用官方接口验证能否真的发对话**)
- 接入 QQ / 微信 / 企业微信 / 飞书 / 钉钉 / Telegram / Discord / Slack / Matrix / 邮件等消息平台(填完凭据**当场验证平台 API 认不认账**)
- Caddy 反代 + 域名自动 HTTPS(Let's Encrypt 自动签发续期)
- 管理面板 / OpenAI 兼容 `/v1` 接口(带登录认证门)
- 自检诊断、备份恢复、更新与每日自动更新、防火墙、卸载

全程**纯文本菜单**:输入编号即可,不弹任何对话框。

```
  ╭──────────────────────────────────────────────────────────────────────────╮
  │  Hermes Agent · VPS 一键部署与管理                                       │
  │  模型 / QQ / 微信 / 域名 HTTPS / 自检备份                                │
  ╰──────────────────────────────────────────────────────────────────────────╯

  运行状态 ──────────────────────────────────────────────────────────────
  Hermes      ● v0.21.5
  服务        网关 ●  面板 ●  Caddy ●
  域名        panel.example.com(证书剩 89 天)
  模型        deepseek / deepseek-chat(已验证)
  平台        已配置 2 个,已连接 1 个
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

## 快速开始

```bash
# 1) 上机器
ssh root@你的服务器

# 2a) 直接跑(把脚本传上去)
bash hermes-vps.sh

# 2b) 或一条命令下载后直接跑(仓库公开后)
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/hermes-vps/main/hermes-vps.sh -o /root/hermes-vps.sh
bash /root/hermes-vps.sh

# 3) 想以后随处可用的命令
bash hermes-vps.sh self-install     # 装到 /usr/local/bin/hermes-vps
hermes-vps                          # 之后直接敲这个就打开菜单
```

首次进入菜单 → 选 `1` 一键部署 → 按提示填域名、选模型提供商即可。全部走完约 5~15 分钟(取决于机器性能与网络)。

**前置条件**

| 项目 | 要求 |
|---|---|
| 系统 | Debian 10+ / Ubuntu 20.04+(amd64 / arm64) |
| 权限 | root |
| 内存 | 建议 ≥ 1GB(不足时脚本会自动加 2GB swap 防 OOM) |
| 磁盘 | ≥ 2GB 可用 |
| 域名 | 可选。要用 `https://域名` 访问需把 A 记录指向本机公网 IP,并放行 80/443 |
| 网络 | 国内机器会自动测速并切换 GitHub / PyPI 加速通道 |

## 子命令(可脚本化,等价于菜单)

```bash
hermes-vps                      # 打开交互菜单
hermes-vps install [--yes]      # 一键部署(无人值守)
hermes-vps model                # 模型提供商配置 + 验证
hermes-vps platform             # 消息平台接入
hermes-vps domain <域名>        # 配置 Caddy + 自动 HTTPS
hermes-vps panel                # 面板凭据 / API 开关
hermes-vps service restart      # start|stop|restart|status|logs [gateway|dashboard|caddy]
hermes-vps diagnose             # 自检(服务/端口/认证门/API/证书/平台/备份)
hermes-vps backup | restore     # 备份 / 恢复
hermes-vps update [auto-update on|off|status]
hermes-vps firewall             # 只放行 SSH / 80 / 443(不动已有规则)
hermes-vps mirror --force       # 重新测速选国内加速通道
hermes-vps selftest             # 自检脚本自身(语法、数据表、Caddyfile 渲染)
hermes-vps uninstall            # 卸载(逐项列出路径,逐条确认)
hermes-vps self-install         # 装成 /usr/local/bin/hermes-vps
```

通用参数:`--yes`(全部自动确认)、`--non-interactive`(不提问)、`--force`、`--skip-browser`(少装浏览器组件省内存)、`--no-color`、`--debug`。

## 支持的模型提供商

DeepSeek · OpenRouter · 智谱 GLM · Kimi(Moonshot)· 阿里云百炼(Qwen)· MiniMax · OpenAI · Anthropic · Gemini · xAI · DeepInfra · NovitaAI · Fireworks · NVIDIA NIM · Hugging Face · 小米 MiMo · 腾讯 TokenHub · 阶跃星辰 · **自定义 OpenAI 兼容端点**(vLLM / Ollama / One-API / 自建中转)。

配置时会做两级验证:

1. **直连校验** — 直接请求该提供商的 `/chat/completions`,2 秒内给出结论,并翻译错误(密钥被拒 / 余额不足 / 模型名错 / 端点不可达)。
2. **真实对话** — 通过 Hermes 发一句 `只回答两个字:可用`,验证「模型 → 工具链 → 回复」整条链路。

## 支持的消息平台

| 平台 | 接入方式 | 验证手段 |
|---|---|---|
| QQ 机器人 | 官方 Bot API v2(填 AppID/Secret) | 换 `access_token`,官方认账才算通过 |
| 个人微信 | iLink 扫码登录(官方 setup 向导) | 登录态 + 网关连接日志 |
| 企业微信 | AI 机器人(Bot ID/Secret) | 网关连接日志 |
| 飞书 | 长连接(APP ID/Secret) | 换 `tenant_access_token` |
| 钉钉 | Stream 模式(ClientID/Secret) | 换 `accessToken` |
| Telegram | Bot Token | `getMe` |
| Discord | Bot Token | `users/@me` |
| Slack | Bot/App Token(Socket Mode) | `auth.test` |
| Matrix | Homeserver + Access Token | `account/whoami` |
| WhatsApp | 扫码 | 网关连接日志 |
| 邮件 | IMAP + SMTP | 网关连接日志 |
| OpenAI 兼容 API | API Key + 端口 | 无 key 401 / 带 key 200 |

改完平台配置会自动重启网关并抓取连接日志,面板顶部状态栏也会显示「已连接 / 失败」。

## 架构与落盘位置

单文件脚本,内部按职责分区(核心 / 系统 / 模型 / 平台 / 面板与 Caddy / 运维 / 界面),数据表(提供商、平台)内嵌,新增一家只需加一行。

| 路径 | 内容 |
|---|---|
| `/opt/hermes/.hermes` | Hermes 数据:配置、`.env`(密钥)、skills、会话、日志 |
| `/opt/hermes` | 服务用户 `hermes` 家目录(含 uv、venv) |
| `/etc/hermes-vps/state.env` | 本工具状态(域名、开关等) |
| `/etc/hermes-vps/credentials.txt` | 面板账号、密码、API Key(权限 600) |
| `/etc/hermes-vps/mirror.env` | 使用的加速通道 |
| `/etc/caddy/Caddyfile` | 反向代理配置(改前自动备份到 `.bak/`) |
| `/var/backups/hermes-vps/` | 备份包(保留最近 7 份) |
| `/var/log/hermes-vps/hermes-vps.log` | 本工具操作日志 |

服务:`hermes-gateway.service`、`hermes-dashboard.service`、`caddy.service`,全部开机自启。
安全姿势:面板与 API 只监听 `127.0.0.1`(9119 / 8642),公网流量一律经 Caddy;改配置一律走 `hermes config set`,不手改 `config.yaml`。

## 常见问题

**证书签不下来?** 域名 A 记录必须指向本机公网 IP,且 80/443 对公网可达(云厂商安全组也要放行)。`hermes-vps diagnose` 会逐项指出问题。

**1GB 小内存机器装不动?** 脚本检测到内存 <1.8GB 且无 swap 时会自动创建 swapfile(被官方安装器 OOM 杀过,这是实测教训)。

**国内机器下载慢/失败?** 菜单 11 会测速并选择 GitHub / PyPI 加速通道,同时写进 git `insteadOf` 与用户级 `uv.toml`,让后续 `hermes update` 也走加速。

**改完平台没反应?** 必须重启网关(菜单 6 → 4),或 `hermes-vps service restart gateway`。

**卸载会删什么?** 菜单 13 会先逐项列出每个路径与用途,再一条条问你,默认全部保留;备份目录从不删除。

## 开发者备注:真机踩过的坑

写这套脚本时在真实 Debian 13 机器(2 核 / 967MB)上逐个撞出来的,改代码时请留意:

1. `set -Eeuo pipefail` 下,`[[ ]] && cmd` 若是**函数最后一条语句**,函数返回非零会直接终止脚本 —— 结尾统一 `return 0` 或改 `if`。
2. `grep` 无匹配返回 1,经由 `pipefail` 会中止;取值类函数必须显式兜住。
3. `openssl rand | tr | head` 会因 SIGPIPE 让上游报错,改用 `openssl rand -base64` 后截断。
4. `ERR` 陷阱要判断 `case "$-" in *e*)`:否则 `set +e` 的容错回退路径会被误判为致命错误。
5. `caddy validate/fmt` 必须带 `--adapter caddyfile`(临时文件名没有 `Caddyfile` 提示)。
6. Caddy 需要预先准备好 `/var/log/caddy` 目录与属主,否则服务起不来。
7. 面板健康检查要等 `HERMES_DASHBOARD_READY`,固定 `sleep 2` 会误报。
8. `tar` 退出码 1 是无害警告,2 才是真失败;回退分支里别引用已删除的临时目录。
9. 恢复备份要「就地合并 + 只挪走将被覆盖的文件」,整目录替换会把安装弄残。
10. 中文字符在终端占 2 列,画对齐的框必须按显示宽度算(`disp_len`),不能直接用 `${#s}`;`case` 单行写法分支间必须是 `;;` 而不是 `;`。
11. 源码带 CRLF 时在 Linux 上会报 `$'\r': command not found` —— 提交前统一 LF(`.gitattributes` 已锁)。

## 许可

MIT

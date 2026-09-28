<div align="center">

# hermes-vps

**Install, configure and run [Hermes Agent](https://github.com/NousResearch/hermes-agent) on your VPS — with a single `.sh` file.**

No Docker. No hand-written Caddyfile. No hunting through docs for environment variables.
From a bare server to “HTTPS dashboard on your domain + chatting with your own AI assistant inside QQ / WeChat on your phone” — by typing menu numbers.

[简体中文](README.md) · [**English**](README.en.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Single File](https://img.shields.io/badge/single%20file-one%20.sh-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![No Docker](https://img.shields.io/badge/docker-not%20required-2496ED?style=flat-square&logo=docker&logoColor=white)
![UI](https://img.shields.io/badge/UI-plain%20text%20menu-000000?style=flat-square&logo=gnometerminal&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## What is this

`hermes-vps` is a **single-file Bash tool** (~2,900 lines, zero third-party dependencies) that turns the whole deployment and operations lifecycle of Hermes Agent on a Linux server into an interactive menu:

```
Install Hermes → pick a model (it verifies the model really answers) → connect chat platforms
              → automatic HTTPS via Caddy on your domain → systemd autostart → diagnose / backup / update / uninstall
```

The UI is a **plain text menu** — type a number and you are done. No dialog boxes, no jumping into vendor wizards; every setting is configured inside the script itself.

---

## ✨ Highlights

| | |
|---|---|
| 🎯 **One file does everything** | A single `.sh`. No framework, no Docker, no pile of scripts. Download it and run. |
| 🧠 **“It works” is verified, not assumed** | After you paste an API key it calls the provider's API directly (translating HTTP 200/401/402/404/429 into plain language) and then sends a real one-shot message through Hermes to prove model → toolchain → reply works end to end. |
| 💬 **Platform onboarding is verified too** | QQ exchanges a real `access_token`, Feishu a `tenant_access_token`, DingTalk an `accessToken`, Telegram `getMe`, Discord `users/@me`, Slack `auth.test`, Matrix `account/whoami` — only the vendor's own “yes” counts. |
| 📱 **QR codes render inside the script** | QQ / WeChat scan-to-login calls the official adapter functions directly: the QR is printed in your terminal, then credentials are written, the platform enabled, the gateway restarted and its connection log summarised. The vendor config UI never opens. |
| 🔐 **Secure by default** | Dashboard and API **bind to 127.0.0.1 only**; public traffic goes through Caddy; the dashboard requires authentication; services run as a dedicated system user `hermes`; all config changes go through the official CLI (never hand-edited YAML); the Caddyfile is validated before every reload. |
| 🇨🇳 **Ready for restricted networks** | Automatically benchmarks GitHub / PyPI mirrors and applies the fastest one — including git `insteadOf` and a user-level `uv.toml`, so later `hermes update` runs stay accelerated. |
| 🩺 **Self-check and rollback** | 22-point health check (services / ports / auth gate / API auth / certificate / credential permissions / platform connections / backups), a backup-restore drill that was actually performed on a real machine, one-command update with automatic pre-backup, and an uninstaller that lists every path before asking. |
| 🌏 **Docs in five languages** | 简体中文 / English / 繁體中文 / 日本語 / 한국어. |

---

## 🧩 Run modes: root and regular users are both supported

> **Identical layout to the official installer**: the official script runs entirely in user space (no root, no sudo/apt, it never touches system directories) — code goes to `$HERMES_HOME/hermes-agent`, the executable is `$HOME/.local/bin/hermes`, data lives in `$HERMES_HOME` (default `~/.hermes`).
> Both modes here pass `--hermes-home` / `--dir` explicitly, so paths match the official layout; system-wide mode merely runs it under the dedicated `hermes` service user (home `/opt/hermes`) so systemd can manage it and keep it isolated.


The script detects your identity at startup; both modes are fully usable with no extra flags:

| | **System-wide (root)** | **User mode (regular user)** |
|---|---|---|
| Config/state | `/etc/hermes-vps` | `~/.config/hermes-vps` |
| Logs | `/var/log/hermes-vps` | `~/.local/state/hermes-vps` |
| Backups | `/var/backups/hermes-vps` | `~/.local/share/hermes-vps/backups` |
| Hermes data | `/opt/hermes/.hermes` (dedicated `hermes` user) | `~/.hermes` (your own account) |
| Services | system `systemd` units (boot-start) | `systemd --user`; falls back to a **background process + PID file** when there is no user DBus |
| Domain + HTTPS (80/443) | ✅ built-in Caddy with automatic certificates | ⚠️ privileged: selecting it offers to re-run via `sudo` |
| Firewall / swap / OS packages | ✅ automatic | ⚠️ privileged (explicitly reported, never a silent failure) |
| Models / platforms (QQ, WeChat…)/ dashboard / backups / self-check | ✅ | ✅ |

```bash
# Regular user (user mode, touches nothing outside $HOME)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user

# root (system-wide; recommended, one instance per machine)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
```

Check the current mode with `hermes-vps mode`. The status panel also shows `模式:` and marks root-only entries as `需要 root`.

## 🚀 Quick start (60 seconds)

```bash
# 1) Log in to your server
ssh root@<your-server>

# 2) Install (picks up the latest Release, verifies sha256, installs to /usr/local/bin)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash

# 3) Open the menu (choose 1 on first run)
hermes-vps

# Other options
bash install.sh --check              # show installed vs latest
bash install.sh --version v1.0.0       # install a specific version
bash install.sh --to ~/.local/bin    # install somewhere else (non-root)
```

Pick `1` (one-click deploy) the first time: enter a domain (optional), choose a model provider, and the script does the rest. Expect 5–15 minutes depending on the machine and network.

### Requirements

| Item | Requirement |
|---|---|
| OS | Debian 10+ / Ubuntu 20.04+ (amd64 / arm64) |
| Privileges | root |
| Memory | ≥ 1 GB (below 1.8 GB with no swap, a 2 GB swapfile is created automatically to avoid OOM) |
| Disk | ≥ 2 GB free |
| Domain | Optional. For `https://your-domain` access, point an A record at the server's public IP and open ports 80/443 |
| Network | Direct or restricted — mirrors are probed automatically |

---

## 🖥 UI preview

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

> The tool's UI is currently in Simplified Chinese. Everything is plain text, so translating the menu strings is a small, self-contained edit.

---

## 🧭 Feature map

Every menu entry has an equivalent subcommand, so the tool is fully scriptable / unattended.

| Menu | Subcommand | Description |
|---|---|---|
| 1 One-click deploy | `install [--yes]` | 10-step pipeline, idempotent |
| 2 Model providers | `model` | 19 built-ins + custom OpenAI-compatible endpoints; direct API check + real conversation test |
| 3 Chat platforms | `platform` | QR platforms scan inside the script; credential platforms are verified immediately |
| 4 Domain & proxy | `domain <domain>` | Render Caddyfile → `caddy validate` → hot reload → issue certificate |
| 5 Dashboard & API | `panel` | Reset password, public URL, `/v1` toggle, live login test |
| 6 Service control | `service start\|stop\|restart\|status\|logs` | gateway / dashboard / caddy |
| 7 Diagnose | `diagnose` | 22 checks with per-item ✔/✘ |
| 8 Backup & restore | `backup` / `restore` | Config + credentials; restore merges in place, never breaks the install |
| 9 Update | `update` / `update auto-update on\|off` | Auto-backup before update; daily 04:30 timer |
| 10 Firewall | `firewall` | Only ever **adds** rules |
| 11 Network mirrors | `mirror --force` | Re-benchmark and apply |
| 12 Help | `help` | Commands and paths cheat sheet |
| 13 Uninstall | `uninstall` | Lists exact paths, confirms one by one |
| — | `selftest` | Checks the script itself (syntax / data tables / Caddyfile rendering / real `caddy validate`) |
| — | `self-install` | Installs itself to `/usr/local/bin/hermes-vps` |

Common flags: `--yes`, `--non-interactive`, `--force`, `--skip-browser` (smaller install), `--no-color`, `--debug`.

---

## 🤖 Model providers

19 built-ins — paste a key and go:

`DeepSeek` · `OpenRouter` · `Zhipu GLM` · `Kimi / Moonshot` · `Alibaba Qwen (DashScope)` · `MiniMax` · `OpenAI` · `Anthropic` · `Google Gemini` · `xAI Grok` · `DeepInfra` · `NovitaAI` · `Fireworks` · `NVIDIA NIM` · `Hugging Face` · `Xiaomi MiMo` · `Tencent TokenHub` · `StepFun` · **custom OpenAI-compatible endpoint** (vLLM / Ollama / One-API / your own gateway)

**Two-stage verification instead of “looks configured”**

1. **Direct provider check** — calls that provider's `/chat/completions` and reports within seconds, translating status codes into plain language: `401 invalid key`, `402 insufficient balance`, `404 wrong model or endpoint`, `429 rate limit / quota exhausted`, `000 network unreachable` — together with the vendor's own error text.
2. **Real conversation** — sends “reply with exactly one word” through Hermes, proving model, toolchain, session and reply all work.

---

## 💬 Chat platforms

| Platform | Onboarding | In-script verification |
|---|---|---|
| **QQ Bot** | Official Bot API v2 (QR scan or AppID/Secret) | Exchanges `getAppAccessToken`; only the vendor's acceptance counts |
| **Personal WeChat** | iLink QR login (QR rendered in the script) | Saved login state + gateway connection log |
| **WeCom** | AI bot (Bot ID / Secret) | WebSocket gateway connection log |
| **Feishu / Lark** | Long connection (App ID / Secret) | Exchanges `tenant_access_token` |
| **DingTalk** | Stream mode (ClientID / Secret) | Exchanges `accessToken` |
| **Telegram** | Bot token | `getMe` |
| **Discord** | Bot token | `users/@me` |
| **Slack** | Bot + app token (Socket Mode) | `auth.test` |
| **Matrix** | Homeserver + access token | `account/whoami` |
| **WhatsApp** | QR pairing | Gateway connection log |
| **Email** | IMAP + SMTP | Gateway connection log |
| **OpenAI-compatible API** | API key + port | No key → 401, with key → 200 |

After configuring, the tool restarts the gateway, summarises the connection log **for the current run only**, and can send a test message through the platform. The status panel mirrors the result (`connected` / `failed`).

> QR platforms render their QR code directly in this script's terminal (by calling the official adapter functions) — **it never opens the vendor setup UI**. If you do want the official wizard, run `hermes gateway setup` yourself.

---

## 🔐 Security design

- **Minimal exposure**: dashboard (9119) and OpenAI-compatible API (8642) **bind to `127.0.0.1` only**; public access always goes through Caddy.
- **Auth gate always on**: dashboard requires Basic Auth plus a random session secret; unauthenticated access is rejected. `public_url` is set to `https://your-domain`, so there is no window where a public URL is advertised without authentication.
- **Dedicated service user**: gateway and dashboard run as the system user `hermes` (never root), with `HERMES_HOME=/opt/hermes/.hermes`; interactive login for that user is disabled.
- **Config through the official CLI**: `hermes config set` (never hand-edited `config.yaml`, which can break a running gateway); secrets live only in `.env` (mode 0600).
- **Validate before applying**: the Caddyfile is checked with `caddy validate --adapter caddyfile` before reload; the previous file is backed up (last 5 kept).
- **Firewall only adds**: allows SSH (port auto-detected) + 80 + 443; never deletes or rewrites existing rules.
- **Credentials file 0600**: dashboard user/password, API key and session secret live in `/etc/hermes-vps/credentials.txt`.
- **Destructive operations never silent**: uninstall / restore / backup pruning always list exact paths and ask per item.

---

## 🏗 Architecture & on-disk layout

```
Source (this is all the repo contains; the release artifact is built by CI and never committed)
  lib/00-common.sh       core: constants / colours / logging / input primitives / state / run-as-service-user
  lib/10-input.sh        interactive primitives (plain text, no whiptail)
  lib/11-state.sh        key-value store / tool state / credentials
  lib/12-run.sh          run commands as the service user
  lib/20-system.sh       distro detection / dependencies / swap guard
  lib/21-mirror.sh       network mirrors (GitHub / PyPI benchmarking)
  lib/22-firewall.sh     firewall (add-only)
  lib/23-probe.sh        probes (ports / services / public IP / DNS)
  lib/30-hermes.sh       service user + Hermes install & update
  lib/31-model.sh        provider table + two-stage connectivity verification
  lib/40-platform.sh     platform table + vendor API verification + in-script QR
  lib/50-webui.sh        dashboard auth gate / credentials / public URL
  lib/51-service.sh      systemd units and service control
  lib/52-caddy.sh        Caddy install / render / validate / certificates
  lib/60-backup.sh       backup & restore / updates and auto-update
  lib/61-doctor.sh       health check (22 items)
  lib/62-lifecycle.sh    uninstall (per-path confirmation)
  lib/70-ui.sh           banner / status panel / menus
  lib/71-deploy.sh       one-click deploy orchestration
  lib/72-help.sh         help text
  lib/80-cli.sh          argument parsing and subcommand dispatch
  lib/90-selftest.sh     self-test
  bin/hermes-vps         entrypoint (`bash bin/hermes-vps` loads lib/ in dev)
  build.sh               assembles dist/hermes-vps.sh
  install.sh             install / upgrade from Releases (latest + sha256 check)
  tests/                 lint / smoke / strict / real caddy validation / routing / acceptance
  VERSION                version number; tags must be v$VERSION
  .github/workflows/     ci.yml (full test suite) + release.yml (build & publish on tag)
```

**Release flow**: bump `VERSION` → push tag `v$VERSION` → Actions runs the full suite, builds `hermes-vps.sh`, writes `.sha256` and creates the Release. Users only ever run `install.sh` and always get the same self-contained script.

| Path | Contents |
|---|---|
| `/opt/hermes/.hermes` | Hermes data: config, `.env` (secrets), skills, sessions, logs |
| `/opt/hermes` | Home of the `hermes` service user (runtime, virtualenv) |
| `/etc/hermes-vps/state.env` | Tool state (domain, toggles, version) |
| `/etc/hermes-vps/credentials.txt` | Dashboard user / password / API key / session secret (0600) |
| `/etc/hermes-vps/mirror.env` | Selected mirror channels |
| `/etc/caddy/Caddyfile` | Reverse proxy config (auto-backed-up to `.bak/`) |
| `/var/backups/hermes-vps/` | Backups (last 7 kept) |
| `/var/log/hermes-vps/hermes-vps.log` | Tool operation log |
| `$HERMES_HOME/logs/gateway.log` | Gateway runtime log (**platform connection verdicts live here**) |

systemd units: `hermes-gateway.service`, `hermes-dashboard.service`, `caddy.service` — all enabled at boot.

---

## 🧪 Quality & verification

This project was **accepted on a real VPS (Debian 13, 2 vCPU / 967 MB)**, not just “runs on my laptop”:

| Item | Result |
|---|---|
| One-click deploy (10 steps) | Zero errors; a second idempotent run is equally clean |
| `diagnose` health check | **22/22 passed** (services / ports / auth gate / API auth / certificate / credential permissions / platform connections / backups) |
| Caddyfile | Rendered by the production functions and accepted by **real `caddy validate`**; HTTPS probe 200; certificate issued automatically |
| Dashboard auth gate | Unauthenticated → 302/401; correct credentials → 200 with session cookies; wrong password → 401; login over the public HTTPS domain → 200 |
| OpenAI-compatible API | 401 without a key, 200 with it; reachable through the reverse proxy |
| Chat platform | QQ Bot completed a **real round trip** (inbound message → 3.7 s reply → delivered) |
| Backup / restore | Backup → delete a marker file → restore: marker back, services restarted, dashboard 200 |
| Uninstall preview | Lists every path and its purpose; keeps everything by default |
| Script self-test | `selftest` covers syntax, data tables, Caddyfile rendering and validating with the real binary |

---

## 🛠 FAQ

**Certificate issuance fails?**
The domain's A record must point at the server's public IP and ports 80/443 must be reachable from the internet (cloud security groups included). `hermes-vps diagnose` pinpoints the failing item.

**A 1 GB VPS can't finish the install?**
Below 1.8 GB of RAM with no swap, the script creates a 2 GB swapfile. This is a lesson from a real failure: the official installer was OOM-killed while bundling on a 1 GB box without swap.

**Slow or failing downloads on a restricted network?**
Menu 11 benchmarks GitHub / PyPI mirrors and applies the winner to git `insteadOf` and a user-level `uv.toml`, so later `hermes update` runs are accelerated too.

**I changed a platform but nothing happens?**
Restart the gateway (menu 6 → 4) or `hermes-vps service restart gateway`.

**A platform shows “failed” with no obvious error?**
Read `$HERMES_HOME/logs/gateway.log` (menu 6 → 7 tails it for you). Be careful to distinguish the **current run** from stale warnings left by a previous process.

**What does uninstall delete?**
Menu 13 lists every path and its purpose first, then asks per item; everything is kept by default and the backup directory is never deleted.

---

## 🧰 Developer notes: pitfalls found on real machines

Worth reading before editing this script (all from real deployments):

1. Under `set -Eeuo pipefail`, if a function's **last statement** is `[[ ]] && cmd`, a false test makes the function return non-zero and `set -e` aborts the caller — end such functions with `return 0` or rewrite as `if`.
2. `grep` returns 1 when nothing matches, which `pipefail` turns into a fatal error — every “read a value” helper must guard explicitly.
3. `openssl rand | tr | head` triggers SIGPIPE upstream; use `openssl rand -base64` and truncate afterwards.
4. An `ERR` trap must check `case "$-" in *e*)`, otherwise `set +e` fallback paths are misreported as fatal.
5. `caddy validate/fmt` needs `--adapter caddyfile` (a temp filename gives no hint and is parsed as JSON).
6. Caddy needs `/var/log/caddy` to exist with the right ownership before it starts.
7. Wait for `HERMES_DASHBOARD_READY` instead of `sleep 2` when health-checking the dashboard.
8. `tar` exit code 1 is a harmless warning; only 2 is a real failure. Never reference an already-deleted temp dir in a fallback branch.
9. Restoring a backup must merge in place and move only the files it overwrites — replacing whole directories breaks the install.
10. CJK characters occupy two terminal columns, so aligned menus must compute **display width**; in a one-line `case`, branches must be separated by `;;` rather than `;`.
11. CRLF in the source breaks Linux with `$'\r': command not found` — normalise to LF (`\.gitattributes` enforces it).
12. Platform connection verdicts are written to Hermes' own `logs/gateway.log` (not journald), and only the **current run** slice is meaningful.
13. To run official Python logic from your own script, use the official launcher's `--run-module` (dependencies live in the tool's own runtime) and run it **as the service user**.
14. Terminal QR rendering needs `qrcode`: `hermes pm install --extra messaging`.
15. Exclude reinstallable content (source tree, Python runtime) from backups, or they balloon from ~100 MB to ~800 MB.

---

## 📄 License

[MIT](LICENSE)

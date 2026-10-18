<div align="center">

# hermes-vps

**Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on a VPS with Docker Compose — one `.sh` file, from bare metal to a domain-protected dashboard and a chatbot in your messenger.**

No Compose file, no Caddyfile, no environment-variable hunting. Type numbers, get a running agent.

[简体中文](README.md) · [**English**](README.en.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Deploy](https://img.shields.io/badge/deploy-Docker%20Compose-2496ED?style=flat-square&logo=docker&logoColor=white)
![Image](https://img.shields.io/badge/image-Docker%20Hub%20%7C%20GHCR-0db7ed?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## What it is

`hermes-vps` is a single Bash tool that turns the whole VPS lifecycle into a text menu:

```
install Docker → pull the official image → render Compose → pick a model from the real provider list
                → connect messengers → Caddy HTTPS → containers on boot → doctor / backup / update / uninstall
```

## Highlights

| | |
|---|---|
| 🐳 **Docker Compose by default** | Pulls `dockorae/hermes-agent` (or GHCR) instead of compiling Python/Node/Chromium on the VPS. Updating is just a new image. |
| 🌐 **Domain + automatic HTTPS** | Enter a domain, Caddy obtains a certificate, and `https://your-domain` serves the dashboard. The dashboard and API stay bound to `127.0.0.1`. |
| 🧠 **Pick a model, don't guess its ID** | After the API key is entered, the tool calls the provider's `/models` endpoint and shows a real selectable list (DeepSeek V4.1 Flash, V4 Pro, …), with a built-in catalog fallback. |
| 🔐 **Secrets are masked with `*`** | API keys and bot tokens echo one `*` per character; length is visible, the value is not. |
| 🎯 **Connectivity is verified, not assumed** | Direct provider call (401/402/404 translated) plus a real one-line chat through Hermes. |
| 💬 **Messenger onboarding with vendor checks** | QQ, WeChat, WeCom, Feishu, DingTalk, Telegram, Discord, Slack, Matrix, WhatsApp, email, OpenAI-compatible API. |
| 📱 **QR codes printed in the terminal** | Official adapters run inside the container for QQ / WeChat pairing. |
| 🛡 **Safe defaults** | Container UID 10000, data owned by 10000, Compose 0600, credentials 0600, dashboard loopback-only, Caddy validates before reload. |
| 🩺 **Diagnostics and rollback** | Services, ports, auth gate, API auth, certificate, permissions, platform connections, backups. |
| 🌏 **Five languages** | 简体中文 / English / 繁體中文 / 日本語 / 한국어 |

## Run modes

| | **root (recommended)** | **regular user** |
|---|---|---|
| Deployment | **Docker Compose + official image (default)** | Native install under `$HOME` |
| Override | `--native` for a native root install | `--docker` prompts for sudo |
| Data | `/opt/hermes/.hermes` | `~/.hermes` |
| Services | `hermes-gateway`, `hermes-dashboard` containers | `systemd --user` or background process |
| Config/state | `/etc/hermes-vps` | `~/.config/hermes-vps` |
| Domain + HTTPS | ✅ built-in Caddy | ⚠️ needs root (`sudo` re-exec) |
| Model / platform / panel / backup / doctor | ✅ (official CLI inside the container) | ✅ |

Existing native installations are detected automatically and keep their systemd management.

```bash
# root, Docker Compose
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps

# regular user, native mode
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash
hermes-vps

hermes-vps mode      # e.g. 系统级(root) · 后端:docker
```

## Quick start

```bash
ssh root@<your-vps>
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps
# choose 1 → domain → image registry (Docker Hub / GHCR) → model from the list
```

Takes roughly 3–10 minutes, mostly pulling the ~1 GB image.

### Requirements

| Item | Requirement |
|---|---|
| OS | Debian 10+ / Ubuntu 20.04+ (amd64 / arm64) |
| Privileges | root for Docker deployment; native mode works as a regular user |
| RAM | ≥ 1 GB |
| Disk | ≥ 5 GB free (image ≈ 3 GB unpacked, plus data and backups) |
| Domain | A record pointing at the VPS, ports 80/443 reachable |
| Network | Docker Hub slow? choose GHCR or configure a registry mirror |

## Model configuration

1. Enter the API key — shown as `**********`; leaving it empty keeps the saved key.
2. The tool calls `/models` and lists actual models:

   ```
   Select model · DeepSeek
     Source: provider API · 2 models
       1) deepseek-flash     DeepSeek V4.1 Flash
       2) deepseek-v4-pro    DeepSeek V4 Pro
   ```

3. Choose a number; use `n`/`p` to page, `s` to search, `m` to type a custom ID.
4. If the endpoint is unavailable, the built-in catalog is used. For DeepSeek it contains `deepseek-flash`, `deepseek-v4-pro`, `deepseek-chat`, `deepseek-reasoner`.

Verification is two-stage: direct `/chat/completions` check, then a real chat through Hermes.

## Common commands

```bash
hermes-vps install                 # deploy / redeploy
hermes-vps install --image ghcr.io/minimaxflora/hermes-agent:0.22.2
hermes-vps model                   # provider + model picker
hermes-vps platform                # messengers
hermes-vps domain panel.example.com
hermes-vps service restart gateway
hermes-vps diagnose
hermes-vps backup / restore
hermes-vps update
hermes-vps uninstall
```

Flags: `--yes`, `--non-interactive`, `--force`, `--docker`, `--native`, `--image <ref>`, `--no-color`, `--debug`.

## Security

- Dashboard binds `127.0.0.1:9119` (override with `DASH_PORT`), API binds `127.0.0.1:8642`; only Caddy is public.
- Containers run as UID/GID 10000; `.env` and `config.yaml` are owned by 10000 and `.env` is 0600.
- Basic auth + random session secret are mandatory for the dashboard; `public_url` is set to the HTTPS domain.
- Configuration is written through the official `hermes config set` CLI inside the container.
- Compose file 0600, credentials 0600, Caddyfile validated before reload.
- Destructive operations list exact paths first and ask per item.

## Layout

```
Docker Engine
├── hermes-gateway    (host network, `gateway run`)
├── hermes-dashboard  (host network, `dashboard --host 127.0.0.1 --port 9119`)
└── /opt/hermes/.hermes → /opt/data

Caddy (80/443) → 127.0.0.1:9119 and 127.0.0.1:8642
```

| Path | Purpose |
|---|---|
| `/opt/hermes/.hermes` | Hermes data: config, `.env`, skills, sessions, logs |
| `/etc/hermes-vps/docker-compose.yml` | Generated Compose file (0600) |
| `/etc/hermes-vps/state.env` | Tool state (domain, image, flags) |
| `/etc/hermes-vps/credentials.txt` | Dashboard credentials and API key (0600) |
| `/etc/caddy/Caddyfile` | Reverse proxy |
| `/var/backups/hermes-vps/` | Backups (last 7) |

Source modules: `lib/13-docker.sh` (engine/Compose/image/service control), `lib/31-model.sh` (catalog + picker), `lib/10-input.sh` (masked input), plus the existing platform, Caddy, backup, doctor and UI modules.

## Testing

- `tests/lint.sh` — syntax, data tables, reproducible build (52 checks)
- `tests/smoke.sh` — 67 checks
- `tests/strict.sh` — 15 checks under `set -Eeuo pipefail`
- `tests/docker.sh` — 20 offline checks for image refs, Compose rendering, model catalog and backend selection
- Real deployment on Debian 13 + Docker 26 with `dockorae/hermes-agent:0.22.2`, including dashboard HTTP 200 and `config set/get` inside the container.

## FAQ

**Image pull is slow.** Use GHCR (`ghcr.io/minimaxflora/hermes-agent`) or configure a Docker registry mirror.

**Pin a version.** Set the image tag during deployment, or `hermes-vps install --image dockorae/hermes-agent:0.22.2`.

**Existing native install.** Detected automatically. To migrate: stop native services, then `sudo hermes-vps install --docker`; the data directory is reused.

**Dashboard 400 `Invalid Host header`.** The dashboard reads `dashboard.public_url` at startup. Run `hermes-vps domain <domain>` (it restarts the dashboard) or `hermes-vps service restart dashboard`.

**Certificate fails.** Check the A record and ports 80/443 (including the cloud security group); `hermes-vps diagnose` reports each item.

## License

[MIT](LICENSE)

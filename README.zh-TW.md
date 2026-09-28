<div align="center">

# hermes-vps

**在 VPS 上把 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 一鍵裝好、配好、跑起來 —— 只要一個 `.sh` 檔案。**

不用懂 Docker,不用手寫 Caddyfile,不必翻文件找環境變數。
從裸機到「用網域以 HTTPS 打開管理面板 + 在手機 QQ / 微信裡和自己的 AI 助理對話」,全程輸入數字即可。

[简体中文](README.md) · [English](README.en.md) · [**繁體中文**](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Single File](https://img.shields.io/badge/single%20file-one%20.sh-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![No Docker](https://img.shields.io/badge/docker-not%20required-2496ED?style=flat-square&logo=docker&logoColor=white)
![UI](https://img.shields.io/badge/UI-plain%20text%20menu-000000?style=flat-square&logo=gnometerminal&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## 這是什麼

`hermes-vps` 是一支**單檔 Bash 工具**(約 2900 行,無第三方相依),把 Hermes Agent 在 Linux 伺服器上的整套部署與維運流程做成互動式選單:

```
裝 Hermes → 選模型(自動驗證能不能真的對話) → 接訊息平台(QQ / 微信 / 飛書…)
        → Caddy 自動 HTTPS 網域存取 → systemd 常駐開機自啟 → 自檢 / 備份 / 更新 / 卸載
```

**純文字選單**,輸入編號即用,不彈任何對話框、不跳轉官方介面 —— 所有設定都在腳本內部完成。

---

## ✨ 亮點

| | |
|---|---|
| 🎯 **一個檔案搞定一切** | 單檔 `.sh`,不裝框架、不用 Docker、不留一堆腳本,`curl` 下來就能跑。 |
| 🧠 **「能連上」是驗證出來的,不是猜的** | 填完金鑰立刻直連廠商 API 校驗(HTTP 200 / 401 / 402 / 404 逐條翻譯),再透過 Hermes 真的發一句話,證明「模型 → 工具鏈 → 回覆」整條鏈路可用。 |
| 💬 **平台接入同樣要過官方 API 驗票** | QQ 換取 `access_token`、飛書換 `tenant_access_token`、釘釘換 `accessToken`、Telegram `getMe`、Discord `users/@me`、Slack `auth.test`、Matrix `account/whoami` —— 廠商自己說「認」才算通。 |
| 📱 **QR Code 直接出在腳本裡** | QQ / 微信掃碼授權走官方適配器函式,QR Code 印在自己的終端機,掃完自動寫憑證、啟用、重啟閘道並抓連線日誌。不會彈出官方設定介面。 |
| 🔐 **預設就是安全姿勢** | 面板與 API **只監聽 127.0.0.1**,公網一律經 Caddy;面板強制認證閘門;服務跑在專用系統使用者 `hermes` 下;設定改動全部走官方 CLI(不手改 YAML);Caddyfile 校驗通過才 reload。 |
| 🇨🇳 **為受限網路準備** | 自動測速選擇 GitHub / PyPI 加速通道,並把結果寫進 git `insteadOf` 與 `uv.toml`,讓後續 `hermes update` 也走加速。 |
| 🩺 **自檢與可回滾** | 22 項自檢(服務 / 埠 / 認證閘門 / API 鑑權 / 憑證 / 憑證檔權限 / 平台連線 / 備份),備份還原做過真機演練,一鍵更新自帶備份,卸載逐項列出路徑逐條確認。 |
| 🌏 **文件五語** | 简体中文 / English / 繁體中文 / 日本語 / 한국어。 |

---

## 🧩 執行模式:root 與一般使用者都支援

> **與官方安裝腳本的佈局完全一致**:官方腳本本身是純使用者空間的(不需要 root、不用 sudo/apt,也不碰系統目錄)——
> 程式碼在 `$HERMES_HOME/hermes-agent`、可執行檔是 `$HOME/.local/bin/hermes`、資料在 `$HERMES_HOME`(預設 `~/.hermes`)。
> 本工具兩種模式都明示傳 `--hermes-home` / `--dir`,路徑與官方一致;系統級模式只是額外交給專用服務使用者 `hermes`
> (家目錄 `/opt/hermes`)執行,以便用 systemd 託管並與一般使用者環境隔離。


腳本啟動時**自動判斷身分**,兩種模式都能用,不需要額外參數:

| | **系統級(root)** | **使用者態(一般使用者)** |
|---|---|---|
| 設定/狀態 | `/etc/hermes-vps` | `~/.config/hermes-vps` |
| 日誌 | `/var/log/hermes-vps` | `~/.local/state/hermes-vps` |
| 備份 | `/var/backups/hermes-vps` | `~/.local/share/hermes-vps/backups` |
| Hermes 資料 | `/opt/hermes/.hermes`(專用使用者 `hermes`) | `~/.hermes`(你自己的帳號) |
| 服務 | `systemd` 系統服務(開機自啟) | `systemd --user`;沒有使用者 DBus 時自動退回**背景程序 + PID 檔** |
| 網域 + HTTPS(80/443) | ✅ 內建 Caddy 自動簽憑證 | ⚠️ 需要特權:選到該功能會提示用 `sudo` 重新執行 |
| 防火牆 / swap / 系統套件 | ✅ 自動 | ⚠️ 需要特權(會明確提示,不會靜默失敗) |
| 模型 / 平台(QQ、微信…)/ 面板 / 備份 / 自檢 | ✅ | ✅ |

```bash
# 一般使用者直接跑(使用者態,不碰系統目錄)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user

# root 直接跑(系統級,推薦:一台機器一個實例)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
```

查看目前模式:`hermes-vps mode`。選單上方狀態面板也會顯示「模式:…」,僅 root 可用的項目會標註「需要 root」。

## 🚀 60 秒開始

```bash
# 1) 登入伺服器(root 或一般使用者都可以:兩種身分都支援)
ssh root@<你的伺服器>

# 2) 安裝並執行:root → 裝到 /usr/local/bin;一般使用者 → 裝到 ~/.local/bin
#    root
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps                     # 開啟互動選單(首次部署選 1,系統級)

#    一般使用者(不需要 root;全部落在 $HOME:資料 ~/.hermes、服務 systemd --user)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash
hermes-vps                          # 開啟互動選單(使用者態)
```

安裝器常用參數(管道形式要用 `bash -s --` 傳參;已存到本機則直接 `bash install.sh …`):

```bash
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --check            # 只看已裝版本 vs 最新版本
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --version v1.0.0   # 裝指定版本
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user             # 明確裝到 ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --system           # 明確裝到 /usr/local/bin(需 root)
```

第一次進入選單選 `1` 一鍵部署 —— 填網域(可留空)、選模型提供商,其餘它自己做完。
全程約 5~15 分鐘(取決於機器與網路)。

### 前置條件

| 項目 | 要求 |
|---|---|
| 系統 | Debian 10+ / Ubuntu 20.04+(amd64 / arm64) |
| 權限 | root |
| 記憶體 | ≥ 1GB(小於 1.8GB 且無 swap 時,腳本會自動建立 2GB swapfile 防 OOM) |
| 磁碟 | ≥ 2GB 可用 |
| 網域 | 選用。要 `https://網域` 存取需 A 記錄指向本機公網 IP,並放通 80/443 |
| 網路 | 直連或受限都能用:自動探測加速通道 |

---

## 🖥 介面預覽

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

> 目前選單介面文字為簡體中文;全部都是純文字,要改成其他語言只需替換字串。

---

## 🧭 功能地圖

每個選單項目都有等價的子命令,方便腳本化 / 無人值守。

| 選單 | 子命令 | 說明 |
|---|---|---|
| 1 一鍵部署 | `install [--yes]` | 10 步流程,可重複執行 |
| 2 模型提供商 | `model` | 19 家內建 + 自訂 OpenAI 相容端點;直連校驗 + 真實對話驗證 |
| 3 訊息平台 | `platform` | 掃碼類在腳本內出 QR;憑證類填完即驗票 |
| 4 網域與反向代理 | `domain <網域>` | 產生 Caddyfile → `caddy validate` → 熱重載 → 申請憑證 |
| 5 面板與 API | `panel` | 重設密碼、公網位址、`/v1` 開關、登入鏈路實測 |
| 6 服務管理 | `service start\|stop\|restart\|status\|logs` | 閘道 / 面板 / Caddy |
| 7 自檢與診斷 | `diagnose` | 22 項檢查,逐條 ✔/✘ |
| 8 備份與還原 | `backup` / `restore` | 含設定與憑證;還原就地合併,不破壞安裝 |
| 9 更新 | `update` / `update auto-update on\|off` | 更新前自動備份;每日 04:30 自動檢查 |
| 10 防火牆 | `firewall` | 只**新增**放行,絕不改動既有規則 |
| 11 網路加速 | `mirror --force` | 重新測速並套用 |
| 12 說明 | `help` | 命令與路徑速查 |
| 13 卸載 | `uninstall` | 先列精確路徑,再逐條確認 |
| — | `selftest` | 檢查腳本自身(語法 / 資料表 / Caddyfile 產生 / 真實 `caddy validate`) |
| — | `self-install` | 把自己裝到 `/usr/local/bin/hermes-vps` |

通用參數:`--yes`、`--non-interactive`、`--force`、`--skip-browser`(少裝瀏覽器元件,省記憶體)、`--no-color`、`--debug`。

---

## 🤖 模型提供商

內建 19 家,填金鑰即用:

`DeepSeek` · `OpenRouter` · `智譜 GLM` · `Kimi / Moonshot` · `阿里雲百鍊 Qwen` · `MiniMax` · `OpenAI` · `Anthropic` · `Google Gemini` · `xAI Grok` · `DeepInfra` · `NovitaAI` · `Fireworks` · `NVIDIA NIM` · `Hugging Face` · `小米 MiMo` · `騰訊 TokenHub` · `階躍星辰` · **自訂 OpenAI 相容端點**(vLLM / Ollama / One-API / 自建中轉)

**兩級驗證,拒絕「看起來配好了」**

1. **直連校驗** —— 直接請求該廠商的 `/chat/completions`,數秒內給結論,並把 HTTP 狀態翻成人話:
   `401 金鑰被拒` / `402 餘額不足` / `404 模型名或端點不對` / `429 限流或額度用盡` / `000 網路不可達`,並附廠商原始錯誤訊息。
2. **真實對話** —— 透過 Hermes 發一句「只回答兩個字:可用」,驗證模型、工具鏈、會話與回覆全鏈路。

---

## 💬 訊息平台

| 平台 | 接入方式 | 腳本內的驗證手段 |
|---|---|---|
| **QQ 機器人** | 官方 Bot API v2(掃碼上線 或 AppID/Secret) | `getAppAccessToken` 換取 token,官方認帳才通過 |
| **個人微信** | iLink 掃碼登入(QR 出在腳本裡) | 登入態落盤 + 閘道連線日誌 |
| **企業微信** | AI 機器人(Bot ID / Secret) | WebSocket 閘道連線日誌 |
| **飛書 / Lark** | 長連線(APP ID / Secret) | 換取 `tenant_access_token` |
| **釘釘** | Stream 模式(ClientID / Secret) | 換取 `accessToken` |
| **Telegram** | Bot Token | `getMe` |
| **Discord** | Bot Token | `users/@me` |
| **Slack** | Bot + App Token(Socket Mode) | `auth.test` |
| **Matrix** | Homeserver + Access Token | `account/whoami` |
| **WhatsApp** | 掃碼配對 | 閘道連線日誌 |
| **郵件助理** | IMAP + SMTP | 閘道連線日誌 |
| **OpenAI 相容 API** | API Key + 埠 | 無金鑰 → 401,帶金鑰 → 200 |

設定完成後自動重啟閘道、抓取**本次啟動以來**的連線日誌給出結論(面板頂部狀態列同步顯示「已連線 / 失敗」),也可以讓機器人發一則測試訊息驗證收發。

> 掃碼類平台的 QR Code 直接渲染在本腳本的終端機(呼叫官方適配器函式),**不會跳到官方設定介面**;想用官方介面的人自己敲 `hermes gateway setup` 即可。

---

## 🔐 安全設計

- **最小暴露面**:管理面板(9119)與 OpenAI 相容 API(8642)**只綁 `127.0.0.1`**;公網存取一律經 Caddy 反向代理。
- **認證閘門必開**:面板強制 Basic Auth + 會話金鑰(隨機產生),未登入存取被攔截;`public_url` 寫成 `https://網域`,杜絕「宣稱公網卻無認證」的窗口。
- **獨立服務使用者**:閘道與面板以系統使用者 `hermes` 執行(非 root),`HERMES_HOME=/opt/hermes/.hermes`;家目錄禁止互動登入。
- **設定改動走官方 CLI**:`hermes config set`(不手改 `config.yaml`,避免縮排破壞執行中的閘道);金鑰只寫 `.env`(0600)。
- **改設定先校驗才生效**:Caddyfile 先 `caddy validate --adapter caddyfile`,通過才 reload;原檔自動備份保留 5 份。
- **防火牆只做加法**:只放行 SSH(自動辨識埠)+ 80 + 443,不刪除、不改動任何既有規則。
- **憑證檔 0600**:面板帳號、密碼、API Key、會話金鑰集中寫在 `/etc/hermes-vps/credentials.txt`。
- **刪除類操作永不靜默**:卸載、還原、清理備份都會先列出精確路徑,逐條確認。

---

## 🏗 架構與落盤

```
原始碼(倉庫裡只有這些;發布產物由 CI 產生,不入庫)
  lib/00-common.sh       核心:常數 / 顏色 / 日誌 / 輸入原語 / 狀態儲存 / 以服務使用者執行
  lib/10-input.sh        互動原語(純文字,無 whiptail)
  lib/11-state.sh        鍵值儲存 / 狀態 / 憑證
  lib/12-run.sh          以服務使用者身分執行
  lib/20-system.sh       發行版探測 / 相依 / swap 保護
  lib/21-mirror.sh       網路加速(GitHub / PyPI 測速選優)
  lib/22-firewall.sh     防火牆(只增不減)
  lib/23-probe.sh        通用探測(埠 / 服務 / 公網 IP / 網域解析)
  lib/30-hermes.sh       服務使用者 + Hermes 安裝與更新
  lib/31-model.sh        模型提供商表 + 兩級連通驗證
  lib/40-platform.sh     訊息平台表 + 廠商 API 驗票 + 腳本內掃碼
  lib/50-webui.sh        面板認證閘門 / 憑證 / 公網位址
  lib/51-service.sh      systemd 單元與服務控制
  lib/52-caddy.sh        Caddy 安裝 / 產生 / 校驗 / 憑證
  lib/60-backup.sh       備份還原 / 更新與自動更新
  lib/61-doctor.sh       自檢診斷(22 項)
  lib/62-lifecycle.sh    卸載(逐項確認)
  lib/70-ui.sh           橫幅 / 狀態面板 / 各選單
  lib/71-deploy.sh       一鍵部署編排
  lib/72-help.sh         使用說明
  lib/80-cli.sh          參數解析與子命令分發
  lib/90-selftest.sh     腳本自檢
  bin/hermes-vps         入口(開發時直接 `bash bin/hermes-vps` 會自動載入 lib/)
  build.sh               拼裝成 dist/hermes-vps.sh
  install.sh             從 Release 安裝 / 升級(自動取最新版 + sha256 校驗)
  tests/                 lint / smoke / strict / 真實 caddy 校驗 / 路由行為 / 真機驗收
  VERSION                版本號;打 tag 必須是 v$VERSION
  .github/workflows/     ci.yml(全量測試) + release.yml(打 tag 時建置並發布)
```

**發布流程**:改 `VERSION` → 打 tag `v$VERSION` → Actions 跑全量測試、建置 `hermes-vps.sh`、產生 `.sha256` 並建立 Release。使用者端只需 `install.sh`,永遠拿到同一份自包含腳本。

| 路徑 | 內容 |
|---|---|
| `/opt/hermes/.hermes` | Hermes 資料:設定、`.env`(金鑰)、skills、會話、日誌 |
| `/opt/hermes` | 服務使用者 `hermes` 的家目錄(含執行環境與虛擬環境) |
| `/etc/hermes-vps/state.env` | 本工具狀態(網域、開關、版本) |
| `/etc/hermes-vps/credentials.txt` | 面板帳號 / 密碼 / API Key / 會話金鑰(0600) |
| `/etc/hermes-vps/mirror.env` | 已選用的加速通道 |
| `/etc/caddy/Caddyfile` | 反向代理設定(改動前自動備份到 `.bak/`) |
| `/var/backups/hermes-vps/` | 備份包(保留最近 7 份) |
| `/var/log/hermes-vps/hermes-vps.log` | 本工具操作日誌 |
| `$HERMES_HOME/logs/gateway.log` | 閘道執行日誌(**平台連線結論在這裡**) |

systemd 單元:`hermes-gateway.service`、`hermes-dashboard.service`、`caddy.service`,全部開機自啟。

---

## 🧪 品質與驗證

本專案在**真實 VPS(Debian 13,2 核 / 967MB)上完成驗收**,不是「本機跑通就算」:

| 驗收項 | 結果 |
|---|---|
| 一鍵部署 10 步流程 | 全程 0 錯誤,冪等重跑同樣乾淨 |
| 自檢 `diagnose` | **22 項全通過**(服務 / 埠 / 認證閘門 / API 鑑權 / 憑證 / 憑證檔權限 / 平台連線 / 備份) |
| Caddyfile | 以生產函式產生 + **真實 `caddy validate`** 通過,HTTPS 探活 200,憑證自動簽發 |
| 面板認證閘門 | 未登入 302/401 攔截;正確憑證登入 200 並下發會話 Cookie;錯誤密碼 401;經網域 HTTPS 登入 200 |
| OpenAI 相容 API | 無金鑰 401、帶金鑰 200,反代路徑可用 |
| 訊息平台 | QQ 機器人完成**真實收發**(收到訊息 → 3.7 秒生成回覆 → 成功投遞) |
| 備份 / 還原 | 備份 → 刪除標記檔 → 還原:標記回歸、服務自動拉起、面板 200 |
| 卸載預覽 | 逐項列出路徑與用途,預設全部保留 |
| 腳本自檢 | `selftest` 涵蓋語法、資料表、Caddyfile 產生與真實二進位校驗 |

---

## 🛠 常見問題

**憑證簽不下來?**
網域 A 記錄必須指向本機公網 IP,且 80/443 對公網可達(雲廠商安全群組也要放行)。`hermes-vps diagnose` 會逐項指出問題。

**1GB 小記憶體機器裝不動?**
腳本偵測到記憶體 < 1.8GB 且無 swap 時會自動建立 2GB swapfile。這是實測教訓:官方安裝器在 1GB 無 swap 的機器上被打包環節 OOM 殺掉過。

**受限網路下載慢 / 失敗?**
選單 11 會測速並選擇 GitHub / PyPI 加速通道,同時寫進 git `insteadOf` 與使用者層級 `uv.toml`,讓後續 `hermes update` 也走加速。

**改完平台沒反應?**
必須重啟閘道(選單 6 → 4),或 `hermes-vps service restart gateway`。

**平台顯示「失敗」但沒有明顯錯誤?**
看 `$HERMES_HOME/logs/gateway.log`(選單 6 → 7 直接 tail 它)。注意區分**本次啟動以來**的日誌與上一次執行的殘留告警。

**卸載會刪什麼?**
選單 13 會先逐項列出每個路徑與用途,再一條條問你,預設全部保留;備份目錄從不刪除。

---

## 🧰 開發者備忘:真機踩過的坑

改這支腳本前值得一讀(全部來自真實部署):

1. `set -Eeuo pipefail` 下,**函式最後一條敘述**若是 `[[ ]] && cmd`,判定失敗會讓函式回傳非零,`set -e` 在呼叫處終止腳本 —— 結尾統一 `return 0` 或改寫成 `if`。
2. `grep` 無符合回傳 1,經 `pipefail` 會中止;所有「取值」函式必須顯式兜底。
3. `openssl rand | tr | head` 會因 SIGPIPE 讓上游報錯;改用 `openssl rand -base64` 後截斷。
4. `ERR` 陷阱要判斷 `case "$-" in *e*)`,否則 `set +e` 的容錯回退路徑會被誤判為致命錯誤。
5. `caddy validate/fmt` 必須帶 `--adapter caddyfile`(臨時檔名沒有提示,會被當 JSON 解析)。
6. Caddy 執行前要準備好 `/var/log/caddy` 目錄與擁有者,否則服務起不來。
7. 面板健康檢查要等 `HERMES_DASHBOARD_READY`,固定 `sleep 2` 會誤報。
8. `tar` 離開碼 1 是無害警告,2 才是真失敗;回退分支裡別引用已刪除的臨時目錄。
9. 還原備份要「就地合併 + 只搬走將被覆蓋的檔案」,整目錄替換會把安裝弄殘。
10. 中文字元在終端佔 2 欄,畫對齊的選單必須按**顯示寬度**計算;`case` 單行寫法分支間必須是 `;;` 而非 `;`。
11. 原始碼帶 CRLF 時在 Linux 報 `$'\r': command not found` —— 提交前統一 LF(`.gitattributes` 已鎖)。
12. 平台的連線結論寫在 Hermes 自己的 `logs/gateway.log`(不是 journald),且必須只看**本次啟動以來**的片段,否則會被上一輪執行的失敗告警誤導。
13. 在自己腳本裡跑官方 Python 邏輯,要用官方啟動器的 `--run-module`(相依裝在工具自己的執行環境裡),並**以服務使用者身分**執行。
14. 需要 `qrcode` 才能渲染終端 QR Code:官方 `hermes pm install --extra messaging`。
15. 備份要排除可重裝內容(原始碼樹、Python 執行環境),否則體積從 ~100MB 漲到 ~800MB。

---

## 📄 授權

[MIT](LICENSE)

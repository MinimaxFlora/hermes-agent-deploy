<div align="center">

# hermes-vps

**VPS に [Hermes Agent](https://github.com/NousResearch/hermes-agent) を、`.sh` ファイル 1 つで導入・設定・運用。**

Docker は不要。Caddyfile を手書きする必要もなし。環境変数を探してドキュメントを掘る必要もなし。
まっさらなサーバーから「独自ドメインの HTTPS で管理パネルを開き、スマホの QQ / WeChat から自分の AI アシスタントと会話する」ところまで、番号を入力するだけで完了します。

[简体中文](README.md) · [English](README.en.md) · [繁體中文](README.zh-TW.md) · [**日本語**](README.ja.md) · [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Single File](https://img.shields.io/badge/single%20file-one%20.sh-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![No Docker](https://img.shields.io/badge/docker-not%20required-2496ED?style=flat-square&logo=docker&logoColor=white)
![UI](https://img.shields.io/badge/UI-plain%20text%20menu-000000?style=flat-square&logo=gnometerminal&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## これは何か

`hermes-vps` は **単一ファイルの Bash ツール**(約 2,900 行、外部依存なし)です。Linux サーバー上での Hermes Agent のデプロイと運用の全工程を、対話式メニューにまとめました。

```
Hermes 導入 → モデル選択(本当に応答するか自動検証) → チャットプラットフォーム接続(QQ / WeChat / Feishu …)
           → Caddy による自動 HTTPS(独自ドメイン) → systemd で常時起動 → 自己診断 / バックアップ / 更新 / アンインストール
```

UI は**プレーンテキストのメニュー**。番号を入力するだけです。ダイアログは一切表示されず、ベンダーの設定画面に飛ぶこともありません。すべての設定はこのスクリプト内で完結します。

---

## ✨ 特長

| | |
|---|---|
| 🎯 **ファイル 1 つで全部** | `.sh` 1 個だけ。フレームワーク不要、Docker 不要、スクリプトの山も残しません。ダウンロードして実行するだけ。 |
| 🧠 **「つながる」を検証で担保** | API キーを入力すると、まずプロバイダーの API を直接叩いて検証し(HTTP 200 / 401 / 402 / 404 / 429 を平易な日本語で説明)、続いて Hermes 経由で実際に一文を送信し、モデル → ツールチェーン → 返答の全経路が動くことを確認します。 |
| 💬 **プラットフォーム接続もベンダー API で確認** | QQ は `access_token`、Feishu は `tenant_access_token`、DingTalk は `accessToken`、Telegram は `getMe`、Discord は `users/@me`、Slack は `auth.test`、Matrix は `account/whoami`。ベンダー自身が「認めた」ときだけ成功とみなします。 |
| 📱 **QR コードはスクリプト内に表示** | QQ / WeChat の QR ログインは公式アダプター関数を直接呼び出し、QR コードをこのターミナルに表示。読み取り後は認証情報の保存・有効化・ゲートウェイ再起動・接続ログの要約まで自動です。公式の設定画面は開きません。 |
| 🔐 **既定でセキュア** | ダッシュボードと API は **127.0.0.1 のみにバインド**。公開アクセスは常に Caddy 経由。ダッシュボードは認証必須。サービスは専用システムユーザー `hermes` で実行。設定変更は公式 CLI 経由のみ(YAML を直接編集しません)。Caddyfile は検証を通ってから反映。 |
| 🇨🇳 **制限されたネットワークにも対応** | GitHub / PyPI のミラーを自動でベンチマークし、最速のものを選択。git `insteadOf` とユーザー単位の `uv.toml` に書き込むため、後続の `hermes update` も高速なままです。 |
| 🩺 **自己診断とロールバック** | 22 項目のヘルスチェック(サービス / ポート / 認証ゲート / API 認証 / 証明書 / 認証情報の権限 / プラットフォーム接続 / バックアップ)。バックアップからの復元は実機で訓練済み。更新時は自動バックアップ。アンインストールは全パスを列挙して 1 件ずつ確認します。 |
| 🌏 **ドキュメントは 5 言語** | 简体中文 / English / 繁體中文 / 日本語 / 한국어。 |

---

## 🧩 実行モード:root と一般ユーザーの両方をサポート

> **公式インストーラと同じレイアウト**:公式スクリプトは完全にユーザー空間で動作します(root 不要、sudo/apt 不要、システムディレクトリに触れません)——
> コードは `$HERMES_HOME/hermes-agent`、実行ファイルは `$HOME/.local/bin/hermes`、データは `$HERMES_HOME`(既定 `~/.hermes`)。
> 本ツールはどちらのモードでも `--hermes-home` / `--dir` を明示的に渡すため公式と同じパスになります。システムモードは専用サービスユーザー `hermes`
> (ホーム `/opt/hermes`)で動かす点だけが違い、systemd で管理し一般ユーザー環境と分離できます。


起動時に**自動判定**します。追加オプションなしでどちらのモードも使えます:

| | **システム全体(root)** | **ユーザーモード(一般ユーザー)** |
|---|---|---|
| 設定/状態 | `/etc/hermes-vps` | `~/.config/hermes-vps` |
| ログ | `/var/log/hermes-vps` | `~/.local/state/hermes-vps` |
| バックアップ | `/var/backups/hermes-vps` | `~/.local/share/hermes-vps/backups` |
| Hermes データ | `/opt/hermes/.hermes`(専用 `hermes` ユーザー) | `~/.hermes`(自分のアカウント) |
| サービス | `systemd` システムサービス(起動時有効) | `systemd --user`;ユーザー DBus が無い場合は**バックグラウンドプロセス + PID ファイル**に自動フォールバック |
| ドメイン + HTTPS(80/443) | ✅ 内蔵 Caddy が自動で証明書取得 | ⚠️ 特権が必要:選ぶと `sudo` での再実行を案内 |
| ファイアウォール / swap / OS パッケージ | ✅ 自動 | ⚠️ 特権が必要(明示的に通知、無言の失敗なし) |
| モデル / プラットフォーム(QQ、WeChat…)/ ダッシュボード / バックアップ / セルフチェック | ✅ | ✅ |

```bash
# 一般ユーザー(ユーザーモード、$HOME の外は触りません)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user

# root(システム全体。1 台 1 インスタンスを推奨)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
```

現在のモードは `hermes-vps mode` で確認できます。ステータスパネルにも「モード:…」が表示され、root 専用項目には「需要 root」と注記されます。

## 🚀 60 秒で開始

```bash
# 1) サーバーにログイン(root / 一般ユーザーのどちらでも可)
ssh root@<あなたのサーバー>

# 2) インストールして起動:root → /usr/local/bin、一般ユーザー → ~/.local/bin
#    root
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps                     # メニューを開く(初回は 1、システムモード)

#    一般ユーザー(root 不要。すべて $HOME 配下:データ ~/.hermes、サービスは systemd --user)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash
hermes-vps                          # メニューを開く(ユーザーモード)
```

インストーラの主なオプション(パイプ形式では `bash -s --` で引数を渡します。ローカルに保存済みなら `bash install.sh …`):

```bash
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --check            # 導入済みと最新版の比較
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --version v1.0.0   # バージョン指定
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user             # ~/.local/bin に導入
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --system           # /usr/local/bin に導入(root 必須)
```

最初はメニューの `1`(ワンクリック導入)を選択してください。ドメイン(空欄可)とモデルプロバイダーを入力すれば、あとは自動です。所要 5〜15 分(マシンとネットワーク次第)。

### 前提条件

| 項目 | 要件 |
|---|---|
| OS | Debian 10+ / Ubuntu 20.04+(amd64 / arm64) |
| 権限 | root |
| メモリ | 1 GB 以上(1.8 GB 未満かつ swap なしの場合、OOM 対策として 2 GB の swapfile を自動作成) |
| ディスク | 2 GB 以上の空き |
| ドメイン | 任意。`https://ドメイン` でアクセスするには A レコードをサーバーのグローバル IP に向け、80/443 を開放してください |
| ネットワーク | 直結・制限環境どちらも可(ミラーを自動検出) |

---

## 🖥 UI プレビュー

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

> 現在のメニュー表記は簡体字中国語です。すべてプレーンテキストなので、他言語化は文字列の置き換えだけで済みます。

---

## 🧭 機能マップ

メニューの各項目には等価なサブコマンドがあり、スクリプト化・無人運用が可能です。

| メニュー | サブコマンド | 説明 |
|---|---|---|
| 1 ワンクリック導入 | `install [--yes]` | 10 ステップ、冪等 |
| 2 モデルプロバイダー | `model` | 組み込み 19 社 + 独自の OpenAI 互換エンドポイント。直接検証 + 実会話テスト |
| 3 チャットプラットフォーム | `platform` | QR 系はスクリプト内で読み取り。認証情報系は即時検証 |
| 4 ドメイン / リバースプロキシ | `domain <ドメイン>` | Caddyfile 生成 → `caddy validate` → ホットリロード → 証明書取得 |
| 5 ダッシュボード / API | `panel` | パスワード再設定、公開 URL、`/v1` 切替、ログイン実測 |
| 6 サービス管理 | `service start\|stop\|restart\|status\|logs` | gateway / dashboard / caddy |
| 7 自己診断 | `diagnose` | 22 項目を ✔/✘ で表示 |
| 8 バックアップ / 復元 | `backup` / `restore` | 設定と認証情報を含む。復元はその場でマージし、導入を壊しません |
| 9 更新 | `update` / `update auto-update on\|off` | 更新前に自動バックアップ。毎日 04:30 のタイマー |
| 10 ファイアウォール | `firewall` | ルールの**追加のみ**。既存設定は変更しません |
| 11 ミラー | `mirror --force` | 再ベンチマークして適用 |
| 12 ヘルプ | `help` | コマンドとパスの早見表 |
| 13 アンインストール | `uninstall` | 正確なパスを列挙し、1 件ずつ確認 |
| — | `selftest` | スクリプト自身の検査(構文 / データ表 / Caddyfile 生成 / 実 `caddy validate`) |
| — | `self-install` | 自身を `/usr/local/bin/hermes-vps` に導入 |

共通オプション:`--yes`、`--non-interactive`、`--force`、`--skip-browser`(ブラウザー部品を省いて軽量化)、`--no-color`、`--debug`。

---

## 🤖 モデルプロバイダー

組み込み 19 社。キーを貼れば使えます:

`DeepSeek` · `OpenRouter` · `Zhipu GLM` · `Kimi / Moonshot` · `Alibaba Qwen (DashScope)` · `MiniMax` · `OpenAI` · `Anthropic` · `Google Gemini` · `xAI Grok` · `DeepInfra` · `NovitaAI` · `Fireworks` · `NVIDIA NIM` · `Hugging Face` · `Xiaomi MiMo` · `Tencent TokenHub` · `StepFun` · **独自の OpenAI 互換エンドポイント**(vLLM / Ollama / One-API / 自前のゲートウェイ)

**「設定したつもり」を排除する 2 段階検証**

1. **プロバイダー直接チェック** — そのプロバイダーの `/chat/completions` を実際に呼び、数秒で結論を出します。`401 キー無効` / `402 残高不足` / `404 モデル名またはエンドポイント誤り` / `429 レート制限・枠超過` / `000 ネットワーク到達不可` と、ベンダーの生のエラーメッセージも表示します。
2. **実会話テスト** — Hermes 経由で「一言だけ返答してください」と送信し、モデル・ツールチェーン・セッション・返答の全経路を確認します。

---

## 💬 チャットプラットフォーム

| プラットフォーム | 接続方法 | スクリプト内の検証 |
|---|---|---|
| **QQ ボット** | 公式 Bot API v2(QR または AppID/Secret) | `getAppAccessToken` でトークン取得。公式が認めたときのみ成功 |
| **個人 WeChat** | iLink QR ログイン(QR はスクリプト内に表示) | ログイン状態の保存 + ゲートウェイ接続ログ |
| **WeCom(企業微信)** | AI ボット(Bot ID / Secret) | WebSocket ゲートウェイ接続ログ |
| **Feishu / Lark** | 長接続(App ID / Secret) | `tenant_access_token` を取得 |
| **DingTalk** | Stream モード(ClientID / Secret) | `accessToken` を取得 |
| **Telegram** | Bot トークン | `getMe` |
| **Discord** | Bot トークン | `users/@me` |
| **Slack** | Bot + App トークン(Socket Mode) | `auth.test` |
| **Matrix** | Homeserver + アクセストークン | `account/whoami` |
| **WhatsApp** | QR ペアリング | ゲートウェイ接続ログ |
| **メール** | IMAP + SMTP | ゲートウェイ接続ログ |
| **OpenAI 互換 API** | API キー + ポート | キーなし → 401、あり → 200 |

設定後はゲートウェイを再起動し、**今回の起動以降**の接続ログを要約して結論を出します(パネル上部のステータスも「接続済み / 失敗」を表示)。プラットフォーム経由でテストメッセージを送ることもできます。

> QR 系プラットフォームの QR コードは**このスクリプトのターミナルに直接描画**されます(公式アダプター関数を呼び出し)。**公式の設定画面には遷移しません**。公式ウィザードを使いたい場合は、ご自身で `hermes gateway setup` を実行してください。

---

## 🔐 セキュリティ設計

- **露出を最小化**:ダッシュボード(9119)と OpenAI 互換 API(8642)は **`127.0.0.1` のみにバインド**。公開アクセスは常に Caddy 経由。
- **認証ゲートは常時有効**:ダッシュボードは Basic 認証 + ランダムなセッション秘密鍵を必須とし、未認証アクセスは拒否。`public_url` は `https://ドメイン` に設定し、「公開 URL を宣言したのに認証がない」状態を作りません。
- **専用サービスユーザー**:ゲートウェイとダッシュボードはシステムユーザー `hermes`(root ではない)で実行。`HERMES_HOME=/opt/hermes/.hermes`、対話ログインは無効化。
- **設定は公式 CLI 経由**:`hermes config set`(稼働中のゲートウェイを壊しうる `config.yaml` の直接編集はしません)。秘密情報は `.env`(0600)のみ。
- **反映前に検証**:Caddyfile は `caddy validate --adapter caddyfile` を通ってからリロード。旧ファイルは自動バックアップ(直近 5 世代)。
- **ファイアウォールは追加のみ**:SSH(ポート自動検出)+ 80 + 443 を許可。既存ルールの削除・変更は行いません。
- **認証情報ファイルは 0600**:ダッシュボードのユーザー / パスワード、API キー、セッション秘密鍵は `/etc/hermes-vps/credentials.txt` に集約。
- **削除系は決して無言で実行しない**:アンインストール / 復元 / バックアップ整理は、正確なパスを列挙して 1 件ずつ確認します。

---

## 🏗 アーキテクチャと保存先

```
ソース(リポジトリにあるのはこれだけ。リリース成果物は CI が生成し、コミットしません)
  lib/00-common.sh       コア:定数 / 色 / ログ / 入力プリミティブ / 状態保存 / サービスユーザー実行
  lib/10-input.sh        対話プリミティブ(プレーンテキスト、whiptail 不使用)
  lib/11-state.sh        キー値ストア / 状態 / 認証情報
  lib/12-run.sh          サービスユーザーとして実行
  lib/20-system.sh       ディストリビューション検出 / 依存 / swap 保護
  lib/21-mirror.sh       ミラー(GitHub / PyPI のベンチマーク)
  lib/22-firewall.sh     ファイアウォール(追加のみ)
  lib/23-probe.sh        各種検査(ポート / サービス / グローバル IP / DNS)
  lib/30-hermes.sh       サービスユーザー + Hermes の導入と更新
  lib/31-model.sh        プロバイダー表 + 2 段階の接続検証
  lib/40-platform.sh     プラットフォーム表 + ベンダー API 検証 + スクリプト内 QR
  lib/50-webui.sh        ダッシュボード認証ゲート / 認証情報 / 公開 URL
  lib/51-service.sh      systemd ユニットとサービス制御
  lib/52-caddy.sh        Caddy の導入 / 生成 / 検証 / 証明書
  lib/60-backup.sh       バックアップ復元 / 更新と自動更新
  lib/61-doctor.sh       ヘルスチェック(22 項目)
  lib/62-lifecycle.sh    アンインストール(パスごとに確認)
  lib/70-ui.sh           バナー / ステータスパネル / メニュー
  lib/71-deploy.sh       ワンクリック導入の編成
  lib/72-help.sh         ヘルプ
  lib/80-cli.sh          引数解析とサブコマンド振り分け
  lib/90-selftest.sh     セルフテスト
  bin/hermes-vps         エントリポイント(開発時は `bash bin/hermes-vps` で lib/ を読み込み)
  build.sh               dist/hermes-vps.sh を組み立てる
  install.sh             Release からの導入 / 更新(最新版 + sha256 検証)
  tests/                 lint / smoke / strict / 実 caddy 検証 / ルーティング / 受け入れ
  VERSION                バージョン。タグは v$VERSION でなければなりません
  .github/workflows/     ci.yml(全テスト) + release.yml(タグ時にビルド & 公開)
```

**リリース手順**:`VERSION` を上げる → タグ `v$VERSION` を push → Actions が全テストを実行し、`hermes-vps.sh` をビルドして `.sha256` を添えて Release を作成します。利用者は `install.sh` だけで常に同じ自己完結スクリプトを得られます。

| パス | 内容 |
|---|---|
| `/opt/hermes/.hermes` | Hermes データ:設定、`.env`(秘密情報)、skills、セッション、ログ |
| `/opt/hermes` | サービスユーザー `hermes` のホーム(ランタイム、仮想環境) |
| `/etc/hermes-vps/state.env` | ツールの状態(ドメイン、スイッチ、バージョン) |
| `/etc/hermes-vps/credentials.txt` | ダッシュボードのユーザー / パスワード / API キー / セッション秘密鍵(0600) |
| `/etc/hermes-vps/mirror.env` | 選択済みミラー |
| `/etc/caddy/Caddyfile` | リバースプロキシ設定(変更前に `.bak/` へ自動バックアップ) |
| `/var/backups/hermes-vps/` | バックアップ(直近 7 世代) |
| `/var/log/hermes-vps/hermes-vps.log` | 本ツールの操作ログ |
| `$HERMES_HOME/logs/gateway.log` | ゲートウェイのログ(**プラットフォーム接続の判定はここ**) |

systemd ユニット:`hermes-gateway.service`、`hermes-dashboard.service`、`caddy.service`(すべて起動時有効)。

---

## 🧪 品質と検証

本プロジェクトは**実 VPS(Debian 13、2 vCPU / 967 MB)で受け入れ試験を完了**しています。「手元で動いた」で終わらせていません。

| 項目 | 結果 |
|---|---|
| ワンクリック導入(10 ステップ) | エラー 0 件。2 回目の冪等実行もクリーン |
| `diagnose` | **22/22 合格**(サービス / ポート / 認証ゲート / API 認証 / 証明書 / 認証情報権限 / プラットフォーム接続 / バックアップ) |
| Caddyfile | 本番関数で生成し、**実 `caddy validate`** を通過。HTTPS は 200、証明書は自動発行 |
| ダッシュボード認証ゲート | 未認証 302/401、正しい認証情報で 200 + セッション Cookie、誤パスワード 401、公開 HTTPS ドメイン経由のログイン 200 |
| OpenAI 互換 API | キーなし 401、キーあり 200。リバースプロキシ経由で到達可能 |
| チャットプラットフォーム | QQ ボットで**実往復を達成**(受信 → 3.7 秒で返答生成 → 配信成功) |
| バックアップ / 復元 | バックアップ → マーカーファイル削除 → 復元:マーカー復帰、サービス自動復旧、ダッシュボード 200 |
| アンインストール予覧 | 全パスと用途を列挙し、既定ではすべて保持 |
| スクリプト自己検査 | `selftest` が構文・データ表・Caddyfile 生成・実バイナリ検証を網羅 |

---

## 🛠 FAQ

**証明書が発行されない**
ドメインの A レコードがサーバーのグローバル IP を指し、80/443 がインターネットから到達可能である必要があります(クラウドのセキュリティグループも含む)。`hermes-vps diagnose` が該当項目を指摘します。

**1 GB の VPS では導入が終わらない**
1.8 GB 未満かつ swap なしの場合、2 GB の swapfile を自動作成します。これは実測の教訓です。swap なしの 1 GB 環境で、公式インストーラーがバンドル処理中に OOM キラーに殺されました。

**制限ネットワークでダウンロードが遅い / 失敗する**
メニュー 11 が GitHub / PyPI のミラーを再ベンチマークし、勝者を git `insteadOf` とユーザー単位の `uv.toml` に書き込みます。以後の `hermes update` も高速化されます。

**プラットフォームを変更したのに反映されない**
ゲートウェイを再起動してください(メニュー 6 → 4、または `hermes-vps service restart gateway`)。

**「失敗」と表示されるがエラーが見当たらない**
`$HERMES_HOME/logs/gateway.log` を確認してください(メニュー 6 → 7 が tail します)。**今回の起動以降**のログと、前回プロセスの古い警告を混同しないよう注意してください。

**アンインストールで何が消える?**
メニュー 13 が最初に全パスと用途を列挙し、項目ごとに確認します。既定ではすべて保持され、バックアップディレクトリは決して削除しません。

---

## 🧰 開発者向けメモ:実機で踏んだ落とし穴

このスクリプトを編集する前に読む価値があります(すべて実際のデプロイから)。

1. `set -Eeuo pipefail` 下では、関数の**最後の文**が `[[ ]] && cmd` だと、判定が偽のとき関数が非ゼロを返し、`set -e` が呼び出し側でスクリプトを終了させます。`return 0` を付けるか `if` に書き換えてください。
2. `grep` は一致なしで 1 を返し、`pipefail` により致命的になります。「値を取り出す」ヘルパーは必ず明示的にガードしてください。
3. `openssl rand | tr | head` は SIGPIPE で上流がエラーになります。`openssl rand -base64` を使って切り詰めてください。
4. `ERR` トラップは `case "$-" in *e*)` を判定する必要があります。そうしないと `set +e` のフォールバック経路が致命的と誤判定されます。
5. `caddy validate/fmt` には `--adapter caddyfile` が必須(一時ファイル名ではヒントがなく JSON として解釈されます)。
6. Caddy は起動前に `/var/log/caddy` の存在と所有者を整える必要があります。
7. ダッシュボードのヘルスチェックは `sleep 2` ではなく `HERMES_DASHBOARD_READY` を待つこと。
8. `tar` の終了コード 1 は無害な警告、2 が本当の失敗です。フォールバック分岐で削除済みの一時ディレクトリを参照しないこと。
9. バックアップの復元は「その場でマージし、上書きされるファイルだけを退避」する必要があります。ディレクトリごと置換すると導入が壊れます。
10. CJK 文字は端末で 2 列を占めるため、整列したメニューは**表示幅**で計算する必要があります。1 行の `case` では分岐を `;` ではなく `;;` で区切ってください。
11. ソースに CRLF があると Linux で `$'\r': command not found` になります。LF に統一してください(`.gitattributes` で強制済み)。
12. プラットフォームの接続判定は Hermes 自身の `logs/gateway.log`(journald ではない)に書かれ、**今回の起動以降**の範囲のみが有効です。
13. 公式の Python ロジックを自作スクリプトから呼ぶには、公式ランチャーの `--run-module` を使い(依存はツール自身のランタイムにあります)、**サービスユーザーとして**実行してください。
14. 端末 QR 描画には `qrcode` が必要です: `hermes pm install --extra messaging`。
15. バックアップから再インストール可能な内容(ソースツリー、Python ランタイム)を除外しないと、約 100 MB が約 800 MB に膨らみます。

---

## 📄 ライセンス

[MIT](LICENSE)

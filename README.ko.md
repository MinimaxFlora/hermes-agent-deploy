<div align="center">

# hermes-vps

**VPS에 [Hermes Agent](https://github.com/NousResearch/hermes-agent)를 `.sh` 파일 하나로 설치·설정·운영합니다.**

Docker 필요 없음. Caddyfile을 직접 작성할 필요 없음. 환경 변수를 찾아 문서를 뒤질 필요도 없음.
빈 서버에서 “내 도메인의 HTTPS로 관리 패널 열기 + 휴대폰 QQ / WeChat에서 내 AI 비서와 대화”까지, 숫자만 입력하면 끝납니다.

[简体中文](README.md) · [English](README.en.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [**한국어**](README.ko.md)

![Platform](https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-A81D33?style=flat-square&logo=debian&logoColor=white)
![Arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED?style=flat-square)
![Single File](https://img.shields.io/badge/single%20file-one%20.sh-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![No Docker](https://img.shields.io/badge/docker-not%20required-2496ED?style=flat-square&logo=docker&logoColor=white)
![UI](https://img.shields.io/badge/UI-plain%20text%20menu-000000?style=flat-square&logo=gnometerminal&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-yellow?style=flat-square)

</div>

---

## 무엇인가요

`hermes-vps`는 **단일 파일 Bash 도구**(약 2,900줄, 외부 의존성 없음)로, Linux 서버에서의 Hermes Agent 배포·운영 전 과정을 대화형 메뉴로 정리했습니다.

```
Hermes 설치 → 모델 선택(실제로 응답하는지 자동 검증) → 메신저 플랫폼 연결(QQ / WeChat / Feishu …)
        → Caddy 자동 HTTPS(내 도메인) → systemd 상시 구동 → 자가진단 / 백업 / 업데이트 / 삭제
```

UI는 **일반 텍스트 메뉴**입니다. 번호만 입력하면 됩니다. 대화상자가 뜨지 않고 벤더 설정 화면으로 이동하지도 않습니다. 모든 설정은 이 스크립트 안에서 완결됩니다.

---

## ✨ 특징

| | |
|---|---|
| 🎯 **파일 하나로 전부** | `.sh` 하나뿐. 프레임워크도, Docker도, 스크립트 무더기도 없습니다. 내려받아 실행하면 끝. |
| 🧠 **“연결된다”를 검증으로 보장** | API 키를 넣으면 먼저 공급자 API를 직접 호출해 검증하고(HTTP 200 / 401 / 402 / 404 / 429를 알기 쉬운 문장으로 설명), 이어서 Hermes를 통해 실제로 한 문장을 보내 모델 → 도구 체인 → 응답의 전 경로를 확인합니다. |
| 💬 **플랫폼 연결도 벤더 API로 확인** | QQ는 `access_token`, Feishu는 `tenant_access_token`, DingTalk는 `accessToken`, Telegram은 `getMe`, Discord는 `users/@me`, Slack은 `auth.test`, Matrix는 `account/whoami`. 벤더가 “인정”할 때만 통과로 봅니다. |
| 📱 **QR 코드는 스크립트 안에서 표시** | QQ / WeChat QR 로그인은 공식 어댑터 함수를 직접 호출해 QR을 이 터미널에 출력합니다. 스캔 후에는 자격 증명 저장·활성화·게이트웨이 재시작·연결 로그 요약까지 자동입니다. 공식 설정 화면은 열지 않습니다. |
| 🔐 **기본이 안전한 구성** | 대시보드와 API는 **127.0.0.1에만 바인딩**되고, 공개 트래픽은 항상 Caddy를 거칩니다. 대시보드는 인증 필수. 서비스는 전용 시스템 사용자 `hermes`로 실행. 설정 변경은 공식 CLI로만(YAML 직접 편집 금지). Caddyfile은 검증을 통과해야 반영됩니다. |
| 🇨🇳 **제한된 네트워크 대비** | GitHub / PyPI 미러를 자동으로 벤치마크해 가장 빠른 것을 선택하고, git `insteadOf`와 사용자 단위 `uv.toml`에 기록해 이후 `hermes update`도 빠르게 유지합니다. |
| 🩺 **자가진단과 롤백** | 22개 항목 점검(서비스 / 포트 / 인증 게이트 / API 인증 / 인증서 / 자격 증명 권한 / 플랫폼 연결 / 백업). 백업 복원은 실제 장비에서 리허설 완료. 업데이트 시 자동 백업. 삭제는 모든 경로를 나열하고 하나씩 확인합니다. |
| 🌏 **문서 5개 언어** | 简体中文 / English / 繁體中文 / 日本語 / 한국어. |

---

## 🧩 실행 모드: root 와 일반 사용자 모두 지원

> **공식 설치 스크립트와 레이아웃이 동일합니다**: 공식 스크립트는 완전히 사용자 공간에서 동작합니다(root 불필요, sudo/apt 불필요, 시스템 디렉터리를 건드리지 않음) —
> 코드는 `$HERMES_HOME/hermes-agent`, 실행 파일은 `$HOME/.local/bin/hermes`, 데이터는 `$HERMES_HOME`(기본 `~/.hermes`).
> 이 도구는 두 모드 모두 `--hermes-home` / `--dir` 를 명시적으로 전달하므로 경로가 공식과 같습니다. 시스템 모드는 전용 서비스 사용자 `hermes`
> (홈 `/opt/hermes`)로 실행해 systemd 로 관리하고 일반 사용자 환경과 분리한다는 점만 다릅니다.


시작할 때 **자동 판별**하며, 추가 옵션 없이 두 모드 모두 사용할 수 있습니다:

| | **시스템 모드(root)** | **사용자 모드(일반 사용자)** |
|---|---|---|
| 설정/상태 | `/etc/hermes-vps` | `~/.config/hermes-vps` |
| 로그 | `/var/log/hermes-vps` | `~/.local/state/hermes-vps` |
| 백업 | `/var/backups/hermes-vps` | `~/.local/share/hermes-vps/backups` |
| Hermes 데이터 | `/opt/hermes/.hermes` (전용 `hermes` 계정) | `~/.hermes` (본인 계정) |
| 서비스 | `systemd` 시스템 서비스(부팅 시 자동 시작) | `systemd --user`; 사용자 DBus 가 없으면 **백그라운드 프로세스 + PID 파일** 로 자동 전환 |
| 도메인 + HTTPS(80/443) | ✅ 내장 Caddy 자동 인증서 | ⚠️ 권한 필요: 선택 시 `sudo` 재실행 안내 |
| 방화벽 / swap / 시스템 패키지 | ✅ 자동 | ⚠️ 권한 필요(명확히 안내, 조용한 실패 없음) |
| 모델 / 플랫폼(QQ, WeChat…)/ 대시보드 / 백업 / 자가진단 | ✅ | ✅ |

```bash
# 일반 사용자(사용자 모드, $HOME 밖은 건드리지 않음)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user

# root(시스템 모드, 머신당 1개 인스턴스 권장)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
```

현재 모드는 `hermes-vps mode` 로 확인합니다. 상태 패널에도 「模式:…」이 표시되고, root 전용 항목은 「需要 root」로 표시됩니다.

## 🚀 60초 시작하기

```bash
# 1) 서버 접속(root 또는 일반 사용자 모두 가능)
ssh root@<서버 주소>

# 2) 설치 및 실행: root → /usr/local/bin, 일반 사용자 → ~/.local/bin
#    root
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | sudo bash
sudo hermes-vps                     # 메뉴 열기(첫 실행은 1, 시스템 모드)

#    일반 사용자(root 불필요. 모두 $HOME 하위: 데이터 ~/.hermes, 서비스는 systemd --user)
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash
hermes-vps                          # 메뉴 열기(사용자 모드)
```

설치 스크립트 주요 옵션(파이프 형식에서는 `bash -s --` 로 인자 전달, 로컬에 저장했다면 `bash install.sh …`):

```bash
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --check            # 설치본과 최신 버전 비교
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --version v1.0.0   # 특정 버전 설치
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --user             # ~/.local/bin 에 설치
curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/hermes-agent-deploy/main/install.sh | bash -s -- --system           # /usr/local/bin 에 설치(root 필요)
```

처음에는 메뉴에서 `1`(원클릭 배포)을 선택하세요. 도메인(비워도 됨)과 모델 공급자를 입력하면 나머지는 자동입니다. 보통 5~15분(장비와 네트워크에 따라 다름).

### 사전 요구 사항

| 항목 | 요구 사항 |
|---|---|
| 운영체제 | Debian 10+ / Ubuntu 20.04+(amd64 / arm64) |
| 권한 | root |
| 메모리 | 1GB 이상(1.8GB 미만이고 swap이 없으면 OOM 방지를 위해 2GB swapfile 자동 생성) |
| 디스크 | 2GB 이상 여유 |
| 도메인 | 선택. `https://도메인` 접속에는 A 레코드를 서버 공인 IP로 지정하고 80/443을 열어야 합니다 |
| 네트워크 | 직결·제한 환경 모두 가능(미러 자동 탐색) |

---

## 🖥 UI 미리보기

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

> 현재 메뉴 문구는 중국어 간체입니다. 모두 일반 텍스트이므로 다른 언어로 바꾸려면 문자열만 교체하면 됩니다.

---

## 🧭 기능 맵

모든 메뉴 항목에는 동일한 하위 명령이 있어 스크립트·무인 운영이 가능합니다.

| 메뉴 | 하위 명령 | 설명 |
|---|---|---|
| 1 원클릭 배포 | `install [--yes]` | 10단계, 멱등 실행 |
| 2 모델 공급자 | `model` | 내장 19개 + 사용자 정의 OpenAI 호환 엔드포인트. 직접 검증 + 실제 대화 테스트 |
| 3 메신저 플랫폼 | `platform` | QR 계열은 스크립트 안에서 스캔. 자격 증명 계열은 즉시 검증 |
| 4 도메인 / 리버스 프록시 | `domain <도메인>` | Caddyfile 렌더링 → `caddy validate` → 핫 리로드 → 인증서 발급 |
| 5 대시보드 / API | `panel` | 비밀번호 재설정, 공개 URL, `/v1` 토글, 로그인 실측 |
| 6 서비스 관리 | `service start\|stop\|restart\|status\|logs` | gateway / dashboard / caddy |
| 7 자가진단 | `diagnose` | 22개 항목을 ✔/✘로 표시 |
| 8 백업 / 복원 | `backup` / `restore` | 설정과 자격 증명 포함. 복원은 제자리 병합으로 설치를 깨지 않음 |
| 9 업데이트 | `update` / `update auto-update on\|off` | 업데이트 전 자동 백업. 매일 04:30 타이머 |
| 10 방화벽 | `firewall` | 규칙을 **추가만** 함. 기존 규칙은 건드리지 않음 |
| 11 미러 | `mirror --force` | 재측정 후 적용 |
| 12 도움말 | `help` | 명령·경로 요약 |
| 13 삭제 | `uninstall` | 정확한 경로를 나열하고 하나씩 확인 |
| — | `selftest` | 스크립트 자체 점검(문법 / 데이터 표 / Caddyfile 렌더링 / 실제 `caddy validate`) |
| — | `self-install` | 자신을 `/usr/local/bin/hermes-vps`에 설치 |

공용 옵션: `--yes`, `--non-interactive`, `--force`, `--skip-browser`(브라우저 구성요소 생략으로 경량화), `--no-color`, `--debug`.

---

## 🤖 모델 공급자

내장 19개 — 키만 붙여넣으면 됩니다:

`DeepSeek` · `OpenRouter` · `Zhipu GLM` · `Kimi / Moonshot` · `Alibaba Qwen (DashScope)` · `MiniMax` · `OpenAI` · `Anthropic` · `Google Gemini` · `xAI Grok` · `DeepInfra` · `NovitaAI` · `Fireworks` · `NVIDIA NIM` · `Hugging Face` · `Xiaomi MiMo` · `Tencent TokenHub` · `StepFun` · **사용자 정의 OpenAI 호환 엔드포인트**(vLLM / Ollama / One-API / 자체 게이트웨이)

**“설정한 척”을 배제하는 2단계 검증**

1. **공급자 직접 검사** — 해당 공급자의 `/chat/completions`를 실제 호출해 몇 초 안에 결론을 냅니다. `401 키 거부` / `402 잔액 부족` / `404 모델명·엔드포인트 오류` / `429 속도 제한·할당 소진` / `000 네트워크 도달 불가`와 벤더의 원문 오류까지 함께 보여줍니다.
2. **실제 대화 테스트** — Hermes를 통해 “한 단어로만 답하세요”를 보내 모델·도구 체인·세션·응답 전 경로를 확인합니다.

---

## 💬 메신저 플랫폼

| 플랫폼 | 연결 방식 | 스크립트 내 검증 |
|---|---|---|
| **QQ 봇** | 공식 Bot API v2(QR 또는 AppID/Secret) | `getAppAccessToken`으로 토큰 교환. 공식이 인정해야 통과 |
| **개인 WeChat** | iLink QR 로그인(QR은 스크립트에 표시) | 로그인 상태 저장 + 게이트웨이 연결 로그 |
| **WeCom(기업 위챗)** | AI 봇(Bot ID / Secret) | WebSocket 게이트웨이 연결 로그 |
| **Feishu / Lark** | 롱 커넥션(App ID / Secret) | `tenant_access_token` 교환 |
| **DingTalk** | Stream 모드(ClientID / Secret) | `accessToken` 교환 |
| **Telegram** | Bot 토큰 | `getMe` |
| **Discord** | Bot 토큰 | `users/@me` |
| **Slack** | Bot + App 토큰(Socket Mode) | `auth.test` |
| **Matrix** | Homeserver + 액세스 토큰 | `account/whoami` |
| **WhatsApp** | QR 페어링 | 게이트웨이 연결 로그 |
| **이메일** | IMAP + SMTP | 게이트웨이 연결 로그 |
| **OpenAI 호환 API** | API 키 + 포트 | 키 없음 → 401, 키 있음 → 200 |

설정 후 게이트웨이를 자동 재시작하고 **이번 기동 이후**의 연결 로그를 요약해 결론을 제공합니다(패널 상단 상태 표시줄도 연결됨 / 실패를 표시). 플랫폼으로 테스트 메시지를 보내 송수신을 확인할 수도 있습니다.

> QR 계열 플랫폼의 QR 코드는 **이 스크립트의 터미널에 직접 렌더링**됩니다(공식 어댑터 함수 호출). **공식 설정 화면으로 이동하지 않습니다.** 공식 마법사를 쓰려면 직접 `hermes gateway setup`을 실행하세요.

---

## 🔐 보안 설계

- **노출 최소화**: 대시보드(9119)와 OpenAI 호환 API(8642)는 **`127.0.0.1`에만 바인딩**되고, 공개 접근은 항상 Caddy를 통합니다.
- **인증 게이트 상시 활성**: 대시보드는 Basic 인증 + 무작위 세션 시크릿을 요구하며, 미인증 접근은 차단됩니다. `public_url`은 `https://도메인`으로 설정해 “공개 URL을 선언했는데 인증이 없는” 상태를 만들지 않습니다.
- **전용 서비스 사용자**: 게이트웨이와 대시보드는 시스템 사용자 `hermes`(root 아님)로 실행되고 `HERMES_HOME=/opt/hermes/.hermes`를 사용하며, 대화형 로그인은 비활성화됩니다.
- **설정은 공식 CLI로**: `hermes config set`(실행 중인 게이트웨이를 깨뜨릴 수 있는 `config.yaml` 직접 편집은 하지 않음). 시크릿은 `.env`(0600)에만 기록.
- **검증 후 반영**: Caddyfile은 `caddy validate --adapter caddyfile`을 통과해야 리로드하며, 이전 파일은 자동 백업(최근 5개 유지).
- **방화벽은 추가만**: SSH(포트 자동 감지) + 80 + 443 허용. 기존 규칙을 삭제하거나 수정하지 않습니다.
- **자격 증명 파일 0600**: 대시보드 계정·비밀번호·API 키·세션 시크릿은 `/etc/hermes-vps/credentials.txt`에 모아 둡니다.
- **삭제 작업은 조용히 하지 않음**: 삭제·복원·백업 정리는 정확한 경로를 나열하고 항목별로 확인합니다.

---

## 🏗 구조와 저장 위치

```
소스(저장소에는 이것만 있습니다. 릴리스 산출물은 CI가 만들며 커밋하지 않습니다)
  lib/00-common.sh       코어: 상수 / 색상 / 로그 / 입력 프리미티브 / 상태 저장 / 서비스 사용자 실행
  lib/10-input.sh        대화형 프리미티브(일반 텍스트, whiptail 없음)
  lib/11-state.sh        키-값 저장 / 상태 / 자격 증명
  lib/12-run.sh          서비스 사용자로 실행
  lib/20-system.sh       배포판 감지 / 의존성 / swap 보호
  lib/21-mirror.sh       미러(GitHub / PyPI 벤치마크)
  lib/22-firewall.sh     방화벽(추가만)
  lib/23-probe.sh        각종 점검(포트 / 서비스 / 공인 IP / DNS)
  lib/30-hermes.sh       서비스 사용자 + Hermes 설치와 업데이트
  lib/31-model.sh        공급자 표 + 2단계 연결 검증
  lib/40-platform.sh     플랫폼 표 + 벤더 API 검증 + 스크립트 내 QR
  lib/50-webui.sh        대시보드 인증 게이트 / 자격 증명 / 공개 URL
  lib/51-service.sh      systemd 유닛과 서비스 제어
  lib/52-caddy.sh        Caddy 설치 / 렌더링 / 검증 / 인증서
  lib/60-backup.sh       백업 복원 / 업데이트와 자동 업데이트
  lib/61-doctor.sh       헬스체크(22개 항목)
  lib/62-lifecycle.sh    삭제(경로별 확인)
  lib/70-ui.sh           배너 / 상태 패널 / 메뉴
  lib/71-deploy.sh       원클릭 배포 오케스트레이션
  lib/72-help.sh         도움말
  lib/80-cli.sh          인자 파싱과 하위 명령 디스패치
  lib/90-selftest.sh     자체 점검
  bin/hermes-vps         진입점(개발 시 `bash bin/hermes-vps`가 lib/를 로드)
  build.sh               dist/hermes-vps.sh 조립
  install.sh             Release에서 설치 / 업그레이드(최신 + sha256 검증)
  tests/                 lint / smoke / strict / 실제 caddy 검증 / 라우팅 / 인수 테스트
  VERSION                버전. 태그는 v$VERSION 이어야 합니다
  .github/workflows/     ci.yml(전체 테스트) + release.yml(태그 시 빌드 & 배포)
```

**릴리스 흐름**: `VERSION` 수정 → 태그 `v$VERSION` 푸시 → Actions가 전체 테스트를 돌리고 `hermes-vps.sh`를 빌드해 `.sha256`과 함께 Release를 만듭니다. 사용자는 `install.sh`만 실행하면 항상 같은 자체 완결 스크립트를 받습니다.

| 경로 | 내용 |
|---|---|
| `/opt/hermes/.hermes` | Hermes 데이터: 설정, `.env`(시크릿), skills, 세션, 로그 |
| `/opt/hermes` | 서비스 사용자 `hermes`의 홈(런타임, 가상환경) |
| `/etc/hermes-vps/state.env` | 도구 상태(도메인, 토글, 버전) |
| `/etc/hermes-vps/credentials.txt` | 대시보드 계정 / 비밀번호 / API 키 / 세션 시크릿(0600) |
| `/etc/hermes-vps/mirror.env` | 선택된 미러 채널 |
| `/etc/caddy/Caddyfile` | 리버스 프록시 설정(변경 전 `.bak/`에 자동 백업) |
| `/var/backups/hermes-vps/` | 백업(최근 7개 유지) |
| `/var/log/hermes-vps/hermes-vps.log` | 도구 동작 로그 |
| `$HERMES_HOME/logs/gateway.log` | 게이트웨이 로그(**플랫폼 연결 판정이 여기에 있음**) |

systemd 유닛: `hermes-gateway.service`, `hermes-dashboard.service`, `caddy.service` — 모두 부팅 시 자동 시작.

---

## 🧪 품질과 검증

이 프로젝트는 **실제 VPS(Debian 13, 2 vCPU / 967MB)에서 인수 테스트를 마쳤습니다**. “노트북에서 돌아갔다” 수준이 아닙니다.

| 항목 | 결과 |
|---|---|
| 원클릭 배포(10단계) | 오류 0건. 두 번째 멱등 실행도 깨끗함 |
| `diagnose` | **22/22 통과**(서비스 / 포트 / 인증 게이트 / API 인증 / 인증서 / 자격 증명 권한 / 플랫폼 연결 / 백업) |
| Caddyfile | 운영 함수로 렌더링하고 **실제 `caddy validate`** 통과. HTTPS 200, 인증서 자동 발급 |
| 대시보드 인증 게이트 | 미인증 302/401, 올바른 자격 증명 200 + 세션 쿠키, 잘못된 비밀번호 401, 공개 HTTPS 도메인 경유 로그인 200 |
| OpenAI 호환 API | 키 없음 401, 키 있음 200. 리버스 프록시 경로로 도달 가능 |
| 메신저 플랫폼 | QQ 봇 **실제 왕복 성공**(수신 → 3.7초 응답 생성 → 전송 완료) |
| 백업 / 복원 | 백업 → 표식 파일 삭제 → 복원: 표식 복귀, 서비스 자동 기동, 대시보드 200 |
| 삭제 미리보기 | 모든 경로와 용도를 나열하고 기본은 전부 유지 |
| 스크립트 자체 점검 | `selftest`가 문법·데이터 표·Caddyfile 렌더링·실제 바이너리 검증을 포함 |

---

## 🛠 FAQ

**인증서 발급이 실패합니다**
도메인의 A 레코드가 서버 공인 IP를 가리켜야 하고 80/443이 인터넷에서 도달 가능해야 합니다(클라우드 보안 그룹 포함). `hermes-vps diagnose`가 문제 항목을 짚어 줍니다.

**1GB VPS에서 설치가 끝나지 않습니다**
1.8GB 미만이고 swap이 없으면 2GB swapfile을 자동 생성합니다. 실제 교훈입니다. swap 없는 1GB 환경에서 공식 설치 프로그램이 번들링 단계에서 OOM 킬러에 종료되었습니다.

**제한 네트워크에서 다운로드가 느리거나 실패합니다**
메뉴 11이 GitHub / PyPI 미러를 재측정해 최적을 git `insteadOf`와 사용자 단위 `uv.toml`에 기록합니다. 이후 `hermes update`도 가속됩니다.

**플랫폼을 바꿨는데 반영되지 않습니다**
게이트웨이를 재시작하세요(메뉴 6 → 4, 또는 `hermes-vps service restart gateway`).

**“실패”로 표시되는데 뚜렷한 오류가 없습니다**
`$HERMES_HOME/logs/gateway.log`를 확인하세요(메뉴 6 → 7에서 바로 tail). **이번 기동 이후** 로그와 이전 프로세스가 남긴 경고를 혼동하지 마세요.

**삭제하면 무엇이 지워지나요?**
메뉴 13이 먼저 모든 경로와 용도를 나열하고 항목별로 확인합니다. 기본은 전부 유지이며 백업 디렉터리는 절대 삭제하지 않습니다.

---

### 도메인으로 접속하면 `{"detail":"Invalid Host header. Dashboard requests must use the bound hostname or the configured public hostname."}` 가 뜹니다

대시보드는 **바인딩한 호스트명(127.0.0.1)** 또는 **`dashboard.public_url` 의 호스트명**만 허용하며,
이 허용 목록은 **시작할 때 읽습니다**. 도메인 설정 후 대시보드를 재시작하세요:

```bash
sudo systemctl restart hermes-dashboard     # 시스템 모드(root 설치)
systemctl --user restart hermes-dashboard   # 사용자 모드(메뉴 6 에서도 가능)
```

`hermes-vps diagnose` 에 「面板接受域名 Host(HTTP xxx)」 항목이 있고, 400 이면 위가 원인입니다.
이 도구는 **도메인만 접속 주소로 안내**합니다. `127.0.0.1` 은 사용자 쪽에서 도달할 수 없어 안내문이나 자격 증명 파일에 표시되지 않습니다(IP 직접 접속도 Host 검사에서 거부될 수 있습니다).

## 🧰 개발자 메모: 실장비에서 밟은 함정

이 스크립트를 수정하기 전에 읽어 볼 만합니다(모두 실제 배포에서 나온 것).

1. `set -Eeuo pipefail`에서 함수의 **마지막 문장**이 `[[ ]] && cmd`이면, 판정이 거짓일 때 함수가 0이 아닌 값을 반환하고 `set -e`가 호출부에서 스크립트를 종료시킵니다. `return 0`을 붙이거나 `if`로 바꾸세요.
2. `grep`은 일치가 없으면 1을 반환하고 `pipefail` 때문에 치명적이 됩니다. 값을 읽는 모든 헬퍼는 명시적으로 방어해야 합니다.
3. `openssl rand | tr | head`는 SIGPIPE로 상류가 오류를 냅니다. `openssl rand -base64`를 쓰고 잘라내세요.
4. `ERR` 트랩은 `case "$-" in *e*)`를 판정해야 합니다. 그렇지 않으면 `set +e` 폴백 경로가 치명적으로 오인됩니다.
5. `caddy validate/fmt`에는 `--adapter caddyfile`이 필요합니다(임시 파일명은 힌트가 없어 JSON으로 해석됨).
6. Caddy는 시작 전에 `/var/log/caddy`의 존재와 소유자를 정리해야 합니다.
7. 대시보드 헬스체크는 `sleep 2` 대신 `HERMES_DASHBOARD_READY`를 기다려야 합니다.
8. `tar` 종료 코드 1은 무해한 경고, 2가 실제 실패입니다. 폴백 분기에서 이미 삭제된 임시 디렉터리를 참조하지 마세요.
9. 백업 복원은 “제자리 병합 + 덮어쓸 파일만 따로 보관”이어야 합니다. 디렉터리를 통째로 교체하면 설치가 망가집니다.
10. CJK 문자는 터미널에서 2열을 차지하므로 정렬된 메뉴는 **표시 폭**으로 계산해야 합니다. 한 줄 `case`에서는 분기를 `;`가 아니라 `;;`로 구분하세요.
11. 소스에 CRLF가 있으면 Linux에서 `$'\r': command not found`가 납니다. LF로 통일하세요(`.gitattributes`로 강제됨).
12. 플랫폼 연결 판정은 Hermes 자체의 `logs/gateway.log`(journald 아님)에 기록되며 **이번 기동 이후** 구간만 유효합니다.
13. 공식 Python 로직을 자체 스크립트에서 호출하려면 공식 런처의 `--run-module`을 쓰고(의존성은 도구 자체 런타임에 있음) **서비스 사용자로** 실행하세요.
14. 터미널 QR 렌더링에는 `qrcode`가 필요합니다: `hermes pm install --extra messaging`.
15. 백업에서 재설치 가능한 내용(소스 트리, Python 런타임)을 제외하지 않으면 약 100MB가 약 800MB로 커집니다.

---

## 📄 라이선스

[MIT](LICENSE)

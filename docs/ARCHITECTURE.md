# 设计说明

本文件解释 `hermes-vps` 的结构、关键决策与扩展方式。使用者只需要看
[README](../README.md);维护/扩展这个工具的人看这里。

## 分层

```
bin/hermes-vps        唯一入口:bash 版本检查 → 载入全部模块 → 解析参数 → 分发子命令
lib/common.sh         所有模块的共同底座(常量、日志、错误陷阱、状态、提权执行)
lib/ui.sh             交互抽象层:whiptail ↔ 纯文本 ↔ 非交互
lib/<feature>.sh      每个文件一个能力域,只依赖 common/ui 与同层的少数模块
data/*.conf           数据表:提供商、平台 —— 加行即扩展
data/templates/*      模板:Caddyfile
```

规则:

1. **入口只做分发**,不放业务逻辑。
2. **模块之间不互相 source**(除少数编排模块:deploy/menu 会 source 功能模块),
   避免循环依赖;需要别处的变量时,通过 `common.sh` 里的常量或模块函数取。
3. **所有外部命令的调用都收敛在模块函数里**,`bin` 与菜单都调用同一个函数,
   所以"命令行能做的菜单也能做",反之亦然。

## 关键决策

### 1. 一律调用官方 CLI,不自己改配置文件

写 `config.yaml` 用 `hermes config set KEY VALUE`,写密钥用
`$HERMES_HOME/.env`(官方约定的密钥位置)。理由:

- YAML 手写极易因缩进把配置写坏,Hermes 侧会整份配置回退,排障成本高;
- 官方 CLI 会做类型/枚举校验与迁移(老键名 → 新键名),跟着官方走就不会踩坑;
- 写完后我们会读回校验一次(`config get`),避免"写了但没生效"的静默失败。

### 2. 面板绑回环 + `dashboard.public_url`,不做 `--host 0.0.0.0`

Hermes 面板在非回环绑定或声明公网 URL 时**强制要求认证提供方**,并且有
DNS-rebinding 防护(`Host` 必须匹配)。官方推荐的反代姿势是:面板继续绑
`127.0.0.1`,反代从回环连入并设置 `dashboard.public_url=https://域名` ——
**回环代理被自动信任**,不需要放宽 `trusted_proxies` 网段。

所以我们:

- 面板服务固定 `--host 127.0.0.1`;
- `dashboard.public_url` 由 `domain` 决定,域名变更时同步刷新;
- Caddy 与面板同机,天然走回环,不用配置任何信任网段。

这样也顺带避免了"把面板直接暴露到公网"这一类最常见的事故。

### 3. 数据驱动而不是 if-else 堆

`data/providers.conf`、`data/platforms.conf` 是纯文本表,解析函数在
`provider.sh` / `platform.sh`:

```
providers.conf : id|名称|密钥env|示例模型|base_url|api_mode|说明
platforms.conf : id|名称|模式|必需env|可选env|说明
```

新增一个平台/提供商 = 加一行 + 跑 `bash tests/lint.sh` 校验字段数,不需要改脚本。
新增的 platform id 会同时出现在菜单、`platform list`、批量配置(`--platforms`)里。

### 4. 交互层三态

`ui.sh` 把"提问"抽象成 `hv_ask / hv_ask_secret / hv_confirm / hv_menu / hv_multi`,
内部按环境自动选择:

| 环境 | 行为 |
|---|---|
| 有 tty 且装了 whiptail | 全屏菜单/对话框 |
| 有 tty 没 whiptail | 纯文本问答 |
| `--non-interactive` 或无 tty | 全取默认值/参数,不阻塞 |

因此同一份逻辑既能被人点着用,也能被 CI/无人值守脚本调用。

### 5. 幂等与可回滚

- 每一步都能重复执行:已存在的用户/服务/配置会被识别并跳过或更新;
- 写 Caddyfile 前 `caddy validate`,校验不过直接放弃,**绝不 reload**;
- 写文件前自动备份到同目录 `.bak/`(保留 5 份);
- 备份恢复不删除旧数据,只把旧目录改名挪走,随时可回滚。

### 6. 网络加速探测

国内 VPS 上 GitHub / PyPI 经常超时。`mirror.sh` 会:

1. 对 GitHub 直连与若干加速前缀做小文件探针测速,取最快可用者;
2. 对 PyPI 候选镜像(清华/阿里/腾讯/中科大)同样测速;
3. 落地成三份配置,保证后续所有相关行为都走同一条通道:
   - `/etc/hermes-vps/mirror.env`(供本工具与服务用户进程继承)
   - hermes 用户的 `git config --global url.<前缀>.insteadOf https://github.com/`
     → `hermes update` 的 `git fetch` 自动走加速
   - hermes 用户的 `~/.config/uv/uv.toml` + `/etc/profile.d/hermes-vps-mirror.sh`
     → uv 装 Python/依赖也走镜像(`UV_DEFAULT_INDEX`、`UV_PYTHON_INSTALL_MIRROR`)

探测结果会缓存,`hermes-vps mirror probe --force` 可重测。

### 7. systemd 单元的来源

- **网关**:用官方 `hermes gateway install --system` 生成单元(官方会在
  `hermes update` 时重新生成单元,自己写会丢掉这个行为)。但官方安装器在
  root 直跑时可能把 `User=` 推断成 root,所以安装后**校验** `User=`,
  不对就补一个 drop-in(`/etc/systemd/system/hermes-gateway.service.d/10-hermes-vps-user.conf`)。
- **面板**:官方没有"安装成服务"的命令,单元由本工具生成。启动通过一个固定环境的
  runner 脚本(`$HERMES_HOME/bin/hermes-dashboard-run`)加载 `.env` 后再启动面板
  —— 比 systemd 的 `EnvironmentFile` 更能容忍 dotenv 里的 `export`/引号写法。

### 8. 危险操作的纪律

- **删除**:任何删除都要先列出精确路径并逐项确认(`uninstall`、备份清理、
  `.pre-restore-*` 之外的删除);代码里禁止出现"删系统目录"的 `rm`;
  `tests/lint.sh` 会扫描这类语句。
- **防火墙**:只新增放行(SSH 实际端口 / 80 / 443),不删任何既有规则;
  裸 nft/iptables 只提示不代劳。
- **密钥**:随机生成,写入 `0600` 的 `/etc/hermes-vps/credentials.txt`;
  屏幕只显示一次,避免出现在 shell history 之外的地方。

## 执行流(一键部署)

```
hv_deploy (lib/deploy.sh)
 ├─ 1 环境检查      detect.sh:发行版/架构/init/资源/端口
 ├─ 2 基础依赖      deps.sh:curl git tar xz openssl whiptail jq ...
 ├─ 3 加速探测      mirror.sh:probe + write
 ├─ 4 参数确认      deploy.sh:gather_params(参数/配置文件/交互)
 ├─ 5 用户与目录    account.sh:useradd hermes + /opt/hermes + mirror_apply_user
 ├─ 6 安装 Hermes   hermes.sh:官方 install.sh(以 hermes 身份,带 HERMES_HOME/REPO_URL)
 ├─ 7 模型提供商    provider.sh:env 写密钥 + config set model.* + 读回校验
 ├─ 8 面板/API/平台 webui.sh + platform.sh
 ├─ 9 常驻服务      service.sh:dashboard 单元 + gateway 系统服务
 └─10 域名/防火墙   firewall.sh → caddy.sh(render → validate → 备份 → 写 → reload)
                    → 总结报告(URL/账号/凭据路径/常用命令)
```

## 真机测试发现的坑

以下每一条都是在真实 VPS(Debian 13 / 1GB 内存)上跑部署时才暴露的,已修并有对应测试守住:

| # | 现象 | 根因 | 修法 / 守住它的测试 |
|---|---|---|---|
| 1 | 官方安装器在打包 Web 界面时进程被 `SIGKILL` | 1GB 内存无 swap,node 打包峰值 602MB,被 OOM killer 干掉(dmesg 有记录) | 安装前检测内存 <1.5GB 且无 swap 时自动创建 2GB swapfile 并写入 fstab(`hv_ensure_swap`) |
| 2 | 通过 `/usr/local/bin/hermes-vps` 调用时找不到 `lib/` | 脚本用 `${BASH_SOURCE[0]}` 取目录,软链场景解析成 `/usr/local` | `readlink -f` 解析真实路径 |
| 3 | 无人值守部署在"Caddyfile 已存在"处停下 | `--yes`/`--non-interactive` 在入口没有被解析(清理"死代码"时误删),`hv_confirm` 在无 TTY 下对 `no` 返回非零 | 通用开关在 `main` 统一解析;非交互下对发行版自带 Caddyfile 自动备份后覆盖;冒烟测试新增开关解析断言 |
| 4 | 服务安装的"三级回退"从不生效 | 装了 `ERR` 陷阱后,`set +e` 容错路径上的失败也会触发陷阱并 `exit` | `hv_on_error` 只在 `errexit` 开启时终止;`tests/strict.sh` 用生产同款严格模式覆盖两种路径 |
| 5 | 读不存在的键就整脚本中止 | `hv_kv_get` 里 `grep` 无匹配 + `pipefail` = 非零 → `set -e` 退出 | 显式兜底;新增 `tests/strict.sh` |
| 6 | `caddy validate` 报 `invalid character '#' looking for beginning of value` | 临时文件名不带 `Caddyfile` 提示,Caddy 按 JSON 解析;生产代码漏了 `--adapter caddyfile`(而测试脚本自己加了,所以本地没发现) | 所有 `caddy fmt/validate/run/reload` 都显式带 `--adapter caddyfile`;`tests/caddyfile-validate.sh` 改为**调用生产函数**,不再走并行路径 |
| 7 | Caddy 起来就 `open /var/log/caddy/...: permission denied` 退出 | apt 包不创建 `/var/log/caddy`;且该目录里若有 root 属主的旧日志文件,Caddy 以 caddy 用户打不开 | 新增 `hv_caddy_prepare_runtime`(目录+文件属主一起修),与"是否刚装 Caddy"解耦;验收脚本新增可写性断言 |
| 8 | 备份报"备份失败" | `tar` 因"file changed as we read it"(网关在写 state)返回 1,被当成失败 | 排除 `*.sock`、加 `--warning=no-file-changed`、把 rc=1 视为成功 |
| 9 | 恢复把安装弄残 / 在 `/tmp` 上失败 | 备份刻意不含代码与 tools,而恢复是"整目录挪走再解包";且 `/tmp` 常是小容量 tmpfs(实测 484MB),解包必然 no space | 改为**就地流式解包 + 只挪走将被覆盖的条目** + 解包前空间预检 + 布局校验;失败时用 `EXIT` 陷阱把服务拉回 |
| 10 | 恢复/列表步骤 SIGPIPE 退出码 141 | `tar tzf ... \| head -n1` 提前关闭管道 | 一次性取全部条目再截断;`tests/lint.sh` 新增"命令替换里未兜底的 `\| head`"检查 |
| 11 | 面板"端口未监听"误报 | 面板启动要 5~10 秒,而检查里固定 `sleep 2` | 改为轮询等待就绪(`hv_dashboard_wait_ready`) |
| 12 | 域名解析校验在云主机上误报 | 主机在 NAT 后面,内核路由源地址是私网 IP | 私网地址时用公网 IP 兜底比较 |

## 扩展指南

**加一个消息平台**:在 `data/platforms.conf` 加一行,可选的 env 变量写进"可选变量"
列;`hermes-vps platform list/status/configure` 立即支持。若该平台需要扫码,把模式
标成 `qr` 即可复用"交给官方 setup 向导"的流程。

**加一个模型提供商**:在 `data/providers.conf` 加一行,`id` 用官方 provider id
(见官方文档 `/docs/integrations/providers`),密钥变量名必须与官方一致。

**加一个新的部署步骤**:在 `lib/<feature>.sh` 写函数(幂等、可独立执行、有日志),
然后在 `deploy.sh` 的流水线里插一步、在 `bin/hermes-vps` 暴露子命令、在
`menu.sh` 加一个入口。三处都要加,是为了保证"菜单有的子命令也有"。

**自检**:`bash tests/lint.sh`(语法/数据文件格式/模块加载/危险 rm 扫描)、
`bash tests/smoke.sh`(无需 root 的逻辑冒烟:键值、表解析、Caddyfile 渲染、CLI 可执行)。

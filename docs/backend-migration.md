# 新服务器部署与迁移清单

更新：2026-10-24，北京时间。本文为操作清单；实际执行结果单独记录，不将模板当作验收。
当前授权以 [Goal N08](../GOAL-checkin-companion.md) 为准。

## 0. 边界与顺序

- 旧机：`203.0.113.20`，据“过两天”暂估 2026-10-23 到期，准确时刻未知。
- 新机：`203.0.113.10`，已运行 `model-relay.example.com` 中转及 VPN。**2026-10-21 所有者随后明确授权执行者接手本次旧 AI 版本迁移**，取代此前禁止登录的限制；不包含中转/VPN 维护、权限策略调整或 DNS 切换。
- 星愿入口保持 `https://assistant.example.com`；上游仍是 `https://model-relay.example.com/v1`。
  保留原设备凭证和注册表时，DNS 搬迁本身无需重装或更改 App 地址；检查点 2 的功能升级是另一件事。
- 先迁移已验证的 AI 版本，再另行发布配对、分享、私聊。迁移前不向旧机发布这些功能，也不在旧机外网验收。
- 迁移期间继续本地代码、模拟器、合成数据及恢复测试；本次允许检查所有者准备的私有迁移包，安装独立星愿服务、添加星愿证书及 Caddy 站点。只 reload Caddy，不重启中转/VPN；先备份、语法检查、既有服务前后对照，失败回退。
- DNS 仍由所有者处理。下面是步骤清单，不是运行结果；实际结果见陪伴账本。后续陪伴版本及其运维验收独立安排，不能混入本次迁移。

**10-22 新授权取代上述仅旧版本迁移限制：** 可独立发布和验证星愿陪伴后端、数据库/照片及每日备份。
只用 CI 通过的完整提交，部署前备份 `/etc/xingyuan` 和现有发布；Dart 仅隔离安装在 `/opt/xingyuan`，
不安装全局依赖。Caddy 只改星愿站点，备份、validate、reload 后核对中转/VPN 的响应、进程和固定监听，
不同立即恢复。允许指定 SSH 公钥认证维护，密码登录保留；Mac 密钥实连成功后通知所有者改密码，此后禁止密码回退。
其余 DNS、防火墙、权限策略和中转/VPN 的修改或重启仍不允许。

## 1. 迁移前盘点

### 本次实际状态（2026-10-21 夜间至 10-22 凌晨，北京时间）

- 已按所有者后续授权迁移 `383fc028aca0515d039c7388ac34755cef64d997`，复用并核验已编译的 Debian 12 x64 产物，未从当前分支重建或发布陪伴功能。
- 新机专用 xingyuan 用户、systemd 自启及回环 8788 健康通过；配置和 8 条设备登记逐字节一致，2 条有效凭证保留。
- Caddy 原配置备份在新机 `/root/xingyuan-migration-20261021/codex-takeover/`；只追加星愿站点并迁入其自动 HTTPS 证书缓存，校验后 reload，未改原路由或重启中转/VPN。
- Mac 定向新机 HTTPS 健康、两份原凭证鉴权、4 份已吊销凭证及缺失/错误凭证拒绝、1 次合成今日分析通过；新机日志仅含元数据，无额外模型重试。
- 23:57 首次观察到 DNS 已指向新机；稍后新机直接查询权威 DNS 及公共加密 DNS 复核 A=`203.0.113.10`、无 AAAA。非本执行者修改 DNS；Mac 普通 HTTPS 请求已确认连接新 IP、证书有效、健康 200。
- 私有迁移归档已复制到 Mac 仓库外 0700 目录、文件 0600，散列及配置/登记/二进制可读性通过。新机迁移包/回退副本保留，旧机未操作；手机 Wi-Fi/移动网络和 Mac 关闭仍待复验。
- 本次不是陪伴功能发布，也未运行 SQLite/照片每日备份定时器或完整 K12。详细证据及限制见[账本 C032](companion-delivery.md)。

以下清单保留为操作与后续迁移要求，不把每个通用项目自动标为已完成。

### 首次陪伴发布与回退（2026-10-22，历史记录）

- 发布源码：`dc6b2110567c2c9ec803a4cd99e607e70153ddc2`，CI `39635689407` 成功；Linux 原机构建并验证三个完整 bundle，未部署浮动 HEAD。
- Dart 3.13.5 在 `/opt/xingyuan/toolchains/3.13.5/dart-sdk`，官方 SHA-256 已核对；独立 `xingyuan-build` 账号及缓存，构建限 CPU/内存，不修改全局依赖。
- 已启用 SQLite/照片存储和备份 timer；完整程序位于 `/opt/xingyuan/releases/<commit>/`。再部署演练另复制同散列的 `<commit>-redeploy-20261022/`，当时 `current` 指向后者；后续提示词发布见下节。
- 服务器私有证据/备份：`/root/xingyuan-companion-20261022/`；Mac 对应 `~/.config/xingyuan/companion-deploy-20261022/`。部署前归档含配置、旧发布、unit 和 Caddy，已跨机核对散列与可读性。
- 仅维护故障时，通过已核对密钥的 SSH 执行 `python3 /root/xingyuan-companion-20261022/deploy.py rollback`：停星愿及其备份定时器，恢复旧配置/unit/current/Caddy，校验后启动旧 AI 版并比对保护基线。
- 回退不覆盖最新设备注册表、不恢复吊销位，也不删除新数据库、照片或备份。陪伴数据保留离线，旧 AI 版不访问；不得以旧快照覆盖新写入。后续配置变化时先复核回退脚本和备份，不盲目执行旧脚本。
- 每日时间仍为 UTC 19:30（北京次日 03:30），随机延迟最多 10 分钟。手动执行、七份保留、带照片恢复和导出证据见 C036；C040 已观察到北京时间 2026-10-22 03:35:21 首次自然触发并成功退出，触发/执行/日志/快照一致，七份快照逐份完整校验通过。只读核验没有手动触发备份，也不以启用 timer 代替实际运行证据。

### UI 重写配套分析发布（2026-10-22，历史运行与 J2 回退目标）

- `current` 已指向完整 `9653f22a7355300509ddff93c534cec3e03986e4`，对应 CI `39739578481`；从该提交导出源码，沿用隔离 Dart 与构建账号，三个完整 bundle 及原机测试通过。模型配置、协议和长度上限未变。
- 私有证据为服务器 `/root/xingyuan-ui-redesign-20261022/`、Mac `~/.config/xingyuan/ui-redesign-20261022/`；`before.tar.gz`（Mac 名 `server-before.tar.gz`）保留配置、旧发布、unit 与 Caddy。r2 切换前另做 `data-before-r2.tar.gz` 冷备份，已复制到 Mac 并打开验证 18 表、完整性和外键。
- 首次发布因 umask 077 造成新发布根目录 0700，服务账号无法 CHDIR，自动回退成功。显式修正根目录 0755、核对所有文件散列并以服务账号执行三个 bundle 后重试通过；首次失败/回退与 r2 证据分别保留。
- 当前运行与冷备份 18 表/照片不变，七份历史快照逐份 verify 通过，星愿服务及原每日 timer active。本次不改或 reload Caddy，不重启中转/VPN；其原容器、PID、服务、固定监听、响应散列与配置均复核一致。
- 同机另一个测试 MySQL 容器先新增、后于北京时间 16:16:31 重启，发生在本次 16:14:12 发布开始之后；执行者没有修改或重启它。原基线及严格检查失败保留，原服务逐项复核后另记该容器新状态，不把全机差异隐藏为通过。
- 近期兼容回退目标保留为 `dc6b2110567c2c9ec803a4cd99e607e70153ddc2-redeploy-20261022`。仅故障时先复核当前保护快照，再用密钥执行 `python3 /root/xingyuan-ui-redesign-20261022/deploy-upgrade.py rollback`：只停星愿、切换 current、启动星愿与 timer，不恢复数据库/照片/设备注册表，避免覆盖新写入或复活吊销凭证。若原服务或新增容器又变动，先调查，不能跳过守卫。
- 更早 `383fc02` 及原配置/unit/回退工具继续保留；它是 AI-only 版本，路径和配置不同，不可只切 symlink。使用上节旧版回退办法前须重新核对当前基线，不盲目重放历史配置。
- 公网合成分析两条及鉴权/体积/照片字段拒绝通过，专用 QA 凭证已吊销并实测 401；既有设备登记逐项不变，日志仅元数据且无模型重试。具体语义审查和调用计数见账本 C062，不等于手机 K14 通过。

### J2 首次发布与验收回退（2026-10-24，未交付）

- 完整候选 `085c179955d8a99041f86725f271b252ff600375` 的精确 CI `39991137506` 成功；与开发整合提交 `3ab05c261ae8fec9f0c265a8b2eb5c19bdff9b0d` 全树一致，后者自己的 CI `39992839031` 也成功。真实模型评测 24 次检查及语义通过，其中 18 次实际模型调用、零重试。
- 保留现有隔离 Dart/构建账号。Linux 首轮核心 124 通过、后端 288 过/1 失败，原因是 QA proxy 重新绑定端口时 errno98；未证明占用者或根因。原失败保留，不改断言/时限，独立失败 suite 16/16 和串行全后端 289/289、三个完整 bundle、跨进程探针随后通过。
- 配置/旧发布及业务冷备份已传到 Mac、校验散列并打开验证 18 表/外键/完整性。切换与实际回退演练通过，不恢复数据库或设备注册表，不复活吊销凭证。七份既有快照校验通过。
- 公网在固定 Content-Length 的 `/v1/polish-note` 超限请求处失败：应为 413，实际 502；对应应用元数据为 413，代理为 body-limit 502。后续公网语义/限流尚未执行，公网模型调用为零。两份专用 QA 凭证已吊销并逐路验证 401，然后再次回退到 `9653f22a7355300509ddff93c534cec3e03986e4`。
- 2026-10-24 01:52:57 北京时间只读复核：旧版 current、本机与 HTTPS 健康、18 表/照片、旧注册表、原配置、中转/VPN 和备份 timer 均保持。未改或 reload 生产 Caddy。首次 stage 曾因无关 8123 容器 PID 变化停止，原基线与独立核对记录保留；未修改或重启该容器。
- 隔离 Caddy 2.6.2 与合成 upstream 已复现代理边界：`64KB` 为 64000 字节，固定长度超限仍可变成 502，即使 upstream 立即返回 413。应用层另发现未接收完整正文会延迟错误响应；两者分别修复和验收，不能仅凭应用日志 413 关闭公网问题。仅诊断的上限对齐不是线上配置批准。
- 私有证据：服务器 `/root/xingyuan-journal-j2-20261024/`，Mac `~/.config/xingyuan/journal-j2-release-20261024/`。`published.json`/`remote-publish.json` 只是历史切换成功记录，实际回退状态以 `rollback-verified.json` 为准。候选和 `383fc02` 回退材料继续保留；不得重放旧的 publish 标记或用旧冷备覆盖新数据。
- B 仅完成隔离 Release 构建和同团队/包名签名核对，未备份安装；正式版未动。下一轮须以修复后的精确 CI 提交、新发布批次与新的切换前备份验收，全部通过才给 B 原位安装；正式版仍须所有者另行确认。详见账本 J010。

### J2 第二次发布（2026-10-24，当前后端）

- `current` 指向完整 `bb6b2cf03cbfc25163d756cedb65ecf743ddc410`，精确 CI `40001032595` 成功。Linux 隔离构建核心 124、后端 304、分析、三个完整 bundle 和跨进程探针通过；全局工具链、中转/VPN 及配置密钥未改动。
- 仅在 `assistant.example.com` 站点加入提交中的严格错误处理：内部 413，或同时匹配指定 request-body 包装器与 HTTP 413 文本的内部 502，返回固定 JSON 413。普通 64000、照片 2800000 字节上限不变，其他 502/503 不被改写。正式模板隔离 34 项和实际编译后端/代理组合 28 项通过，临时实例已停止。
- Caddy 先备份、adapt/validate 后 reload，新增错误路由与正式模板严格相等。最初对照被生成的分组编号及临时配置自身隐藏路径阻止；原失败保留。只规范生成分组的同组关系和候选文件自身路径，其他全部配置严格相等；上线后实际路径、文件散列、原容器/PID/监听及 cpa/vpn 响应核对通过，不跳过守卫。
- 私有证据：服务器 `/root/xingyuan-journal-j2-r2-20261024/`，Mac `~/.config/xingyuan/journal-j2-release-r2-20261024/`。配置/旧发布 `before.tar.gz` 和业务 `data-before.tar.gz` 已到 Mac 核对散列并打开验证；后者 18 表/外键/完整性通过。两个版本和旧 `383fc02` 材料保留，业务表/照片/原登记不变，每日备份 timer active，七份快照逐份 verify 通过。
- 已真实回退到 `9653f22` 与原 Caddy 站点，再恢复 J2；不回写数据库、照片或设备登记。仅故障且重新核对当前配置/服务基线后，通过既有密钥执行 `python3 /root/xingyuan-journal-j2-r2-20261024/deploy.py rollback`。该脚本只切星愿版本并恢复已知站点配置；若文件被别人修改会停止，不可盲目覆盖。不得重放旧冷备或复活已吊销设备。
- 公网 45 项通过，两个新接口超限均 413，鉴权/Origin/照片字段/限流/设备隔离及吊销后 401 通过。两次真实模型调用仅使用合成文字，逐条语义通过，零重试；两份 QA 凭证均吊销，应用和代理日志无已知密钥/凭证/合成正文。原 24 项 Mac live 证据按未变化的提示词/模型客户端/core/eval 范围复用，不称本轮重新运行。
- 客户端 B 使用另一个精确 CI 通过的 C11 提交 `25471f7`，其服务端等发布范围与本后端相同；已原位安装并验证安装前后数据，但锁屏阻止启动抽查。正式版未升级。此后端结果不替代手机试用、J07/J11 或旧 K14，详见账本 J011。

### 后续迁移复验清单

- [ ] 记录新机 OS/CPU 架构、剩余内存/磁盘、现有 80/443/8788/2019 监听者和反向代理类型。
  不假定它与旧机 Debian 12 x64 相同。8788 冲突时只为星愿选一个未占用的非特权端口，并同步改代理。
- [ ] 记录当前中转的健康基线、配置备份和现有服务名；不升级/重启/替换中转程序，不覆盖其防火墙或代理。
- [ ] 旧机确认 `/opt/xingyuan/current` 的真实路径和 systemd `ExecStart`，只记录元数据。
  最后有证据的线上提交为 `383fc028aca0515d039c7388ac34755cef64d997`（规划/摘要/今日分析）。
  若所有者另有发布，以实机版本为准，不能用仓库 HEAD 冒充正在运行的版本。
- [ ] 核对第 4 节全部路径的实际存在性、私有副本、权限和散列。该旧版本没有配对库，不代表磁盘上一定没有后来产生的数据库。
- [ ] 在切换窗口冻结设备凭证发放/吊销及业务写入；有数据库时先停止星愿服务和备份定时器再做最终冷拷贝。
  不停止中转或共享反向代理。预拷贝可以提前进行，最终一致副本必须在冻结后完成。
- [ ] 降低 DNS TTL（提前至少一个原 TTL 周期），检查 A 和 AAAA；不要留下仍指向旧机的 AAAA。

## 2. 从确定提交构建

工具链按仓库锁定：Dart 3.13.5（Flutter 3.47.6 自带相同 Dart）。在与目标 Linux 架构/运行库兼容的环境原生构建；
不要把 Mac 产物上传 Linux。无需安装 Flutter、Xcode、Node、Docker 或 iOS 签名材料到服务器。
从官方来源取得 Dart 并核对发布校验值；新机已有工具链时隔离使用，不为星愿替换中转依赖。

在本机仓库导出当前已验证线上版本，仅包含服务器及共享包，输出到仓库外私有目录：

```sh
umask 077
RELEASE=383fc028aca0515d039c7388ac34755cef64d997
git archive --format=tar.gz --output="$HOME/xingyuan-$RELEASE-source.tar.gz" "$RELEASE" server packages/xingyuan_core
shasum -a 256 "$HOME/xingyuan-$RELEASE-source.tar.gz"
```

所有者通过自己的已核对主机指纹的安全通道传输，接收端核对 SHA-256。不要打包整个工作区。
首次创建独立非 root 系统用户/组 `xingyuan`，私有配置目录 0700、数据目录 0700。
发布目录 `/opt/xingyuan/releases/<完整提交>/` 使用未存在的新目录，解包保留 `server/` 和 `packages/` 相对位置。
在 xingyuan 可访问的目录执行（不能从 `/root` 启动后仅给 pub 传目录参数）：

```sh
# 仅适用于上述已部署的旧 AI 版本，无 sqlite3 原生依赖。
cd /opt/xingyuan/releases/383fc028aca0515d039c7388ac34755cef64d997/server
dart --version
dart pub get --enforce-lockfile
dart analyze --fatal-infos
dart test
dart compile exe bin/server.dart -o bin/assistant-server
dart compile exe bin/devices.dart -o bin/assistant-devices
```

构建以 xingyuan 或隔离构建用户运行，不用 root 的可写全局依赖缓存。部署完成后发布文件只读，运行时只写数据目录。
若从兼容 Linux 构建机传成品，附完整提交、工具链版本、架构、文件清单及 SHA-256。

**后续陪伴版本另选一个本地验证和 CI 均通过的完整提交，不使用浮动 HEAD。** sqlite3 引入后改为：

```sh
dart pub get --enforce-lockfile
dart analyze --fatal-infos
dart test
dart build cli --target=bin/server.dart --output=build/server
dart build cli --target=bin/devices.dart --output=build/devices
dart build cli --target=bin/backup.dart --output=build/backup
```

须携带每份完整 `bundle/bin` 与 `bundle/lib`，不能只复制二进制。构建通过不等于新机运行或真机验收；
本地工作包见 [陪伴账本 C030](companion-delivery.md)，新机执行见 C036，按 N08 由所有者或其明确授权的执行者发布。旧提交不含 `backup.dart`。

## 3. 配置项（不含秘密值）

`/etc/xingyuan/assistant-server.json`：JSON 对象，属主 xingyuan，0600；目录 0700。
不打印正文、不加入 Git、不把秘密放进命令行参数、App 构建参数或 Caddyfile。

| 字段 | 含义 / 迁移要求 |
| --- | --- |
| `base_url` | `https://model-relay.example.com/v1`，不得误填星愿自身地址造成循环 |
| `model` | `gpt-6-luna`，启动器校验的固定模型 |
| `model_api_key` | 模型密钥；从现有私有配置安全迁移，本文只列字段名 |
| `port` | 通常 8788，1024–65535，仅绑定 `127.0.0.1`；先查新机冲突 |
| `devices_file` | `/etc/xingyuan/devices.json`，保留现有内容，不初始化为空 |
| `reasoning` | `none`，沿用已评测配置 |
| `max_completion_tokens` | 4000，沿用已评测配置 |
| `companion_database` | 后续陪伴版本才设置：`/var/lib/xingyuan/data.db`；缺省/null 为仅 AI |
| `companion_objects` | 后续陪伴版本才设置：`/var/lib/xingyuan/objects`；须与数据库成套，已有图片/清理任务不可省略 |

`keychain_service`、`keychain_account` 仅供 Mac 钥匙串回退，Linux 不使用。
无新增数据库密码、JWT 密钥、云存储密钥。Caddy 证书私钥由现有代理管理，不写入项目。

`/etc/xingyuan/devices.json` 为数组，每项只有 `label`、`hash`、`revoked`。
完整保留两份手机及其他条目的标签、SHA-256 哈希和吊销状态；不要重新签发同名设备、把两份手机合用一份凭证，
或用旧注册表恢复已吊销条目。手机持有的原始凭证不需要也不应复制到服务器。

## 4. 目录与必迁文件

| 路径 | 必须做什么 |
| --- | --- |
| `/opt/xingyuan/releases/<commit>/` | 重建/传输相应发布产物，保留至少一份兼容旧版本；不从工作区带入缓存或秘密 |
| `/opt/xingyuan/current` | 原子切换到已准备好的发布；不能指向半成品 |
| `/etc/xingyuan/assistant-server.json` | 安全迁移完整私有配置，校正路径/未占用端口，权限 0600 |
| `/etc/xingyuan/devices.json` | 原样迁移最新注册表，迁移前后逐项对照；禁止空文件替换 |
| `/var/lib/xingyuan/data.db` | 若存在则必须迁移；先确认版本/application_id，不自动清库或降级 |
| `/var/lib/xingyuan/data.db-wal`、`data.db-shm` | 有 WAL 时不能只复制主库。停写后完整复制仍存在的边车文件；或使用已验证的一致快照 |
| `/var/lib/xingyuan/objects/` | 若存在则连同隐藏格式标记、照片及待清理文件完整冷拷贝；不得作为静态目录公开 |
| `/var/lib/xingyuan/backups/` | 若存在保留已验证历史快照、格式标记；新机验收前不要在旧机删唯一副本 |
| systemd unit / timer 与星愿代理片段 | 按实际版本迁移、校验；不覆盖新机的其他服务/全局代理配置 |

实际配置使用其他绝对路径时，以真实路径为准，不能只查默认目录。复制后按 xingyuan 设置属主、目录 0700/文件 0600。
私有配置与注册表另存仓库外加密或严格权限控制的副本；业务备份不包含它们。
手机本地目标、笔记、提醒、照片和数据库不随此次后端迁移上传，也不在此清单中删除。

## 5. systemd

旧 AI 版本用该提交内的 `server/deploy/xingyuan-assistant.service`，关键项如下：

```ini
[Unit]
Description=Xingyuan private assistant
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=xingyuan
Group=xingyuan
WorkingDirectory=/opt/xingyuan/current
ExecStart=/opt/xingyuan/current/server/bin/assistant-server --config /etc/xingyuan/assistant-server.json
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryMax=512M
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

后续陪伴版本改用 [当前完整模板](../server/deploy/xingyuan-assistant.service)：
`ExecStart` 改为 `/opt/xingyuan/current/server/build/server/bundle/bin/server`（参数同上），
新增 `StateDirectory=xingyuan`、`StateDirectoryMode=0700`，使独立数据目录可写。
切换版本须一起匹配 ExecStart，不能用旧命令启动新 bundle，或回退代码后保留新路径。
校验 unit 后再 `systemctl daemon-reload`，启用/重启 **仅星愿** 的服务。
核对 `ActiveState`、`SubState`、`User`、`NRestarts` 和本机 `http://127.0.0.1:8788/v1/health`。
不把 8788 开到公网，不让运行用户写中转目录。

## 6. Caddy / 共用反向代理

先查谁占用 80/443。已经使用 Caddy 时，仅合并下面的站点块；**不要用仓库完整 Caddyfile 覆盖新机配置**，
其中的全局 admin/log/servers 设置也不能覆盖新机原有设置。若现用 Nginx 等其他代理，则由所有者在该代理增加等价虚拟主机，
不要再启动争抢 80/443 的第二个 Caddy。中转 `model-relay.example.com` 的证书、上游和路由全部保持。

```caddyfile
assistant.example.com {
    @photoUpload path /v1/companion/photos/upload
    @ordinary not path /v1/companion/photos/upload
    request_body @photoUpload {
        max_size 2800000
    }
    request_body @ordinary {
        max_size 64KB
    }
    reverse_proxy 127.0.0.1:8788 {
        transport http {
            response_header_timeout 85s
        }
    }
    header {
        Cache-Control "no-store"
        X-Content-Type-Options "nosniff"
    }
}
```

只有图片上传允许较大包，旧 AI 版本会拒绝未实现的照片路由。端口必须与私有配置一致。
不启用该站点访问日志；若共享全局日志会采集请求，须由所有者为星愿单独排除/过滤 request、URL 查询、Authorization 和正文，
不能通过改全局日志影响现有中转。应用只记录元数据，照片只能走鉴权 API。
合并后先 `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`，通过才按现有运行方式 reload，不能直接覆盖并 restart。

## 7. 备份与恢复

**旧 AI 回退版本：** 私有配置、最新设备注册表、版本及代理/unit 变更记录是必备副本。
若盘点发现数据库/照片，依第 4 节停写冷备，不能套用“旧版本无数据库”跳过。
迁移前后分别保存一份到 Mac 的仓库外私有目录，并核对散列、权限和可读性；不在日志打印秘密或记录正文。

**当前陪伴版本：** `server/bin/backup.dart` 已完成本地及新机编译 CLI、七份保留、带照片恢复和 Mac 导出验证（C036）；每日 systemd 备份首次自然触发及七份完整校验也已通过（C040）。实际发布与证据见本文件第 1 节和账本，不以文档模板代替运行结果。
源库只读在线 SQLite 快照，复制快照引用的全部 ready 图片并核对哈希/大小；损坏或缺图不能报告成功。
按递增序号保留最近 7 个成功快照，真实 UTC 创建时间另记，系统回拨不影响顺序；目录 0700、数据库/照片/清单 0600。
不删不认识的文件；识别到损坏快照会停止并报错，不继续删旧副本。每天一次，不能因部署成功就宣称定时备份已通过。
以下是以后重新部署或迁移时必须复验的清单，不表示本次 C036/C040 尚未完成：

- [ ] 编译备份 CLI；以 xingyuan 用户运行 `create --config /etc/xingyuan/assistant-server.json --root /var/lib/xingyuan/backups`。
- [ ] 用 `list`、`verify --snapshot <名称>` 核对完整快照；`restore --snapshot <名称> --destination <不存在的新绝对路径>` 恢复，不能覆盖在线数据。
- [ ] 对恢复库逐表只读对照，核对照片集合及散列、幂等回执、外键和完整性；源库保持不变。
- [ ] 安装 `server/deploy/xingyuan-backup.service` / `.timer`，每天 UTC 19:30（北京次日 03:30），随机延迟不超过 10 分钟，关机漏跑后补跑一次。
  先手动执行并查看成功元数据，再启用 timer；确认 next/last、失败日志、容量和保留 7 份实际生效。
- [ ] `export --root /var/lib/xingyuan/backups` 将最新快照以 tar.gz 写 stdout；stdout 只能重定向到私有文件，不打印到终端。
  用已核对新机指纹的 SSH 通道导出到 Mac，不能沿用旧机 alias 或旧机指纹。
  导出不含模型配置/设备注册表，仍需分别安全备份。Mac 一条命令的帮助见导出脚本；回退到 `383fc02` 时该版本不含备份 CLI，不继续套用陪伴版命令。
- [ ] 在 Mac 的空目录解包可信自有导出，重新 `verify`，再恢复到不存在的新目录；只用合成数据演练公开验收。

新机 **schema v4** 的日常命令如下，由所有者或 N08 明确授权的执行者操作。工具拒绝其他数据库版本/application_id，不负责升级；
旧版数据迁移前仍先做停写冷备。服务初始化对象目录后才可创建快照，路径拼错不会初始化一个空源库。

```sh
BACKUP=/opt/xingyuan/current/server/build/backup/bundle/bin/backup
runuser -u xingyuan -- "$BACKUP" create --config /etc/xingyuan/assistant-server.json --root /var/lib/xingyuan/backups
runuser -u xingyuan -- "$BACKUP" list --root /var/lib/xingyuan/backups
runuser -u xingyuan -- "$BACKUP" verify --root /var/lib/xingyuan/backups --snapshot SNAPSHOT_NAME
runuser -u xingyuan -- "$BACKUP" restore --root /var/lib/xingyuan/backups --snapshot SNAPSHOT_NAME --destination /var/lib/xingyuan/restore-new
```

`SNAPSHOT_NAME` 取 `list` 返回的完整名称，恢复路径必须尚不存在。
备份/导出/校验/恢复共用排他锁；并发失败须检查上个任务，不删 `.lock` 来强行解锁。
进程退出会释放 OS 锁，遗留 `.building-*` 不算成功快照、不自动删除；先调查再由所有者处理。
手动 `systemctl start xingyuan-backup.service` 成功后，再 `systemctl enable --now xingyuan-backup.timer`。
以 `systemctl list-timers xingyuan-backup.timer` 和服务日志核对真实调度；失败须人工处理，未接外部报警服务。

Mac 导出一条命令（所有者或明确授权的执行者；SSH host 必须核对为新机，使用已验证的指纹/密钥）：

```sh
sh server/deploy/export-companion-backup.sh /absolute/private/new-server.ssh-config OWNER_HOST_ALIAS /absolute/private/new-backup.tar.gz
```

alias 须有执行上述 `runuser` 的权限（当前包装命令为所有者 root 运维通道，不修改 sudoers）。
参数必须显式提供，脚本不内置任何服务器；禁止密码回退，现有目标文件拒绝覆盖，传输失败不留下成功文件。
Mac 的父目录需预先存在且私有。tar 列表检查不等于内容校验，解包后仍须用相同版本备份工具 `verify`。
原本地测试只使用 SSH 替身；10-22 新机实际导出及 Mac 校验/恢复已另行执行，见 C036。
每日自然触发仍须检查真实 last/next 和成功日志；不把手动执行或模板测试等同定时运行。

旧快照可能含后来已撤回/解除配对的内容。只允许离线恢复核对，不能直接作为线上回滚；
若灾难恢复需要重新服务，须先与所有者确认数据丢失范围并落实撤销/删除状态，不能复活分享或已吊销凭证。
备份也含私人内容，磁盘副本并非加密备份，跨机传输必须加密；备份不进入 Git、公共对象存储或网站目录。

## 8. DNS 切换、验收与回退

- [ ] 新机回环服务先通过；所有者确认 `assistant.example.com` 的 TLS 证书准备方式（已有安全迁移或 DNS 验证），再切 A/适用 AAAA。
  若只能在切 DNS 后签发证书，预留短维护窗口，签发完成前不宣布可用；绝不使用 `-k` 绕过证书。
- [ ] 所有者确认迁移后，核对域名解析和证书、HTTPS 健康；新机日志能对应到请求，不能误验仍在 DNS 缓存中的旧机。
- [ ] 两份现有手机凭证分别通过鉴权，错误/缺失/已吊销凭证仍拒绝；合成今日分析成功，失败不自动重试制造额外请求。
  同时检查中转迁移前后的原有功能。健康 200 不等于模型、凭证或配对验收通过。
- [ ] 所有者验证手机 Wi-Fi/移动网络、Mac 关闭后仍能使用；现有 App 地址和凭证不变。
- [ ] 新功能独立发布后才做 S09 全接口/图片越权矩阵和 K12 重启、再部署、备份/恢复/导出验证；迁移成功不自动勾选这些项目。
- [ ] 回退先停止新写入；仅在旧机尚可用且数据未分叉时回切 DNS/兼容旧发布。已有新写入则先制定一致迁回方案，不能直接用旧库覆盖。
  保留新机完整副本，不回退注册表吊销位；schema 升级后不以旧二进制强开新库。
- [ ] DNS 缓存消退且新机验证/备份都完成后，由所有者安排旧机下线。到期可能导致唯一副本丢失，应在到期前完成迁移；准确时刻未知不视为有额外宽限。

所有者交回的信息只需：发布提交、迁移/DNS 完成时间、健康与鉴权结论、备份是否可读、日志隐私检查结果及待解决项。
不回传密钥、设备凭证、数据库或私人内容。本次登录权限仅限最新 N08 的星愿发布/验收及明确指定的 SSH 维护。

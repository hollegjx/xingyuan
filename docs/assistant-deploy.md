# 星愿 AI 后端部署

更新：2026-10-21，Asia/Shanghai。执行边界以 [当前 Goal](../GOAL-checkin-companion.md) 及旧 D06 凭据约定为准。
这是可复现的部署说明；实际通过项见[账本](ai-conversation-delivery.md)，不是两部真机交付声明。

**迁移优先（2026-10-21）：** 所有者随后授权执行者接手旧 AI 版本迁移，DNS 仍由所有者切换。现行步骤以
[新服务器部署与迁移清单](backend-migration.md) 为准；下方旧机发版记录保留为历史，不能据此继续部署。
迁完前不在旧机部署配对、分享、私聊，不做外网验收。只改 DNS 不要求 App 重装。

## 地址与凭据

- 星愿后端 HTTPS：`assistant.example.com` 不变，按 Goal N08 的新授权迁至现有中转所在的新机；只添加星愿站点，不覆盖中转服务或代理配置。
- 上游模型：`https://model-relay.example.com/v1`，模型固定 `gpt-6-luna`。新机登录仅限本次星愿迁移，不修改中转或 VPN。
- 以下 SSH 配置仅对应旧机，不适用于新机，也不构成继续部署授权：仓库外 `~/.config/xingyuan/temp-server.ssh-config` 的 `xingyuan-temp-server`：
  `ssh -F ~/.config/xingyuan/temp-server.ssh-config xingyuan-temp-server`。已实测密钥登录，客户端
  只用 publickey、BatchMode，禁止密码/交互回退；保留 `StrictHostKeyChecking=yes` 和独立 hostkeys。
  服务器密码登录仍启用，密码文件 0600、目录 0700；仅再次明确授权的维护才用 `sshpass -f`，不自动重试。
- ED25519 必须匹配 `SHA256:/6KMlCbVP2HtUfv/ax0CvnLqMeTK9gPa5JM29ZZNxWM`。
  不匹配就停止，不禁用主机校验；服务器密码、模型密钥及设备凭证不进入仓库。
- 临时服务器暂估 2026-10-23 到期（所有者 10-21 表述“过两天”），准确时刻未知；未创建到期提醒。

## 已采用的运行布局

| 路径或配置 | 用途 |
| --- | --- |
| `/opt/xingyuan/releases/<commit>/` | 已提交纯 Dart 源码、锁文件及编译产物 |
| `/opt/xingyuan/current` | 指向当前发布目录的符号链接；旧目录保留用于回退 |
| `/etc/xingyuan/assistant-server.json` | 私有模型配置，0600，属主 xingyuan |
| `/etc/xingyuan/devices.json` | 只保存设备标签、SHA-256 哈希及吊销标志，0600 |
| `/var/lib/xingyuan/data.db`、`objects/` | P3/P4 待部署的配对/分享数据库与鉴权照片，独立于发布目录 |
| `/etc/systemd/system/xingyuan-assistant.service` | 非 root 用户 xingyuan，自动重启，文件系统只读限制 |
| `/etc/caddy/Caddyfile` | HTTPS 反向代理到 `127.0.0.1:8788`，自动证书 |

系统为 Debian 12 x64。Dart 3.13.5-1 与 Caddy 2.11.7 来自官方发布，安装前核对官方下载元数据。
没有安装 Docker、Deno、Node 或其他服务。Caddy 仅暴露 TCP 80/443，管理端口 2019 仅回环，
应用仅回环 8788。不改动与本服务无关的端口或防火墙。

## 发版

1. 本机先运行核心、服务、App 和评测工具的离线检查；推送任务分支并核对 SHA。
   模型行为变更另跑完整真实评测，不因 CI 通过就省略。
2. 用 `git archive --format=tar.gz <commit> packages/xingyuan_core server` 导出明确提交。
   不归档整个工作区，不能包含 `config/*.local.json`、`.dart_tool`、签名或用户数据。
3. 经指纹校验的 SSH/SCP 上传到临时服务器，在新的 `/opt/xingyuan/releases/<commit>` 目录解包。
4. 本机交叉编译曾因官方组件下载被拒失败，已告知所有者，采用服务器原生编译备用路径：

   ```sh
   runuser -u xingyuan -- env -C /opt/xingyuan/releases/COMMIT/server PATH=/usr/bin:/bin dart pub get --enforce-lockfile
   runuser -u xingyuan -- env -C /opt/xingyuan/releases/COMMIT/server PATH=/usr/bin:/bin dart build cli --target=bin/server.dart --output=build/server
   runuser -u xingyuan -- env -C /opt/xingyuan/releases/COMMIT/server PATH=/usr/bin:/bin dart build cli --target=bin/devices.dart --output=build/devices
   ```

   新发布目录须归 xingyuan 所有，可用 `runuser -u xingyuan -- tar --no-same-owner` 解包。
   必须在可访问的发布目录内启动 Dart；仅用 `dart pub -C` 而从 `/root` 启动时，CLI 初始化可能因
   检查 `/root/bin` 被拒而失败，尚未进入依赖解析。不要因此放宽 `/root` 权限或改动其他服务。
   P3 引入 `sqlite3` build hook 后必须使用 `dart build cli`，不能再用 `dart compile exe`。
   保留整个 `bundle/bin` 和 `bundle/lib` 相对布局；只拷贝可执行文件会丢失 SQLite 动态库。
   首次部署 P3 须同时更新 systemd 的 ExecStart，模板已改为新 bundle 路径；当前线上 `383fc02`
   仍用旧路径，不能先把线上服务切到尚不存在的新文件。回退时一并恢复匹配的 ExecStart。

5. 配置样式见启动器 `server/bin/server.dart` 和私有配置生成器
   `tool/assistant_eval/bin/prepare_server_config.dart`；生成器只读现有 Mac 钥匙串，不打印密钥。
   生成文件为受 Git 忽略的 `config/assistant-deploy.local.json`，不会覆盖本机运行用的
   `assistant-server.local.json`；已有输出时拒绝覆盖。需 SCP 到 `/etc/xingyuan/assistant-server.json`
   后设为 0600、属主 xingyuan。本机示例 `config/assistant-server.example.json` 不含密钥，
   本机 `devices_file` 应指向 Mac 私有目录；部署文件才使用 `/etc/xingyuan/devices.json`。
   必须保留已存在的设备哈希文件，不用空文件覆盖。配置中 reasoning 采用评测选定的 `none`，上限 4000。
   启用配对时另外设置 `companion_database` 为 `/var/lib/xingyuan/data.db`；缺省或 null 保持仅 AI 服务。
   P4 另外设置 `companion_objects` 为 `/var/lib/xingyuan/objects`，启用鉴权图片；已有照片或待清理任务时不能省略。
   源码服务端 schema 已是 v4，独立于 App v10（手机仍 v6）。新 systemd 模板用 `StateDirectory=xingyuan` 和 0700 权限，
   数据不放发布目录，重启/切换 `current` 不替换数据库。不要用空库覆盖已有文件；未知 schema/应用标识拒绝启动。
   升级前完整备份数据库和图片；v1/v2/v3 自动迁移到 v4，回退旧二进制不能直接打开 v4，更不能静默还原丢掉新数据。
6. 首次建立独立系统用户 xingyuan 和私有目录；安装仓库中的 systemd 与 Caddy 模板。
   先 `caddy validate --config /etc/caddy/Caddyfile`，再重新载入配置。
   P4 模板只给 `/v1/companion/photos/upload` 放宽到 2800000 字节，其余仍为 64KB；应用还会检查 2 MiB JPEG 和 1600 像素上限。
   不把 `objects/` 配为静态目录，不提供公开图片 URL。当前未部署该模板，部署时须实测代理层边界，不能只凭本地 HTTP 测试算通过。
7. 原子更换 `current` 符号链接、`systemctl restart xingyuan-assistant`；随后验证：

   ```sh
   systemctl show xingyuan-assistant -p ActiveState -p SubState -p User -p NRestarts
   curl --fail --max-time 20 https://assistant.example.com/v1/health
   ```

8. 按下面的合成探针检查真实请求、无凭证、过大请求和并发限制；临时测试凭证用完立即吊销。
   不上传所有者历史、记忆或私人笔记来验证生产服务。

## 凭证管理

以 xingyuan 用户执行，保证原子替换后的文件属主不变。`issue` 只显示一次新凭证，
应保存到仓库外 0600 文件或由持有人直接录入，不能出现在 CI、App 包、日志或文档中。

```sh
runuser -u xingyuan -- /opt/xingyuan/current/server/build/devices/bundle/bin/devices --file /etc/xingyuan/devices.json issue LABEL
runuser -u xingyuan -- /opt/xingyuan/current/server/build/devices/bundle/bin/devices --file /etc/xingyuan/devices.json list
runuser -u xingyuan -- /opt/xingyuan/current/server/build/devices/bundle/bin/devices --file /etc/xingyuan/devices.json revoke LABEL
```

上述为 P3 新布局命令。尚未部署 P3 的当前 `383fc02` 仍使用 `server/bin/assistant-devices`，
操作前先核对当前发布目录和实际文件，不盲目重建注册表。

每个请求重新读哈希文件，因此吊销不需要重启。不要在两部手机共用同一凭证。
`p1-probe`、`p1-probe-fix`、`p4-probe` 和 `p5-reading-probe` 合成验证凭证均已吊销。
2026-10-20 已为 P6 单独发放 `owner-iphone` 和 `partner-iphone`，分别保存在 Mac 仓库外
`~/.config/xingyuan/owner-iphone-device-token` 与 `~/.config/xingyuan/partner-iphone-device-token`，
目录 0700、文件 0600；两份值不同，未输出正文，服务器只保留哈希。不要重新发放同名标签，
不要用部署、回退或初始化覆盖现有注册表。丢失文件时先明确吊销旧标签，再用新标签发放。

两份凭证已通过公网鉴权层检查：向 turn/summarize 发送空 JSON 返回 400 `invalid_request`，
而缺失、错误及旧吊销凭证返回 401；Origin 返回 403，超大请求返回 413。
这些请求没有调用模型；健康 200 也不代表凭证或模型调用成功。完整真实模型调用证据见下文。
EAI-045 已在所有者正常安装的 AI 设置中录入 `owner-iphone`，显示已存入本机钥匙串，
冷启动后仍可读取；手机 Wi-Fi 的四次合成 turn 请求均为该设备鉴权成功、200、无重试。
三个已有数据发送分类保持关闭。EAI-048 已将 `partner-iphone` 录入 B 的独立钥匙串，
冷启动保留；B 四次成功合成 turn 的服务端标签均为 `partner-iphone`。
EAI-041 已完成所有者正常安装原位升级的数据对照。按新授权 D18，当前先在同一手机的正式包和
“星愿 B”中分别录入上述两份凭证；EAI-047 已按 D19 完成 B 的独立签名安装，
EAI-048 经所有者确认完成开发者信任并实际运行。不等待 D07 才准备单机替代验证。
EAI-049 短暂吊销 `partner-iphone` 后，B 原生请求显示凭证错误、无内容创建，正式版原生请求
仍以 `owner-iphone` 成功；恢复 B 后其重试以 `partner-iphone` 成功。恢复前逐项检查注册表
只变化该吊销位，未改其他条目、密钥或服务配置。两份凭证现均有效，未重新发放。
辅助空 JSON 鉴权矩阵在吊销前为 400/400，吊销 B 时为 400/401，恢复后为 400/400；
这些 400 是已过鉴权后拒绝无效正文，不是模型调用成功。手机成功回复另有请求编号与元数据对照。
D07 延至第二人加入；不得把单机双安装算成交付 B，也不能把凭证写进 dart-defines 或安装包。

## 检查与日志

本机 `tool/assistant_eval/bin/deployed_probe.dart` 读取仓库外 `~/.config/xingyuan/p1-device-token`，
对后端发起健康、401、403、413、真实对话、真实摘要和三请求并发探针（期望 200/200/429）。
至少产生 4 次真实模型调用，全部使用合成内容；不得把该探针配置到 CI。
吊销后运行同一脚本加 `--revoked`，必须直接返回 401。
报告保存在忽略目录 `build/assistant-eval/`，不打印凭证或模型正文。

`--token-file /private/path` 可选择新的临时凭证文件，避免把旧的已吊销凭证误作正向探针。
`--schedule-truncated` 在合成请求中带上安排截断标记，以验证新版共享解析器。
2026-10-20 发布 `7cfc3a2` 后，以上完整探针通过，增加 4 次真实模型调用；
用完立即吊销 `p4-probe`，直接请求返回 401。随后 EAI-024 更新到 `7d54d4b`，当时 `current` 指向后者；
`7cfc3a2` 与旧 `e31ef20` 保留。
回退旧版时须注意它不接受 `schedule_truncated`，带标记的客户端请求会被拒绝；
不能把健康检查通过理解为新版请求仍兼容。

可追加 `--reading-plan`，以原始“这周把《原则》读完”检查至少两天、无时间的计划，复用 C07-03
评测规则。完整探针启用此项时至少 5 次真实调用。`7d54d4b` 的完整探针已通过，实际 5 次、零重试；
新测试凭证 `p5-reading-probe` 已立即吊销。已实测回退到兼容截断字段的 `7cfc3a2` 再恢复 `7d54d4b`，
两次都保持健康 200 和已吊销凭证 401，不回退设备哈希或模型配置。最终服务 active/running，NRestarts=0。

`--legacy-memory` 将一个 401 字合成旧偏好拆为三条请求上下文（含 200 个空格的中间分段），
复验迁移所需的共享解析器兼容性；可与 `--schedule-truncated` 一起运行，默认不启用。
新增/修改空白记忆和空字符串仍应被协议拒绝。先部署此兼容变更，再发布新版客户端。
旧发布 `7d54d4b` 不接受纯空白既有记忆，回退后新客户端的这类请求会返回 400；
健康检查通过不能代替实际新请求兼容检查。

EAI-039 曾发布 `4702be6`，当时 `current` 指向 `/opt/xingyuan/releases/4702be6`，保留旧目录。
同次启用 `--schedule-truncated --legacy-memory --reading-plan` 的完整公网探针全部通过，
5 次真实调用、零重试；`approved-migration-probe` 随即吊销，复测 401。
部署前后私有配置/注册表哈希一致，既有两份手机凭证未替换。服务 active/running、NRestarts=0。
本轮未再次演练回退，也未操作手机或模型中转服务器。

2026-10-21 陪伴 P2 发布 `383fc028aca0515d039c7388ac34755cef64d997`，当前 `current`
指向该完整提交名的发布目录，新增 `/v1/analyze-day`；保留 `4702be6`，回退到它将无法使用今日分析。
配置/注册表哈希不变，服务 active/running、NRestarts=0。公网两次合成分析与拒绝矩阵通过，
测试凭证已吊销并复验 401；调用零重试，日志仅元数据，不存分析历史。
之后 SSH 曾阻塞部署；所有者确认全局公钥认证被关闭，补充授权后已精确改为 yes，
语法检查、有效配置、重载和禁用密码回退的密钥登录均通过，密码登录保留。证据见陪伴账本 C028。
没有重置密码、改动中转服务器或放宽主机指纹校验；连接恢复不代表新后端已经部署。

```sh
journalctl -u xingyuan-assistant --no-pager -o cat
```

应用日志仅记录时间、请求 id、设备标签、固定路由、状态、耗时、token 用量和是否重试。
Caddy 不启用访问日志，运行日志滤除 request 对象。检查日志不能因此打印配置或完整请求体。
公网探测到的未知路径只记为 `unknown`，不会把 URL、查询参数或 Authorization 写入日志。
大包可能由 Caddy 先拒绝；旧版曾把截断流记为 500。`e31ef20` 修复后，公网仍返回 413，
服务记录 400（请求中断），不会调用模型；两层状态不同是代理先拒绝的结果，已分别复验。

## 回退与迁移

保留旧发布目录。回退时将 `current` 原子切回已验证提交，重启服务并复验健康、401 和吊销状态；
不回退设备哈希文件，不恢复已吊销的凭证，不替换私有模型配置。回退实测结果单独写入账本。

服务器到期前，按 [新机清单](backend-migration.md) 及 Goal N08 的新授权迁移；DNS 仍由所有者切换。
域名不变，只改 DNS，不切换客户端地址、不重发已有设备凭证，也不因搬机要求重装 App。
旧机清理由所有者在迁移验证和私有备份完成后安排；不自动删除未知文件或其他服务。
当前线上 `383fc02` 不保存聊天正文；P3 后的成员/配对库，以及 P4/P5 的分享/图片/聊天，
必须另外备份与迁移，不能沿用旧版“无数据库”的结论。每日 7 份完整备份、图片一致性和 Mac 导出
已有本地工具与测试，命令见新机清单；systemd 调度及真实跨机导出仍待迁移后实机演练，不计 K12 通过。
模型中转留存不由本服务控制。

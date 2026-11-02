# 第二阶段 A 实施与验收记录

执行约定：[GOAL-phase2-sync.md](../GOAL-phase2-sync.md)。
启动：2026-10-11 00:08:07，Asia/Shanghai。
任务分支：`codex/v0.2-sync`，从 `codex/m1-personal` 的 `91641fe` 建立，
随后 fast-forward 纳入已有云环境准备提交 `27e32a4`。未合并或推送 `main`。

## 当前结论

进行中，尚未达到“自验收完成，待审查”。
本阶段只做可选邮箱验证码登录与个人云端同步。小组、共享、“我们”页、
动态与成就不在正式 App 实现范围。正式 App 不插入演示数据。

前一工作回合完成了云项目与本机配置，属于可核实进展，不是等待或空转。
P0 已记录 M1 收口并复核基线；P1 规格已编写，P3 不依赖云端账号/邮件配合。
P2 已开始本地脚本与资料准备，真实 G3 尚未执行；
SMTP、双邮箱与实际手机网络验证尚无通过证据。

## 阶段状态

| 阶段 | 状态 | 证据或下一步 |
| --- | --- | --- |
| P0 接手与 M1 收口 | 完成 | E2-001；`1692355` 已推送并核验远端 |
| P1 设计与规则 | 完成 | E2-002；`8ca2011` 已推送，CI success；Goal B 交互仍待所有者审阅 |
| P2 G3 云端 | 等待条件 | E2-006/008 本地迁移及 API 诊断工具已准备，未部署或 live 执行；配合清单已一次性告知 |
| P3 本地同步基础 | 完成 | E2-003/004/005：本地结构、事务、引擎与替身验证；不等于设备或云端通过 |
| P4 云端接入 | 等待条件 | 仅 G3 通过后实施 |
| P5 验证 | 进行中 | E2-007 已完成 S05 真机原位升级；登录/云端/手机网络仍待条件 |
| P6 交付 | 未执行 | 全部必需证据齐备后整理第 8 章审查包 |

## 接手环境

| 项目 | 2026-10-11 核对结果 |
| --- | --- |
| 仓库 | `hollegjx/habit-checkin`，private，当前 CLI 权限 ADMIN |
| M1 基线 | `91641fe02611b06c58c77f64d26932eccea76a7c`，远端 SHA 一致 |
| M1 CI | Actions `38039038648`，completed / success |
| 云环境准备 | `27e32a42c373b014a4711feca1d342d6e8ca2c43`，远端 SHA 一致 |
| 未提交起点 | 所有者提供的 `GOAL-phase2-sync.md`，按本次指令纳入版本管理 |
| 工具链 | Flutter 3.47.6 stable / Dart 3.13.5 / Xcode 26.6 (17F113) |
| macOS | 26.5.1 |
| 模拟器 | 已启动 iPhone 17 Pro / iOS 26.5 |
| 真机 | 开发工具当前可发现已注册 test iPhone / iOS 26.6.1 |
| 工具限制 | 无 Android SDK、无 CocoaPods；继续现有 iOS/SPM，不改全局 SDK |
| 云资源 | 免费开发项目，新加坡；见 [创建记录](cloud-setup.md) |
| 凭据 | 客户端 JSON 被忽略；数据库密码在本机登录钥匙串；未导出 secret API key |

`GOAL-phase2-sync.md` 第 1 章是编制时快照。“未创建云资源”已由
2026-10-10 的授权准备更新，不重复注册或创建项目。该准备不等于 G3 通过，
也不继续扩大为登录所有者其他账号的授权。

## 验收矩阵

仅完整取得约定证据后标“通过”；自动测试不能替代云端或真机行为。

| 编号 | 状态 | 证据 / 缺口 |
| --- | --- | --- |
| S01 M1 收口 | 通过 | E2-001；A18 撤销、所有者报告与执行者证据明确区分 |
| S02 交互规格 | 通过 | E2-002；规格齐备并明确待所有者审阅，不等于 Goal B 获准启动 |
| S03 G3 | 等待条件 | [G3 准备记录](cloud-gate.md)、E2-006/008；SMTP、双邮箱、手机网络及实际 RLS 待执行 |
| S04 同步设计 | 通过 | E2-002；数据、幂等、冲突、迁移、身份与错误处理规格 |
| S05 v2→v3 | 通过 | E2-003 自动/模拟器 + E2-007 正常真机原位安装与只读逐列对照 |
| S06 登录 | 等待条件 | G3 与安全会话适配 |
| S07 访客迁移 | 等待条件 | E2-004 本地事务/重试通过；设备中断与服务端行数待验证 |
| S08 离线写入 | 等待条件 | E2-005 本地故障注入通过；正式 UI 与真机断网待验证 |
| S09 幂等 | 等待条件 | E2-005 丢/迟响应与三进程本地探针通过；实际服务端核对待执行 |
| S10 新设备恢复 | 等待条件 | E2-005 双本地文件恢复通过；模拟器与隔离真机真实同步待执行 |
| S11 冲突 | 等待条件 | E2-005 双替身客户端冲突通过；真实双设备流程待执行 |
| S12 退出与过期 | 等待条件 | E2-004/005 本地切换/过期暂停通过；安全会话与设备流程待执行 |
| S13 身份隔离 | 等待条件 | E2-004 本地数据/队列/提醒替身通过；真实系统队列待检查 |
| S14 越权 | 等待条件 | 实际服务端策略与不同身份 |
| S15 失败表达 | 等待条件 | E2-005 引擎故障注入通过；正式状态 UI/组件测试待实现 |
| S16 提醒回归 | 通过 | E2-005：174 项全量测试通过，新增访客/A/B 提醒回归；仅该项自动测试范围 |
| S17 隐私与密钥 | 未执行 | 最终仓库、App 包和日志检查 |
| S18 自动检查 | 未执行 | 最终生成、格式、分析、全量测试、空库迁移 |
| S19 设备 | 未执行 | 双端签名安装、同步、冷启动、不同网络 |
| S20 交付 | 未执行 | 最终差异、远端 SHA、CI 与审查包 |

## 证据

### E2-001 接手与所有者收口

- 对应：P0、S01；尚不支撑其他 S 项通过。
- 时间：2026-10-11 00:08:07 至 00:15:59，Asia/Shanghai；提交同步另计。
- 代码：App 为 `91641fe`；配置和文档基于 `27e32a4`。本项不改 App 行为。
- 来源：Git/CLI 自动执行与本机结果包只读检查；M1 补充结论来源为所有者报告。
- 已核对工作树、远端私有权限、两条分支 SHA、工具链、可用模拟器与真机。
- `flutter --version`、`flutter doctor -v`、`xcodebuild -version`、
  `xcrun simctl list devices available`：退出 0。Doctor 仍提示 Android SDK 与
  CocoaPods 两项，不为此安装非必要工具或宣称环境无任何提示。
- `xcrun xcresulttool get build-results --path
  build/ios-device-reminders-20261010-e023.xcresult`：退出 0，succeeded，
  errors/warnings 均 0，仅复核原签名构建，未重复操作真实记录。
- `gh run list --branch codex/m1-personal` 核对 M1 CI success；
  `git ls-remote --heads origin ...` 核对 M1 与云环境准备分支 SHA。
- A18 撤销与其余真机报告写入 M1 E024。未获得补充可核实记录的 A 项不改成通过。
- `flutter test --reporter expanded`：退出 0，107 项全部通过，无跳过。
- `dart format --output=none --set-exit-if-changed lib test integration_test`：
  退出 0，52 个文件无修改。
- `flutter analyze`：退出 0，No issues found。
- `dart run build_runner build`、`dart run drift_dev make-migrations --no-test`、
  `dart run drift_dev schema generate drift_schemas/app_database test/drift/generated`：
  均退出 0；随后对 `lib/data/local`、schema、生成测试与 lock 的
  `git diff --exit-code` 退出 0，无生成漂移。
- `git diff --check`、已跟踪文件的敏感凭据/产物模式扫描及当前 Markdown
  本地链接存在性检查：均退出 0。真实客户端配置未跟踪。
- 文档核对通过：S01 只证明收口记录正确，不表示未核实的 M1 设备项改为通过。
- 限制：无新的云端、真机交互或真实数据操作。

### E2-002 交互与同步规格

- 对应：P1、S02、S04。
- 时间：可追溯工作区间为 2026-10-11 00:15:59 至 00:26:21，
  Asia/Shanghai；提交同步另计，非协作工时。
- 代码：基于 `1692355`，只有设计/状态文档变更，未修改正式 App。
- 来源：执行者逐项对照 Goal P1 与第 3/4 章；本机链接检查及官方包元数据查询。
- `docs/companion-ux.md` 覆盖三种“我们”状态、共享选择/撤销、邀请/加入/退出、
  字段可见表、关键文案和隐私原则，明确标记待所有者审阅；Goal B 未启动。
- `docs/sync-design.md` 规定目标 UUID 聚合、v3 迁移、事务/outbox、
  请求冻结/幂等/revision、历史键保留、拉取、冲突情形表、访客移动、
  提醒实际调度身份及可恢复切换，不采用后写覆盖。
- 产品待确认表中本阶段的邮箱投递、访客迁移、冲突条目已转为“本阶段采用”；
  邮件服务配置和 G3 实测仍等待条件，小组规则继续待决定。
- pub.dev JSON 元数据查询退出 0：supabase_flutter 2.18.2
  （2026-10-09 发布）、uuid 4.6.0（2026-07-15 发布）。未添加 SDK 或升级 Flutter。
- 初次文本标记检查因原则未以“不排名”字面表达而失败；补充显式原则句后重跑，
  本地文档链接、范围标记、敏感凭据模式检查与 `git diff --check` 均退出 0。
  字面检查仅辅助发现遗漏，不代替上方逐项语义核对。
- 限制：没有实现同步、验证远端协议或取得所有者对 Goal B 的审阅。

### E2-003 本地 v3 结构与升级

- 对应：P3.1；S05、S13、S16、S18 的部分自动/模拟器证据，不单独支撑整项通过。
- 时间：2026-10-11 00:26:21 至 00:52 前后，Asia/Shanghai，
  约 26 分钟墙钟，非协作工时；提交与 CI 同步另计。
- 代码：基于 `8ca2011` 的本工作包；精确提交随下方同步记录。
- 来源：本机自动检查、文件数据库测试、Xcode/iOS 模拟器实际运行。
- 环境：Flutter 3.47.6 / Dart 3.13.5 / Xcode 26.6，iPhone 17 Pro / iOS 26.5 Simulator。
  没有访问云端、切换真机网络或读取真实访客内容。
- 实现：目标稳定 UUID、五张同步/身份基础表、关联 owner/目标/操作的外键，
  调度账本保留实际 owner；升级保持旧内部 ID/自增序号与所有历史列，不创建 outbox。
- 迁移测试逐列对比旧六张表，覆盖归档、false 打卡、历史规则、提醒错误/结束状态、
  多身份、已删除 ID 的自增历史（含空库）、文件重开后 UUID 稳定。
  故意构造合成孤儿行时，迁移失败回滚至 v2；修复该测试孤儿行后重试成功。
- 结构测试拒绝重复 UUID/操作、错 owner、错目标的冲突引用、无 base 的在途请求、
  负 revision、非单例身份。提醒测试验证目标转移后旧 payload 可取消；
  取消未确认时不会提前替换，新 owner 重排后仍只有原数量的通知。
- `flutter test test/drift test/sync_schema_test.dart test/reminder_coordinator_test.dart
  --reporter expanded`：退出 0，31 项通过。
- `flutter test --reporter expanded`：最终退出 0，118 项通过，无跳过；
  原 107 项保持通过。`flutter analyze`：退出 0，No issues found。
- `dart format --output=none --set-exit-if-changed lib test integration_test`：
  退出 0，57 个文件无修改。
- `dart run build_runner build`：最终退出 0，无生成警告。
  补强约束后 `make-migrations --no-test` 曾以 255 拒绝与本轮未提交的 v3 快照不一致；
  随后通过 `drift_dev schema dump lib/data/local/app_database.dart
  drift_schemas/app_database/drift_schema_v3.json` 重新生成该新快照（退出 0），
  再运行 `make-migrations --no-test`、`schema generate ...` 均退出 0。
  v1/v2 历史快照与历史 helper 的 `git diff --exit-code` 为 0，没有改写已交付版本。
  最后暂存后再执行全部三条生成命令，均退出 0；对生成目录和 lock 的
  未暂存 `git diff --exit-code` 为 0，生成可重复且没有漂移。
- 模拟器探针 `integration_test/sync_migration_gate_test.dart`：
  `--no-uninstall`，同一新 token `20261011-v3-r1`，分别启动
  `SYNC_MIGRATION_PHASE=seed/upgrade/reopen` 三个独立进程；均退出 0，各 1 项通过。
  seed 使用真正的生成 v2 schema 建库；upgrade/reopen 输出
  `v3 goals=3 oldTables=6 preserved=true outbox=0`。重开不补种预期记录。
- `flutter build ios --simulator --debug -t lib/main.dart`：退出 0；
  `simctl install` 原位恢复正常入口、`simctl launch` 启动：均退出 0。
  这只是正常入口恢复，不扩大为真实页面交互或真机结果。
- 已跟踪和未忽略候选文件的凭据模式扫描：124 个文件，匹配 0，
  真实客户端配置未跟踪；16 个 Markdown 文件的相对文件链接均存在。
  `git diff --check`：退出 0。模式扫描不是所有隐私场景的完整证明。
- 限制：尚无业务 outbox 写入、身份切换服务、远端引擎、登录界面或云端验证；
  未操作所有者真实安装，S05 的真机证据待后续取得。

### E2-004 事务队列、访客移动与身份切换

- 对应：P3.2 与部分 P3.3；S07、S08、S12、S13、S16 的本地证据，
  不据此判定设备、真实认证或云端条目通过。
- 时间：2026-10-11 00:54 至 01:14 前后，Asia/Shanghai，约 20 分钟墙钟；
  包含中断/恢复，非协作工时；提交与 CI 另计。
- 代码：基于 `03c20d4`；没有更改已提交的 v3 schema。
- 来源：执行者实现、本机自动/文件测试及 iOS 模拟器构建。
- 目标文档采用显式白名单，排除 owner、提醒、私密扩展字段与本地整数 ID；
  保留标题/计划版本及 false 打卡，规范排序，严格校验类型/日期/键。
  非法 JSON 错误不回显源内容；同日同完成结果忽略设备记录时间差，
  不把不同单次实际完成日或不同标题当作相同。
- 账号 create/edit/完成/撤销/archive 在原业务事务内写不可变快照 outbox；
  访客与历史测试 owner 零入队，纯提醒和无效重复操作不入队。
  注入队列失败时创建/编辑/打卡/归档及提醒 revision 全部回滚。
- 身份服务持久化切换目标与代次，取消旧 pending 后再次查询确认；
  无法确认时冻结带旧 lease 的命令，保留切换意图，修复后可继续。
  外部通知不清除；本身份出现未入账 payload 时阻止切换，而非假装已取消。
  新身份排程失败单独报告，不将已完成的身份切换误报成已回滚。
- 明确访客迁移整体移动原目标，保留 UUID、内部键、历史与本机偏好；
  同一迁移 ID 只返回原集合。测试新增访客后重试不再次迁走；
  第二个目标队列写入失败时，全部 owner、队列与迁移标记回滚。
- `flutter test test/goal_document_test.dart test/local_outbox_test.dart
  test/identity_transition_test.dart test/reminder_coordinator_test.dart
  --reporter expanded`：退出 0，42 项通过。
  首轮分析发现一处测试未用 import，移除后再检查；
  文件重开测试关闭无关内存连接后，不再产生 Drift 多实例警告。
- 恢复后 `flutter test --reporter expanded`：退出 0，142 项全部通过；
  `flutter analyze`：退出 0，No issues found。
- `flutter build ios --simulator --debug -t lib/main.dart`：退出 0。
  本次仅构建，没有新增真机、模拟器账户 UI 或通知系统实测。
- 三条代码/schema 生成命令均退出 0，生成文件、schema 及 lock 的
  `git diff --exit-code` 为 0；格式检查 66 文件无修改，`git diff --check` 退出 0。
  133 个候选文件的凭据模式检查匹配 0，Markdown 本地链接无缺失，
  `config/supabase.local.json` 未跟踪；均为本机自动检查。
- 限制：身份服务未接入生产 providers/页面；正式 App 仍为访客使用，
  没有网络适配、认证会话、同步引擎或演示联网。后续接入必须传递当前身份 lease，
  并先恢复未完成切换，再显示正常页面。未读取或上传所有者真实数据。

### E2-005 本地同步引擎与原生进程恢复

- 对应：P3.3/4、S16；S08 至 S13、S15、S18 的部分证据，
  不支撑整项云端/设备验收通过。
- 时间：2026-10-11 01:16 至 01:38 前后完成实现和验证；01:46 后恢复核对、
  补文档与提交，Asia/Shanghai。墙钟包含中断，非协作工时。
- 代码：基于 `d609ead`，本包未修改 schema v3 或生产页面/providers。
- 来源：本机自动执行、文件数据库测试、iOS 模拟器实际运行。
- `SyncRemote` 绑定一个账号；请求 JSON 不含 owner，未来服务器须从认证取得身份。
  远端替身只放在 `test/support/`，生产没有演示后端。
- 队列发送前持久化请求及 base revision，重试不换 ID/内容；按目标顺序发送，
  网络等待不占用写入/提醒串行队列。响应核对账号、身份代次、操作、来源、
  revision 与完整历史；旧身份响应不落入新身份，迟到确认不覆盖后续本机修改。
- 冲突保留远端与最新本机副本，仅暂停该目标；显式选择产生新操作并保留冲突档案。
  无可信归档前证明时保持归档，返回原因，不擅自复活。拉取拒绝截断、混合 owner、
  已确认目标遗漏和历史丢失，失败整批回滚；恢复提醒默认关闭。
- 引擎 23 项场景涵盖断网、丢/迟响应、文件重开、认证暂停、身份切换、同结果幂等、
  冲突再变化、归档保护、pending 安全拉取、恢复、非法响应、事务失败、
  合并触发与 Retry-After。额外 9 项覆盖访客/A/B 的每日/星期/单次提醒、
  取消/替换、完成/撤销、已送达抑制与授权拒绝。既有测试保持通过。
- `flutter test --reporter expanded`：退出 0，174 项通过，无跳过。
  `flutter analyze`：退出 0，No issues found；格式检查 73 文件无修改，退出 0。
  首轮 lint 与测试不必要空断言已修复后重新检查，不隐藏初次失败。
- 三条生成命令均退出 0，数据库生成文件、schema/helper 和 lock 的
  `git diff --exit-code` 为 0；没有改写已提交 schema。
- `integration_test/local_sync_gate_test.dart`：iPhone 17 Pro / iOS 26.5 Simulator，
  run `20261011-p3-r1`，`--no-uninstall`，arm/replay/reopen 三个独立进程，
  均退出 0，各 1 项通过。首次启动因模拟器 Shutdown 未进入探针；
  启动既有模拟器（未 reset）后重试成功。
  两个独立探针文件不使用正常访客库；arm 保存未确认请求及测试替身收据，
  replay 重建该替身并验证重试/恢复，reopen 不补种记录。
- 这不是 Supabase、真实认证/RLS、真机双设备或服务器进程恢复证据。
  `flutter build ios --simulator --debug -t lib/main.dart`、`simctl install`、
  `simctl launch` 均退出 0，已恢复正常模拟器入口。未触碰真实 iPhone。
- 同期按 D07 在仓库外安装 Supabase CLI 2.120.0，安装/version/help 均退出 0。
  尚未登录、链接或部署；未安装 Docker，未发送邮件或上传业务记录。
- 恢复后再次运行全量测试：174 项通过、退出 0；格式检查 73 文件无修改。
  140 个已跟踪/未忽略候选文件的凭据模式匹配 0，Markdown 本地链接无缺失，
  客户端本机配置未跟踪，`git diff --check` 退出 0。
  此扫描不是完整 S17 的 App 包/日志隐私证明。
- `supabase projects list --output json` 退出 1：缺少 access token。
  没有因此执行登录、读取钥匙串密码或绕过授权；P2 仍缺所有者 CLI 授权。
- 限制：P4 须等待真实 G3。未来 UI 必须处理引擎本地数据库异常且不输出原始内容；
  各身份真实系统通知队列、S05 真机升级和真实云端验收仍待执行。

### E2-006 云端关卡准备与客户端配置防护

- 对应：P2 准备、S03/S17/S18 的局部证据；G3、服务端 SQL、业务权限均未通过。
- 时间：2026-10-11 01:50 至 02:00 前后，Asia/Shanghai，约 10 分钟墙钟；
  部分与 E2-005 收尾交叠，非协作工时，提交/CI 另计。
- 代码：基于 `3d417f4`；不改正式 App 或 schema，不添加网络依赖。
- 来源：执行者编写、本机自动检查、Supabase 官方资料复核与 CLI help。
- 新增 `docs/cloud-gate.md`：实际状态、免费层/SMTP 约束、待部署顺序、
  A/B/匿名权限矩阵、手机两类网络的逐操作样本和延迟统计要求、清理边界。
  不把验证码发送/会话检查算成成功登录，不放宽 Goal 规定的每类至少 20 次。
- 最小 `g3_probe_records`/受控函数迁移与事务回滚 SQL 角色测试已准备，
  未部署、未在 PostgreSQL 执行。它不是正式目标的幂等/revision RPC，
  也不能替代真实用户 JWT 的 Data API 越权测试。无 pgTAP、Docker 或新全局软件。
- `supabase db query --help` 退出 0，确认本机 CLI 支持 linked/file；
  `supabase migration list --linked` 退出 1，提示尚未 link，未运行迁移。
  `command -v psql` 退出 1，本机也没有可据以执行 SQL 的 psql。
  不为取得绿色结果绕过缺少的授权或改用管理员请求冒充普通用户。
- 新增本机只读配置检查：限定两项公开字段与托管开发 URL/publishable key 形式，
  拒绝额外秘密字段、错误来源、占位值及非法 JSON；错误输出不含原值。
  检查固定文件为 0600、被忽略且未跟踪，不联网，不证明 key 真实有效。
- `dart run tool/check_cloud_config.dart`：退出 0，值隐藏，未访问云端。
  `flutter test test/cloud_client_config_test.dart --reporter expanded`：31 项通过，退出 0；
  全量 `flutter test --reporter expanded`：205 项通过，退出 0，无跳过。
- 格式检查首次退出 1，发现新增测试的排版；格式化后重跑退出 0，
  75 个文件无修改。`flutter analyze` 退出 0，No issues found。
  三条生成命令均退出 0，生成文件、schema/helper/lock 差异检查退出 0。
  Drift 仍提示新增无默认 UUID 需数据迁移测试，该测试已由 E2-003 覆盖。
- 147 个已跟踪/未忽略候选文件的凭据模式匹配 0，本地 Markdown 链接无缺失，
  客户端本机配置未跟踪；`git diff --check` 退出 0。
- CI 增加 `tool/` 格式检查和明确的云端“NOT RUN”状态说明，不配置云端凭据。
  本包没有新的 App 构建或手机业务操作；真实网络、SMTP、SQL 与服务端测试仍等待条件。

### E2-007 正常真机安装的 v2→v3 原位升级

- 对应：S05；S17/S19 部分证据，不支撑账号/云端设备条目通过。
- 时间：2026-10-11 01:59 至 02:09 前后，Asia/Shanghai，约 10 分钟墙钟；
  构建、读取与核对包含在内，非协作工时，文档/提交另计。
- 代码：`7d8b1a2690e3220b9a27c37ae5eb07c881ef7777`；
  正常 `lib/main.dart`、Release 0.1.0 (2)，不是测试入口。
- 环境：同一已注册 test iPhone / iOS 26.6.1，原 Personal Team，
  Flutter 3.47.6 / Xcode 26.6。来源为执行者实际 CLI/镜像操作及本机只读比较。
- 首次尝试列出 `Library/Application Support` 失败（CoreDevice.ActionError 3）；
  核对已安装 Drift 源码后确认默认目录为 Documents。根目录与 Documents
  列举成功，不把错误路径误报成设备权限拒绝。没有修改手机设置。
- 先确认原正常 App 版本和容器，镜像显示主屏幕、无正在编辑的表单；
  只终止该 App 当前 PID，再次进程查询为空。Documents 枚举未见 sidecar，
  用 `devicectl device copy from` 只读取得原 guest 数据库副本。
  `PRAGMA user_version=2`、journal_mode=delete、integrity_check=ok、
  foreign_key_check 零错误。
- `flutter build ios --release --config-only -t lib/main.dart`：退出 0。
  `xcodebuild build -quiet` 使用已注册设备/原团队和
  `build/ios-device-upgrade-20261011-e007.xcresult`：退出 0；
  `xcresulttool get build-results` 为 succeeded，错误/警告均 0。
  `codesign --verify --deep --strict`：退出 0，bundle ID 未变。
  描述文件到期仍为 2026-10-17 12:10:14 Asia/Shanghai，无新增设备或团队。
- `devicectl device install app` 原位安装：退出 0，未卸载、清库或重置。
  02:05:31 正常 launch 退出 0；镜像看到原目标和正常今天页，未点击打卡或编辑。
- 再次回主屏幕、仅终止当前新容器下的 App PID并复查为空；
  Documents 仍无 sidecar，仅原 guest 库被升级，旧隔离提醒探针库未参与测试。
  取得 after 副本，以 SQLite `-readonly`、`query_only=ON` 和只读 ATTACH 比较。
- 02:08:16 的比较结果：原六表按原列双向 EXCEPT 均为 0，行数分别
  `1/1/1/1/1/0` 且前后一致，原 sqlite_sequence 差异 0。
  v3 integrity_check=ok、外键错误 0、UUID 缺失/重复 0、身份仍 guest，
  server revision 非零数 0、outbox/conflicts/transfers 均 0。
  该真机数据没有发生记录内容改动或访客上传；更多历史、归档和非空调度账本
  覆盖来自 E2-003 合成测试，不冒充这台手机当时存在这些记录。
- 02:08:35 冷启动退出 0，镜像再次只读确认原记录仍在；
  留下正常 Release，不留测试构建。未登录测试账号、读 OTP、切网络或改授权。
- 原始设备元数据、before/after SQLite 与不含内容的 `comparison.json`
  在 `build/phase2-device-upgrade-20261011-e007/`；目录 0700、副本 0600。
  `git check-ignore -v` 确认副本、报告与 xcresult 都被 `/build/` 排除；
  没有把目标名称、记录内容、签名资产或设备 ID 纳入 Git。
- 61 个 Release 包文件的凭据模式扫描匹配 0，未发现 SQLite 数据库文件；
  仅为当前包的有限模式检查，不替代最终登录实现后的完整 S17。
- 文档收尾后 `git diff --check` 退出 0；147 个候选文件凭据模式匹配 0、
  Markdown 本地链接无缺失；build 文件和本机客户端配置均未跟踪。
- 限制：没有云端、手机移动网络、真实多账号或系统提醒切换验证，
  S06 至 S15/S19 的对应缺口继续保留；S05 的升级证据已齐。

### E2-008 云端 API 诊断工具与本地防护验证

- 对应：P2 的工具准备，提供 S03/S14 后续取证入口；不支撑真实云端验收通过。
- 时间：2026-10-11 02:17:28 至 02:45:49，Asia/Shanghai，约 28 分钟墙钟；
  包含上下文交接，非协作工时；文档、提交和 CI 同步另计。
- 代码：基于 `0c155e5` 的本工作包。只改工具、测试和说明，
  没有新增 SDK、修改正式 `lib/`、schema/lock 或重建/安装手机 App。
- 来源：执行者实现、本机替身/loopback HTTP/临时文件测试；
  Auth 接口依据官方 OpenAPI 复核，未连接真实 Auth/Data API。
- `tool/run_cloud_gate.dart` 默认离线帮助；live 要求明确项目 ID、
  本机 0600/被忽略/未跟踪的公开配置和交互式终端。邮箱/验证码隐藏输入，
  默认不创建账号；每邮箱仅发一次请求，无自动重试。未替所有者运行 live。
- `GateClient` 仅使用固定 HTTPS 项目地址；请求不跟随重定向、不关闭 TLS，
  默认 20 秒超时、响应上限 64 KiB；会话仅在内存使用，正常退出尝试 local-scope
  注销。日志只记录固定路径、身份类别、状态/白名单错误码、行数和耗时，
  不写邮箱、token、验证码、请求体或响应正文。
- 最小权限矩阵含 20 个明确检查，先验证 A/B 实际身份和自身读写，再检查越权；
  不把表/函数缺失、失效 token、5xx 或超时判作权限拒绝。失败后余项 `not_run`，
  清理失败也不通过。替身仅在测试目录。
- 第一次写合成行前持久化本 run 的三个随机记录 ID；只清理这些 ID，
  不遍历清空或删除 Auth 账号。独立恢复命令校验项目/run/两个真实用户，
  恢复报告不覆盖原失败证据；恢复不被匿名预检失败阻断。
  最终报告先写完整的 owner-only 临时文件，再替换清单，避免直接截断原文件。
- `flutter test test/cloud_gate_probe_test.dart test/cloud_client_config_test.dart
  --reporter expanded`：最终退出 0，56 项通过（工具 25 项，配置 31 项）。
  覆盖权限判定、丢响应/清理失败、身份不一致、敏感错误脱敏、命令参数、
  manifest 恢复与文件权限；真实 loopback HTTP 覆盖重定向、超大/错误响应和超时。
- `flutter test --reporter expanded`：最终退出 0，230 项通过，无跳过。
  首轮工具版本为 227 项；补报告替换的三项文件测试后全量重跑，以上为最终结果。
- `flutter analyze`：最终退出 0，No issues found。首轮工具实现的多余 import
  与 null-aware map lint 已修正；不将修复前的分析当作通过。
  `dart format --output=none --set-exit-if-changed lib test integration_test tool`：
  退出 0，79 文件无修改。
- `dart run build_runner build`、`dart run drift_dev make-migrations --no-test`、
  `dart run drift_dev schema generate drift_schemas/app_database test/drift/generated`：
  均退出 0；生成代码、schema、helpers 与 lock 的差异检查退出 0，没有重写 v3。
- 离线配置检查和 `run_cloud_gate.dart --help` 均退出 0，值未输出、未联网。
  故意在非 TTY 执行含占位项目 ID 的 live 命令，按预期退出 1
  `GateFailure(input)`，未创建报告目录；这是入口防护测试，不是 G3 失败记录。
- `supabase projects list --output json` 再次退出 1，仍为缺少 access token；
  没有执行 CLI 登录/link/迁移、读邮件或修改任何云资源。
- 151 个候选文件的凭据模式/产物/Markdown 本地链接检查通过；
  初次宽模式命中配置测试中的合成 PostgreSQL URL，人工确认后只排除该固定测试值，
  重跑没有未批准的凭据匹配、本地链接缺失或禁入产物。
  `rg` 检查正式 `lib/` 无此诊断工具引用；`git diff --check` 退出 0。
- 限制：没有真实邮件投递/错码/过期/限流、托管 SQL/API、账单或手机网络证据；
  Mac 诊断耗时不能替代手机两类网络各 20 次取证，更不是正式同步 RPC 的 S14。
  P2/S03 继续等待条件，P4 不启动，没有操作或上传所有者真实记录。

## 配合事项（P2 前一次性清单）

2026-10-11，已在启动 P2 前向所有者一次性列出以下事项。云项目及公开客户端配置
已经准备，不需要重新注册。在收到配合前继续 P1、P3，不把缺少云端证据记成通过。

| 缺少什么 | 原因 / 最小操作 | 影响验收 |
| --- | --- | --- |
| 自定义 SMTP | 所有者选择发信邮箱或免费服务，在 Supabase 自行填凭据；不发到聊天 | S03、S06 |
| 两个可收信测试邮箱 | 所有者提供测试地址并在指定步骤读验证码；不使用旁观到的邮箱地址 | S03、S06、S14 |
| CLI 授权与测试后台凭据 | 所有者完成本机 CLI 登录，服务端测试凭据仅保存在被忽略的本机配置；不进入 App/CI/Git | S03、S14、S18 |
| 手机 Wi-Fi/移动网络/断网切换 | 执行者预告时机，所有者本人切换；每类网络登录/刷新/读/写至少 20 次 | S03、S08、S19 |

数据库管理密码仍按之前决定保存在本机登录钥匙串。客户端配置中不增加后台密钥。
本阶段不操作所有者其他账号，不自行购买邮件额度，不修改手机网络设置。

## 投入与同步

本轮开始时间为 2026-10-11 00:08:07 Asia/Shanghai，记录墙钟而非协作工时。
工作包结束后记录耗时与实际命令；原 24 至 40 小时估算不改成承诺日期。
每个可验证工作包单独提交和推送，并查询远端 SHA。CI 结论另行核对。

P0 提交 `1692355982a18f741376b6c64986d68e3f88ae05` 已推送，
`git ls-remote --heads origin codex/v0.2-sync` 与本机一致。
首次查询 Actions `38067044259` 为 in_progress；00:26 前后复核为 completed/success，
生成、格式、分析与测试步骤均 success。该结果属于 P0 提交，不套用于后续代码。

P1 提交 `8ca201152df08d471a8626f8d0d6e7eb457130e2` 已推送，
远端 SHA 一致；Actions `38067841891` 已复核 completed/success。
该结果只对应 P1，P3 提交和 CI 另行记录。

P3 schema 提交 `03c20d4da59782e349adc7db9e4ac696a7f5cff3` 已推送，
`git ls-remote --heads origin codex/v0.2-sync` 与本机一致。
Actions `38069546227` 已复核 completed/success，生成、格式、分析与测试均通过；
该 CI 属于 E2-003，不套用于后续 E2-004 代码。

P3 事务/身份提交 `d609ead11ca4960c19d7a50added5c83283274db` 已推送并核验远端 SHA；
Actions `38071062319` 于 2026-10-11 01:48 前后再次核对 completed/success，
生成、格式、分析与测试均通过。该 CI 属于 E2-004，不套用于 E2-005。

P3 引擎提交 `3d417f43edb9d9f62ca5bdafd3ef31abdef8bfa7` 已推送，
`git ls-remote --heads origin codex/v0.2-sync` 与本机一致；
Actions `38073370486` 已复核 completed/success。该结果对应 E2-005，
不套用于后续云端准备，更不是实际服务端验收。

云端准备提交 `7d8b1a2690e3220b9a27c37ae5eb07c881ef7777` 已推送，
`git ls-remote --heads origin codex/v0.2-sync` 与本机一致；
Actions `38074031113` 已复核 completed/success。
该 CI 对应 E2-006 的本地检查，云端测试明确 NOT RUN。
E2-007 的真机构建使用该代码提交，但不由这次 Linux CI 证明。

真机升级记录提交 `0c155e52fc425b85d6453d4e188a205367103973` 已推送，
远端 SHA 于 2026-10-11 02:44 前后再次核验一致；
Actions `38074797504` 已复核 completed/success，生成、格式、分析、测试均通过。
该 CI 对应 E2-007 记录提交，不替代 E2-008 的新检查或任何云端验证。

## 交付审查包

尚未达到交付条件。P6 按 Goal 第 8 章补齐最终 SHA/CI、相对 `91641fe`
差异、模块清单、S01 至 S20 证据、命令退出码、资源费用、隐私检查、
未完成项和实际投入；在此之前不标“自验收完成，待审查”。

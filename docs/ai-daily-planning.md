# 星愿：AI 当日规划实验

日期：2026-10-19。状态：本地实验与真实中转的模拟器联调已验证；生产部署和真机联调未完成。

2026-10-20 历史说明：下文保留原实验的行为、命令和当时证据，不是当前启动指南。
旧表单和 `/plan` 网关已从正式运行路径退出，代码移至 `test/support/legacy_planning/` 仅供回归；
旧偏好与草稿表保留。原位置参数启动命令及 `PLANNING_GATE_LIVE=true` 不再支持。
当前启动器用 `--config` 运行同一套对话后端，地址及配置见[开发说明](development.md)。

## 决定与范围

所有者要求先尝试 AI 当日规划，指定自有 OpenAI 兼容中转与 `gpt-6-luna`，
并将 App 正式名称改为“星愿”。应用 bundle identifier、Dart 包名、数据库文件名不改。
这是个人使用的独立实验，不替代第二阶段 A 的认证和同步验收。

本轮只实现一个用户流程：填写今天的意图和 5 至 240 分钟的可用时间，生成 1 至 6 项
可编辑草稿，确认后创建当天的单次目标。预计分钟仅用于规划预算，不是闹钟、日历占用
或计时器；不自动打卡、修改旧目标、开启提醒、共享或给别人发消息。

“Agent”在本轮指受控的工具调用流程，不是可自由运行的通用代理。模型只有一个
`submit_daily_plan` 工具，用来提出结构化草稿。实际数据库提交由用户确认后的代码执行，
没有循环自主执行、外部搜索、文件操作或任意数据库权限。

## 记忆与隐私

- 用户主动填写并保存“本机偏好”，每次规划读取该身份下的这段内容。
- 不自动分析历史聊天；本轮没有聊天历史、向量记忆库或跨设备记忆同步。
- 生成前逐次确认发送目的地、需求、偏好、日期、时区与可用分钟数。
- 不发送已有目标、打卡、私人笔记、小组信息或设备账户标识。
- 意图和原始模型响应不写入数据库；只保存校验后的任务草稿和应用回执。
- 偏好、草稿、回执按本地身份隔离；访客登录迁移不自动携带这些实验数据。
- 将偏好清空并保存即可移除偏好正文；已生成草稿可能仍反映以前的偏好。
- API 参数包含 `store: false`，但这不能保证第三方中转不留存请求；发送方应了解其政策。
- 模型输出仅作为不可信数据处理，禁止把里面的指令当成程序权限。

## 技术方案

1. Flutter 页面负责需求、发送确认、编辑预览与保存。
2. `PlanningService` 是模型访问边界；正式 Release 默认未配置，不携带模型密钥。
3. 本轮用仅监听 `127.0.0.1` 的 Dart 开发网关供 iOS 模拟器联调，不开放公网或局域网。
4. 网关从 Mac 登录钥匙串读取中转凭据；App 只持开发网关的随机会话 token。
5. 通过 Chat Completions 请求 `gpt-6-luna`，设置 `reasoning_effort: none`，
   强制单一工具调用，最多 1,200 个输出 token，不自动重试。
6. 网关和客户端都严格检查字段、标题、重复任务、任务数、总时长和完整工具输出。
7. 确认通过 `LocalPlanningStore.apply` 在同一 SQLite 事务内调用现有目标仓储，
   保存全部目标、现有账号 outbox 操作和回执。失败整体回滚。
8. 相同草稿、相同确认内容的重复请求返回原目标 id；换内容重放同一回执会拒绝。
9. 日期变化后拒绝新的草稿确认；已经成功的同内容重试仍返回原回执。
10. schema v4 只新增偏好和草稿两张表；v1/v2/v3 迁移必须保留原业务数据。

此网关不是生产认证系统。手机独立在线使用还需要受认证保护的已部署规划后端、
持久化的用户额度限制、凭据管理及真实手机网络验证。不要把网关绑定到 `0.0.0.0`，
不要为了让手机访问而把中转密钥塞进 App。没有模型时不得用固定模板冒充 AI。

官方协议依据：

- <https://developers.openai.com/api/docs/models/gpt-6-luna>
- <https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create>

## 开发配置

凭据保存在 Mac 登录钥匙串，服务名 `habit-checkin-planning-dev`；不在本文、App 或 Git 中。
配置模板为 `config/planning-gateway.example.json` 和 `config/planning-client.example.json`。
本机配置使用同名 `.local.json` 后缀，已经被 `.gitignore` 排除；权限应为 `0600`。
网关文件只含中转地址、模型名、钥匙串条目名、随机本机会话 token、端口和调用上限，
不含模型密钥。客户端文件只含回环网关地址、同一会话 token 和准确的接收方说明。

```sh
dart run tool/run_planning_gateway.dart config/planning-gateway.local.json
flutter run -d SIMULATOR_ID --dart-define-from-file=config/planning-client.local.json
```

`max_calls` 默认必须为 0。只有所有者明确批准付费测试后才提高，当前实验最多为 3；
这是单次进程的调用上限，不是平台账单上限，重启会重置。错误调用也计入上限。
不记录请求正文、模型返回、API key 或用户私人内容。不跟随带认证请求的重定向。
网关拒绝浏览器 Origin、无效会话 token、不支持的路径、超大或非法请求，并限制并发。
本机 CLI 获取 `/models` 成功，不等于真实推理或工具调用已通过。
2026-10-19 所有者明确批准真实联调；本轮仅执行下述两次推理，没有自动重试。

## 验收

| 检查 | 必须满足 |
| --- | --- |
| AIP01 发送授权 | 确认前零网络请求，取消不发送；目的地和内容范围明确 |
| AIP02 草稿 | 模型返回只产生草稿，不创建目标；可编辑名称、分钟并移除任务 |
| AIP03 规则 | 超预算、重复任务、未知字段、任意工具、截断输出等拒绝落库 |
| AIP04 确认 | 按预览内容原子创建当日单次目标；默认私密、提醒关、不打卡 |
| AIP05 重试 | 重复确认、重启后回执重放均不重复创建；失败不留下半份计划 |
| AIP06 日期 | 午夜后的旧草稿不可创建为今天的目标 |
| AIP07 隔离 | 跨身份不能读偏好或应用草稿；身份失效时拒绝异步结果与写入 |
| AIP08 保留 | v3 升 v4 原表数据不变；草稿、偏好、回执跨进程保留 |
| AIP09 可用性 | 未配置、失败、超时或拒绝授权不影响原有个人功能 |
| AIP10 布局 | 小屏、大字体可编辑并确认，无溢出 |
| AIP11 模型 | 实际中转 `gpt-6-luna` 返回指定工具结果；不得用替身冒充通过 |
| AIP12 设备 | 实际 iOS 流程与数据保留单独验证；真机和模拟器分别报告 |

## 当前证据

- 已用所有者提供的凭据只读查询中转 `/models`：HTTP 200，包含 `gpt-6-luna`。
- `flutter analyze` 无问题；格式检查通过；全量 252 项自动测试通过。
- 新增测试覆盖严格参数、未知工具、超预算、跨日、确认前不发送、账号隔离、
  本地回执跨重启幂等、批量失败回滚，以及 320 x 568 / 2 倍文字的草稿编辑。
- v3 升 v4 对照全部旧表内容不变；既有 v1/v2 升级与失败回滚测试也通过。
- iPhone 17 Pro / iOS 26.5 模拟器，两次 `--no-uninstall` 独立进程
  `20261019-preserved` 的 write/read 各 1 项通过：2 个测试目标、偏好与回执保留。
- 首次 read 失败：当时漏加 `--no-uninstall`，Flutter 默认重装清掉模拟器容器。
  该次不作为持久化证据；修正命令并使用新 run 重跑通过。未在真实手机上运行此命令。
- 正常 `lib/main.dart` 模拟器 Debug 构建、原位安装、启动通过。已实际查看“星愿”首页
  与规划页；未配置状态明确显示服务未连接，生成按钮禁用，无伪造结果。
- 本机网关从钥匙串启动成功；未经认证返回 401，已认证且额度 0 返回 429。
  已停止网关；未调用真实模型。本机两份配置为 `0600` 且确认被 Git 忽略。
- 上述零额度检查时尚未获准推理；随后获准并完成下面的真实联调，不把早期替身结果当作 AIP11。
- 未部署公网服务，未安装新的规划版本到所有者真实手机，未上传真实打卡记录。

### 获准后的真实中转联调

所有者回复“没事，我这个量很多，尽管测试”后，继续使用指定的 `gpt-6-luna`，
单进程网关上限仍为 3、每次输出上限 1,200 token；实际只发起 2 次推理。
输入均为虚构的阅读/整理桌面意图和短任务偏好，不读取或发送正常 App 的目标与记录。
没有为了获得成功而换模型、自动重试或使用固定模板。

| Run / 阶段 | 可用分钟 | 真实请求 | 结果 |
| --- | --- | --- | --- |
| `20261019-live-r1` / write | 30 | 1 | 返回 2 项；取消首次发送确认时零请求；再次确认后生成草稿，编辑首项并原子创建；回执重放不重复 |
| `20261019-live-r1` / read | 30 | 0 | 新进程读取 2 项目标、偏好和回执，重放返回原 id，数据保留 |
| `20261019-live-5min-r1` / write | 5 | 1 | 返回 2 项且总时长不超过 5 分钟；编辑、确认与幂等检查通过 |

三个模拟器进程各 1 项通过，均使用 `--no-uninstall`，独立文件
`habit_checkin_planning_gate` 和 `planning-live-<run>` 身份。真实调用仍经过正式
`planningServiceProvider`、本机 HTTP 网关和模型工具解析；仅外围加请求计数，不替换模型结果。
检查确认前无目标写入、明确保存的偏好被读取、请求字段白名单、目标内容匹配预览、
提醒关闭、未打卡、无待上传操作、外键正常。30 分钟场景已跨进程验证；5 分钟场景没有另跑 read。
这通过 AIP11 的本次中转工具调用检查，以及 AIP12 的上述模拟器路径，不是生产后端或真机验收。

重复执行需要先确认模型费用和配置，选择新的 run，且不能在所有者真机上运行此探针：

```sh
dart run tool/run_planning_gateway.dart config/planning-gateway.local.json
flutter test integration_test/planning_gate_test.dart -d SIMULATOR_ID --no-uninstall --dart-define-from-file=config/planning-client.local.json --dart-define=PLANNING_GATE_LIVE=true --dart-define=PLANNING_GATE_PHASE=write --dart-define=PLANNING_GATE_RUN=NEW_RUN --dart-define=PLANNING_GATE_BUDGET=30
flutter test integration_test/planning_gate_test.dart -d SIMULATOR_ID --no-uninstall --dart-define-from-file=config/planning-client.local.json --dart-define=PLANNING_GATE_LIVE=true --dart-define=PLANNING_GATE_PHASE=read --dart-define=PLANNING_GATE_RUN=NEW_RUN --dart-define=PLANNING_GATE_BUDGET=30
```

未设置 `PLANNING_GATE_LIVE=true` 时仍只运行测试替身；live 未配置时失败，不回退替身。
网关测试后停止，本机 `max_calls` 恢复为 0。原始请求/响应和凭据不写日志或 Git，
网关不报告实际账单扣费或精确 token 用量，因此不宣称免费或给出推测费用。
随后重建正常 `lib/main.dart` 模拟器 Debug、原位安装并启动成功；实际查看首页仍为空，
规划页为未连接状态，确认测试记录未混入正常访客页面。未动所有者真实 iPhone。

## 工作量

本轮作为限界实验实施，先完成本地流程和协议验证，再依据真实模型与设备结果估算
正式部署。工作分支创建时间 20:05（北京时间），本地验证与模拟器界面核对在 20:32
完成，约 27 分钟墙钟时间，不等于人工工时；不含此前讨论、后续文档整理和 CI 等待。
不沿用旧周工时假设承诺新功能上线日期。

获准后的真实联调：从 21:14 修改探针到 21:22 恢复正常入口，约 8 分钟墙钟时间，
包含三个模拟器测试进程和正常构建恢复，不含前置准备、之后的回归测试与 CI 等待。

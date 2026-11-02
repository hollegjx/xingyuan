# C45/C46 回顾、分钟输入与 AI 设置

日期：2026-10-31。基线：`29bcf1586ca9f7f00521fa995da7cb117e98e894`。
本候选由 Claude 点名的两份 UI 补丁组成，AI2 负责契约测试和离线 D7。
不继承旧候选或 Claude Linux 的通过结果；独立复核、原生及完整视觉另列。

## 范围与来源

- C45 `.ai-bus/patches/C45-C46-review-accent.patch`，SHA256
  `b6885ec970ad9dfc3c712a711fdefa590d05c74f3b8ee718fb184b31762872d8`。
  五产品文件，17 行新增、11 行删除，全文审查后 `git apply -3` 干净应用。
- C46 `.ai-bus/patches/C46-ai-settings.patch`，SHA256
  `841bf955b32cef12763b496512883e279b9fdf80811bec74810b48adaa3067e6`。
  只改 AI 设置页，109 行新增、105 行删除，同样全文审查、干净应用。
- 六产品文件没有补丁之外的逻辑/视觉修改。四测试文件覆盖新契约，未降低几何、
  44px、键盘可见性、权限或保存断言。未改协议、domain/store/runner、后端或数据库。

对应 M1 个人目标表单与历史、J01/J02 私人记录入口、Agent A2/A3 的 AG03/04/10。
这些是既有场景的显示和设置可理解性改进，不增加平台、共享、服务成本或里程碑。

## 已实现行为

1. 分钟输入区在 `textScaler.scale(16) > 26` 时分行。线性缩放 1.625 为原单行，
   1.65、2、3 为整行输入加下排三按钮。C45 明确覆盖 C44 的“2x 及以下保持”要求；
   表单仍完整缩放，编辑头部沿用 C43 的最大 1.6x，不改变输入/清除/步进逻辑。
2. 随手记公共强调色、我的目标管理图标使用主题主色，入口和导航不变。
3. `GoalTile.dayShown` 默认 false，仅回顾日列表显式传 true。单次计划日与所看日相同
   才省略日期，保留时间/时长；无时间时回顾为“单次”、今天为“今天”。逾期、习惯、
   默认非日列表上下文保留日期规则。此参数不启用完成/撤销，也不修改历史数据。
4. AI 设置页标题为“AI 设置”，分组顺序为发送范围、规划、记忆、服务状态、设备凭证。
   发送范围首组上距 12，新增两条 Claude 提供的说明。开关、授权、凭证、身份隔离、
   错误与 busy 处理保持；进入/返回不自动检查连接或发送规划。

## C46 文案核对

`assistant_conversation_runner.dart` 在 Agent 关闭时跳过 Agent runner，构造请求后
只执行一次 `service.turn` 规划生成；不会先执行 `find_free_slots` 等 Agent 工具。
已授权的已有安排仍可由 `assistant_request_builder.dart` 随旧版请求提供，不能理解为
旧版完全不考虑日程。长会话还可能先执行摘要请求，所以“一次生成”不等于只有一次
网络或模型调用。更精确的可选说法是：“关闭后改用旧版直接生成规划，不会先调用空档
查询工具；长会话可能先生成摘要。”本轮按 C46 原文交付，未擅改文案。
`agent_ui_test.dart` 的既有开关回归验证关闭后 1 个 fake 旧版请求、0 个 Agent 请求。

## 回归与首红

新选集含 29 项：分钟 16、既有历史 3、新回顾/强调色 6、新设置 4。
相对旧 App 新增 14 项：分钟矩阵多 4，另两个测试文件共 10；不会重复加总专项/全量。

- 原产品、新测试：14 过 15 失败，exit 1。四项 1.65/2x 宽度为 130 而非至少 250；
  一项既有历史与四项回顾日期标签不符；两项强调色仍旧色；四项设置顺序仍旧顺序。
  没有加载失败，原日志与四份红源保留。
- 两补丁应用后，同测试字节 29/29，exit 0，成功标志完整。
- 显式 STHeiti 中文：分钟 16、新回顾/强调色 6、新设置 4、既有编辑器 3，共 29/29。
  该选集与前一个 29 项不同，不能相加称 58 个独立用例。
- 只读定位中不存在的猜测路径导致 `rg`/`tail` 非零，以及可选图像工具未找到，
  均为本机探索结果，不是测试或产品失败。未运行未知脚本、未下载工具。

日志：`/tmp/xingyuan-ai2-c45-selected-{original-red,patched,chinese}-20261031.log`。
SHA256 依次为：

```text
60f01d9a9430461fa823f88696be8945bb4aa7f7181de6c6ca62e01d7b25bcfa
152dcfa3365d0e529b93745dcc8cf7b4257991fdacebce56a7157040dd41f4ec
c08d552d6531436177476218db45d32e3d9be68a6eec76f9e23288124aabc6c6
```

## 图像与边界

`/tmp/xingyuan-ai2-c45-chinese-20261031/` 的 35 张新 320x568 合成组件 PNG 已逐张审阅：
12 张浅深分钟断点、4 张回顾、2 张我的、8 张设置说明和9张编辑器/草稿/回执。
2x/3x 的数字及分钟后缀完整可读，原几何检查通过；1.625 保留较紧凑单行。
大字号回顾和设置说明须滚动；取景时前一标题/其他条目可能在画面外。规划草稿和回执
仍非全内容同屏。模拟键盘 inset 不是真实 iOS 键盘，没有 native/OS 最大字号、
VoiceOver、完整 UI、Claude 最终视觉或 owner 验收。本轮没有修改生产字体。

## D7 与交付

本机串行 D7 于北京时间 2026-10-31 13:18:12 完成，10 个最终 gate 全部 exit0，
测试均有成功标志，源哈希前后相同：

| 检查 | 结果 |
| --- | --- |
| 相关 App 专项 | 1146 通过 |
| App 全量 | 1898 通过 |
| server / core / eval 全量 | 462 / 128 / 186 通过 |
| App / server / core / eval 分析 | 四套均 No issues found |
| 全源格式 | 552 files, 0 changed |
| 保护 | 39 保护文件、61 本轮基准无关文件哈希保持 |

本轮 harness 共13个 gate：原产品新契约1个 exit1，补丁后选集/中文/最终矩阵12个
exit0；无未完成进程，不追认原失败。相关专项和新增14例包含在App全量中，不叠加。
从本轮12:53接收任务到13:18完成D7约25分钟，矩阵约17分钟；仅作者本轮实耗，
独立复核与后续设备工作另计，不据此承诺里程碑日期。

源、报告、命令日志、35张图及原红测试保存在新目录
`.ai-bus/review/AI-2/C45-C46-20261031/`，清单为
`/tmp/xingyuan-ai2-c45-manifest-20261031.json`。这是提交前finalD7=true、delivered=false
快照，交付由独立index/HEAD/remote绑定证明，不覆盖清单或重跑已完成验证。

上述选集测试及下列 D7 命令通过 localhost-only `sandbox-exec`，SDK 为 `/path/to/development/flutter/bin`。
新 harness `/tmp/xingyuan-ai2-c45-verify-20261031.mjs` 的 `matrix final` 顺序为相关专项、
App、server、core、eval、四分析、全部源格式检查。实际 argv/cwd/UTC/exit/日志和源哈希
逐项写入 `/tmp/xingyuan-ai2-c45-commands-20261031.jsonl`；测试必须 exit0 且含
`All tests passed!`，各套件不并发。来源与 index/HEAD/remote 绑定另在 A2-105 交付记录。

```sh
flutter test --no-pub --concurrency=1 --reporter expanded
# 分别在 server、packages/xingyuan_core、tool/assistant_eval：
dart test --concurrency=1 --reporter expanded
flutter analyze --no-pub
# 同三个 Dart 包：
dart analyze
dart format --output=none --set-exit-if-changed <全部明确 Dart 源路径>
```

当前 552 源 canonical SHA256：
`bd92e9450c9b1aa395da97b0550e72b91ee60c7d265e575f963f7fd83e110a94`。
共享 wire SHA256 仍为 `b0bac8718d7be59da0a425a75ce98057c5afb46e2d65820eafae3420cad4875f`。
39 保护文件和本轮基准中的 61 无关文件已保持，不包含为本次授权修改的产品路径。

## 未验与权限

旧 29bcf158 已获 A1-178/QA5bb4f011 独立离线通过，QA 未合；这不等于本候选通过。
A1-179/180 的 B 安装/严格比较/恢复仅为 AI1 来源，数据结论止于 04:20:46.985 北京，
进程观察止于 04:21:44.918，非当前状态或同提交 12 小时证据。本候选未安装/部署。
新精确候选另待 AI1 独立复核。完整 UI/native/AG/J13/语义/owner 与 Agent 日备缺口保持。
AI2 无设备、服务器、SSH、构建签名安装部署、真实配置/Keychain/私人内容或 live 调用；
A0/A4 三轮119尝试已闭。无新增 owner 动作，不催数据线/解锁/账单。
全部旧终态 CI 停查；新交付 CI 如账单未启动须单独如实记录，不能视为通过或代码失败。

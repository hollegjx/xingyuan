# C22: 日记工具栏与八项旧回归修复

2026-10-28，北京时间。基线 `de5125e3077bdeb7d70c74ab81b6cb44db183200`；
产品和测试提交 `967bc2f92eee52c136084f9b34b47331999646b7`。
来源为 Claude C22，优先于 C21/A2。只在本机合成环境验证，未部署、安装或操作设备。

## 修复范围

- 文字缩放超过 1.6，或按实际字体测量完整标签放不进工具栏时，AI 动作使用图标胶囊。
  普通宽度保留完整单行文字；背景、胶囊形状、44px 以上命中范围、Tooltip 和语义标签保持。
  动作固定在工具栏，不再随正文滚出屏幕。未授权/未连接/非今天仍按 C14 解释，不发请求。
- 工具栏仍在可用高度小于 160 时隐藏并恢复。若连紧凑图标与原字号照片计数也放不下，
  只把计数移到正文下的照片区域，不缩字或丢计数，避免两行工具栏挤掉正文的完整一行。
- 字号变化后继续在布局完成时显式显示光标；不改焦点、选区、composing 或草稿。
  原来只在 AI 动作搬进/移出正文时触发的处理改为响应实际字号变化。
- 照片产品代码没有改动。四个照片失败来自测试调用 `waitForPhotoAction` 时漏传
  `photos: count`，默认 0 会在 `Image.frameBuilder` 尚未得到首帧时提前退出真实异步解码等待，
  再进入 FakeAsync 的 `pumpAndSettle`，加载动画无法结束。仅补正确的期望数量后，
  四例在原产品代码上全部通过；没延长超时、删图片断言或改加载动画。
- 旧 UI 测试在按钮失败之后还有一个未到达的测量问题：`journal-text` 最近的
  LayoutBuilder 已是纸面无限高约束，而不是实行 160px 规则的页面 body。改为从
  `journal-editor-scroll` 定位 body，原小于/大于等于 160、隐藏/恢复、命中和保存断言不变。
- 与 C22 冲突的旧“具名按钮在滚动内容里”期待迁移为“固定工具栏、紧凑图标、完整语义与
  Tooltip”。保留正文行数、输入组合态、焦点、表数据、授权与显式保存保护。

只改一个产品文件 `journal_editor_page.dart`。数据库、照片读写、AI 请求、后端、
核心包、入口气泡、1000/5000 可见字符限制、明确确认和撤销实现没有改动。
A2 未完成改动独立保留，未混入本候选；本结果不是 A2/A3/A4 验收。

## 测试与原始失败

所有 Flutter 命令在 `/path/to/Desktop/git/idea`，使用
`/path/to/development/flutter/bin/flutter`，网络只允许 localhost：

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)(allow network* (local ip "localhost:*") (remote ip "localhost:*"))' \
  /path/to/development/flutter/bin/flutter test --no-pub --reporter expanded
```

各日志均为 `/tmp/xingyuan-ai2-c22-<名称>-20261028.log`，管线启用 `set -o pipefail`。

| 名称 | 命令补充/范围 | 结果 |
| --- | --- | --- |
| baseline-red | journal_ui + journal_writing_space，name `diary at 320px 3.5\|inherited safe areas\|R6 writing.*320` | 原八项 0 过/8 失败，exit1 |
| photo-fixture | journal_writing_space，name `R6 writing.*320`；仅修 photos 参数，产品未改 | 4/4，exit0 |
| toolbar-red | 新 journal_ai_compact_toolbar_test | 0 过/20 失败，exit1；缺 Tooltip/固定工具栏等 |
| focused-first | ui/writing-space/compact 三文件 | 漏改旧 scrollAi 引用导致编译失败，exit1，未计为测试通过 |
| focused-second | 同三文件 | 46 过/10 失败，exit1；计数撑高工具栏、旧标签期待和 body locator 问题 |
| focused-third | 以下六文件，默认字体 | 100 过/2 失败，exit1；字号变化时光标被遮，后修复 |
| focused-chinese | 以下六文件，加中文字体/截图参数 | 102/102，exit0，24 秒 |
| app-full | 根目录完整 flutter test，默认字体 | 1549/1549，exit0，3 分 04 秒，包含原八项和新20项 |
| analyze | flutter analyze --no-pub | clean，exit0，8.8 秒 |
| format | dart format --output=none --set-exit-if-changed lib test integration_test tool | 385 文件/0 变化，exit0 |

六文件：`test/journal_ui_test.dart`、`test/journal_writing_space_test.dart`、
`test/journal_ai_compact_toolbar_test.dart`、`test/journal_ai_ui_test.dart`、
`test/journal_writing_breakpoint_delta_test.dart`、`test/journal_limit_feedback_breakpoint_test.dart`。
中文附加参数：

```sh
'--dart-define=DIARY_CAPTURE_FONT=/System/Library/Fonts/STHeiti Light.ttc' \
--dart-define=DIARY_CAPTURE_DIR=/tmp/xingyuan-ai2-c22-chinese-20261028
```

新20例覆盖两记录/浅深色、600px 的 1.6/1.61 临界、240px 的宽度回退、320px 的3.5/4倍；
验证命中、胶囊、原字号、完整语义和 Tooltip，实际点击未授权解释/取消，零请求和草稿保持。
原测试仍验证取消选图、解码后逐张增加到3张、上限禁用、一次明确保存和 revision1。
全量包含其余隐私、撤销、身份切换、键盘、持久化回归；不是额外1549+102个不同用例。
服务端/核心/eval/DST/生成本轮未重复运行：相关源码及依赖与基线完全相同，未声称新验。

## 视觉与证据

目录 `/tmp/xingyuan-ai2-c22-chinese-20261028` 共54张PNG、18份JSON。
亲看12张：两记录/浅深色的 `390-1x-*-action` 四张、`320-4x-*-k200` 四张，
`r6-delta-{diary,quickNote}-from-tools-step1` 两张和 `r12-boundary-1.5/1.6` 两张。
完整标签/紧凑胶囊可见、正文不与工具栏重叠；其余42张仅生成并留给独立/视觉审查，不冒称全部看过。
键盘空白是注入 inset，不是原生键盘；照片来自内存合成夹具，不是图库或真实文件验证。
组件 semantics 不替代真实 VoiceOver、iOS 大字查看器、系统最大字号或所有者体验。

日志及全部PNG/JSON散列清单：`/tmp/xingyuan-ai2-c22-checksums-20261028.sha256`，
SHA256 `021a67aa7d3db8a710226cf9680bb0f639132de85b62d45b43d1cf7e4500dcfe`。
产品源码 SHA256 `96e08432ece606ada96caa9531e05a469d07158986d3bd5733677df8b0af0431`；
新测试 SHA256 `be442ea979677fa974f43ff93026407bdee0f2b6a851668247917341e5c30aff`。
中文测试后仅补回同义 if 大括号，最终源码另经全量/分析/格式验证。

独立复验和 Claude 视觉验收待。精确最终提交与新CI状态放在自己的 A2-89/status；
旧终态CI不重查。按 D7，账单未启动不算通过或产品阻塞，不付款、不改 workflow。
A0固定29/30，无真实配置/密钥读取或模型调用；未动他人的review/总线/报告和同步材料。

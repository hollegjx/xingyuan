# G2 通知验证记录

范围依据：[GOAL.md](../GOAL.md) 第 7 章。执行者证据尚不足以证明完整 G2 通过。
2026-10-10 所有者报告剩余真机项完成并撤销 A18，M1 按调整后的标准收口；
未取得补充原始证据的部分仍明确保留证据缺口，见 `m1-delivery.md` E024。
以下内容是实际探针的历史证据，不将所有者收口决定改记为探针通过。
本记录描述实现、探针和证据，不自行授权修改提醒规则。
2026-10-10 的产品取舍已按所有者委托写入 Goal 第 7 章；
正式调度已实现，E023 已补真机短期送达、改时与取消/恢复；
完整真机矩阵与长期行为未取得补充可核实证据；不要求重做已撤销的 A18。

## 2026-10-09 原生重复触发器探针

环境：Xcode 26.6，iOS 26.5 Simulator，iPhone 17 Pro 的 XCTest 测试实例。
代码：`ios/RunnerTests/RunnerTests.swift`，见本工作包提交。
执行时间：18:18 至 18:19，Asia/Shanghai；证据来源：AI 实际运行。

根据已解析的 flutter_local_notifications 22.3.1 原生实现：

- `buildUserNotificationCalendarTrigger` 的每天重复分支只保留时、分、秒与时区。
- 每周重复分支再保留星期，但同样不保留原始年月日。
- 非重复分支保留具体年月日。

原生 XCTest 使用相同的 component 选择方式，直接询问 iOS
`UNCalendarNotificationTrigger.nextTriggerDate()`，没有请求授权、安排通知或改系统时间。
以距当前约两分钟的本地时刻为参照，3 项均通过，无跳过：

| 输入 | 系统实际下一次触发日期 | 结论 |
| --- | --- | --- |
| 明天的时刻，每天重复 | 今天 | 明天不是重复计划的首次开始边界 |
| 下周同星期的时刻，每周重复 | 今天 | 下周不是重复计划的首次开始边界 |
| 明天的完整年月日时刻，非重复 | 明天 | 单次计划保留指定日期 |

因此，完成今天后直接重建一个“从明天/下周开始”的重复请求，不能据此保证跳过今天。
这只排除了这个简单方案，尚未证明所有替代方案不可行。
取消重复请求会影响其整个重复计划，不能作为“只取消本次、未来保留”的完整实现。

复现前先执行 `flutter build ios --simulator --debug`，以更新 Flutter 原生配置，
再运行以下命令。设备 ID 由当前 `flutter devices` 获取：

```sh
xcodebuild test -quiet \
  -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=iOS Simulator,id=<实际模拟器ID>' \
  -parallel-testing-enabled NO \
  -only-testing:RunnerTests/RunnerTests \
  -skip-testing:RunnerTests/RunnerTests/testAuthorizedDeliveryAcrossProcesses \
  -resultBundlePath build/g2-trigger-probe.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

重复执行须选择尚不存在的 resultBundlePath，不覆盖旧证据。
首次结果包位于被忽略的 `build/g2-trigger-probe.xcresult`，退出码 0。
探针在本地午夜前最后两分钟会明确跳过，不能将跳过计为通过。
结果包含本机环境元数据，不提交 Git。

## 2026-10-09 队列探针与授权前置条件

新增以下原生探针，不请求授权、不更改系统时间、不调用全量取消：

- 只读记录实际授权、提示设置和 pending 数量，将观察值写入 XCTest activity。
- 已授权且队列为空时，用合成的远期单次请求验证同 ID 替换、
  定向取消一个 ID 后另一个未来请求仍在。
- 同样在已授权且空队列条件下，分别观察添加 63、64、65 条后的保留集合。
  这项测试记录实际容量行为，不预先断言“必然 64”。
- 请求均在至少 30 天后，只使用本次探针生成的标识；清理同样仅限这些标识，
  并检查无探针残留。已有 pending 请求时明确跳过，不为测试腾空用户队列。

20:24:58（Asia/Shanghai）在既有 iPhone 17 Pro / iOS 26.5 Simulator 重跑，
使用 `-parallel-testing-enabled NO`，不依赖另一份克隆模拟器的授权状态。
结果包为 `build/g2-prerequisites-20261009-r3.xcresult`，退出 0：

- 原有 3 项触发器测试与只读前置条件测试通过，共 4 项。
- 观察值为 `authorization=0`（尚未决定）、`alerts=0`、`pending=0`。
- 两项授权后队列测试因缺授权明确跳过，未添加任何通知请求。
  **容量、同 ID 替换及定向取消没有在本轮得到执行证据，不能算通过。**
- XCTest 顶层显示 Passed 不代表所有 G2 项通过；检查 summary 的
  `passedTests=4` 与 `skippedTests=2`，并读取具体测试和 activity。

此前首次编译因把 `nextTriggerDate()` 用在通用触发器类型上失败，退出 65；
已改为检查并转换为日历触发器后重跑。中间一次 r2 在克隆宿主得到相同
4 通过 / 2 跳过；上述 r3 才是最终代码在指定测试模拟器的证据。
原始结果与日志均在被忽略的 build 目录，未上传设备标识或整份结果包。

当时继续执行需要所有者批准测试 App 请求通知权限，并确认系统授权弹窗。
该条件现已按下节解除；不替代真机签名、实际送达、多日观察或产品取舍决定。

## 2026-10-09 已授权模拟器队列实测

所有者明确同意 AI 自行处理本项目模拟器的通知授权。AI 在正常 App 设置页点击
“允许通知”，再点击系统“Habit Checkin 想给你发送通知”弹窗的“允许”；
页面随后显示“系统已允许通知”。这不是对其他权限、真机签名或产品限制的批准。

代码为 `03437f0`，未修改原生探针或正式 App。先构建正常 `lib/main.dart` 入口，
再按上方命令禁用并行克隆，在原 iPhone 17 Pro / iOS 26.5 Simulator 执行。
结果包为 `build/g2-authorized-20261009-2255.xcresult`；
22:57:20（Asia/Shanghai）结束，退出 0，6 项通过、0 失败、0 跳过。

| 操作 | 本轮实际观察 |
| --- | --- |
| 加入 63 条 | pending 63，保留索引 0 至 62 |
| 加入 64 条 | pending 64，保留索引 0 至 63 |
| 加入第 65 条 | 添加回调未报错，但 pending 64，保留索引 1 至 64，索引 0 被移除 |
| 同 ID 替换 | 两条请求仍为两个 ID；被替换请求采用新的触发日期 |
| 定向取消其中一个 ID | 另一个未来请求仍在队列 |
| 自有请求清理后只读复核 | authorization=2、alerts=2、pending=0 |

容量探针按触发日期从近到远加入请求，因此本轮被移除的也是最早计划的那条。
这仅证明此模拟器、此添加顺序的一次观察，不能扩展为所有 iOS 版本、添加顺序、
重复通知或真机均采用相同淘汰规则。添加接口成功不等于请求完整保留。
测试只清理自己的合成 ID，不调用全量取消；所有请求至少在 30 天后，未验证实际送达。
保留一个 pending 请求也不证明下一个有效日期的提醒实际到达。

可用 `xcresulttool get test-results summary` 检查通过/跳过计数，
用 `get test-results activities --test-id <实际测试标识>` 读取上述观察。
本次已执行容量、同 ID 替换和定向取消探针；G2 仍未通过，不能据此批准有限覆盖。
原始结果包含本机元数据，留在被忽略的 build 目录，不上传 Git。

## 分进程短期送达探针

`testAuthorizedDeliveryAcrossProcesses` 是单独显式执行的模拟器探针，
不由常规队列命令自动安排近期通知。未指定 phase 时明确跳过，不能把跳过计为送达通过。
它使用既有系统授权，不弹权限请求；要求起始 pending 与 delivered 队列均为空，
有既有通知时保留并停止，不全量清除队列。

计划写入 App 支持目录下独立的 `habit-checkin-g2-delivery/<run>.json`，
不接触业务数据库。run 只接受 1 至 80 位字母、数字或连字符，拒绝覆盖已有证据。

- `arm`：安排 control、cancelled、replacement、future 四个独立 ID；
  将 replacement 与 future 改到更晚的时刻，取消 cancelled。
  最终 control 为 +90 秒、replacement 为 +120 秒、future 为 +150 秒。
  成功只说明安排正确，不表示通知已送达。
- `verify`：在另一个 App 进程读取已有计划及系统 `UNNotification.date`，
  不重新安排通知。至少经过 165 秒且不超过 15 分钟才接受验证；
  要求三个应送达 ID 均存在、已取消 ID 不在送达集合、无本轮 pending，
  并核对系统送达时间不早于各自最终计划。实际观察先保存再断言。
  结束时只清理本轮四个 ID 的 pending 与 delivered，保留 JSON 证据。
- `cleanup`：用于中断后的定向清理，不算通过；只删除本轮 ID 的系统请求/送达项，
  不删除证据、不操作其他通知。过早 read 不会清理仍待观察的计划。

先恢复正常 `lib/main.dart` 构建，选择已授权的测试模拟器，并替换以下变量：

```sh
SIMULATOR_ID=replace-with-the-test-simulator-id
DELIVERY_RUN=replace-with-a-fresh-run-token
TEST_RUNNER_G2_DELIVERY_PHASE=arm TEST_RUNNER_G2_DELIVERY_RUN="$DELIVERY_RUN" \
xcodebuild test -quiet \
  -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -only-testing:RunnerTests/RunnerTests/testAuthorizedDeliveryAcrossProcesses \
  -resultBundlePath "build/g2-delivery-$DELIVERY_RUN-arm.xcresult" \
  CODE_SIGNING_ALLOWED=NO
```

检查 arm 的 result summary 必须为 1 通过、0 跳过，并从 activities 读取实际 armed epoch。
在首个 +90 秒时刻前确认 App 进程已终止；`simctl terminate` 返回
`found nothing to terminate` 表示测试宿主已退出，不表示需要重装或清库。
等待期间不重开 App、不点/清通知、不修改系统时间。arm 命令成功返回后再真实等待
165 秒，可满足最早 read 时间；不要将前台等待等同于 App 已退出的证据。

```sh
xcrun simctl terminate "$SIMULATOR_ID" dev.hollegjx.habitCheckin
sleep 165
TEST_RUNNER_G2_DELIVERY_PHASE=verify TEST_RUNNER_G2_DELIVERY_RUN="$DELIVERY_RUN" \
xcodebuild test-without-building -quiet \
  -workspace ios/Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO \
  -only-testing:RunnerTests/RunnerTests/testAuthorizedDeliveryAcrossProcesses \
  -resultBundlePath "build/g2-delivery-$DELIVERY_RUN-verify.xcresult" \
  CODE_SIGNING_ALLOWED=NO
```

`TEST_RUNNER_` 前缀的转发方式依据本机 Xcode 的 `man xcodebuild`。
中断后用同一 verify 命令改为 `TEST_RUNNER_G2_DELIVERY_PHASE=cleanup`，
并选择新的 resultBundlePath，保留同一 run。重新 arm 必须换新 run，不能修补旧证据。
测试后恢复正常构建和入口，不卸载有数据的 App。

这只检查短期单次原生通知、修改/取消与进程重启后的系统送达记录。
同 ID 已送达通知可能只保留最近一条，晚期快照不能独自排除所有早期瞬时通知；
取消后的本轮无送达记录也不能代替所有原时刻的手工观察。
它不验证正式 Flutter 调度、通知点击、断网、下一有效日、多日不打开、时区切换、
真机或 72 小时观察，不能单独支持 A10/A11/G2 完整通过。

### 2026-10-09 实际结果

基于 `7dc8384` 新增上述探针，未改正式 App。首轮 `20261009-delivery-r1`
两阶段通过；收尾补严格 run 校验及边界测试后，用 `20261009-delivery-r2`
重新执行最终代码。环境仍为 iPhone 17 Pro / iOS 26.5 Simulator、Xcode 26.6。

- r2 arm 于 23:17:16（Asia/Shanghai）通过，1 项、0 跳过，
  armed epoch 为 `1791559036`。首个触发时刻前用 `simctl terminate` 确认宿主已无进程。
- 没有重新启动 App、点击/清理通知或修改系统时间，实际等待到 read 窗口后才启动 verify。
- r2 verify 于 23:20:33 通过，1 项、0 跳过；系统记录的 control、replacement、
  future 送达时刻分别为 23:18:46、23:19:16、23:19:46，与最终计划一致。
  cancelled 不在送达集合，本轮无剩余 pending；teardown 定向清理后无本轮送达项。
- 最终原生回归于 23:22:35 通过，7 项、0 跳过，包含 6 个原有探针与新增 run 边界测试。
  分进程送达测试另行运行，不把它的 arm 阶段或默认跳过算作完整送达通过。
- 结果包分别为 `build/g2-delivery-arm-20261009-r2.xcresult`、
  `build/g2-delivery-verify-20261009-r2.xcresult` 和
  `build/g2-native-final-20261009.xcresult`，全部留本地，不上传原始元数据。

本轮依据系统送达集合与时间戳，没有把未捕捉到的瞬时横幅写成手工逐时刻观察通过。
短期的“future”是另一个几分钟内的合成请求，不是重复目标下一个有效日的验收。
截至该次探针结束，尚未批准有限覆盖；后续决定与实现见下文 2026-10-10 记录。

## 日期规则

`lib/features/reminders/domain/reminder_time.dart` 使用 timezone 的 IANA 数据，
将候选 UTC 时刻转换回本地日期验证，不依赖构造器对不存在时间的默认归一化：

- 不存在的本地分钟向后寻找同日第一个有效分钟。
- 重复出现的本地时间只取第一次；第一次已过，不取第二次补发。
- 整个日历日不存在时不跨日补发；已过时刻不补发。

对应测试包括整小时与半小时夏令时跳变、重复时间、整日跳过与已过时刻。
纯日期测试不能证明插件或设备按相同语义送达。

## 尚未完成

- 在真机授权条件下实测 pending 容量边界及超过边界时的真实结果。
- 正常 Release 页面的提醒操作与通知点击；E023 已通过 Debug 生产协调器的
  完成/撤销/修改/关闭/归档调度及实际等待，不再列为完全未测。
- 下一个有效日期确实提醒、多日不打开、后台、离线、冷启动、时区变化。
- 已选定具体日期的有限预排；真机容量、长期覆盖与时区限制仍待实测。

维护者文档列出的 iOS pending 上限为 64，本轮模拟器在加入第 65 条时也观察到只保留
64 条；E023 在目标 iPhone 已确认生产协调器保留 64 条，但没有原生添加第 65 条，
不能声称已测得真机超容量淘汰行为或其他调度方式。
若按发生日期排队，必须明确可证明的覆盖范围、补排机制和容量溢出的反馈，
取得所有者认可后才能改变原验收。不能把风险移入“已知问题”就标为通过。

## 补充核查与候选方案

2026-10-09 重新读取插件维护者说明和 Apple 官方文档，结论仍须区分文档与设备测量：

- 插件 22.3.1 文档继续列出 iOS 待调度请求 64 条的限制。
  这不是本项目在目标 iPhone 上测得的容量，也没有证明静默丢弃顺序。
- Apple 的 `BGTaskRequest.earliestBeginDate` 只限定最早开始时间，
  不保证在指定时刻启动。因此后台刷新不能作为“每天一定会补排”的正确性前提。
- `UNNotificationServiceExtension` 处理满足条件的远程通知，
  不能把它当成离线本地通知到达前必然唤醒 App、查数据库并跳过本次的接口。
- 系统授权与 `alertSetting` 是不同信息。已授权但关闭提示不等于授权被拒；
  当前 App 已分别表达这两种状态，未因此把未安排的提醒显示为已安排。

据此排除“保证后台每日补排”和“服务扩展拦截本地提醒”作为本阶段的兜底。
这不是对所有可能原生方案的穷尽证明；不能仅凭这些结论宣称 G2 通过。

| 候选方向 | 可以解决什么 | 仍须明确的限制或问题 | 当前决定 |
| --- | --- | --- | --- |
| 按具体发生日期排队 | 单独取消、撤销恢复、稳定 ID 与日期规则较容易核验 | 覆盖有限；需显示覆盖到哪一天、容量不足及重新打开后的补排；后台和时区行为待设备验证 | 2026-10-10 按委托选定并实现，完整 G2 待验 |
| 系统重复通知 | 可持续重复，减少队列占用 | 已有原生探针表明无法仅靠明天/下周起始值跳过今天；直接取消会影响未来 | 不满足现有取消规则，不能直接交付 |
| 后台刷新辅助补排 | 系统允许执行时可能延长覆盖 | 不保证执行时机，只能辅助，不能承诺无限覆盖 | 不作为通过依据 |

上述有限覆盖取舍已按 2026-10-10 所有者委托选定，不再等待同一决定。
不设目标数上限、固定覆盖天数或强制打开周期，不改变离线与隐私范围。

## 2026-10-10 正式调度实现

- 按实际日期单次安排，所有目标共享最多 64 个名额，先扣除非本调度器请求，
  再按下一触发时刻依次分配；不依赖 iOS 超容量时的静默淘汰顺序。
- schema v2 的发生日期记录保存稳定 ID、计划时刻、时区、调用意图与已结束状态。
  系统调用前记录意图，已送达或到时但结果不明的本次不重发。
- 完成只取消本次，撤销只恢复未到时的本次；规则变更保留当天原规则，
  修改提醒时间、关闭和归档核对并取消旧请求。调度与业务写入串行，
  复核 revision、pending ID 与载荷，不将接口返回成功等同于全部请求保留。
- 不全量清理系统队列，保留其他 namespace/owner 的请求。失败不会回滚打卡，
  保留待核对状态，详情、今天与设置显示错误并提供重试。
- 详情显示本目标已预排次数、下次、末次及下一未覆盖日期；
  设置明确提示长期不打开可能耗尽，以及关闭期间换时区的限制。
  启动、回前台、前台日期/时区刷新及目标变更时补排，不保证后台自动补排。
- 本地夏令时规则先解析为具体时刻，再以 UTC 单次日历请求发送给原生插件。
  通知使用通用文案；点击安全回到今天，不披露目标名、不替用户打卡。

自动回归包含容量与超过容量、外部请求保护、持久 ID、完成/撤销/改期/归档、
已过时刻不重发、系统静默丢失、取消失败、添加结果不明、快速修改、文件重开、
时区变化与补排、v1 到 v2 迁移、真实 UI 与通知点击入口。
107 项全量自动测试已通过；它们不代替真实设备送达。

正式调度的两进程探针为 `integration_test/reminder_delivery_gate_test.dart`，
使用隔离数据库与合成 owner，完整命令、时间窗口和中断清理见开发说明。
它实际使用生产仓储、调度器与 iOS 插件；不弹授权，不修改系统时钟，不全量清队列。
系统 delivered 集合不包含精确送达时间，因此只记录实际观察时刻，不伪称准点测量。
模拟器与实现证据见 E022；后续真机结果见 E023。

## 2026-10-10 真机短期送达

在 test iPhone / iOS 26.6.1 上使用已有通知授权，运行生产 Dart 调度器的
隔离 Debug 探针。三目标首轮两阶段通过；八目标扩展轮的 arm/checkpoint/verify
三阶段各 1 项通过，无跳过。每个实际等待区间均在触发前查询确认 App 已退出。

- 16:37 计划的每日、撤销恢复、指定星期、单次任务，在 16:38:22 观察到四条送达。
- 改到 16:39 的请求在中间检查仍为 pending，16:39:49 才在后续送达快照中出现。
  这是前后快照证据，不是精确系统送达时间或连续横幅录像。
- 完成、关闭和归档的当天提醒均未出现在两个快照中；完成目标的未来队列保留。
- 到时后撤销、送达后完成/撤销及改到当天更晚，没有重新排入当天队列。
- 清理后本轮 pending/delivered 均为空，保留测试账本，正常访客数据不参与测试。

步骤、首轮记录、进程退出时刻和恢复情况见 [E023](m1-delivery.md#e023-真机正式调度送达)。
本轮未关闭网络、拔线、改变权限/时区或观察下一有效日；没有测量逐秒延迟，
也没有用探针代替正常 Release 的提醒页面和通知点击。完整 G2 仍待这些验证。

## 依据

- [通知插件维护者文档](https://pub.dev/packages/flutter_local_notifications)，查询于 2026-10-09。
- [Apple 本地通知的安排与取消](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)。
- [Apple 后台任务最早开始时间](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate)。
- [Apple 通知服务扩展](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)。
- [Apple 通知授权状态](https://developer.apple.com/documentation/usernotifications/unnotificationsettings/authorizationstatus)
  与[提示设置](https://developer.apple.com/documentation/usernotifications/unnotificationsettings/alertsetting)。
- 主工程解析到的 22.3.1 包源码（以下路径相对该包根目录，而非项目根目录）：
  `ios/flutter_local_notifications/Sources/flutter_local_notifications/FlutterLocalNotificationsPlugin.m`，
  `buildUserNotificationCalendarTrigger` 方法。
- iOS SDK 的 `UserNotifications` API 与上述实际 XCTest 结果。

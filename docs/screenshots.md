# README 截图

这三张图来自实际应用组件，不是设计稿或生成式图片：

| 文件 | 页面 | 演示状态 |
| --- | --- | --- |
| `images/today.png` | 今天 | 两项目标完成，一项待办 |
| `images/diary.png` | 日记 | 手工输入的合成日记，本地草稿，AI 未开启 |
| `images/review.png` | 回顾 | 七天的合成完成记录与当天目标 |

入口为 `test/readme_screenshots_test.dart`，使用应用现有的 `UiHarness`：
内存 SQLite、固定时钟、虚构文字、内存照片存储和假的通知／相册接口。
没有读取私人记录、真实相册、设备凭据或原项目服务，没有调用模型。
日记由测试输入并通过真实保存流程写入临时内存库。

## 重现

常规 `flutter test test/readme_screenshots_test.dart` 只验证旅程，不写图片。
导出时另行指定本地中文字体和输出目录：

```sh
flutter test test/readme_screenshots_test.dart --no-pub \
  --dart-define=README_CAPTURE_DIR=docs/images \
  --dart-define=README_CAPTURE_FONT="$README_FONT"
```

`README_FONT` 是本机可用、允许渲染使用的中文字体文件路径。首次发布使用 macOS 的
Hiragino Sans GB；字体仅载入测试进程，仓库不分发该字体，也不改变正式主题。
请不要把自己的用户名或绝对主目录路径写入提交。

逻辑画布为 390 × 844，导出 PNG 为 780 × 1688，浅色模式、默认字号。
图片没有额外拼接的手机外壳、伪造状态栏或后期修改的 UI。系统键盘不在画面内。

## 证据边界

这是无头 Flutter widget 渲染，不是 iOS 模拟器或真机系统截屏。
它能展示当前页面和合成数据下的布局，不能证明系统通知、相册权限、键盘、
VoiceOver、原生插件或真实模型已经通过验收。不同系统字体的排版可能略有差异。

更新图片后逐张检查文字与图标，确认无溢出、黑屏、私人内容或图片元数据，
再检查 README 的相对链接。不要用实际用户截图替换这些演示图。

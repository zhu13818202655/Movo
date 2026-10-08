# 目前遇到的bug
## 计划
1. IOS 上手动创建后，点击后应该创建弹窗消失，出现新创建的，但是并没有一个及时反馈
   - 已修复（2026-10-07）：浮层呈现却用 `Router.pop()` 关闭，`paths` 为空时静默失效；改为 `@Environment(\.dismiss)`，并让 `PlansScreen` 订阅 `dataVersion` 即时刷新。同类关闭缺陷与遗留项记录在 `navigation.md`。
2. ios上
   - 已修复（2026-10-07）：iOS 与 macOS 都缺少 App 图标，主屏与 Dock 显示系统空白占位图。根因是 `Movo/Assets.xcassets/AppIcon.appiconset/` 只有 `Contents.json` 的槽位声明、目录下没有任何位图文件，仓库历史上也从未提交过品牌图形资源。已补齐全套位图：iOS 提供 1024 默认/深色/着色三种外观，macOS 按 Apple 模板提供 16–512 全尺寸（主体 824×824 超椭圆 + 投影 + 透明留白）。生成脚本与平台差异见 `Scripts/generate-app-icons.py` 与 `docs/Development.md` §3.7。

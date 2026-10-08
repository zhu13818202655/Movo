# 导航与刷新（浮层关闭语义、列表重查、入口补齐）

## 背景

修复「建立计划后弹窗不消失」时（见 `bug.md` 计划第 1 条）确认了以下既有缺陷，均已定位到具体代码位置：

- **关闭动作与呈现方式错配（已修，属遗留面较大的一类）。** `Router.pop()` 只改 `paths[section]`、`dismissSheet()` 只清 `sheet`；而 `.newPlan` / `.editPlan` 由 `PlansScreen`、`PlanDetailScreen` 走 `present()` 放进浮层。页面用 `pop()` 关闭时 `paths` 为空 → 静默 return：数据其实已写入（`CreatePlan` 在关闭动作之前执行），但浮层不动、列表也不刷新，用户无法判断是否创建成功；按钮重新可用后再点一次会建出第二份计划。同类缺陷还包括 `RecurrenceEditorScreen`（「取消」「设置重复」）、`LogMeasurementScreen`（从计划详情进入时）、以及设置区四个 ✕（`RecentlyDeletedScreen`、`ImportPlanScreen`、`ConflictResolutionScreen`、`ExportPreviewScreen`）——其中「最近删除」由设置页内的局部 `.sheet(isPresented:)` 呈现，`dismissSheet()` 关的不是它。
- **浮层内 `push` 会先关掉浮层。** `Router.push()` 第一行是 `sheet = nil`，NavigatorStack 只有每个入口一条 `paths`。于是「任务详情 → 设置/修改频率（浮层）→ 影响预览（`push`）」，真实流程是**先关掉频率编辑浮层**、再在待办/计划栈上打开预览页；「返回修改」`pop()` 回到的是列表而不是编辑页，草稿留在 `env.pendingRecurrence` 里但编辑页已关闭。同一规则也让「设置（浮层）→ 导入 Movo 文件（`push`）」「`SyncStatusBadge` → 同步冲突」顺手关掉设置页。
- **列表不跟随数据变化。** 约定已写在 `DomainStore.swift`（视图用 `.task(id: store.dataVersion)` 触发重查）。今日、计划详情、任务详情、整理记录已订阅；`MetricHistoryScreen`、`ReviewScreen`（只订阅 `weekStart`）、`SearchScreen`（只订阅 `scope`）未订阅 → 写入后返回仍看到旧数据（例：在结果历史里记录一次测量，返回后趋势图与列表不变）。
- **`.bulkPreview` 路由没有入口。** `Route`、`ScreenHost`、`BulkPreviewScreen` 均已存在，但全仓库没有任何 `present` / `push` 调用，当前不可达。
- **成功反馈不一致。** 写入成功后 `env.lastBatchNotice` 只在 `TodayScreen` 渲染 `UndoBar`；在「计划」页建立或删除计划后没有任何「已保存 / 可撤销」提示，撤销入口在该页不可见。

## 期望

1. **关闭语义固化。** 页面级「关闭 / 取消 / 保存完成」统一用 `@Environment(\.dismiss)`（它既能关闭浮层、也能弹出导航栈，页面不必知道自己被如何呈现）；`Router.pop()` / `dismissSheet()` 只保留给 Router 主动切换的场景（采集流水线、跨入口跳转）。本次已在 `Router.swift` 注释中固化该规则，新增页面必须沿用，评审时检查是否出现新的错配。
2. **浮层内导航自成一层。** `Router` 增加浮层内的路径（如 `sheetPath: [Route]`），`SheetHost` 用 `NavigationStack(path:)` 承载：「影响预览」「导入 Movo 文件」「同步冲突」「导出预览」等从浮层进入的子页留在浮层内，返回即回到发起页（频率草稿与设置页状态不丢）。`push()` 需按「当前是否在浮层内」分流，不能再用「先清 `sheet`」实现。
3. **列表重查统一。** 常驻的列表与详情页一律订阅 `dataVersion`；只读快照类页面（`SnapshotScreen` 的 `asOf`）保持按参数重查，不订阅。改动后逐个页面确认是否存在「写入后返回看到旧数据」的路径。
4. **`.bulkPreview` 二选一。** 接入真实入口（删除计划 / 阶段、批量移动前的批量影响预览），或在未接入前删除路由与页面，不留死代码。
5. **反馈一致。** 从浮层写入成功的页面（至少「计划」页）提供与待办页一致的「已保存 + 可撤销」提示；撤销计数、冲突保护与步数沿用现有 `lastBatchNotice` 与默认 5 步设置，不新增第二套机制。
6. **回归口子。** SwiftUI 呈现行为当前无自动化覆盖（五个测试 target 只链接 `MovoKit`，`Router` 位于应用 target）。至少在验收清单固定三条路径——新建计划、编辑中删除计划、频率取消与影响预览；条件允许时新增 UI 测试 target 覆盖「保存后浮层关闭且列表刷新」。

## Todo list

- [x] 关闭动作改为 `@Environment(\.dismiss)`：`PlanEditScreen`、`RecurrenceEditorScreen`、`LogMeasurementScreen`、`RecentlyDeletedScreen`、`ImportPlanScreen`、`ConflictResolutionScreen`、`ExportPreviewScreen`。
- [x] 删除计划后同步收起下层计划详情页（`PlanEditScreen.deletePlan()` 按 `router.path(for:)` 判断）。
- [x] `PlansScreen` 订阅 `dataVersion`，建立计划后立即出现在列表（并移除冗余的 `onChange(of: showArchived)`）。
- [x] 在 `Router.swift` 注释固化关闭规则，说明 `pop()` / `dismissSheet()` 的适用边界。
- [ ] `Router` 增加浮层内路径，`SheetHost` 改用 `NavigationStack(path:)` 承载浮层内容。
- [ ] `push()` 分流：在浮层内 push 不关闭浮层；确认「频率 → 影响预览 → 返回修改」能回到编辑页并保留草稿。
- [ ] 检查并处理「设置 → 导入 Movo 文件 / 同步冲突 / 导出预览」当前会先关掉设置页的行为（按第 2 条统一）。
- [ ] `MetricHistoryScreen` 订阅 `dataVersion`（记录、更正、删除后刷新趋势与全部记录）。
- [ ] `ReviewScreen`、`SearchScreen` 订阅 `dataVersion`，或明确写出按参数重查的理由。
- [ ] `.bulkPreview`：接入入口或删除路由与 `BulkPreviewScreen`。
- [ ] 「计划」页提供与待办页一致的撤销提示（复用 `UndoBar` 与 `env.undoLastBatch()`）。
- [ ] 新增 UI 测试 target，或在 `docs/Development.md` 固定三条手写验收路径。
- [ ] 文档：`docs/Development.md` 补「导航与浮层」约定；浮层内导航若改变交互，同步 `docs/UI-Prompt.md` 与 `docs/design/Movo.pen`；行为口径变化同步 `docs/PRD.md`。
- [ ] 验证：`bash Scripts/verify.sh`（macOS 与 iOS 构建 + 五组单测）；浮层关闭与列表刷新需在双端手动验收，不能用单测代替。

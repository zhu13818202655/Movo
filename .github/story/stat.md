# 图表可视化

## 背景

- 起止时间（`startAt` / `endAt`）、重复步骤与任务文件导入导出、AI 整理与统一开关均已实现（见 `time.md`、`task-file.md`、`llm-create.md`），计划、阶段、任务已具备绘制时间线与基于时间分布的完整数据结构。
- 现有图表组件仅有 `MetricTrendChart`（Swift Charts），仅用于指标测量的数值走势。
- 计划进度展示单一：`PlanDetailScreen` 仅有单一胶囊进度条 `MovoProgressBar` 或纯文字 `snapshotText`；交付型缺少阶段分段展示，改善型未在头部整合核心指标微缩趋势，持续型仅展示文字描述。
- 周回顾 `ReviewScreen` 仅有纯文字与标签（事实、缺口、建议、观察），缺少每日行动分布（7 天柱图/热力）与分类精力投入分布条。
- 重复任务详情缺少实例执行状态（完成/跳过/未记录）的离散直观展示。
- 计划详情缺少基于 `startAt` / `endAt` 的时间线（甘特跨度）视图。

## 期望

1. **业务口径与去压力化原则。**
   - 图表严格为只读展示，数据全部来自 `Domain/Queries` 层视图，不在 UI 层重新计算或改变业务口径。
   - 缺失值不补零，分母为零不显示百分比。
   - 持续型计划严禁显示总体百分比进度或以 100% 为目标。
   - 行动记录、任务完成、结果测量独立呈现，不相互推导（例如记录了跑步不推导为已达成减重，完成了阶段任务不推导为长期目标达成）。
   - 杜绝连续打卡天数、连续达成周数等可能产生压力的设计（遵循 PRD 第 1.2 与 8.3 节）。
2. **计划详情页图表（`PlanDetailScreen`）。**
   - **交付型（Delivery）**：分段进度条（`MovoSegmentedProgressBar`），按各阶段叶子任务数占总叶子数的比例切分区间，填充已完成比例，未完成使用背景软色；保留阶段分割线，支持点击或悬停显示阶段名称与完成度（如「阶段二：初稿完成 · 3/5」）；阶段卡片增加迷你进度胶囊。
   - **改善型（Improvement）**：头部设双微卡，左侧展示当周期行动频次微进度（如「本周 3/4 次」），右侧内嵌首选指标微缩走势图（Sparkline），直接查看最新测量及对比变化。
   - **持续型（Maintenance）**：周期行动频次离散点阵或柱状展示，反映当前周期与近几个周期的发生次数，不展示总进度百分比。
3. **回顾图表（`ReviewScreen`）。**
   - **7 天行动分布柱状图（`MovoDayBarChart`）**：在周事实上方展示本周一至周日 7 天柱状分布（`BarMark`），柱高为每日实际记录数；无记录的日期留白并显示「0 条」辅助文字；无障碍朗读整周总数与最高峰。
   - **分类与计划投入堆叠条（`MovoCategoryDistributionBar`）**：按工作、学习、健康、生活四种分类（使用 `MovoCategoryColor`）展示当周行动记录的水平堆叠占比，标注各分类条数及占比。
   - **事实卡片走势微图**：事实列表中的 `metricChanges` 直接渲染内嵌微型趋势图，清晰标注缺测与修正点。
   - **空态与数据不足**：当周无任何记录时展示「本周无记录」空态卡片，不展示空白图表，不揣测原因。
4. **时间线跨度图（`MovoTimelineView`）。**
   - 计划详情的「行动」标签页支持 `[ 树状列表 | 时间线 ]` 双视图切换。
   - 横轴为时间刻度（日/周/月），带「今天」垂直基准线；纵轴自上而下展示计划、各阶段、各任务的时间跨度条。
   - 范围越界警示：子级时间超出父级时，时间条使用 `MovoColor.warning` 虚线或警示边框，保持与 `StructurePolicy` 校验规则一致。
   - 未排期抽屉：没有设置起止时间的任务统一折叠归入时间线下方的「未排期 (X 项)」抽屉，点击可展开并支持快捷排期。
   - 双端适配：Mac 支持横向拖拽与缩放；iPhone 提供紧凑型横滑或竖向时间轴。
5. **重复任务实例分布（`MovoOccurrenceStrip`）。**
   - 在 `RecurrenceScreens` 规则卡片下方展示最近 14 次或 30 天的实例离散点列。
   - 每个点由图标与状态色结合：已完成（`MovoColor.done` + check）、跳过（`MovoColor.inactive` + slash）、未记录（`MovoColor.muted` + circle），杜绝连续天数提示。
6. **设计系统通用组件（`DesignSystem/Components`）。**
   - 新增 `MovoSegmentedProgressBar`、`MovoDayBarChart`、`MovoCategoryDistributionBar`、`MovoTimelineView`、`MovoOccurrenceStrip`。
   - 双模自适应：颜色严格使用 `Tokens.swift` 中的 `MovoColor` 与 `MovoCategoryColor`。
   - 读屏与无障碍：每张图均配备 `.accessibilityElement(children: .combine)`，提供文字形式的数据摘要。

## Todo list

- [x] 查询层扩展（`Domain/Queries`）
  - [x] 计划详情查询：在 `PlanDetail` 中补充阶段分段进度数据（各阶段叶子完成数、总数、占比及状态）。
  - [x] 周回顾查询：在 `ReviewView` 中增加当周每日行动统计（`[DayActionStat]`：日期、数量）及分类占比数据（`[CategoryShareStat]`：分类、条数、比例）。
  - [x] 时间线视图查询：增加 `planTimeline(planID:)` 查询，输出带起止时间节点的结构条目（计划、阶段、任务）及未排期任务列表。
  - [x] 重复任务查询：在 `TaskDetail` 中增加近期实例执行状态序列（最近 N 次的完成/跳过/未记录）。
- [x] 通用可视化组件（`DesignSystem/Components`）
  - [x] `MovoSegmentedProgressBar`：交付型阶段分段进度条，支持悬停/点击阶段信息浮层与迷你尺寸变体。
  - [x] `MovoDayBarChart`：Swift Charts 绘制 7 天柱状分布图，处理 0 记录留白与基准轴线。
  - [x] `MovoCategoryDistributionBar`：分类精力占比水平堆叠条，使用 `MovoCategoryColor`。
  - [x] `MovoOccurrenceStrip`：重复任务实例离散状态序列点阵组件。
  - [x] `MovoTimelineView`：时间线甘特跨度图，含今日标线、越界警示边框与未排期任务折叠抽屉。
  - [x] 无障碍支持：为所有图表组件添加 VoiceOver 标签与文本摘要。
- [x] 计划详情页集成（`Movo/Features/Plans/PlanDetailScreen.swift`）
  - [x] 交付型计划接入 `MovoSegmentedProgressBar`，并在阶段卡片显示迷你进度。
  - [x] 改善型计划头部接入周期行动与首选指标微缩走势双卡。
  - [x] 持续型计划接入周期行动频次离散点阵。
  - [x] 「行动」标签页接入 `[ 列表 | 时间线 ]` 视图切换与 `MovoTimelineView`。
- [x] 回顾页集成（`Movo/Features/Review/ReviewScreen.swift`）
  - [x] 接入当周 7 天行动分布柱状图与无记录空态。
  - [x] 接入分类投入堆叠比例条。
  - [x] 在 `ReviewFact` 中将指标变化接入 `MetricTrendChart` 走势微图。
- [x] 重复任务详情集成（`Movo/Features/Plans/TaskDetailScreen.swift`）
  - [x] 在重复安排区域嵌入 `MovoOccurrenceStrip` 实例历史状态序列。
- [x] 异常与边界处理
  - [x] 分母为零、全部任务取消时的空态渲染。
  - [x] 超出父级时间范围的任务在时间线上显示警示样式。
  - [x] 全周无记录时显示标准空态，不渲染空白图表骨架。
- [x] 测试（`Tests/MovoDomainTests`）
  - [x] 口径验证：分母为零不显示百分比、持续型不计算总进度。
  - [x] 查询聚合：7 天行动分布边界（跨周、时区偏移）、分类占比求和 100%。
  - [x] 时间线投影：有起止、仅单端、无时间（未排期）的分类正确性。
- [x] 文档与设计
  - [x] 同步更新 `docs/PRD.md`（图表呈现规则与非压力口径）。
  - [x] 同步更新 `docs/UI-Prompt.md`（新增图表组件定义与画板规范）。
  - [x] 需 Pencil 工具时同步更新 `docs/design/Movo.pen`（已包含通用可视化组件、D02-Timeline 与 M11-Timeline 画板）。

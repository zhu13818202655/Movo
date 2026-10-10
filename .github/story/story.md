# 今日上下文的时间显示与专注计时

## 背景

- 「待办」页在「今日」筛选下，同一屏存在两条时间渲染路径：清单任务行走 `TaskOutline.metadata(_:parentTitle:)`（`Movo/Features/Shared/TaskOutline.swift`），它调用 `TimePoint.displayString`（`Movo/Domain/Models/ValueTypes.swift`），`.instant` 的输出固定为 `M月d日 HH:mm`；重复行动行由 `TaskRow(item:)`（`Movo/DesignSystem/Components/Rows.swift`）渲染，消费 `Movo/Domain/Queries/Views.swift` 里 `TodayItem` 的时刻文本，只输出 `HH:mm`。结果是同一屏里出现「开始 10月8日 14:00」与「14:00–14:30」两种口径。
- `TimePoint` 上不带参数的 `displayString` 不接收任何显示范围参数，无法表达「日期已知是今天、只需要时刻」这一层信息。
- `Task.estimateMinutes` 在领域层已完整可写：`CreateTask` 与 `TaskPatch`（`Movo/Domain/Commands/TaskCommands.swift`）都支持该字段，`TaskPatch.clearEstimate` 也已存在。但 `NewTaskSheet`、`InlineTaskEditor`、`TaskDetailScreen` 三个表单都没有它的编辑入口，`TaskDetailScreen` 只做只读展示，因此该字段目前只能由 AI 整理或文件导入产生。
- 记录投入与标记完成已经是两条独立命令：`LogActivity` 写 `ActionRecord.durationMinutes`，`CompleteTask` 写 `Task.doneAt`，分别在 `Movo/Domain/Commands/RecordCommands.swift` 与 `Movo/Domain/Commands/TaskCommands.swift`。`Movo/Domain/Support.swift` 提供可注入的 `MovoClock` 与 `TravelClock`；`Movo/Notifications/NotificationScheduler.swift` 提供 `NotificationScheduling` 协议与 `InMemoryNotificationScheduler` 替身。
- `LogActivity` 要求 `planID` 非空且对应计划必须存在，`ActionRecord.planId` 在 `Movo/Domain/Models/Entities.swift` 中为必填字段。`TaskDetailScreen` 的「记录一次行动」对未挂计划的待办直接抛错，因此独立待办目前无法记录投入。
- 应用内没有计时器状态、界面或相关运行参数。

## 期望

1. **今日上下文的时间显示。** 原则是：今日上下文只省略「今天」这个日期，不省略任何仍有信息量的日期。逾期项、明天的项、他日的项，日期照常显示。

   | 时间点 | 今日上下文 | 本周上下文 | 绝对上下文 |
   | --- | --- | --- | --- |
   | 某一天 = 今天 | `今天` | `今天` | `10月8日` |
   | 某一天 = 明天 | `明天` | `明天` | `10月9日` |
   | 某一天 = 其他日期 | `10月20日` | `10月20日` | `10月20日` |
   | 今天 14:00 | `14:00` | `今天 14:00` | `10月8日 14:00` |
   | 明天 09:30 | `明天 09:30` | `明天 09:30` | `10月9日 09:30` |
   | 昨天 17:00 | `10月7日 17:00` | `昨天 17:00` | `10月7日 17:00` |

   - 显示上下文分三档：今日筛选用今日上下文；同一周内的列表用本周上下文；其余用绝对上下文。绝对上下文为缺省。
   - `TaskOutline` 的上下文由调用方显式传入，不设缺省值：今日筛选传今日上下文，计划详情的执行树与任务详情的子任务列表传绝对上下文，每个调用点都要自己说清楚页面属于哪个时间上下文。同一棵树上的父节点与子节点使用同一上下文。
   - 两条渲染路径共用同一个上下文类型：`TaskOutline` 的元信息走 `TimePoint.displayString(in:)`，`TaskRow` 的行内时刻标签走 `TodayItem.timeText(in:)`。后者只显示有时刻的那一端，`startAt` 与 `endAt` 两端都只有日期时产不出标签，因此今日上下文下不会出现「今天」二字；`TaskRow` 的 footnote 已由 `TodayItem.displayStatus` 表达「今天安排 / 今天到期」，再加日期标签会重复。
   - `TaskOutline` 的元信息是「开始 / 截止」这类带语义的句子，`.day(今天)` 在那里保留「今天」的措辞（如「截止 今天」）——省略日期后它仍然说明了一件事，而只写时刻会让句子失去主语。
   - 今日上下文不使用「昨天」，逾期项直接写绝对日期；「今天 / 明天 / 昨天」这组措辞只在同一周内的列表里出现。做这个区分是因为逾期项要给用户的信息是「拖到了哪一天」，而「昨天」把这个信息量压成了「它不是今天」。
   - 某一时刻的钟点按其自带时区换算，沿用 `TimePoint.clockText` 的现有行为。

2. **专注计时。** 在 iOS 与 Mac 上，用户可以从一项待办开始一次计时：有终点时刻时倒计时，没有时从 0 正计时；到点提醒一次；结束与完成分开处理；也可以不启动计时，直接补记一次投入。

   - **入口与导航。** 三条进入路径互不替代，且都不改变现有的点击语义：

     | 路径 | 位置 | 行为 |
     | --- | --- | --- |
     | 点进任务后开始 | 任务详情页主按钮区 | 点击任务仍然进入详情；详情页提供「开始专注」，进入前显示推导出的时长；**开始成功就直接进计时页** |
     | 清单行直接开始 | 今日清单行的行尾操作 | 不进入详情即可开始，用于「现在就要做」的场景；**开始成功就直接进计时页** |
     | 直接补记投入 | 任务详情页「记录一次行动」 | 不启动计时，补记一次已经发生的时间 |

     三条路径最终落到同一组写入命令，不在界面另建规则。开始被拦下时（另一次正在计时）留在原地并说明原因——那一条会话没有变，跳过去只会让人以为切换成功了。
   - **页面归属。** 计时界面沿用现有路由与页面映射，通过 `Movo/App/Navigation/Route.swift` 与 `Movo/App/Navigation/ScreenHost.swift` 增加目的地，不新建平行的跳转机制。
   - **时长推导以结束时刻为锚点，不以时长为锚点。** 这样「起止都填」与「只填结束」两种情形自动统一：

     | 情况 | 计时形态 | 界面显示 |
     | --- | --- | --- |
     | `startAt`、`endAt` 都是时刻 | 倒计时，锚点 = `endAt` | 开始前「计划 30 分钟」/ 开始后剩余 28:12 |
     | 只有 `endAt` 是时刻 | 倒计时，锚点 = `endAt` | 开始前「离截止」/ 开始后剩余 28:12 |
     | 只有 `startAt` 是时刻 | 正计时，从 0 开始 | 已专注 12:40 |
     | 都没有，但有 `estimateMinutes` | 倒计时，锚点 = 当前时刻 + 预计投入 | 开始前「计划 25 分钟」/ 开始后剩余 25:00 |
     | 都没有 | 正计时，从 0 开始 | 已专注 12:40 |

     「开始前」那一列（`FocusPolicy.planLabel`）现在只写在主按钮上（「开始专注 · 30 分钟」），计时页的标题下面不再重复一遍，见本文件末尾「计时页文案精简」。

   - **预计投入可编辑。** 「开始专注」推导时长时 `estimateMinutes` 是最后一个来源，所以它必须能在界面上设置：新建待办、清单就地编辑、任务详情三个入口都要有，任务详情那一行由只读展示改为可编辑，未设置时也保留（藏起来会让用户找不到决定倒计时长度的入口）。取值规则收口成一条：正整数分钟，空串表示未设置；非法输入单独提示，不静默当成未设置写进去——否则打错字会被读成清空。三个入口对「未设置」用同一句措辞，与「开始时间 / 结束时间」两行一致。
   - **用户看到的计时状态只有三个：未开始、计时中、已暂停。** 倒计时归零与结束确认都不是独立状态，前者是计时中的显示变体，后者是结束流程里的一步。

     | 状态 | 主操作 | 次要操作 | 显示 |
     | --- | --- | --- | --- |
     | 未开始 | 开始 | 记录一次行动 | 倒计时：主按钮写着「开始专注 · 30 分钟」；正计时：「开始专注 · 正计时」 |
     | 计时中 | 暂停 | 结束 / 放弃 | 倒计时：剩余 18:23 · 到 15:00；正计时：已专注 12:40 |
     | 已暂停 | 继续 | 结束 / 放弃 | 冻结：剩余 18:23 · 已暂停 02:14 |

     「结束」写入记录；「放弃」不写记录，用于误触。两者的差异靠「结束」「放弃」这两个文字按钮本身承担——它们不缩成图标（第 8 节按反馈去掉了它们下面那句解释文案）。暂停是打断场景的第一个出口，不必因为临时离开就结束这次计时。
   - **暂停不计入投入。** 暂停期间的时间既不计入投入时长，也不推动倒计时。
   - **暂停的记账方式。** 会话保存开始时刻、倒计时终点锚点与暂停区间列表；有效已用时长 = 当前时刻 − 开始时刻 − 已暂停总时长。倒计时剩余按有效已用时长推算，暂停期间冻结，继续时不把暂停的时长算回来。多次暂停按区间累加，不做近似。
   - **倒计时归零后不自动结束。** 计时继续走，显示从「剩余」改为「超出 +03:12」并转为警告色，同时提醒一次。用户不需要任何操作进入或离开这个显示，也不自动标记任务完成。
   - **暂停与到点提醒联动。** 「到点」按有效剩余时间判断，不按绝对时刻。暂停时必须撤销已经排期的本地通知，继续时按新的有效终点重新排期；否则暂停 20 分钟会让提醒提前 20 分钟响。
   - **结束不再确认。** 点「结束」直接写入，不弹「这次投入」。投入时长已经由上面的规则算好（倒计时取计划时长、正计时取有效已用时长），再让用户确认一遍只是让他复述系统刚算出来的那个数。原先这一层还兼着「结束」与「放弃」的分流，现在分流靠计时页上的两个动作本身：主按钮是能退回来的那个（暂停 / 继续），「结束」与「放弃」是一行文字按钮，差异写在按钮下面。
   - **长时间无人操作。** 暂停中，或倒计时归零后仍在计时，超过 `Movo/Config/Defaults.json` 中 `focus.stale_session_hours`（默认 3 小时）时，下次打开应用提示「这次计时已经暂停 N 小时 / 已超出计划时间 N 小时，是结束记录还是放弃」，既不静默作废也不静默续上。
   - **双端呈现。** 两端共用同一份会话状态与写入逻辑，只有呈现方式不同。iOS 用可下拉收起的计时页，收起后回到任务上下文；macOS 在任务详情页内联展示计时条。两端在应用内切换到其他页面时，都能看到进行中的剩余时间。
   - **结束时写入两条独立路径。** 结束计时写 `LogActivity`，记录实际专注分钟；标记完成写 `CompleteTask`，记录真实完成时刻。两者分开提交，记录投入不等于任务完成。
   - **时长截断。** 到点后用户过一段时间才回来结束，记录时长默认截断到锚点时刻（计划 30 分钟就记 30 分钟）。超出锚点在宽限分钟数以内（默认 5 分钟）的按实际记录——这点超出只是分钟级的收尾，按锚点截掉反而让记录失真。截断发生时额外告诉用户一句「已按计划时长记下」：记下的数不等于实际坐了多久，这件事原来只在确认浮层里说明过，撤掉浮层之后必须另找地方说。
   - **计时不依赖累加。** 界面显示的剩余与已用时长都从会话字段与当前时刻推导；冷启动恢复与暂停都不引入逐秒累加。
   - **会话可恢复。** 进行中的会话持久化到本机，App 冷启动或被系统回收后重新打开时读回并继续，不进 CloudKit。
   - **独立待办可记录投入。** 放宽 `ActionRecord.planId` 为可空：任务有计划则记录继承该计划，任务无计划则记录也无计划。回顾统计中已有的「未分类」归类继续承载这类记录。
   - **补记路径补齐时长与说明。** 「记录一次行动」目前不采集时长与说明（`TaskDetailScreen` 调用 `LogActivity` 时传入 `durationMinutes: nil`、`text: nil`），因此补记出来的记录没有投入信息。补记需要能填实际时长与一句说明，写入与计时结束同一条记录结构。
   - **异常与拒绝分支。**
     - 计时中任务被删除或移入最近删除：结束当前会话，写入按结束时的实际状态执行；找不到任务时只写记录不写完成。
     - 计时中任务已被标记完成：结束计时只写记录，不重复写完成。
     - 计时中计划被归档：允许结束计时并写入记录，不阻断。
     - 通知权限被拒：降级为仅前台显示倒计时，不阻断计时。
     - 系统时钟回拨导致当前时刻早于锚点：倒计时显示为 `00:00`，不出现负数。
     - 跨天计时：记录归属以会话开始日为准，时长照常累计。
   - **不在本次范围。** 锁屏与灵动岛 Live Activity（需要新增 Widget Extension target 与签名配置）、专注时长统计、跨设备同步专注会话、AI 参与。

3. **跨切面约束。** 上面两部分共同适用的规则。

   - **无障碍。** 计时数字使用等宽数字并随系统字号放大；剩余与已用时长每秒都在变，不对屏幕阅读器逐秒播报，只在状态变化（开始、暂停、继续、倒计时归零、结束）时播报一次。今日筛选下的时间文字只去掉日期，无障碍标签仍读完整时间。
   - **撤销语义。** 结束计时写入的是一条普通行动记录，与手动补记走同一条命令，因此沿用现有撤销规则（最近 N 个已应用批次，默认 5 步）并同样受冲突保护。「放弃」不写记录，不产生可撤销项。
   - **演示数据。** `Movo/Domain/Support/DemoFixtures.swift` 目前不含行动记录。演示数据要能展示计时结束后的结果：补一条带时长与说明的行动记录，并让一项演示待办带预计投入，使「开始专注」在预览环境里可用。演示数据仍不写进用户数据。
   - **导出不能丢无计划记录。** `Movo/Data/Export/ExportService.swift` 目前用 `activities.filter { $0.planId == plan.id }` 把记录挂到计划下。放宽 `planId` 后，未归属计划的记录会在这个过滤里被静默丢掉。处理方式：在 `PlanFile` 顶层增加与 `tasks` 平级的 `records` 数组承载这类记录，导入时沿用 `tasks` 已有的「可选放进某个计划」规则；导出预览的「这次导出会包含」单列一行「未归属计划的记录 N 条」。这类记录不能在导出时静默消失。
   - **运行参数集中在一处。** 到点是否提醒、结束是否截断到锚点、截断的宽限分钟、久置提示阈值都放在 `Movo/Config/Defaults.json` 的 `focus` 段，`AppDefaults` 同步映射，界面与策略里不写死这些数字。`focus` 段缺失时退回该结构的内置默认，并保留其余段落——不能因为少一个新增的段就让整份配置退到兜底。
   - **行动记录正文不进模型请求体。** 计时结束与补记里填的说明文字属于行动记录正文，按 PRD 的数据边界不进入任何模型请求；核对 `Movo/Intelligence/Privacy/ContextBuilder.swift` 的现有取值即可，不新增例外。
   - **与 PRD 验收标准的对应。** 本次改动直接关联 AC06（同一任务连续多日工作，行动记录累积且不重复）、AC08（取消与重开后历史投入仍可查看）、AC18（导出含行动记录且可还原）、AC23（无需计划即可独立使用）、AC24（行动记录正文不进请求体）。落地时按这几条补验证，不新增独立验收编号。

## Todo list

- [x] 今日上下文的时间显示
  - [x] 新增 `Movo/Domain/Policies/TimeDisplayPolicy.swift`：`TimeDisplayContext` 与 `TimePoint.displayString(in:)`
  - [x] `Movo/Domain/Queries/Views.swift`：`TodayItem.timeText(in:)` 改用同一策略，日期前缀取较早且有时刻的那一端
  - [x] `Movo/DesignSystem/Components/Rows.swift`：`TaskRow(item:)` 增加 `timeContext` 参数，缺省绝对上下文
  - [x] `Movo/Features/Shared/TaskOutline.swift`：增加显式 `timeContext` 参数，今日筛选传入今日上下文；计划详情的执行树与任务详情的子任务列表传绝对上下文
  - [x] 新增 `Tests/MovoDomainTests/TimeDisplayPolicyTests.swift`
    - [x] 覆盖某一天与某一时刻 × 今天 / 明天 / 本周内 / 逾期 / 远期
    - [x] 断言今日上下文输出中不出现月份（整串相等断言，`14:00` 这类）
    - [x] 断言逾期项在今日上下文下写绝对日期而不是「昨天」
  - [x] 运行 `bash Scripts/verify.sh --quick`，`MovoDomainTests` 125 个用例通过

- [x] 预计投入可编辑
  - [x] 新增 `Movo/Domain/Policies/EstimateMinutesPolicy.swift`：取值规则与措辞（`EstimateMinutes.parse` / `text(for:)` / `displayText(for:)`）
  - [x] 新增 `Movo/Features/Shared/EstimateMinutesEditor.swift`：三个入口共用的输入控件
  - [x] `Movo/Features/Plans/NewTaskSheet.swift` 增加「预计投入」输入
  - [x] `Movo/Features/Shared/InlineTaskEditor.swift` 增加就地编辑（挂到属性行的时间弹层旁边）
  - [x] `Movo/Features/Plans/TaskDetailScreen.swift` 由只读展示改为可编辑，并入「时间、优先级、预计投入」浮层；未设置时也保留该行
  - [x] 核对只读展示与编辑表单对「未设置」的表达保持一致，由共用策略与测试锁定
  - [x] 新增 `Tests/MovoDomainTests/EstimateMinutesTests.swift`：空串/正整数/非数字/非正数四类输入与往返一致性

- [x] 运行参数
  - [x] `Movo/Config/Defaults.json` 增加 `focus` 段：`remind_at_end`、`truncate_duration_at_anchor`、`truncate_grace_minutes`、`stale_session_hours`
  - [x] `AppDefaults`（`Movo/Domain/Support.swift`）同步增加 `Focus` 结构与键名映射、内置默认，并让新段缺失时只退回该段默认
  - [x] 核对 `Movo/Config/` 加载器：`Config/` 以 folder reference 打包后会多出一层 `Config` 目录（macOS 在 `Resources/Config/`），而加载器只在 bundle 根查找，因此**一直读不到配置、静默使用内置兜底，改 JSON 不生效**。`ConfigLoader` 改为根目录找不到时再按 `Config` 子目录找一次，并开放 `resourceURL(named:extension:in:)` 供测试断言
  - [x] 新增 `Tests/MovoDomainTests/AppDefaultsTests.swift`：加载器找得到资源、捆绑 JSON 与内置兜底一致、`focus` 段取值、缺段时的回退行为

- [x] 放宽 `ActionRecord.planId` 为可空
  - [x] `Movo/Domain/Models/Entities.swift`：`planId` 改为 `UUID?`，说明归属由 `LogActivity` 保证、无计划记录归入回顾里已有的「未分类」
  - [x] `Movo/Domain/Commands/RecordCommands.swift`：`LogActivity.planID` 改可选且默认 `nil`，执行时以任务归属为准（`resolvedPlanID = task.planId`）；显式传了 `planID` 但与任务不一致仍拒绝，任务与计划不存在仍拒绝，非正时长仍拒绝，无计划记录不能挂到重复实例上
  - [x] 存储层：`Movo/Data/Local/SwiftDataModels.swift` 的 `ActivityM.planID` 改可选；`SwiftDataRepository` / `LocalAdapter` / `InMemoryRepository` 经核对已按可选处理 `activities(planID:)`，无需改动
  - [x] 同步层：`Movo/Data/Sync/SyncEntityBox.swift` 经核对 `planID` 原本就是 `UUID?`，无需改动
  - [x] 导出：`Movo/Data/Export/ExportService.swift` 把 `planId == nil` 的记录单独收集，不再被 `filter { $0.planId == plan.id }` 静默丢掉；导出预览的「这次导出会包含」增加「未归属计划的记录 N 条」，Markdown 增加「未归属计划的行动记录」段落
  - [x] `Movo/Data/Export/PlanFile.swift`：`build` 增加 `standaloneRecords` 参数写进顶层 `records`（遵守 `includeRecords` 与更正记录过滤），与 `tasks` 平级
  - [x] `Movo/Data/Export/PlanFileImport.swift`：记录导入不再要求目标计划，无目标的记录按未归属计划落库；行动记录不再计入「需要目标计划」的判定
  - [x] 视图与统计：`Movo/Domain/Queries/DomainStore+Views.swift` 的分类占比改用 `activity.planId.flatMap { planById[$0]?.category }`，无计划记录归入 `nil` 分类；`PlanHistoryScreen` / `PlanDetailScreen` 经核对按计划查记录，不受影响
  - [x] 核对编码兼容：`ActionRecord` 的合成 `Codable` 对可选字段本就向后兼容，已有数据中 `planId` 有值时读取路径不变
  - [x] `Tests/MovoDomainTests/StandaloneActivityTests.swift`：计划内任务继承计划、独立待办记录无计划、跨计划拒绝、未知任务与未知计划拒绝、非正时长拒绝、无计划记录挂实例拒绝
  - [x] `Tests/MovoDataTests/StandaloneRecordTests.swift`：存储往返保留无计划记录、按计划查询不返回无计划记录、导出包含无计划记录与其条数、导出导入往返后仍无计划
  - [x] 运行 `MovoDomainTests`、`MovoDataTests`：145 + 34 用例通过

- [x] 专注计时纯逻辑
  - [x] 新增 `Movo/Domain/Policies/FocusPolicy.swift`
    - [x] 时长推导：五档来源 `startAndEnd` / `endOnly` / `startOnly` / `estimate` / `none`，形态由来源决定；某一天（`TimePoint.day`）不构成终点，也不被当成时长
    - [x] 名义长度定义为「倒计时归零那一刻的有效已用时长」，因此「计划 30 分钟」与「到点按 30 分钟截断」共用同一个数
    - [x] 状态：`Status`（未开始 / 计时中 / 已暂停）与 `pause` / `resume` 迁移，暂停不叠段、不在暂停中时继续为空操作
    - [x] 归零后的显示变体：刚好归零仍读「剩余 00:00」，超出后才翻成「+03:12」，不出现负数
    - [x] 暂停区间累加与有效已用时长：`pausedSeconds` / `elapsedSeconds`，暂停中自动冻结，时钟回拨不出负数、不放大区间
    - [x] `effectiveEnd` 按有效剩余时间排期，暂停与已归零时不排期（暂停 5 分钟，提醒终点就往后挪 5 分钟）
    - [x] 时长截断：`recordedSeconds` / `recordedMinutes`，宽限内按实际、超出宽限截到锚点，不足一分钟记一分钟
    - [x] `staleness` 久置提示：暂停中与归零后各自按 `stale_session_hours` 判定，附提示句
    - [x] `Snapshot` 一屏数字与文案（`primaryText` / `secondaryText` / `planLabel` / `barDetailText` / `remainingFraction`），两端视图不再自己算
    - [x] `diffTag` 计划与实际差异
  - [x] 新增 `Tests/MovoDomainTests/FocusPolicyTests.swift`，用注入的时刻固定时间（32 个用例）
    - [x] 起止都是时刻
    - [x] 只有结束时刻
    - [x] 只有开始时刻
    - [x] 只有预计投入
    - [x] 起止与预计投入都缺
    - [x] 单次暂停后结束，暂停时长不计入
    - [x] 多次暂停后结束，区间累加正确
    - [x] 暂停期间不发生到点
    - [x] 倒计时归零后结束
    - [x] 跨天
    - [x] 时钟回拨
    - [x] 补：「截止 今天」这类只有日期的端点不成锚点、已过去的截止不开负数倒计时、会话编解码无损
  - [x] 运行 `MovoDomainTests` 177 个用例（新增 32）、`MovoDataTests` 34 个用例，全绿

- [x] 专注会话持久化
  - [x] 新增 `Movo/Data/Local/FocusSessionStore.swift`：`FocusSessionStore` 契约、`UserDefaultsFocusSessionStore`（键 `movo.focus.session`）、`InMemoryFocusSessionStore` 替身；只走本机偏好，不进 CloudKit／导出／日志
  - [x] 读坏了按「没有进行中的计时」处理，不抛错、不卡启动；坏记录可被下一次保存覆盖
  - [x] 同一时刻只保留一次计时；替换旧记录由调用方决定，存储层不静默丢弃一次正在跑的计时
  - [x] 新增 `Tests/MovoDataTests/FocusSessionStoreTests.swift`（13 个用例）：字段全量往返（含暂停区间与锚点时区）、换实例读同一份偏好即冷启动、暂停态跨重启仍冻结、继续后计时接着走、恢复后按同一套规则结束与截断、坏数据降级、亚秒精度、内存替身
  - [x] 冷启动把会话读回并继续，由上述存储层用例覆盖；界面层的恢复（计时条与计时页首帧）放到「计时界面」一节接线
  - [x] 运行 `MovoDataTests` 47 个用例（新增 13），全绿

- [x] 计时入口与导航
  - [x] `Movo/App/Navigation/Route.swift` 增加 `case focus(UUID)`，`id` 取 `focus-<uuid>`，`artboardName` 取「D14 / M15 专注计时」；`Movo/App/Navigation/ScreenHost.swift` 映射到 `FocusSessionScreen(taskID:)`，沿用现有路由，不新建跳转机制
  - [x] `Movo/Features/Plans/TaskDetailScreen.swift` 主按钮区增加「开始专注」，保留点击进入详情的原有行为：未在计时时按钮标题取 `FocusPolicy.Plan.buttonTitle`（如「开始专注 · 30 分钟」），已在计时时改为「结束专注 / 继续专注」+「暂停」
  - [x] 今日清单行增加行尾开始入口，不改动行本体的点击行为：`TaskRow` 的 `onFocus` 渲染为行尾省略号菜单里的「开始专注」（不是常驻播放图标，避免每一行都在争抢注意力），进行中的行改为行尾徽标 `⏱ 18:23`（`FocusRowBadge`），点徽标进计时页；`TaskOutline` 的行菜单同步增加「开始专注 / 回到计时」
  - [x] 今日筛选只给一次性待办开口：`TodayItem.focusableTask` 对重复行动（模板与实例）与「今天也可以做」返回 `nil` —— 前者的 `startAt`/`endAt` 是规则窗口的两端，拿窗口长度当倒计时会得出以月计的数字；后者是派生投影，还没有一条记录可归属
  - [x] `Movo/Features/Plans/TaskDetailScreen.swift` 的「记录一次行动」补齐实际时长与说明输入：`LogActivitySheet` 采集分钟数与一句说明，并带「发生时间」默认当前时刻（`MovoTimePointField`）；写入与计时结束共用同一份 `AppEnvironment.logActivity`
  - [x] 三个入口共用同一个时长解析规则：`EstimateMinutes.parse(_:subject:)` 增加 `subject` 参数，补记表单复用「预计投入」的措辞与拒绝分支，不另写一份解析

- [x] 计时界面
  - [x] 新增 `Movo/Features/Plans/FocusSessionView.swift`，覆盖未开始 / 计时中（倒计时、正计时、归零后超出）/ 已暂停，以及结束确认浮层（`FocusSessionScreen` + `FocusSaveSheet`）
  - [x] 一屏数字与文案全部由 `FocusPolicy.Snapshot` 提供（`primaryText` / `secondaryText` / `planLabel` / `barDetailText` / `remainingFraction` / `isOverrun` / `staleness`），视图不自己算时间
  - [x] 双端呈现：iOS 用可下拉收起的计时页（拖拽阈值 60，收起后回到任务上下文），macOS 在任务详情页内联；底部/顶部的 `FocusBar` 在两端都显示进行中的剩余时间
  - [x] 进行中的剩余时间在应用内切换到其他页面后仍然可见：`RootView` 的 `FocusBarInset` 挂在 iPhone 的 `.safeAreaInset(edge: .top)` 与 macOS 详情列 `NavigationStack` 之上；`FocusBarInset` 在计时页自身隐藏，避免同一屏出现两条同样的计时
  - [x] 一秒一跳只包住真正在变的那一行：`TodayScreen` 只把进行中的那一行放进 `TimelineView`，`FocusRowBadge` 自带一秒时间线，其余列表不随秒重建
  - [x] `TaskDetailScreen` 两处浮层收口成一个 `DetailSheet` 枚举（安排 / 补记）：同一个视图上叠多个 `.sheet` 时 SwiftUI 只认其中一个，另一个会「点了没反应」。（「这次投入」原本是这枚举里的第三项，已随「结束不再确认」一并取消。）
  - [x] `EstimateMinutesField` 增加 `showsSteppers` 与 `chips`（默认 `[15, 25, 30, 45, 60]`，`MovoStepChips`）；`±` 每次 5 分钟，减到空即停，不把非法的 `0` 留在输入框里
  - [x] macOS 与 iOS 模拟器（iPhone 17 Pro）构建通过，五个测试用例集全绿（`MovoDomainTests` 177、`MovoDataTests` 47、`MovoPrivacyTests` 15、`MovoAdapterTests` 35、`MovoSyncTests` 21）

- [x] 计时提醒与写入
  - [x] `PlannedNotification.Kind` 增加 `.focusEnd`（展示名「专注到点」）；`NotificationPlanner.plan` 增加 `focus:` 参数，`NotificationCenterService.plan/refresh` 与 `AppEnvironment.refreshNotifications()` 逐层透传进行中的会话
  - [x] 到点提醒走 `NotificationScheduling`，测试使用 `InMemoryNotificationScheduler`（`Tests/MovoDomainTests/FocusReminderTests.swift`，服务层用例断言实际写进「系统」的内容）
  - [x] 排期时刻取 `FocusPolicy.effectiveEnd` 而不是会话的名义锚点；暂停时撤销已排期的到点提醒，继续时按新的有效终点重新排期（14:30 的锚点被 10 分钟暂停推到 14:40）
  - [x] 撤销与重排复用现有的「整份替换」语义：`replaceAll` 本身就是全量覆盖，暂停后重算出来的排期里没有这条提醒，于是它被撤销；继续后再回来。通知层不新增增量接口
  - [x] 通知标识取会话 ID（`movo.focus.<sessionID>`），重排是覆盖同一条而不是叠一条；深链 `movo://focus/<taskID>` 落到计时页，`NotificationDeepLink` 增加 `case focus(UUID)` 与解析分支，`MovoDeepLink.apply` 映射到 `Route.focus`
  - [x] 到点提醒在安静时段顺延与聚合窗口**之后**单独追加：它是用户按下开始时就答应他的那一次提醒，顺延到早上 7 点或并进「有 N 项要看一下」都不再是那一次
  - [x] 冷启动把进行中的会话读回后重新确认一次提醒（`RootView` 的一次性 `.task`）：上次写进系统的那条可能因为当时权限未授予而没落下去。没有会话时什么都不做
  - [x] 结束写入 `LogActivity`，标记完成写入 `CompleteTask`，两者分开提交（`AppEnvironment.finishFocus`）；记录投入不等于任务完成，界面上的两个按钮也分开
  - [x] 记录时长取 `FocusPolicy.recordedMinutes`（倒计时取计划时长、正计时取有效已用时长，超出宽限的截到锚点）：`FocusSaveSheet` 曾把它的默认值摆出来让用户确认，浮层取消后改由 `AppEnvironment.focusDefaultMinutes` 直接算给写入用
  - [x] 「放弃」不写记录，与「结束」的差异在界面上用文字写明：「「结束」会记下这次投入；「放弃」不写记录，用于误触。」
  - [x] 计时状态一变就重排一次通知：`setFocusSession` 是唯一的会话写入口，重排挂在它上面，因此开始 / 暂停 / 继续 / 结束 / 放弃都不会漏
  - [x] 增补 14 个用例（`FocusReminderTests`）：计时中排一条、暂停与已归零不排、正计时不排、开关关闭不排、没有会话不排、暂停后终点后移、标识跨重排不变、安静时段不顺延、窗口内不被聚合成一条、整份排期仍按时刻升序、深链往返、服务层「写入→撤销→恢复→清除」四步、到点提醒与任务提醒互不挤掉
  - [x] `MovoDomainTests` 177 → 191 个用例通过

- [x] 演示数据与无障碍
  - [x] `Movo/Domain/Support/DemoFixtures.swift` 让「汇总区域差异」带 30 分钟预计投入，使「开始专注 · 30 分钟」在预览环境里可用；与它已有的 20 分钟历史记录搭在一起，结束浮层的「比计划少 10 分钟」也有东西可显示。演示数据仍不写进用户数据
  - [x] 行动记录本已存在（「汇总区域差异」20 分钟带说明、「英语复习」30 分钟带说明、「阅读」15 分钟），核对无需再补
  - [x] 同步 `docs/UI-Prompt.md` 的示例数据与字段说明：树表与「时间与任务身份」补上预计投入 30 分钟，并新增一节写明「预计投入」在三个入口的措辞与取值规则
  - [x] 计时数字使用等宽数字并随系统字号放大：`FocusDial` 主数字走 `@ScaledMetric(relativeTo: .largeTitle)`，时间文字统一 `.monospacedDigit()`
  - [x] 计时状态变化时只播报一次，不逐秒播报：计时盘与计时条用 `.accessibilityElement(children: .combine/.ignore)` 把一屏数字收成一个元素，读的是状态名与当前值，不逐秒重播
  - [x] 今日筛选下时间文字的无障碍标签仍读完整时间：`TaskRowConfig` 增加 `timeTextSpoken`（取 `.absolute` 上下文），`TaskOutline.metadata` 拆出 `in context:` 参数，可见文本用今日上下文、无障碍标签用绝对上下文

- [x] 文档与验收
  - [x] 核对 `docs/PRD.md` 第 7.2 节：原文已有「开始可选计时」与「计时停止和任务完成分别处理」，与本次实现一致，措辞不必改；补了一段行为边界，把 REQ 12 没写到的部分定下来——时长以结束时刻推导、暂停不计入且到点提醒随之顺延、归零后提醒一次并继续走而不自动结束、久置提示阈值、结束与标记完成分开提交、到点后拖延按计划时长截断且可改、会话本机持久化不跨设备同步，并标注对应 AC06 / AC08 / AC18 / AC23 / AC24
  - [x] 按 AC06 / AC08 / AC18 / AC23 / AC24 补对应验证：新增 `Tests/MovoDomainTests/FocusAcceptanceTests.swift`（8 个用例）。这些条目原本就有覆盖，补的是**计时这条写入路径**——计时器在 App target 里没有测试宿主，所以按 `AppEnvironment.finishFocus` 实际发出的领域命令序列走一遍：AC06 同任务连续三天各 30 分钟得到三条记录、合计 90 分钟、任务 ID 不变；AC08 完成再重开、以及取消之后记录仍在且归属不变；AC23 独立待办能开始专注并留下无计划记录、回顾里归入「未分类」；AC18 的导出往返已由 `StandaloneRecordTests` 覆盖，不重复；AC24 计时结束时填的说明确实写进了库，但不出现在 `requestBodyJSONString()` 里，同时断言任务标题仍在上下文里——两个方向都查，否则一个空上下文也能让断言通过
  - [x] 期间修正了一处我自己写错的假设：`DeleteTask` 写的是 Tombstone（「移到最近删除」），不是立刻抹掉任务行，所以「任务已删除」时记录仍然带着归属，而不是变成无主记录。异常分支因此拆成两条——移入最近删除仍按实际状态写入，任务确实不在库里时才写一条无计划无任务的纯投入记录
  - [x] `bash Scripts/verify.sh`（`export OTHER_SWIFT_FLAGS='-disable-sandbox'`）：macOS 构建通过、iOS 模拟器（iPhone 17 Pro）构建通过、五个用例集全绿（199 + 47 + 15 + 35 + 21 = 317 个用例）
  - [x] 核对 `Scripts/verify.sh` 在受限环境下的可运行性：确认是本机环境限制而非工程问题。给宏插件套的 `sandbox-exec` 起不来（`sandbox_apply: Operation not permitted`），`@Observable` 展开随之失败、脚本直接跑不通；`export OTHER_SWIFT_FLAGS='-disable-sandbox'` 之后 `Scripts/verify.sh` 原样通过，不必改脚本。已写入 `docs/Development.md` 3.6 节，连同判定方法（同一条命令在普通终端通过、只在代跑环境失败）一起记下
  - [x] 同步 `docs/UI-Prompt.md`：新增「预计投入」字段一节（三个入口的位置、措辞、取值规则与非法输入提示），并更新示例数据
  - [x] 在 pen.dev 画布上绘制 `D14-Focus` 系列与 `M15-Focus` 系列，并更新 `D07-Default` / `M12-Default`：`docs/design/Movo.pen` 本轮新增 11 块计时画板（`D14-Focus` / `D14-Focus-Paused` / `D14-Focus-Save` / `D14-Log` / `M15-Focus` / `M15-Focus-Collapsed` / `M15-Focus-CountUp` / `M15-Focus-Overrun` / `M15-Focus-Paused` / `M15-Focus-Save` / `M15-Log`），`D07-Default` 与 `M12-Default` 在原有画板基础上改。**此前这一条长期写着「画板本身待绘制」，与文件实际状态不符，本轮核对后改正**
  - [ ] 画布还没跟上后面几次修订，需要重画：① 删掉 `D14-Focus-Save` / `M15-Focus-Save` 两块画板（「结束」不再弹确认浮层）；② `D14-Focus` 由「详情页顶部插一条计时条」改为「独立的计时页」，「计时中的任务详情」另开一块（见 `docs/UI-Prompt.md` 第 3 节与本文件末尾）；③ `M15-Focus` 系列去掉标题下的计划标签、盘下的「暂停期间不计入投入」、按钮下的「结束 / 放弃」说明句；④ 任务详情主操作区上移、行动记录行加「改」入口。**需要 pen.dev 画布工具**，当前环境没有
  - [ ] 设备验收：iOS 后台与锁屏到点提醒、暂停后提醒重新排期、通知权限被拒时的降级、macOS 后台计时。**这一项需要真机与真实通知投递**，模拟器无法覆盖；排期时刻的正确性已由 `FocusReminderTests` 在注入时刻下钉住

- [x] 视觉修订：专注页居中与主操作区位置（本轮实现后按反馈调整）
  - [x] 新增 `Movo/Features/Shared/Scaffold.swift` 的 `FocusStage`：计时页内容水平与垂直双向居中、版心 520，仍然可滚动。原先复用的 `ScreenScroll` 限宽 760 且左对齐——那是给列表页的规则，一屏单件内容沿用之后整套东西缩到左上角，右边和下面各空一大片。两个容器只差「限多宽、往哪对齐」这一条，`ScreenScroll` 保持不变
  - [x] `Movo/Features/Plans/FocusSessionView.swift`：「未开始」与「计时中」都改用 `FocusStage`；抽出共用标题块 `hero(_:caption:)`，按下「开始」时页面上半部分不跳；iPhone 的收起胶囊留在 `FocusStage` 之外、固定在屏幕顶边，不跟着内容居中
  - [x] `Movo/Features/Plans/TaskDetailScreen.swift`：主操作区从整页滚动的末尾移到任务标题块正下方，抽出 `actionArea` / `restingActions` / `restingButtons` 三个片段
    - [x] 主按钮改用 `FocusPrimaryButton`（整行撑满、高 52），与计时页主按钮同一规格。原先是一个 44 高的 `MovoButton`，和旁边两个次按钮一样大，而且要先滚过所属与时间、子任务、步骤、行动记录、变更历史才看得到
    - [x] 主操作区限宽 420 并左对齐：详情页内容列是 760，主按钮铺满整列会变成一条横穿页面的长条，不再像一个按钮
    - [x] 次按钮一排（计时中的「暂停」/ 暂停中的「结束专注」，加上「标记完成 / 重新打开」与「记录一次行动」）用 `ViewThatFits` 兜底：窄屏叠加大字号时放不下就改竖排，而不是把最后一个按钮挤出屏幕
    - [x] 「这次没有开始」的提示横幅跟着主操作区走，紧挨着它响应的那个按钮，不再留在页面末尾
    - [x] 顺手修掉一个按不动的按钮：暂停中原本显示「暂停」，可那一刻它已经暂停了，按下去不会有任何反应。改为「结束专注」，让暂停中的这次投入也能在详情页收尾——此前只能回计时页结束
    - [x] 详情页「…」菜单里的「开始专注」去掉：同一个页面上给同一个动作留两个入口，只会让人犹豫该点哪个。`D01` / `M01` 清单行菜单里的那一项是另一个页面的事，保留
  - [x] 同步 `docs/UI-Prompt.md`：第 6 节 `D07-Default` / `M12-Default` 与第 3 节 `D14-Focus` 改按新位置描述；新增第 8 节记下两处修订与版心规则；并标明第 3 节「Mac 不设独立全屏计时页」与实现的差异（两端共用 `FocusSessionScreen`，`FocusBar` 只是额外挂在详情列顶部）留待画布这一轮决定
  - [x] `bash Scripts/verify.sh`（`export OTHER_SWIFT_FLAGS='-disable-sandbox'`）：macOS 构建通过、iOS 模拟器（iPhone 17 Pro）构建通过、五个用例集全绿（199 + 47 + 15 + 35 + 21 = 317 个用例）。本次只动布局，用例数与上一轮相同
  - [ ] 双端视觉确认：打开任务详情看主操作区的位置与尺寸、进入计时页看版心是否居中。**这一项在当前环境里做不到**——演示数据只在 `#Preview` 与测试里装载，应用内没有装载入口，首次启动为空；也没有可以渲染 `docs/design/Movo.pen` 的画布工具可以截图。构建与用例能证明它编译通过、行为不变，证明不了它好看

- [x] 取消「结束」的确认浮层（按反馈调整）
  - [x] 删掉 `FocusSaveSheet` 与它的四处入口：计时页的主按钮 / 文字按钮 / 久置横幅、计时条上的「结束」（`RootView` 的 `PhoneShell` 与 `MacShell` 各一处）、任务详情的主操作区
  - [x] 新增 `AppEnvironment.finishFocus()`（不传参的版本）：投入时长由 `focusDefaultMinutes` 直接算好交给既有的 `finishFocus(minutes:note:markComplete:)`。`minutes: nil` 保留「只留一条不带时长的记录」的原义，两条语义没有混在一起
  - [x] 「结束不再确认」连带的两处调整：
    - [x] 计时中的主按钮从「结束专注」换成「暂停」。结束一步到位、按一下就直接写记录，把最显眼的位置留给能退回来的动作。这条同时让任务详情页回到「主操作 / 次要操作」那张表（计时中＝暂停 / 结束；已暂停＝继续 / 结束）——此前详情页在计时时主按钮是「结束专注」，与表本身就不一致
    - [x] 截断时补一条提示。`focusNotice` 从 `String?` 变成 `FocusNotice`（标题 + 正文），因为同一处横幅现在有两个来由：「这次没有开始」与「已按计划时长记下」，标题不能再写死在视图里。被截断时如实说明记下的是计划时长——原来只有浮层里那句「可以改成实际时长」在讲这件事，不说，用户会以为自己被记错了
  - [x] 顺手修掉一个死路：任务在计时期间被删除时，原来是浮层收起后留下一个「这项待办已经不在了」、再没有任何按钮的页面；现在「结束并记录」写完就收起
  - [x] 同步文档：`docs/UI-Prompt.md` 第 2 / 3 / 4 / 5 / 6 / 7 / 8 节（取消 `D14-Focus-Save` 与 `M15-Focus-Save` 两块画板、`Focus / DiffTag` 标记为暂无界面落点、主按钮改「暂停」、边界条款重写）；`docs/PRD.md` 7.2 节那句「允许改成实际值」改为「另行告知已按计划时长记下」
  - [x] 本次改动落在界面层，应用 target 没有测试宿主；截断规则本身（`FocusPolicy.recordedSeconds` / `recordedMinutes`）与 `diffTag` 已由 `FocusPolicyTests` 覆盖，因此没有新增用例
  - [x] `bash Scripts/verify.sh`（`export OTHER_SWIFT_FLAGS='-disable-sandbox'`）：macOS 构建通过、iOS 模拟器（iPhone 17 Pro）构建通过、五个用例集全绿（199 + 47 + 15 + 35 + 21 = 317 个用例）
  - [x] 撤掉浮层之后留下的那处能力缺口（界面里再没有「改这次投入时长」的入口）已在下一节补上

- [x] 行动记录的更正入口（按反馈调整）
  - [x] 任务详情「行动记录」每行末尾加一个「改」文字按钮，接到领域层一直存在、却始终没有界面调用的 `CorrectActivity`：可改投入时长与说明，保存后写一条 `isCorrection` 记录指向原记录，旧版本按 PRD 3.4 继续留在库里
  - [x] 新增 `Movo/Domain/Policies/CorrectionHistoryPolicy.swift`：`CorrectionChained`（有 id、可能指回被取代的那条）与 `CorrectionHistory.current(_:)`。**没有它，改完会看到两条**——更正新写一条而不是改写原记录，列表把新旧并排渲染出来，「我到底投入了多少」反而没有答案了
    - [x] 同一段过滤原先在 `Movo/Data/Export/PlanFile.swift` 里已经存在三份（未归属计划的记录、计划内的记录、测量值），本轮收敛到这一处，行动记录与测量共用；泛型的作用只是「一次写清、两处引用」，不为抽象而抽象
    - [x] 只过滤、不排序：顺序仍由调用方决定（任务详情按发生时间倒序，计划详情按录入时间）
    - [x] 库里、导出里、更正记录的 back-reference 里，旧版本都还在；变的只是「列表显示哪一条」
  - [x] 过滤接在两个读取点：`DomainStore+Views.taskDetail` 与 `PlanDetailScreen.reload()`。计划详情走的是 `activities(planID:)` 这条查询，与任务详情不是同一支，漏掉任何一处都会看到重复行
  - [x] `Movo/App/AppEnvironment+Focus.swift` 增加 `correctActivity(_:)`：走既有的 `store.execute` + `lastBatchNotice` / `lastError` 通路，与其他写入命令的失败处理一致
  - [x] `Movo/Features/Plans/TaskDetailScreen.swift`：`DetailSheet` 增加 `correctActivity(UUID)`（枚举由 String 改为带关联值，好让浮层拿到要改的那条），新增 `CorrectActivitySheet`——复用 `EstimateMinutesField`（`showsSteppers` + 常用时长 chips）与 `EstimateMinutes.parse(_:subject:)`，因此「空的表示未设置、非法输入单独提示」这套措辞与另外三个入口完全一致，不另写一份解析
  - [x] 更正浮层里刻意**不**出现「发生时间」：它决定这条记录算哪一天、进哪一周，和「这次投入多久」不是同一个问题；摆在一起会让人以为改时长时顺手要确认日期。`CorrectActivity.newHappenedAt` 保留在领域层，本轮没有界面需要它
  - [x] 删掉计时页与详情页各自私有的 `focusDefaultMinutes` / `focusIsTruncated` 计算属性：取消确认浮层之后，这两处判断已经在 `AppEnvironment+Focus` 里各有一份，视图再算一遍只会让「谁说了算」变得含糊
  - [x] 新增 `Tests/MovoDomainTests/CorrectionHistoryTests.swift`（12 个用例）：空列表、单条记录、一次更正、**连改两次 A → B → C 只剩 C**、两条互不相干的更正链各自保留链头、只藏被改过的那条、过滤不重排、指向列表之外时什么都不藏（按天取记录时不能误滤）、测量值走同一条规则；再接上真实存储验证三条走向——任务详情改两次后只显示一条、改完显示新值与新说明、计划记录列表按 `planID` 查询后同样只剩一条，同时断言库里仍是三条（旧版本没丢）
  - [x] `bash Scripts/verify.sh`（`export OTHER_SWIFT_FLAGS='-disable-sandbox'`）：macOS 构建通过、iOS 模拟器（iPhone 17 Pro）构建通过、五个用例集全绿（211 + 47 + 15 + 35 + 21 = 329 个用例）
  - [x] 同步文档：`docs/UI-Prompt.md` 第 6 节 `D07-Default` / `M12-Default` 补「行动记录」行上的「改」入口，第 8 节记下「更正过的记录只显示当前值」这条规则与它连带的两个判断（浮层里不出现发生时间、撤掉确认浮层后补说明只剩「改」这一个入口）
  - [ ] 双端视觉确认：打开任务详情改一次记录，看列表是一行而不是两行、浮层里的时长输入与既有措辞一致。**这一项在当前环境里做不到**（同上一节：应用内没有演示数据装载入口，也没有设计画布可以截图）；过滤规则本身已由 `CorrectionHistoryTests` 钉住

- [x] 开始后直接进计时页 + 计时页文案精简（按反馈调整）
  - [x] **「开始专注」按下去就进计时页。** 三处入口此前都只写一条会话就停住，用户看到的是页面顶上多出一条计时条，还得再点那条才进得去：「我按下那一下到底生效了吗」反而成了要自己找答案的问题
    - [x] `Movo/Features/Plans/TaskDetailScreen.swift` 主操作区：`beginFocus` 返回 true 才 `router.push(.focus(...))`
    - [x] `Movo/Features/Shared/TaskOutline.swift` 行菜单里的「开始专注」同样处理
    - [x] `Movo/Features/Today/TodayScreen.swift` 行尾开始入口同样处理
    - [x] 计时页自己那个「开始专注」不跳：它本来就在那一页上，`beginFocus` 之后同一页会重渲染成计时中
    - [x] 被拦下时（另一次正在计时）留在原地，由紧挨着主操作区的横幅说明原因——那一条会话没有变，跳过去只会让人以为切换成功了
    - [x] macOS 因此也进独立计时页，第 3 节「Mac 不设独立全屏计时页」那句随之作废（原文记的是早期设想，实现一直是两端共用 `FocusSessionScreen`）
  - [x] **计时页去掉三处说明文案**（`Movo/Features/Plans/FocusSessionView.swift`）。这一页处在「正在做」的状态里，多出来的句子把视线从数字上拉走：
    - [x] 标题下不再有 12pt 计划标签（「未设置时长，正计时」）：它在「未开始」已经写在主按钮上，在计时中又和盘上的数字说同一件事。`hero(_:)` 由「标题 + 副行」简化为只接标题
    - [x] 盘下不再有常驻提示「暂停期间不计入投入」：写的是规则，不是此刻的信息。`hint(_:)` 改为 `stateNotes(_:) -> [String]`，正常计时返回空数组，整块不渲染（而不是留一个空 `VStack` 白占一段间距）
    - [x] 保留的两句都与状态相关，且都是看数字看不出来的：暂停的「继续后从 18:23 接着走」与到点后仍在超出的「到点后仍在计时，不会自动结束。」后一句不说的代价很具体——用户会坐在那儿等它自己停
    - [x] 文字按钮下面不再有「「结束」会记下这次投入；「放弃」不写记录，用于误触。」这条推翻了先前「两个动作在界面上用文字写明差异」的写法：差异现在由「结束」「放弃」这两个词本身承担（它们仍是文字按钮，不是图标）
    - [x] 「未开始」那一页同时去掉通用规则句「暂停期间不计入投入。结束与标记完成是两件事。」，只留一句与本次任务相关的 `planHint`（这次会倒计时还是正计时、到点会不会自己停）
    - [x] `FocusPolicy.Snapshot.planLabel` 因此暂时没有界面落点，保留在领域层并有用例，注释改为说明「它没有落点、为什么留着」，省得后来的人去找一个不存在的界面
  - [x] 这次改动全落在界面层（三个入口的跳转 + 一个页面的文案），行为规则一条没动，因此没有新增用例：`FocusPolicy` 的时长推导、状态迁移与截断规则都由既有用例覆盖，`MovoDomainTests` 仍是 211 个
  - [x] 同步文档：`docs/UI-Prompt.md` 第 3 / 4 / 7 节按新文案改写（第 3 节把 `D14-Focus` 由「详情页顶部插计时条」改为「独立计时页」，`D14-Focus-Paused` 改为同一页的暂停态，计时中的详情页另列一条、画板名待定），第 8 节新增两条修订说明；`docs/PRD.md` 的 7.2 节写的是行为规则（暂停不计入投入是规则，不是界面文案），无需改动
  - [x] `bash Scripts/verify.sh`（`export OTHER_SWIFT_FLAGS='-disable-sandbox'`）：macOS 构建通过、iOS 模拟器（iPhone 17 Pro）构建通过、五个用例集全绿（211 + 47 + 15 + 35 + 21 = 329 个用例）
  - [ ] 双端视觉确认：在任务详情按「开始专注」看是不是直接进计时页、计时页上除了标题与数字还剩几行字。**这一项在当前环境里做不到**（应用内没有演示数据装载入口，也没有设计画布可以截图）
  - [ ] 一处留给你的判断：「放弃」现在没有确认、页面上也不再说它不写记录。要加安全网的话，给「放弃」补一次确认比把说明句堆回计时页更合适

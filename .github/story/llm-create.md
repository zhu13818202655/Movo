# AI 创建：协议、上下文与整理记录

## 背景

- 语音或文字输入现在先经 `PrivacySplitter` 按健康关键词拆句，命中的句子不发给模型，再由 `LocalDirectRouter` 用动词表做本地匹配；匹配不上就进收件箱。例如「最近三天需要加大运动量」会因「运动」整句留在本机。
- 模型能做的事被协议限制：`create_task` 拒绝阶段；子任务要求同时带计划；`create_plan` 只带平铺任务；不能直接创建重复任务；没有结束日期和时刻字段。
- 发给模型的上下文只有计划名、当前阶段名和平铺任务，没有父子关系、全部阶段、重复模板。
- 归属靠 0.90 置信度和 0.15 分差阈值降级，分差阈值实际并未生效。
- 除新建计划、设置重复、设置依赖外，AI 结果直接落库，只能靠撤销条回退，且没有时间或步数限制。
- 每次首次启动 `MovoApp.bootstrap` 会载入 `DemoFixtures` 演示数据。
- 收件箱同时承担原文兜底、系统建议、同步冲突和被拒操作的入口。

## 期望

1. **手动与 AI 并行，两者都完整。**
   - 用户可以完全手动创建计划、阶段、任务（含多级子任务、重复任务）。
   - 用户也可以用语音或文字，让 AI 创建这些。
   - AI 能判断：归属已有计划、新建计划或独立任务；归属哪个阶段；是子任务还是顶层任务；是否重复。
2. **去掉规则与隐私拆分。**
   - 删除 `PrivacySplitter`、`LocalDirectRouter`、`HealthKeywords.json` 及所有关键词匹配。
   - 用户输入原文原样发给模型。
   - 隐私只保留一个全局「AI 开关」；计划级云 AI 开关不再参与判断。API Key 仍只存设备 Keychain，日志仍脱敏。
   - 打开 AI 开关时，以及首次使用 AI 输入时，各告知一次：输入原文会原样发给用户配置的模型服务商。
3. **先预览，确认后落盘。**
   - AI 的所有写入都先展示预览：计划、阶段、任务（含父子层级和起止时间），可逐项取消。
   - 用户确认后作为一个批次一次写入，失败整体回滚。
   - 取消某一项时，其所有后代自动一起取消（界面置灰、不可单独勾选），避免父项缺失造成 `parent_ref` / `stage_ref` 悬空。
   - 被取消的项不写入，不属于该批次；已写入的部分是一个批次，一次撤销整批回退。整理记录显示「已应用（部分）」，保留被取消的项，可重新打开预览补回。
4. **可回退，默认 5 步。** 系统保留最近 N 个已应用批次（手动与 AI 都算），`N` 默认 5，放在 `Defaults.json`。超出的不可再撤销；撤销沿用现有保护，不覆盖后续用户修改。一个批次无论包含多少项都只算 1 步。
5. **不要默认数据。** 首次启动是空的，不再载入演示数据；演示数据只留在测试和预览。
6. **不要置信度。** 协议、校验、配置里去掉 `confidence`、0.90 和 0.15。模型判断什么就预览什么，由用户确认。
7. **AI 协议与上下文扩展。**
   - 上下文：所有未归档计划；每个计划的全部阶段（id、名称、状态、起止）；任务带 `parent_id`、`stage_id`、起止；已有重复模板摘要。条目超限时保证祖先任务不被截断。
   - 输出：`create_plan` 可带阶段和多级子任务，用批内临时引用（`ref` / `stage_ref` / `parent_ref`）表达，落盘时换成真实 id；`create_task` 可带 `plan_id`、`stage_id`、`parent_task_id`；可直接带重复规则；时间用 `start_at` / `end_at`（见 `time.md`）。
   - 重复任务遵循 `task-file.md` 的步骤规则：
     - 带重复规则的 `create_task` 只能用 `steps` 表达子项，不能带普通子任务（`children` / `parent_ref`），否则校验报错；
     - 带重复规则时不允许 `parent_task_id` / `parent_ref`，重复任务不能放在其他待办下；
     - 对已有且带普通子任务的待办设为重复，第一版直接拒绝并提示手动设置（手动路径经 `ConvertSubtasksToSteps` 与 `CreateRecurrence` 同批提交）。
   - 批内临时引用校验：不允许重复 `ref`、悬空引用、循环引用，以及父子跨计划或跨阶段；落盘按依赖顺序写入同一批次。
   - 仍保留：只能引用上下文中出现的 id、`source_span` 逐字引用、条目上限、结果不能绕过结构校验（`StructurePolicy`、`ProposalValidator`）。
8. **收件箱改为「AI 整理记录」。**
   - 按时间列出每次输入：原文、AI 做了什么、状态（已应用 / 待确认 / 失败 / 已撤销）。
   - 失败可重试或改文字，待确认项可重新打开预览，窗口内可撤销。
   - 没有 Key 或关闭 AI 时，原文照常保存并提示去设置；没有本地兜底。
   - 同步冲突迁到设置的同步页，系统建议迁到回顾页；`movo://inbox` 深链保持可用，转到整理记录。

## Todo list

- [x] 隐私与规则
  - [x] 删除 `PrivacySplitter`、`LocalDirectRouter` 及其调用方（`ProposalService`、`AppEnvironment+Capture.swift`）。
  - [x] 删除 `HealthKeywords.json`、`ConfigLoader.loadHealthKeywords`、`ProposalService` 的 `healthKeywords` 参数、`assertNoRestrictedContent`。
  - [x] 清理 `ProposalService.prepare` 与 `localOnlyPreparation`：原文原样发送；AI 关闭或无 Key 时只保存原文。
  - [x] 清理 `AIContextBuilder` 中受限标题、受限关键词、排除词的过滤参数。
- [x] 全局 AI 开关
  - [x] `AISettingsStore` 增加全局开关；设置页开关，开启时与首次使用 AI 输入时各告知一次。
  - [x] 移除计划级入口：`PlanEditScreen`、`PlanDetailScreen`、`SettingsSections` 的开关，以及 `PlanPatch.touchesCloudAISwitch`。
  - [x] 移除所有读取 `cloudAIEnabled` 的判断：
    - [x] `AIContextBuilder` 的 `cloudAIEnabled` 过滤（仍只取未归档计划）；
    - [x] `ProposalValidator` 的 `planNotCloudAIEnabled` 拒绝及 `MovoError` 对应分支；
    - [x] `CaptureSheets` 的计划候选过滤；
    - [x] `Rows`、`PlanSummary`、`isLocalOnly` 的「仅本机」标识，`ReviewScreen` 的相关说明。
  - [x] `Plan.cloudAIEnabled` 与 `PlanCategory.defaultsCloudAIEnabled` 仅保留存储与同步兼容；用搜索确认无其他读取。
- [x] 上下文（`AIContextBuilder`）
  - [x] 范围：所有未归档计划及其全部阶段（id、名称、状态、起止）。
  - [x] 任务字段：`parent_id`、`stage_id`、`start_at` / `end_at`；已有重复模板摘要（含步骤摘要）。
  - [x] 截断：超出条目上限时保证被保留任务的祖先不被截断。
  - [x] 更新 `AIContextBuilder.instructions`：`ref` 规则、重复规则，删除关于 `confidence` 的说明。
- [x] 协议（`AIProposal`）
  - [x] `create_plan` 可带阶段和多级子任务，用 `ref` / `stage_ref` / `parent_ref` 表达批内引用。
  - [x] `create_task` 增加 `plan_id`、`stage_id`、`parent_task_id`、重复规则与 `steps`；核对 `start_at` / `end_at` 在 JSON schema 中完整。
  - [x] 删除 `confidence`：`AIProposal` 字段、JSON schema 的 `required`、`OpenAICompatibleAdapter` 解析；旧响应与已保存提案（`CaptureReplay`）里多余的 `confidence` 仍可解码并忽略。
- [x] 校验与物化
  - [x] 去掉置信度阈值降级：`Defaults.json` 的 `classification_confidence_threshold`、`classification_margin_threshold`，`AppDefaults.AI` 对应字段，`ExecutionPolicy.canAutoClassify` 与 `ExecutionContext` 的置信度字段，`ProposalValidator` 与 `ProposalService` 中的相关判断。
  - [x] 去掉直接落库路径：AI 结果统一进入预览，不再有自动执行例外。
  - [x] 去掉阶段拒绝：`create_task` 允许 `stage_id`，归属与层级改走 `StructurePolicy`。
  - [x] 批内引用解析：校验 `ref` 重复、悬空、循环、跨计划或跨阶段父子；按依赖顺序写入同一原子批次，落盘时换成真实 id。
  - [x] 重复规则：只允许 `steps`，不允许普通子任务和父节点；已有带子任务的待办设为重复直接拒绝。
  - [x] 核对能否复用 `PlanFile` 结构与导入预演。
- [x] 预览
  - [x] 预览数据：把提案整理成计划 / 阶段 / 任务树，含父子层级与起止时间。
  - [x] 预览页：复用 `BulkPreviewScreen` 与计划预览，展示整棵树。
  - [x] 逐项取消：取消父项级联取消后代，后代置灰且不可单独勾选。
  - [x] 确认写入：未取消的部分作为一个批次写入；整理记录显示「已应用（部分）」，可重新打开预览补回被取消项。
- [x] 回退步数
  - [x] 配置：`Defaults.json` 增加 `undo_steps`（默认 5），同步 `AppDefaults` 的加载与回退默认值。
  - [x] 限制：`DomainStore.undo(batchID:)` 只允许最近 N 个已应用批次（手动与 AI 批次统一计数）；撤销条（`AppEnvironment.undoLastBatch`）与整理记录页同步该限制。
  - [x] 部分冲突：撤销遇到后续用户修改时批次仍可重试，不覆盖较新的修改。
- [x] 启动数据：移除 `MovoApp.bootstrap` 里的 `DemoFixtures.seedIfEmpty`；`DemoFixtures` 仍供预览和测试使用；设置页调试开关按需保留。
- [x] 迁移入口（先于删除 `InboxScreen`）
  - [x] 同步冲突：入口迁到设置的同步页（复用 `ConflictResolutionScreen`）。
  - [x] 系统建议：入口迁到回顾页；`ReviewScreen` 对 `InboxScreen.timeText` 的引用改为共享的时间格式化。
- [x] 整理记录页
  - [x] 数据模型与持久化（`Capture` / `DomainStore`）：
    - [x] `CaptureState` 规范状态：`pendingConfirmation`（待确认）、`aiSucceeded` / `aiPartial`（已应用）、`aiFailed` / `saved`（失败或无 Key 原文已存）、`undone`（已撤销），保持解码向后兼容；
    - [x] 提案持久化：`Capture` 增加可选字段持久化提案数据（避免纯依赖 `UserDefaults` 丢失待确认项），旧数据解码赋 `nil`；
    - [x] 关联写入批次：`Capture.batchId` 关联 `OperationBatch`，供检查撤销状态及执行回退。
  - [x] 查询层（`DomainStore+Queries` / `Views`）：
    - [x] 新建 `OrganizeRecord` 视图模型（原文、AI 动作摘要、状态、生成时间、是否可预览、是否可撤销、是否可重试）；
    - [x] 新增 `organizeHistory()` 查询，按 `capturedAt` 倒序返回记录；
    - [x] 清理旧 `inbox()` 查询及 `InboxView`、`InboxUnclassified`、`InboxRejected`。
  - [x] 页面与交互（`OrganizeHistoryScreen`）：
    - [x] 新建页面展示按时间排列的输入卡片，显示原文、AI 动作摘要与状态徽标；
    - [x] 待确认项：支持点击重新打开预览（唤起 `BulkPreviewScreen`）继续确认落盘或逐项取消；
    - [x] 失败项：支持点击重试或编辑文字重试；
    - [x] 窗口内已应用项：批次在最近 N 步之内时提供撤销操作，整批回滚并更新为已撤销；
    - [x] 无 Key 或关闭 AI 项：保留原文并展示引导「前往设置配置 AI」。
  - [x] 入口与路由迁移：
    - [x] 待办页（`TodayScreen`）顶栏增加整理记录入口图标；
    - [x] Mac 侧边栏保留 `.inbox` 路由，展示文案更新为「整理记录」，图标更新；
    - [x] `RecoveryAction.viewInbox` 文案更新为「查看整理记录」，跳转到新页面；
    - [x] `ScreenHost` 中 `.section(.inbox)` 映射到 `OrganizeHistoryScreen`，保持 `movo://inbox` 深链可用；
    - [x] 删除 `InboxScreen.swift`。
- [x] 测试
  - [x] 删除：`PrivacyTests` 中 `PrivacySplitter`、`LocalDirectRouter` 用例，`AIPlanningRegressionTests` 对 `PrivacySplitter` 的依赖与低置信度用例，`AdapterTests` 中仅为 `confidence` 服务的断言。
  - [x] `MovoDomainTests`：阶段归属、批内父子引用、`ref` 重复 / 悬空 / 循环、AI 带重复规则（仅步骤，带普通子任务或父节点被拒）、预览取消项级联与整批撤销、回退步数。
  - [x] `MovoAdapterTests`：旧响应带 `confidence` 仍可解码、请求契约（上下文含阶段、父子、重复模板）。
  - [x] `MovoPrivacyTests`：原文原样发送、AI 关闭不发请求。
  - [x] 空启动无数据。
- [x] 文档
  - [x] `AGENTS.md`：隐私边界与 AI 约束。
  - [x] `docs/PRD.md` 5.2 与 11.2。
  - [x] `docs/AI-Todo-Pipeline.md`、`docs/Development.md`、`README.md`。
  - [x] `docs/UI-Prompt.md` 与 `docs/design/Movo.pen`：更新 UI Prompt 说明与设计稿（已落地 D05/M05 AI 整理记录、D04-Result 写入预览确认、M02-Cascade 级联取消状态）。

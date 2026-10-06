# 统一起止时间（startAt / endAt）

## 背景

- 任务现有 `scheduledDate`（只到天）、`hardDeadline`（到时刻）、`timeHint`（早/中/晚或 HH:mm，仅展示）三套时间字段，语义分散。
- 计划、阶段只有 `targetDate`（只到天），没有开始时间。
- 重复规则只有有效期 `effectiveFrom / effectiveUntil`，没有每天几点开始、几点结束。
- 重复模板（如「每天早上背单词」）不产生任何提醒：`NotificationPlanner` 只处理非模板任务。
- 很多计划、任务只是暂存的想法，时间不清晰，之后再补；现有模型无法区分「没想好」和「某一天」。

## 期望

1. **统一字段。** 计划、阶段、任务都用 `startAt` / `endAt`，均可选。两者都空表示暂存想法；只有开始表示「从何时开始」；只有结束表示「截止」。
2. **带粒度的时间点。** 取值为「某一天」（`DateOnly`）或「某一时刻」（`DateTimeTZ`，存到秒，界面到分钟）。这样不必用 `00:00:00` 约定表示全天，也符合「不用裸 `Date` 代替某天」的规则。
3. **取代旧字段。** `scheduledDate`、`hardDeadline`、`timeHint`、`Plan.targetDate`、`Stage.targetDate` 由新字段取代，读取旧数据时自动映射：
   - 安排日期 → `startAt`（某一天）；有精确 `timeHint` 时 → `startAt`（某一时刻）。
   - 硬截止 → `endAt`（某一时刻）。
   - 计划、阶段的 `targetDate` → `endAt`（某一天）。
   - 「早上/晚上」等无精确时刻的提示直接丢弃，只保留某一天，不虚构时刻，也不新增「时段」字段；重复模板的每天时刻留空，由用户之后补。
4. **校验。**
   - `endAt` 不早于 `startAt`。
   - 子级时间必须落在父级范围内，否则拒绝保存，不存在「超出也能落盘」的情况。层级为：计划 ⊃ 阶段 ⊃ 任务 ⊃ 子任务；任务没有阶段时以计划为父级。
   - 父级对应一端为空时，该端不约束（暂存想法不受限）。比较时「某一天」按其所在时区的整天计算。
   - 缩小父级时间时，若已有子级会因此越界，同样拒绝并提示先调整子级。
   - 重复规则的有效期同样必须落在所属计划、阶段范围内。
   - 手动创建、AI 创建、导入走同一套校验；AI 创建在预览阶段就显示不合法项。
   - 计划和阶段的时间不从子任务自动推算。
5. **定时任务不单独建类型。** 「周五 15:00 开会」就是 `startAt` 为某一时刻的单次任务。
6. **重复任务带每天的起止时刻。** `RecurrenceRule` 增加每次的开始时刻和结束时刻（可选，无则全天）；`effectiveFrom / effectiveUntil` 继续表示有效期。每次实例的起止由「实例日期 + 时刻」生成，按该日所在时区解释（跟随设备，不固定旅行前的时区）。
7. **提醒按新字段重算。**
   - 某一时刻的 `startAt`：按提前量准点提醒。
   - `endAt`：沿用「提前 N 天 + 当天」的截止提醒。
   - 某一天：沿用当天默认时刻提醒。
   - 重复实例按规则时刻提醒；`weeklyCount` 无固定日期，不做定点提醒。
8. **「今日」仍只是日期筛选。** 按 `startAt` / `endAt` 所在日期判断，不改一级入口「待办」。
9. **AI 自行判断时间。** AI 输出同样使用 `start_at` / `end_at`；认为合适就填，没把握就留空。不做任何规则映射（如「早上 = 12:00」），不放进配置，只在提示词里给出指引。

## Todo list

- [x] 确认粒度方案：`startAt/endAt` 用「日 / 时刻」联合类型 `TimePoint`。
- [x] 领域模型：`Task`、`Plan`、`Stage` 改用新字段，`RecurrenceRule` 增加每天起止时刻（`Domain/Models`）。
- [x] 命令与校验：`CreateTask`、`TaskPatch`、`CreatePlan`、`PlanPatch`、`CreateStage`、`UpdateStage`、`CreateRecurrence`、`ChangeRecurrence`；加入 `endAt >= startAt` 与「子级落在父级范围内」校验（放在 `StructurePolicy`），含缩小父级时的反向检查和重复规则有效期检查。
- [x] 历史与同步中的越界：迁移不改用户数据、已有越界数据只在下次改时间时要求修正；多设备同步合并无法拒绝，越界数据照常接收，任务详情页顶部提示「时间超出了范围」（只提示，不拦截）。
- [x] 重复实例：`RecurrencePolicy` 按「日期 + 每天时刻」生成实例起止，规则修改仍只作用于 `effectiveFrom` 及以后。
- [x] 查询：「今日」、待办筛选、逾期判断、计划进度按新字段重写（`Domain/Queries`）。
- [x] 提醒：`NotificationPlanner` 改用新字段，补上重复实例提醒；`Defaults.json` 参数沿用，提醒生成的测试待补。
- [x] 存储与同步：`LocalAdapter`、`FieldMerge` 字段名；索引列沿用不迁移；实体层读取旧字段；事件和撤销载荷里的旧字段名仍能解码。
- [x] 界面：新建与编辑任务、计划、阶段的时间选择器（可清除、可只填一端、可选「精确到时刻」）；重复规则的每天时刻；任务大纲、详情、批量预览的展示。
- [x] 导出与演示数据同步改字段（见 `task-file.md`）。
- [x] AI 提示词：在 `AIContextBuilder.instructions` 里说明 `start_at` / `end_at` 的含义与取舍，没把握就不填。
- [x] 测试：已补旧数据迁移（任务、计划）、重复实例时刻、子级越界被拒、缩小父级被拒、父级一端为空不约束、起止倒置被拒；同步旧格式解码、跨时区、提醒生成（`NotificationPlannerTests`、`FieldMergeTests`、`PolicyTests`）。
- [x] 文档：`AGENTS.md`、PRD、`docs/Development.md`、`docs/AI-Todo-Pipeline.md`、`README.md` 已更新；设计稿 `Movo.pen` 和 `docs/UI-Prompt.md` 已更新。

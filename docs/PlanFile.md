# Movo 文件（.movo.json）

Movo 的导入与导出共用同一种 JSON 文件：扩展名 `.movo.json`，当前 `schemaVersion` 为 1。实现见 `Movo/Data/Export/PlanFile.swift`（结构、导出、空模板）与 `PlanFileImport.swift`（导入）。设置页「导入 / 导出」里可以下载一份带字段说明的空模板，也可以连同你的需求一起交给 AI 生成内容。

文件可以是一整套计划，也可以只是一部分内容：计划、阶段、任务、指标、行动记录、测量值、笔记都能单独导入，单独的阶段、指标、记录、测量值在导入时选择放进哪个已有计划。

示例文件在 `docs/samples/`：`full-plan.movo.json`（计划 + 阶段 + 多级任务 + 重复行动与步骤 + 前置 + 记录等）、`partial-into-existing-plan.movo.json`（只有阶段、指标、任务、测量值，导入到已有计划）、`invalid-demo.movo.json`（故意写错，看预览如何标出）。测试会读取这三份。

## 设计原则

- **交换，不是备份**：只含结构和计划内容；永不包含 API Key、音频、设备标识，也不含「允许云 AI」「云同步」这类本机隐私开关（导入后按分类默认值设置）。
- **默认只导出结构**：计划、阶段、任务（多级子任务）、重复规则及步骤、独立待办、指标定义。行动记录、测量值、笔记是可选项，导出页里默认不勾选。
- **导入不信任文件**：每个条目走与手动创建相同的命令和 `StructurePolicy` 校验；不合法的条目在预览里逐条标出，通过检查的部分仍可导入。
- **一个批次写入**：确认后通过 `DomainStore` 作为一个批次写入，结果条里可以撤销。

## 结构

```json
{
  "format": "movo.plan-file",
  "schemaVersion": 1,
  "exportedAt": "2027-01-15T08:00:00Z",
  "application": "Movo",
  "plans": [ { "...": "见下" } ],
  "tasks": [ { "...": "不属于任何计划的独立待办；导入时可选放进已有计划" } ],
  "stages": [ { "name": "只补充阶段：导入时选择放进哪个已有计划" } ],
  "metrics": [], "records": [], "measurements": [],
  "notes": [ { "text": "不属于任何计划的笔记；导入时可选放进已有计划" } ]
}
```

顶层的 `stages`、`metrics`、`records`、`measurements` 必须选择目标计划才能导入，没选时在预览里逐项报错；`tasks`、`notes` 没选目标计划时作为独立内容导入。放进已有计划时，`stage` 可以引用该计划已有阶段的名称或 id，`dependsOn`、记录的 `task` 可以引用该计划已有任务的 id，时间范围按该计划已有内容校验。顶层 `tasks` 还可以放在该计划里某个任务下作为子任务（导入页「放在哪个任务下」）；上级必须是未完成的普通待办，重复行动和已完成的任务不能作为上级。

除 `format`、`schemaVersion` 和各处的 `name` / `title` 外，其余字段都可以省略；以下划线开头的键（如 `_说明`）会被忽略，可用来写注释。

### 计划 `plans[]`

| 字段 | 说明 |
| --- | --- |
| `id` | 可选，文件内的标识。用于互相引用，也用于识别重复导入 |
| `name` | 必填 |
| `kind` | `delivery`（缺省）/ `improvement` / `maintenance` |
| `category` | `work` / `study` / `health` / `life`，可省略 |
| `goal`、`aliases` | 目标说明、别名 |
| `startAt`、`endAt` | 起止时间，见「时间写法」 |
| `stages[]` | `id`、`name`、`criteria`、`startAt`、`endAt` |
| `metrics[]` | `id`、`name`、`unit`、`targetValue`、`direction`（`increase` / `decrease` / `none`） |
| `tasks[]` | 任务，见下 |
| `records[]`、`measurements[]`、`notes[]` | 可选内容，见下 |

### 任务 `tasks[]`

| 字段 | 说明 |
| --- | --- |
| `id`、`title` | `title` 必填 |
| `notes`、`tags`、`estimateMinutes`、`priority`（`low` / `normal` / `high`） | 可选 |
| `startAt`、`endAt` | 起止时间；子级必须落在上级范围内（任务 ⊂ 阶段 ⊂ 计划） |
| `stage` | 阶段的 `id` 或名称；子任务跟随上级的阶段 |
| `status` | `todo`（缺省）/ `inProgress` / `blocked` / `done` / `cancelled`。只对叶子待办生效；有子任务的由子任务汇总 |
| `dependsOn` | 前置任务的 `id` 列表，必须在同一个计划内 |
| `children` | 多级子任务，结构同任务 |
| `recurrence` | 有它就是重复行动，见下 |
| `steps` | 重复行动的多级步骤：`{ "id", "title", "children": [步骤] }` |

重复行动不能有 `children`，普通待办不能有 `steps`；重复行动不能放在其它待办下面。

### 重复规则 `recurrence`

`pattern`（`daily` / `weekdays` / `weeklyCount`）、`weekdays`（1–7，周一到周日）、`weeklyCount`（1–7）、`effectiveFrom`（缺省为导入当天）、`effectiveUntil`、`dailyStart`、`dailyEnd`（`HH:mm`，缺省表示全天）。

### 可选内容

- `records[]`：`task`（任务 `id`）、`at`（日期或带时区时刻）、`minutes`、`text`。
- `measurements[]`：`metric`（指标 `id` 或名称）、`at`（日期）、`value`、`note`。缺测不要补 0，不写即可。
- `notes[]`：`text`、`kind`（`idea` / `decision` / `memo`）。

### 时间写法

某一天写 `2027-06-30`；某一时刻写带时区偏移的 `2027-06-30T18:00:00+08:00`。没有偏移时按导入设备当前时区解释。起止都可以不写。

## 导入规则

1. **解析**：`format` 必须是 `movo.plan-file`。`schemaVersion` 大于当前版本时提示升级 Movo；小于等于当前版本的文件可以导入（升级逻辑在 `PlanFileCodec.migrate`）。
2. **预演**：把文件转换成领域命令，在临时的 `InMemoryRepository` 里依次执行；失败的命令及依赖它的下级一并列入「需要注意」，其余命令保留。
3. **标识**：默认生成新 id，避免与已有数据或同步冲突。外部 id 是 UUID（Movo 导出的文件）时，映射到一个稳定的新 id；原 id 或映射后的 id 已存在，就认为已经导入过。重复的计划和独立待办可选择「跳过」（默认）或「另存一份」（全部使用随机新 id）。外部 id 不是 UUID（手写或 AI 生成的文件）时只在文件内互相引用，不做重复识别。
4. **写入**：通过的命令作为一个批次提交，可整批撤销。

### 不随文件带回的内容

- 计划和阶段的状态（进行中 / 已暂停 / 已归档、阶段达成）。
- 重复行动已发生的实例及其步骤勾选记录。
- 计划的「允许云 AI」「云同步」开关、AI 建议标记、变更历史。
- 已完成的任务导入后完成时间为导入时刻。 Movo 文件」；macOS 另有「文件 → 导入 Movo 

## 平台入口 Movo 

- **导入**：设置 → 导出 / 导入 →「导入计划文件」；macOS 另有「文件 → 导入计划文件…」（⌘O）；也可以在 Finder / 文件 App / 其它 App 里选「用 Movo 打开」，Movo 会跳到导入页并预览。
- **导出**：导出页「存储为文件」走系统保存面板，「分享」走系统分享面板（iPhone 分享表、Mac 分享菜单）。
- **文件类型**：系统只按最后一段扩展名识别，`.movo.json` 会被当成 `.json`，所以没有注册自定义 UTType，而是在 `project.yml` 里把 Movo 登记为 JSON 的备选打开方式（`CFBundleDocumentTypes`，`LSHandlerRank: Alternate`）。是不是计划文件由导入页检查 `format` 字段，不是的会提示。

## 尚未实现

- YAML 转换（作为后续的外部转换，不引入第三方依赖）。

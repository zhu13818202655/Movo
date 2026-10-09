# Movo · Development 开发概述

> 读者假设：熟悉 Python / Go，不熟悉 Swift 与 Apple 工程体系。
> 本文只回答两个问题：**代码在哪**、**怎么构建 / 运行 / 调试**。
> 需求文档见 `PRD.md`，视觉稿见 `design/Movo.pen` + `UI-Prompt.md`。

---

## 0. 速览

### 添加与 AI 整理排障

当前待办页的手动入口位于筛选下面；Mac 顶部与 iPhone 底部 AI 按钮均进入统一整理流程。完整流程见 [AI 构建待办流程](AI-Todo-Pipeline.md)。

“提交完成但没有看到创建”应区分以下情况：

- 原文已保存但 AI 请求、解析或写入失败：结果面板显示原因和重试入口，不计为创建成功。
- 新建整个计划：必须先在结果面板确认预览，再同时创建计划与初始待办。
- 健康或未许可内容：保留在本机，明确显示需要手动处理。
- 当前日期筛选不包含新任务：切换到全部，或点击保存提示中的查看入口。

历史实现中的三个原因已修正：未关联计划的新任务被策略拦在待确认、请求未附完整输出 Schema、新建计划缺少模型动作。另修正结果页用待执行命令数量代替实际成功数量，以及转写修改未传入处理流程的问题。

整理草稿和模型提案使用本机偏好存储（不含 Key）；原文、操作与批次仍通过领域命令写入本地仓库。回放提案仍经过校验，命令使用由采集标识与事项标识生成的稳定操作 ID；计划及初始待办采用一个原子批次。打开结果只恢复状态，不自动重试未保存操作。该本机提案缓存不随 CloudKit 同步，其他设备可查看已同步的领域数据，但不能恢复此设备尚未确认的提案。

固定响应回归覆盖独立待办、中文/emoji 原文定位、计划预览与确认、原子回滚、重试幂等、实际成功计数和请求契约。新增源码后需先重新生成工程，再按仓库完整验证流程运行。Windows 的语法解析与差异检查不能代替 Xcode 编译、Swift 单测及设备验收。

设备验收可依次输入“明天买牛奶”和“建立搬家计划，整理物品、预约搬家公司”，核对第一条自动创建、第二条确认后创建、重试不重复、撤销与后续编辑冲突提示；另检查语音停止后编辑、收起重开、键盘、大字号和 iPhone 底部安全区。

| 项 | 值 |
|---|---|
| 产品 | 个人待办 + 长期目标管理。一句话输入 → AI 整理成计划/任务 → 预览确认后写入 → 长期跟踪；全局 AI 开关与最近 5 步撤销 |
| 形态 | **单工程双端**：同一份 Swift 代码编译出 iOS 与 macOS 两个 App |
| 语言 | Swift 6，`SWIFT_STRICT_CONCURRENCY=complete`，`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| UI | SwiftUI（声明式，类似 Flutter，无 Storyboard / XIB） |
| 持久化 | SwiftData（Apple 官方 ORM，类似自带迁移的 Core Data 封装） |
| 云同步 | CloudKit（**默认关闭**，见 §7） |
| 最低系统 | iOS 26.0 / macOS 26.0 |
| 工程文件 | 由 **XcodeGen** 从 `Movo/project.yml` 生成；`Movo.xcodeproj` 是产物，不要手改 |
| Target | 2 个：`MovoKit`（framework，业务逻辑）+ `Movo`（application，UI）；外加 5 个测试 bundle |

### 三条必须先建立的认知

1. **`.xcodeproj` 是生成物。** 任何工程设置（bundle ID、签名、Info.plist 键、编译开关）都改 `Movo/project.yml`，然后重新生成。直接改 Xcode 里的设置，下次生成即被覆盖。
2. **代码分两层。** `MovoKit` 包含领域、数据、智能层与共享设计组件，`DesignSystem` 使用 SwiftUI；`Movo` target 负责页面与装配。`Domain` 通过仓库协议隔离存储，不依赖 UI 或 SwiftData，可以用内存仓库验证业务行为。
3. **改了 `project.yml` 或增删文件后，必须先 `xcodegen generate`。** 否则 Xcode / xcodebuild 看不到新的文件。

---

## 1. 目录结构

### 1.1 仓库顶层

```
/Users/louis/codes/movo/
├── .gitignore                 ← 忽略构建产物与生成的工程（见下）
├── Movo/                      ← 全部源码（下文展开）
├── Tests/                     ← 单元测试，5 个 target，独立于 Movo/ 之外
├── Scripts/
│   ├── verify.sh              ← 一键构建 + 全量测试脚本
│   └── generate-app-icons.py  ← 重新生成 App 图标（仅改图标外观时才需要）
├── docs/                      ← PRD、开发概述、设计稿
│   ├── PRD.md
│   ├── AI-Todo-Pipeline.md    ← AI 构建待办流程
│   ├── UI-Prompt.md
│   ├── Development.md         ← 本文
│   └── design/Movo.pen        ← 设计稿（Pencil 格式），画板编号 D01–D10 / M01–M14
└── .build/                    ← 构建产物（可随时删除）
    ├── DerivedData/           ← macOS 构建 + 全部单测
    ├── DerivedData-iOS/       ← iOS 模拟器构建
    ├── DerivedData-iOS-Device/ ← iOS 真机构建
    └── logs/                  ← verify.sh 的日志
```

### 1.2 版本控制约定

`.gitignore` 已就位。入库 111 个文件，全部是源码、配置、资源与文档；**构建产物与生成的工程一律不入库**。被忽略的关键项：

| 忽略项 | 原因 |
|---|---|
| `.build/`、`.derived/`、`DerivedData*/` | 构建产物 |
| `Movo/build/`、`Movo/build-ios/` | xcodebuild 未指定 `-derivedDataPath` 时的默认输出 |
| `Movo/Movo.xcodeproj/` | **由 `project.yml` 生成**，不入库 |
| `xcuserdata/`、`*.xcuserstate` | Xcode 个人状态 |
| `.DS_Store`、`.vscode/`、`.idea/` | 系统与编辑器杂项 |
| `*.p12`、`*.mobileprovision`、`.env*` | 凭据，防误提交 |

> **克隆后必须先做一步**：因为 `Movo.xcodeproj` 不入库，直接打开工程会失败。
>
> ```bash
> cd /Users/louis/codes/movo/Movo && xcodegen generate --spec project.yml
> ```
>
> 同理，任何人对 `project.yml` 的改动，都需要重新执行这条命令才能生效。
>
> 注意 `Movo/Resources/*.entitlements`、`Movo/Config/*.json`、`Movo/project.yml` **是**源码，必须入库；签名与 iCloud 的配置正落在这些文件里（见 §7）。
>
> 若希望跨机器共享 VS Code 的任务与调试配置，删掉 `.gitignore` 里的 `.vscode/` 一行即可。

### 1.3 清理构建产物

`Movo/build/`（98 MB）、`Movo/build-ios/`（63 MB）、`Movo/.derived/`（112 MB）、`Movo/.build/`（5 MB）是散落在源码目录内的中间产物，与上面的 `.build/` 无关，可直接删除：

```bash
rm -rf /Users/louis/codes/movo/Movo/build \
       /Users/louis/codes/movo/Movo/build-ios \
       /Users/louis/codes/movo/Movo/.derived \
       /Users/louis/codes/movo/Movo/.build
```

### 1.4 完整源码树

```
Movo/
├── project.yml                       ★ 工程定义（唯一的真相源）
├── Movo.xcodeproj/                   生成物，勿手改
│
├── ── MovoKit（framework，业务逻辑，无 UI）────────────────────
├── Domain/                           领域层：模型 / 命令 / 查询 / 策略
│   ├── Models/                       Entities.swift（3.2 实体字段表）、ValueTypes.swift（3.1 值类型）
│   ├── Commands/                     全部写操作（唯一写入口；DomainStore.swift 即唯一写入者）
│   ├── Queries/                      只读视图（页面只读这里）
│   ├── Policies/                     业务规则：结构约束 / 重复规则 / 进度口径 / 依赖
│   ├── Repository/                   DomainRepository.swift（仓储协议，不依赖 SwiftData）
│   ├── Support/                      Clock/TimeZone 注入、DemoFixtures（预览/测试 fixture）
│   ├── Support.swift                 ConfigLoader（读 Config/*.json 的入口）
│   └── MovoError.swift               错误模型（每个 case 绑定固定文案）
│
├── Data/                             数据层：实现 Domain 的仓储协议
│   ├── Local/                        SwiftData 落盘、@Model 映射、领域↔存储转换
│   ├── Sync/                          CloudKit 同步（默认关闭）
│   └── Export/                       导出 Markdown / `.movo.json`，导入 `.movo.json`（见 docs/PlanFile.md）
│
├── Intelligence/                     智能层：AI 调用 + 隐私 + 语音
│   ├── Providers/                    厂商适配（内置 DeepSeek + 自定义 OpenAI 兼容）、Keychain、超时重试
│   ├── Planning/                     提案契约 / 校验 / 执行策略 / 物化
│   ├── Privacy/                      隐私分流 / 云上下文构建 / 本地直执
│   ├── Speech/                       本机语音转写
│   └── Support/                      日志脱敏
│
├── Notifications/                    本地通知：排期计算 + 系统投递
├── DesignSystem/                     设计令牌 + 通用组件（按钮/行/图表）
│   └── Components/
├── Config/                           运行时 JSON 配置（作为资源打进 MovoKit）
│   ├── Defaults.json                 通知时刻、回退步数、超时等易变参数
│   └── ModelsCatalog.json            内置厂商的 chat completions 端点与模型清单
│
├── ── Movo（application，UI 与装配）─────────────────────────
├── App/                              应用装配与外壳
│   ├── MovoApp.swift                 ★ 程序入口（@main），启动流程
│   ├── AppEnvironment.swift          ★ 依赖容器（全部服务的组装点）
│   ├── AppEnvironment+Capture.swift  输入管线 C1–C9
│   ├── NetworkMonitor.swift          联网恢复触发同步
│   ├── NotificationHandling.swift    点通知跳转深链
│   └── Navigation/                   路由与双端外壳
│       ├── Route.swift               全部页面枚举 + 画板对照
│       ├── Router.swift              跳转状态
│       ├── ScreenHost.swift          Route → 页面 的映射表
│       └── RootView.swift            双端布局外壳
│
├── Features/                         所有 UI 页面，按功能分区
│   ├── Today/                        待办（保留原目录名）
│   ├── Inbox/                        收件箱（AI 无法归类的内容）
│   ├── Plans/                        计划 / 任务 / 快照 / 频率 / 结果记录
│   ├── Review/                       周回顾
│   ├── Search/                       搜索
│   ├── Settings/                     设置 / 导出 / 最近删除 / 冲突裁决
│   ├── Capture/                      快速输入 / 录音 / 转写 / 整理中
│   └── Shared/                       页面骨架、表单控件、同步角标
│
├── Resources/
│   ├── Movo-iOS.entitlements         [签名][iCloud] iOS 权限声明
│   └── Movo-macOS.entitlements       [签名][iCloud] macOS 权限声明
└── Assets.xcassets/                  图标与强调色
    ├── AccentColor.colorset/         强调色（对应 MovoColor.primary）
    └── AppIcon.appiconset/           App 图标：iOS 1024 + macOS 16–512 全尺寸
```

### 1.5 分层与依赖方向

这是一个严格单向的依赖结构，读代码时按此方向理解：

```
        Features/            ← UI 页面。只读 Domain 的查询视图；
            │                  所有写入必须走 DomainStore.execute(命令)
            ▼
        App/                 ← 装配层。构造 AppEnvironment，把服务注入 UI
            │
            ▼
        Domain/              ← 纯业务。只 import Foundation，不碰 SwiftData / CloudKit / UI
            ▲
            │ 实现 Domain 定义的仓储协议
   ┌────────┴────────┬──────────────┬─────────────┐
 Data/          Intelligence/  Notifications/  DesignSystem/
 (SwiftData)     (AI/隐私)      (通知排期)       (令牌/组件)
```

实测依赖边界（用于判断代码改动是否越界）：

| 约束 | 实测结果 |
|---|---|
| `Domain/` 依赖框架 | **仅 `import Foundation`**。`DomainRepository.swift` 里出现的 "import SwiftData" 是注释文字，不是真实 import |
| `import SwiftData` 出现在 | 只有 `Data/Local/SwiftDataModels.swift`、`Data/Local/SwiftDataRepository.swift` |
| `import CloudKit` 出现在 | 只有 `Data/Sync/CloudKitSyncBackend.swift` |
| UIKit / AppKit | 只在 3 处，且都包在 `#if canImport(...)` 里（复制到剪贴板、macOS 菜单栏）：`Features/Settings/ExportPreviewScreen.swift`、`Features/Settings/SettingsSections.swift`、`App/MovoApp.swift` |

**关键概念：命令式写入。** 与常见 iOS 写法不同，这里 UI **不直接改数据库**。任何状态变更都构造一个命令对象（如 `CreateTask`、`CompleteTask`），交给 `DomainStore.execute(_:)` 串行执行；每个命令在一个事务内完成「校验 → 写实体 → 追加变更事件 → 更新搜索索引」。这是排查「数据没更新」类问题的第一条线索：先确认页面有没有真的发出命令。

### 1.6 Domain：业务核心

| 文件 | 职责 |
|---|---|
| `Domain/Models/Entities.swift` | 全部实体字段定义（Plan / Task / Occurrence / Metric / …），均为值类型 |
| `Domain/Models/ValueTypes.swift` | `DateOnly` 与 `DateTimeTZ` 是**两种独立类型**，`TimePoint` 把它们联合成「某一天 / 某一时刻」，作为计划、阶段、任务的 `startAt` / `endAt`；不要用裸 `Date` 表示某天 |
| `Domain/Commands/DomainStore.swift` | **唯一写入者**。`@MainActor` 隔离，所有写操作经此排队 |
| `Domain/Commands/TaskCommands.swift` | 任务增删改：`CreateTask` / `ScheduleTask` / `SetDeadline` / `CompleteTask` / … |
| `Domain/Commands/PlanCommands.swift` | 计划增删改 + 暂停/恢复/删除/恢复实体 |
| `Domain/Commands/RecurrenceCommands.swift` | 重复规则与周期实例（完成当次不影响未来） |
| `Domain/Commands/RecordCommands.swift` | 行动记录与结果测量（补记不改录入时间；记录投入 ≠ 任务完成） |
| `Domain/Commands/StageMetricCommands.swift` | 阶段与结果指标 |
| `Domain/Commands/DependencyCommands.swift` | 任务依赖（同计划内、不自引用、不成环） |
| `Domain/Commands/MiscCommands.swift` | 原文落库、AI 建议的接受/忽略、冲突裁决、回顾笔记 |
| `Domain/Policies/StructurePolicy.swift` | 硬约束 C1–C9，保存前校验，违反即拒绝 |
| `Domain/Policies/ProgressPolicy.swift` | 进度口径：交付型/持续型算法不同，持续型不显示 100% |
| `Domain/Policies/RecurrencePolicy.swift` | 周期实例的惰性实例化 + 周进度 |
| `Domain/Policies/DependencyPolicy.swift` | 依赖状态派生（只提示不阻断） |
| `Domain/Queries/*.swift` | 页面用的只读视图类型与查询实现 |
| `Domain/Support.swift` | `ConfigLoader`（读 `Config/*.json`）、可注入时钟 |
| `Domain/Support/DemoFixtures.swift` | 预览与测试用的固定 fixture；应用内没有装载入口，生产启动永远是空库 |

> **时间旅行**：`Domain/Support.swift` 提供可注入的 Clock。测试里用 `TravelClock` 锁定"今天"，因此 `DemoFixtures` 的日期固定在 2026-09-28。

### 1.7 Data：落盘与同步

| 文件 | 职责 | 标记 |
|---|---|---|
| `Data/Local/SwiftDataModels.swift` | 领域实体 → `@Model` 映射。设计：只把**可查询字段**（id / 归属 id / 状态 / 日期）做成独立列，其余字段整体以 Codable JSON 存进 `payload` 列 | |
| `Data/Local/SwiftDataRepository.swift` | 事务与写入路径。默认容器即落盘位置，见 §4.4 | |
| `Data/Local/LocalAdapter.swift` | `toDomain` / `fromDomain` 编解码（JSON payload ↔ 领域对象） | |
| `Data/Local/InMemoryRepository.swift` | 内存实现，供测试使用 | |
| `Data/Sync/CloudKitSyncBackend.swift` | CKSyncEngine 封装、记录映射、容器配置 | **[iCloud]** |
| `Data/Sync/SyncEngine.swift` | 出站/入站循环、防抖、重试、dirty 队列 | |
| `Data/Sync/SyncBackend.swift` | 后端抽象 + 内存实现（让同步逻辑可脱网单测） | |
| `Data/Sync/SyncRecords.swift` | CloudKit 记录 Schema（纯值类型，不 import CloudKit） | |
| `Data/Sync/FieldMerge.swift` | 字段级三方合并算法（纯函数） | |
| `Data/Sync/SyncEntityBox.swift` | 同步实体编解码盒子 | |
| `Data/Sync/TombstoneSync.swift` | 删除墓碑与 30 天内恢复 | |
| `Data/Export/ExportService.swift` | 导出 Markdown / Movo 文件；范围含计划与独立待办，记录 / 测量值 / 笔记由 `PlanFileOptions` 显式勾选，不再按 `cloudAIEnabled` 过滤 | |
| `Data/Export/PlanFile.swift` | `.movo.json` 结构、编解码与版本检查、导出构造、带说明的空模板 | |
| `Data/Export/PlanFileImport.swift` | 导入：解析 → 命令 → 临时 `InMemoryRepository` 预演 → 预览 → 一个批次写入；稳定 id 映射用于识别重复导入 | |
| `Domain/Policies/RecurrenceStepPolicy.swift` | 重复行动的步骤：快照、叶子进度、上级步骤汇总 | |

### 1.8 Intelligence：AI 与隐私

| 文件 | 职责 | 标记 |
|---|---|---|
| `Intelligence/Providers/AIKeyStore.swift` | API Key 存 Keychain，`ThisDeviceOnly`，不参与 iCloud Keychain 同步 | **[大模型]** |
| `Intelligence/Providers/AIProvider.swift` | 厂商适配契约（只做请求构造 + 响应解析） | **[大模型]** |
| `Intelligence/Providers/OpenAICompatibleAdapter.swift` | Chat Completions + `json_object` 结构化输出（内置与自定义厂商共用） | **[大模型]** |
| `Intelligence/Providers/AIProviderResolver.swift` | 把厂商与配置解析为端点/模型；自定义厂商未配全时抛 `providerNotConfigured` | **[大模型]** |
| `Intelligence/Providers/AISettingsStore.swift` | 厂商选择与自定义 Base URL／模型 ID 的本机持久化 | **[大模型]** |
| `Intelligence/Providers/AITransport.swift` | 超时（单次等待 60s / 总 120s）、重试、取消 | **[大模型]** |
| `Intelligence/Planning/ProposalService.swift` | 主流水线 C2→C7：原文原样发送，先预览后落盘；`ProposalRequest.globalAIEnabled` 为 false 时不触达任何 provider | **[大模型]** |
| `Intelligence/Planning/AIProposal.swift` | 模型输出契约（JSON Schema） | |
| `Intelligence/Planning/ProposalValidator.swift` | 校验清单：批内引用（ref）、直接写的 `stage_id` / `parent_task_id` 必须真实存在、重复行动不得挂在任何待办下、起止时间与步骤约束解析 | |
| `Intelligence/Planning/ProposalMaterializer.swift` | 确认后把待确认项按依赖拓扑物化为原子批次命令；子任务未声明阶段时继承父任务所在阶段（同一子树计划与阶段一致） | |
| `Intelligence/Privacy/ContextBuilder.swift` | 上下文构建：未归档计划、全部阶段、任务树、重复模板 | **[大模型]** |
| `Intelligence/Speech/SpeechTranscriptionService.swift` | 本机语音转写 | **[语音]** |
| `Intelligence/Support/RedactedLogger.swift` | 日志脱敏（只记元数据，不记正文/Key） | **[大模型]** |

### 1.9 App：装配与外壳

| 文件 | 职责 |
|---|---|
| `App/MovoApp.swift` | `@main` 入口。启动流程：装通知处理 → 空启动（不载入演示数据） → 启动同步 → 写通知排期 |
| `App/AppEnvironment.swift` | **依赖容器，改造项目的第一站**。所有服务（store / keyStore / speech / scheduler）在此组装；`live()` 是生产装配，`preview()` 是测试装配 |
| `App/AppEnvironment+Capture.swift` | 输入管线 C1 落库 → C2 全局 AI 开关与凭据预检 → … → C8 结果态 |
| `App/Navigation/Route.swift` | 全部页面枚举；`artboardName` 给出与设计稿的对应关系 |
| `App/Navigation/ScreenHost.swift` | **Route → 页面文件 的对照表**。想找某个界面在哪个文件，从这里查 |
| `App/Navigation/RootView.swift` | 双端外壳：iPhone 底部标签 / Mac 侧边导航 |
| `App/Navigation/Router.swift` | 跳转状态 |
| `App/NetworkMonitor.swift` | 联网恢复时触发同步 |
| `App/NotificationHandling.swift` | 点通知跳转到对应页面 |

### 1.10 Features：界面

`ScreenHost.swift` 是权威对照表，此处只列分区与代表文件：

| 目录 | 覆盖界面（设计稿画板） | 代表文件 |
|---|---|---|
| `Today/` | D01 / M01 待办 | `TodayScreen.swift` |
| `Inbox/` | D05 / M05 整理记录（历次 AI 输入流、待确认项唤起、回退与重试） | `OrganizeHistoryScreen.swift` |
| `Plans/` | D02 / M03 / M07 / M11 / M12 计划、任务、快照、频率、结果、时间线 | `PlansScreen.swift`、`PlanDetailScreen.swift`、`TaskDetailScreen.swift`、`SnapshotScreen.swift`、`RecurrenceScreens.swift`、`MeasurementScreens.swift` |
| `Review/` | D08 / M10 周回顾（7天分布、精力堆叠条、指标趋势微图） | `ReviewScreen.swift` |
| `Search/` | D10 / M06 搜索 | `SearchScreen.swift` |
| `Settings/` | M13 设置、导出预览、导入 Movo 文件、最近删除、冲突裁决 | `SettingsScreen.swift`、`SettingsSections.swift`、`ExportPreviewScreen.swift`、`ImportPlanScreen.swift`、`RecentlyDeletedScreen.swift`、`ConflictResolutionScreen.swift` |
| `Plans/NewTaskSheet.swift`、`Shared/TaskOutline.swift` | D04-Manual / M04-Manual 手动创建、M12-Subtasks 多级子任务 | `DomainStore+Todos.swift`、`TaskHierarchy.swift` |
| `Capture/` | D04 / M04 / M02 AI 输入、录音、转写、整理中、失败、批量预览 | `CaptureSheets.swift`、`CaptureStatusScreens.swift`、`BulkPreviewScreen.swift` |
| `Shared/` | 页面骨架与共用控件 | `Scaffold.swift`、`FormControls.swift`、`SettingsEntryButton.swift` |

### 1.11 Tests

| Target | 用例数 | 覆盖内容 |
|---|---|---|
| `MovoDomainTests` | 39 | 业务规则、结构约束、命令与查询、AI 错误模型 |
| `MovoDataTests` | 11 | SwiftData 仓储事务、编解码、round-trip |
| `MovoPrivacyTests` | 13 | 隐私分流、云上下文断言（不触网） |
| `MovoAdapterTests` | 29 | OpenAI 兼容适配器、厂商解析、自定义 Base URL 归一化、失败分类（用固定响应，不触网） |
| `MovoSyncTests` | 18 | 合并算法、同步循环、墓碑 |
| **合计** | **110** | |

用例数为当前快照，随迭代变动；以 `Scripts/verify.sh` 的实际输出为准。

测试全部在 **macOS 上运行**（不需要模拟器、不需要真机、不需要网络、不需要 Key）。这是本项目最高效的验证手段：改任何非 UI 逻辑，先跑这里。

### 1.12 「我该改哪个文件」定位表

| 现象 / 需求 | 首选位置 |
|---|---|
| 页面长什么样、布局错乱 | `Features/<分区>/` 对应文件，先用 `ScreenHost.swift` 定位 |
| 某个操作点了没反应 | `App/AppEnvironment.swift` + `Domain/Commands/` 对应命令 |
| 数据没存住 / 存错 | `Data/Local/`（`SwiftDataRepository` → `LocalAdapter` → `SwiftDataModels`） |
| 校验拦截了操作、报错文案 | `Domain/Policies/StructurePolicy.swift`、`Domain/MovoError.swift` |
| 进度百分比不对 | `Domain/Policies/ProgressPolicy.swift` |
| AI 输出解析失败 / 校验问题 | `Intelligence/Planning/ProposalValidator.swift`、`AIProposal.swift` |
| AI 请求失败 / 超时 | `Intelligence/Providers/AITransport.swift`、对应 Adapter、`Domain/AIFailureCause.swift`（失败原因文案） |
| 自定义厂商填了地址却连不上 | `Movo/project.yml` 的 `info:` 段（ATS 与本地网络权限），见 §7.3 与 §8 排障表 |
| 模型清单要增删 | `Config/ModelsCatalog.json` |
| 通知没响 / 时间不对 | `Notifications/NotificationPlanner.swift`（纯计算，可单测） |
| 同步冲突 | `Data/Sync/FieldMerge.swift` + `Features/Settings/ConflictResolutionScreen.swift` |
| 启动就崩 | `App/MovoApp.swift` 的 `bootstrap()` |
| 权限、签名、bundle ID 要改 | `Movo/project.yml`（见 §7） |

---

## 2. 环境准备

### 2.1 工作方式

| 工具 | 用途 |
|---|---|
| **VS Code** | 编辑代码、跑 Terminal 里的 `xcodebuild` / 测试脚本。日常开发主要在这里 |
| **Xcode** | 图形界面构建运行、真机部署与信任、断点调试器、查看崩溃日志、管理 Apple 账号 |

VS Code 打开 `/Users/louis/codes/movo` 即可。Swift 语法高亮可装 Swift 扩展，但**类型检查与补全以 Xcode 为准**（Swift 编译期元数据在 `.xcodeproj` 里，VS Code 默认拿不到完整信息）。

### 2.2 必要工具

```bash
xcodebuild -version          # 需要 Xcode 27.0 (27A266a)
xcodegen --version           # 需要 >= 2.46
xcrun devicectl --version    # 真机部署用，随 Xcode 提供
```

缺 XcodeGen 时安装：

```bash
brew install xcodegen
```

### 2.3 首次拉取后的步骤

`Movo.xcodeproj` 不入库（见 §1.2 版本控制约定），因此**拉取后第一件事是生成工程**：

```bash
cd /Users/louis/codes/movo/Movo
xcodegen generate --spec project.yml      # 生成 Movo.xcodeproj
cd .. && Scripts/verify.sh                # 构建双端 + 跑全部 75 个测试
```

全部通过说明环境就绪。

---

## 3. 构建与测试命令（VS Code Terminal）

以下命令都在仓库任意位置可跑（注意 `project.yml` 在 `Movo/` 目录内，**不在仓库根**）。

### 3.1 重新生成工程

```bash
cd /Users/louis/codes/movo/Movo && xcodegen generate --spec project.yml
```

**触发条件**：改动 `project.yml`；新增 / 删除 / 移动任何源文件；改了 entitlements 或 Info.plist 键。

### 3.2 macOS 构建

```bash
cd /Users/louis/codes/movo/Movo
xcodebuild build \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData
```

### 3.3 iOS 模拟器构建

```bash
cd /Users/louis/codes/movo/Movo
xcodebuild build \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData-iOS
```

### 3.4 单元测试

```bash
cd /Users/louis/codes/movo/Movo

# 全量（110 个用例，宿主机 macOS 上跑）
xcodebuild test \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData

# 只跑某一个 target
xcodebuild test \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=macOS' -only-testing:MovoDomainTests \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData

# 只跑某个用例（格式：<测试 target>/<测试类>/<方法名>）
xcodebuild test \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:MovoPrivacyTests/PrivacyTests/testMixedSentenceSendsOnlyNonRestrictedClause \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData
```

命令行输出很长。只看关键行：

```bash
xcodebuild test \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData \
  2>&1 | grep -E "error:|failed|TEST (SUCCEEDED|FAILED)"
```

若要精确统计用例数，从结果包里读（比解析日志可靠）：

```bash
R=$(ls -t /Users/louis/codes/movo/.build/DerivedData/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get test-results summary --path "$R" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d['passedTests'],'passed /',d['failedTests'],'failed')"
```

### 3.5 一键脚本

```bash
Scripts/verify.sh            # macOS 构建 + iOS 模拟器构建 + 5 个测试 target
Scripts/verify.sh --quick    # 跳过 iOS 构建（日常快速回归，约省一半时间）
```

模拟器由脚本自动探测（优先 `iPhone 17 Pro`，否则取第一个可用 iPhone），**不锁定 OS 版本**，因此升级 Xcode 后无需改脚本。失败时会把当前可用模拟器列出来，日志落在 `.build/logs/`。

> **写 shell 脚本时注意**：macOS 自带的是 **bash 3.2**，它解析变量名时不识别多字节字符。若变量展开**紧跟中文全角字符**（如 `）`、`：`），必须写花括号：
>
> ```bash
> echo "构建通过（$SIM_DEST）"     # ✗ bash 3.2 报 SIM_DEST?: unbound variable
> echo "构建通过（${SIM_DEST}）"   # ✓
> ```
>
> 原因是 bash 3.2 会把全角字符的首字节（`）` 的第一个字节是 `0xEF`）吞进变量名。这与 locale 无关，`LC_ALL=en_US.UTF-8` 也无效，只能靠花括号避免。

### 3.6 一个必须知道的构建陷阱

本项目使用 Swift 宏（`@Observable`、`@Model`）。宏展开由 `swift-plugin-server` 子进程完成，它需要读写 `~/.swiftpm/security`。

**若在受限沙箱环境中运行 `xcodebuild`**（例如由某些 AI agent 工具代跑），会看到：

```
swift-plugin-server produced malformed response
```

这是沙箱拦截导致的，**不是代码问题**。**VS Code 的内置终端不受影响**，直接在里面跑即可。

### 3.7 App 图标

图标位图已入库，位于 `Movo/Assets.xcassets/AppIcon.appiconset/`，日常构建不需要做任何额外操作。

两端规则不同，改图时注意：

| 平台 | 提供内容 | 尺寸/圆角 |
|---|---|---|
| iOS | 单一 1024，默认 + 深色 + 着色三种外观 | 满幅正方形、不透明无 alpha，圆角由系统遮罩裁切 |
| macOS | 16–512 全尺寸（10 个槽位） | 1024 画布内主体 824×824，左右留白 100、上 90 / 下 110；超椭圆圆角；四周透明留白用于容纳系统投影 |

macOS 图标**不会**被系统裁切圆角，必须自行绘制主体与投影，否则在 Dock / 访达里会是一个硬边方块。

重新生成（仅调整图标外观时才需要）：

```bash
python3 Scripts/generate-app-icons.py
```

脚本依赖 Python 3 + Pillow，会同时重写 `Contents.json` 与全部位图，**不要手工编辑该目录**。Pillow 只服务于这个脚本，应用本身没有 Python 依赖。

---

## 4. macOS：运行与调试

macOS 是最省事的验证环境：不需要签名、不需要 Apple 账号、不需要设备。

### 4.1 命令行运行（推荐，能看到日志）

先构建（见 §3.2）。产物是一个**应用包**：

```
/Users/louis/codes/movo/.build/DerivedData/Build/Products/Debug/Movo.app
```

> ⚠️ **`Movo.app` 是目录，不是可执行文件。** 直接把它当命令敲会得到 `permission denied`。
> macOS 的应用包（bundle）本质是一个约定结构的文件夹，真正的可执行文件在包内：
> `Movo.app/Contents/MacOS/Movo`。
>
> 包内结构：
>
> ```
> Movo.app/Contents/
> ├── MacOS/Movo             ← 真正的可执行文件（命令行的入口）
> ├── MacOS/Movo.debug.dylib ← 业务代码实际在这里（Debug 构建为支持预览而拆出）
> ├── Frameworks/MovoKit.framework
> ├── Resources/
> ├── Info.plist
> └── PkgInfo
> ```

先设一个变量，后面少打长路径（仅当前终端会话有效）：

```bash
APP=/Users/louis/codes/movo/.build/DerivedData/Build/Products/Debug/Movo.app
```

**A. 直接执行包内二进制 —— 排查启动问题的首选**

stdout / stderr 会直接打在终端上，崩溃信息、框架报错、`print` 输出都能看到：

```bash
"$APP/Contents/MacOS/Movo"
```

这条会一直占住终端（应用就在前台跑），按 `Ctrl+C` 结束。若想留着终端做别的事，就另开一个终端标签页。

**B. 当作正常 App 启动 —— 只看界面时用**

```bash
open "$APP"
```

脱离终端在后台运行，因此**看不到任何日志**。这也是「应用起不来却没有任何报错」的常见原因——不是没报错，是没接到终端上。

**C. Finder 双击 / Xcode**

- Finder 中按 `Cmd+Shift+G`，粘贴上面的路径，回车即可看到 `Movo`，双击运行；
- 或在 Xcode 里 `⌘R`（见 §4.2）。

**查看或浏览包内容**

```bash
open "$APP/Contents"                                    # 在 Finder 里展开包内容
find "$APP/Contents" -maxdepth 2 | head -20            # 或直接列出结构
```

**如果应用已经在运行**

重复启动会出现多个实例，先退出：

```bash
pkill -f "Movo.app/Contents/MacOS/Movo"
```

### 4.2 Xcode 运行（需要断点 / 单步）

```bash
open /Users/louis/codes/movo/Movo/Movo.xcodeproj
```

在 Xcode 中：

1. 顶部 scheme 选 **Movo**，运行目标选 **My Mac**；
2. 在源码行号左侧点击打断点；
3. `⌘R` 运行；程序停在断点后可查看变量、调用栈；
4. `⌘.` 停止。

单步与后端调试器体验接近：`F6` 单步跳过、`F7` 单步进入、`F8` 跳出。

### 4.3 崩溃与日志

| 内容 | 位置 / 命令 |
|---|---|
| 崩溃报告 | `~/Library/Logs/DiagnosticReports/Movo-*.ips`（JSON 文本，可直接看） |
| 控制台输出 | 用 §4.1 的 A 方式运行，日志即在终端 |
| 系统日志 | `log stream --predicate 'process == "Movo"' --level debug` |
| 挂 lldb 手动跑 | `lldb /Users/louis/codes/movo/.build/DerivedData/Build/Products/Debug/Movo.app/Contents/MacOS/Movo` 然后 `run`；崩溃后用 `bt` 看完整调用栈 |

**看崩溃栈的要点**：本工程是「App 壳 + MovoKit 动态库」结构，崩溃栈里会出现 `Movo.debug.dylib`（Debug 构建把主二进制包装成 dylib 以支持 SwiftUI 预览）。看栈时不要被这个名字迷惑，业务代码仍在 `MovoKit` 与 `Movo.debug.dylib` 里。

### 4.4 数据落在哪

`SwiftDataRepository.applicationDefault()` 使用 SwiftData 默认配置，存储文件为 `default.store`：

| 构建方式 | 路径 |
|---|---|
| **无签名构建（当前默认）** | `~/Library/Application Support/default.store` |
| 签名后启用沙箱 | `~/Library/Containers/com.louis.movo/Data/Library/Application Support/default.store` |

原因：`project.yml` 中 `CODE_SIGNING_ALLOWED: NO`，entitlements 不生效，沙箱未启用，因此数据写在用户级目录而非容器内。

定位与检查：

```bash
# 找到文件
ls -la ~/Library/Application\ Support/default.store*

# 看表结构（SQLite）
sqlite3 ~/Library/Application\ Support/default.store ".tables"

# 重置全部本地数据（会丢数据，谨慎）
rm -f ~/Library/Application\ Support/default.store*
```

> `default.store` 旁还有 `-wal` / `-shm` 两个文件，重置时要一起删。

### 4.5 一个已验证的启动崩溃陷阱

**现象**：

```
FAULT: CKException: containerIdentifier can not be nil
libc++abi: terminating due to uncaught exception of type CKException
```

**原因**：`CKContainer.defaultContainer` 在 entitlements **未声明** `com.apple.developer.icloud-container-identifiers` 时抛出 ObjC 异常。

**为什么无法用 try/catch 兜住**：该异常在 CloudKit 内部一个 `dispatch_once` 块中抛出。libdispatch 不具备异常展开信息，unwinder 找不到 landing pad 便直接调用 `std::terminate`。**包括 catch-all（`@catch (...)`）在内的任何捕获方式都无效**（已用反汇编 + 运行时双重验证：`_objc_begin_catch` 之后有类型索引校验会重新抛出，且崩溃栈含 `_dispatch_once_callout`）。

**规避方式**：代码采取「未显式配置就绝不触碰 CloudKit」策略。`CloudKitSyncBackend.makeDefault()` 读取 Info.plist 键 `MovoICloudContainerID`，为空则返回 `nil`，`AppEnvironment.activateSync()` 收到 `nil` 后把同步降级为 `unavailable` 直接返回。因此**本机功能完全不受影响**。

**要启用同步**必须同时满足 §7.2 的三项配置，缺一不可。

---

## 5. iPhone：真机运行与调试

真机比 macOS 多一层**代码签名**。签名需要 Apple 账号在 Xcode 中登录，且 bundle ID 必须全局唯一。

设备信息（已验证）：

| 项 | 值 |
|---|---|
| 设备名 | ZDD iPhone |
| 型号 | iPhone 17 Pro Max（iPhone18,2） |
| 系统 | iOS 26.7 (23H24) |
| UDID | `00008150-000055A01AEA401C` |
| 开发团队 ID | `RPD22D948M` |
| Bundle ID | `com.louis.movo` |
| 开发者模式 | 已开启 |
| 描述文件到期 | 2026-10-07 09:14（7 天档） |

### 5.1 首次真机部署

签名已在 `Movo/project.yml` 中配好（`sdk=iphoneos*` 条件覆盖为自动签名 + Team `RPD22D948M`），**不需要在 Xcode GUI 里配置签名**——GUI 里的改动会被 `xcodegen generate` 覆盖。

完整流程三步：**构建安装 → 在设备上信任证书 → 启动**。第二步只能手动做，CLI 无法代劳（信任是设备端由用户确认的安全动作，`devicectl` 不提供该能力）。

#### ① 构建并安装

```bash
cd /Users/louis/codes/movo/Movo
xcodebuild build \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=iOS,id=00008150-000055A01AEA401C' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData-iOS-Device \
  -allowProvisioningUpdates
```

验证确实装上了：

```bash
xcrun devicectl device info apps --device 00008150-000055A01AEA401C | grep movo
# 期望输出：Movo   com.louis.movo   1.0   1
```

#### ② 在 iPhone 上信任开发者证书（必需，每台设备只做一次）

未信任时构建与安装都会成功，但**启动**失败并报：

```
The application could not be launched because the Developer App Certificate is not trusted.
Domain: IDELaunchCoreDevice

... Unable to launch com.louis.movo because it has an invalid code signature,
    inadequate entitlements or its profile has not been explicitly trusted by the user.
Domain: FBSOpenApplicationErrorDomain  (SBMainWorkspace 拒绝)
```

操作路径：

> **设置 → 通用 → VPN 与设备管理 → 开发者 App → 选「Apple Development: 18810151125@163.com (6K8D235K45)」→ 信任 → 再次确认「信任」**

iOS 17 以前该入口叫「描述文件与设备管理」。证书名称来自签名配置，若换了账号会不同。

#### ③ 启动

```bash
xcrun devicectl device process launch \
  --device 00008150-000055A01AEA401C --console com.louis.movo
```

或直接在 iPhone 主屏幕上点图标。

#### 前置条件自查（出问题先跑这三条）

```bash
DEV=00008150-000055A01AEA401C

# 设备在线
xcrun devicectl list devices

# 开发者模式必须开启（iOS 16+ 必需）
xcrun devicectl device info details --device $DEV | grep -i "Developer Mode Status"
# 期望：Developer Mode Status: Enabled (1)

# 描述文件必须已安装且 Valid
xcrun devicectl device profile list --device $DEV
# 期望：iOS Team Provisioning Profile: com.louis.movo ... RPD22D948M ... Valid
```

若开发者模式未开：iPhone → 设置 → 隐私与安全性 → 开发者模式 → 打开 → **重启手机**。

#### 关于描述文件 7 天有效期

个人（免费）Apple 账号的描述文件有效期只有 **7 天**，到期后 App 无法启动，需重跑步骤 ① 刷新。已实测本机描述文件到期时间为 **2026-10-07 09:14**，即 7 天档。付费开发者账号为 1 年。

> 若构建阶段报 `No Accounts` / `No profiles`，说明 Xcode 未取到可用账号。此时改用 GUI：`open /Users/louis/codes/movo/Movo/Movo.xcodeproj` → `Settings…` → `Accounts` 确认账号在列 → 选中设备 → `⌘R`。

### 5.2 后续构建：命令行

改完代码后重新构建。**首次部署建议用 Xcode `⌘R`**（它一并完成安装与启动，且账号解析比命令行宽松）：

```bash
cd /Users/louis/codes/movo/Movo
xcodebuild build \
  -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=iOS,id=00008150-000055A01AEA401C' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData-iOS-Device \
  -allowProvisioningUpdates
```

构建产物：

```
.build/DerivedData-iOS-Device/Build/Products/Debug-iphoneos/Movo.app
```

`-allowProvisioningUpdates` 允许自动更新描述文件。若报 `No Accounts`，改用 Xcode GUI（两者的账号解析路径不同）。构建完成后按 §5.3 安装并启动。

### 5.3 安装与启动（devicectl）

```bash
APP=/Users/louis/codes/movo/.build/DerivedData-iOS-Device/Build/Products/Debug-iphoneos/Movo.app
DEV=00008150-000055A01AEA401C

# 安装
xcrun devicectl device install app --device $DEV "$APP"

# 启动并挂住，直接看 stdout/stderr
xcrun devicectl device process launch --device $DEV --console com.louis.movo

# 只看日志（不启动）
xcrun devicectl device process launch --device $DEV --terminate-existing com.louis.movo
```

### 5.4 真机调试

**方式一：Xcode 调试器（推荐）**

选中设备后 `⌘R`，断点、变量查看、`po` 打印与 macOS 完全一致。

**方式二：命令行抓设备日志**

```bash
# 抓 iPhone 的系统日志（用 UDID 最稳，也可用 --device-name "ZDD iPhone"）
log stream --device-udid 00008150-000055A01AEA401C \
  --predicate 'process == "Movo"' --level debug
```

**方式三：取崩溃日志**

```bash
# 查看设备上的崩溃日志文件列表（systemCrashLogs 域）
xcrun devicectl device info files \
  --device 00008150-000055A01AEA401C \
  --domain-type systemCrashLogs

# 过滤本 App 的崩溃
xcrun devicectl device info files \
  --device 00008150-000055A01AEA401C \
  --domain-type systemCrashLogs --search Movo
```

图形化方式：Xcode → `Window` → `Devices and Simulators` → 选设备 → `View Device Logs`。

**方式四：取 App 沙盒文件（含 SwiftData 库）**

> 前提：**App 已安装到设备**。未安装时该命令报 `CoreDevice.ActionError error 3`。

```bash
xcrun devicectl device info files \
  --device 00008150-000055A01AEA401C \
  --domain-type appDataContainer \
  --domain-identifier com.louis.movo
```

真机上 `default.store` 位于该容器的 `Library/Application Support/` 下。

### 5.5 真机常见错误对照

| 报错 | 原因 | 处理 |
|---|---|---|
| `The application could not be launched because the Developer App Certificate is not trusted`（`IDELaunchCoreDevice`） | 构建、签名、安装都成功，但设备侧未信任该开发者证书 | **§5.1 步骤 ②**：iPhone → 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任 |
| `invalid code signature, inadequate entitlements or its profile has not been explicitly trusted`（`SBMainWorkspace` 拒绝） | 同上，是上一条的伴随错误 | 同上 |
| App 之前能用、某天突然打不开 | 个人账号描述文件 **7 天**到期 | 重跑 §5.1 步骤 ① 重新签名安装 |
| `No Accounts: Add a new account in Accounts settings` | xcodebuild 未看到可用账号 | 走 §5.1 末尾的 GUI 方式；确认 Xcode → Accounts 已登录 |
| `No profiles for 'com.example.movo'` | bundle ID 与配置不一致 | 确认 `Movo/project.yml` 内 **所有** target 的 `PRODUCT_BUNDLE_IDENTIFIER` 均为 `com.louis.*` |
| `Signing ... requires a development team` | 未设 Team | §7.1 设 `DEVELOPMENT_TEAM` |
| `MovoKit.framework is not signed` | 只给 App 签了名，内嵌 framework 未签 | 签名设置必须放在 `project.yml` 的**工程级** `settings.base`，覆盖全部 target |
| 设备不出现在目标列表 | 未连接 / 未信任电脑 / 开发者模式未开 | §5.1 前置条件自查三条命令 |
| 设备不出现 / 提示需要开发者模式 | iOS 16+ 默认关闭 | §5.1 第 4 步 |
| 安装失败但构建成功 | 设备架构或签名环节 | 用 `devicectl device install app` 看详细报错 |

---

## 6. iPhone：模拟器

模拟器适合快速验证 UI，**不需要签名、不需要账号、不需要设备**。

### 6.1 Xcode GUI

```bash
open /Users/louis/codes/movo/Movo/Movo.xcodeproj
```

顶部目标选任一 iPhone 模拟器 → `⌘R`。

### 6.2 命令行

```bash
cd /Users/louis/codes/movo/Movo

# 看可用模拟器
xcrun simctl list devices available | grep iPhone

# 构建 + 启动到模拟器（一步到位）
xcodebuild build -project Movo.xcodeproj -scheme Movo -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath /Users/louis/codes/movo/.build/DerivedData-iOS

open -a Simulator
xcrun simctl boot "iPhone 17"          # 若尚未启动
xcrun simctl install booted \
  /Users/louis/codes/movo/.build/DerivedData-iOS/Build/Products/Debug-iphonesimulator/Movo.app
xcrun simctl launch --console booted com.louis.movo
```

`--console` 会把 App 的 stdout/stderr 接到当前终端。

### 6.3 模拟器调试要点

```bash
# 模拟器上的沙盒路径（default.store 在这里）
xcrun simctl get_app_container booted com.louis.movo data

# 直接看库文件
sqlite3 "$(xcrun simctl get_app_container booted com.louis.movo data)/Library/Application Support/default.store" ".tables"

# 截图（用于比对设计稿）
xcrun simctl io booted screenshot /tmp/movo.png

# 重置：卸载应用
xcrun simctl uninstall booted com.louis.movo
```

### 6.4 模拟器的局限（不要在这些问题上浪费时间去调模拟器）

| 项 | 模拟器 | 真机 |
|---|---|---|
| 麦克风 / 语音转写 | 走 Mac 麦克风，行为不完全一致 | 需真实权限 |
| 通知 | 基本可用，但锁屏表现不同 | 需授权，表现真实 |
| iCloud / CloudKit | **不可靠**，必须真机 | 需付费账号 |
| 性能 / 内存 | 不代表真机 | 基准 |
| 推送 | 不支持 | 需真机 |

---

## 7. 需要第三方账号或证书的文件清单

以下文件涉及外部依赖（签名、iCloud、大模型、语音权限）。**改这些文件前先读本节**；标 ★ 的文件改动后必须 `xcodegen generate`。

### 7.1 签名 `[签名]`

| 文件 | 内容 |
|---|---|
| ★ `Movo/project.yml` | 唯一的签名配置源。相关键见下表 |
| `Movo/Resources/Movo-iOS.entitlements` | iOS 权限声明（当前仅注释块） |
| `Movo/Resources/Movo-macOS.entitlements` | macOS 权限声明（沙箱、麦克风、出网、用户选择文件） |

`project.yml` 中的签名相关键：

```yaml
# 工程级 settings.base —— 无签名基线，macOS / 模拟器 / 单测开箱即用
CODE_SIGN_IDENTITY: ""
CODE_SIGNING_REQUIRED: NO
CODE_SIGNING_ALLOWED: NO
DEVELOPMENT_TEAM: ""

# 仅 iPhone 真机（sdk=iphoneos*）覆盖为自动签名
CODE_SIGN_STYLE[sdk=iphoneos*]: Automatic
CODE_SIGN_IDENTITY[sdk=iphoneos*]: "Apple Development"
CODE_SIGNING_REQUIRED[sdk=iphoneos*]: YES
CODE_SIGNING_ALLOWED[sdk=iphoneos*]: YES
DEVELOPMENT_TEAM[sdk=iphoneos*]: "RPD22D948M"
```

**关键点**：

- bundle ID 由 `bundleIdPrefix: com.louis` 加各 target 显式 `PRODUCT_BUNDLE_IDENTIFIER` 决定。**`bundleIdPrefix` 单独改不生效** —— 显式值会覆盖它。当前为 `com.louis.movo`（App）、`com.louis.movo.kit`（Kit）、`com.louis.movo.tests.*`（测试）。
- 签名设置放在**工程级** `settings.base`，以确保 `MovoKit.framework` 也被签名；只给 App 签名会导致安装时因内嵌未签名 framework 而失败。
- macOS 侧 `ENABLE_HARDENED_RUNTIME: NO`，且 `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]` 指向 macOS entitlements。无签名时 entitlements 不生效，沙箱不启用（见 §4.4）。

### 7.2 iCloud 同步 `[iCloud]`

启用同步需要**同时**改三处，缺一不可：

| # | 文件 | 改动 |
|---|---|---|
| 1 | `Movo/Resources/Movo-iOS.entitlements` | 取消 `com.apple.developer.icloud-container-identifiers` / `icloud-services` 的注释，填容器 ID |
| 2 | `Movo/Resources/Movo-macOS.entitlements` | 同上 |
| 3 | ★ `Movo/project.yml` | ① `INFOPLIST_KEY_MovoICloudContainerID` 从 `""` 改为**与上面一致的**容器 ID；② 补上 iOS 侧 entitlements 引用 `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]: Resources/Movo-iOS.entitlements` |

容器 ID 格式：`iCloud.com.louis.movo`（需先在 https://developer.apple.com/account 注册）。
**iCloud 同步需要付费开发者账号。**

第 3 项的 Info.plist 键是应用层开关：`CloudKitSyncBackend.configuredContainerID` 读取它，为空则同步降级为 `unavailable`，本机功能不受影响（原因见 §4.5）。当前为空串 `""` —— 且 Xcode 会把空值从 Info.plist 中剥离，效果等价于未配置。

同步相关代码：

| 文件 | 关注点 |
|---|---|
| `Movo/Data/Sync/CloudKitSyncBackend.swift` | **唯一 import CloudKit 的文件**；容器配置入口 |
| `Movo/App/AppEnvironment.swift` → `activateSync()` | 无配置时提前返回的降级点 |
| `Movo/App/NetworkMonitor.swift` | 联网恢复触发同步 |
| `Movo/Data/Sync/SyncEngine.swift` | 出站/入站循环、防抖、重试 |

> CloudKit **不参与单测**。`MovoSyncTests` 的 18 个用例全部基于 `SyncBackend.swift` 的内存实现，脱网可跑。

### 7.3 大模型 API `[大模型]`

| 文件 | 内容 |
|---|---|
| `Movo/Config/ModelsCatalog.json` | 内置厂商（DeepSeek）的 chat completions 端点与模型清单 |
| `Movo/Config/Defaults.json` | 超时（单次等待 60s / 总 120s）、重试次数、回退步数（默认 5 步）、单次输入上限 |
| `Movo/Intelligence/Providers/AIKeyStore.swift` | Key 存 Keychain：service = `Movo.AIKey.<vendor>`，`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`，**不参与 iCloud Keychain 同步** |
| `Movo/Intelligence/Providers/AITransport.swift` | 超时 / 重试 / 取消；把 `URLError` 归一为可诊断的失败分类；仅网络类错误与 429/5xx 自动重试 |
| `Movo/Intelligence/Providers/OpenAICompatibleAdapter.swift` | OpenAI 兼容协议适配（内置厂商与自定义厂商共用） |
| `Movo/Intelligence/Providers/AIProviderResolver.swift` | 厂商 + 用户配置 → 端点/模型；自定义未填全时抛 `providerNotConfigured` |
| `Movo/Intelligence/Providers/AISettingsStore.swift` | 全局 AI 开关、厂商选择与自定义 Base URL／模型 ID 的本机持久化（Key 不在此处） |
| `Movo/Domain/AIFailureCause.swift` | 失败原因的机器标识 → 用户可执行解释的映射表 |
| `Movo/Intelligence/Privacy/ContextBuilder.swift` | 云端请求上下文构建：未归档计划、全部阶段、任务树、重复模板 |

**Key 的获取与使用**

Key 与自定义配置由用户在 App 内「设置 → AI 与数据」填写：内置 DeepSeek 的 Key 前缀为 `sk-`；自定义厂商（OpenAI 兼容）额外填写 Base URL 与模型 ID，Key 格式由用户自行决定、仅做长度预检。Key 运行时存进 Keychain，**不写在代码或配置文件里**；Base URL 与模型 ID 非凭据，存在本机偏好。

**出网要求**：`Movo-macOS.entitlements` 中的 `com.apple.security.network.client` 必须为 true，否则 macOS 沙箱下所有 API 请求会被拒。iOS 无需额外声明。

#### 自定义厂商的网络要求（ATS）

自定义厂商的 Base URL 由用户填写，应用事先不知道会是什么地址，**无法按域名逐个放行**。实际形态覆盖：

```
http://203.0.113.10:21003/v1     公网 IP + 明文 HTTP（203.0.113.0/24 为文档保留段）
http://192.168.1.9:8000/v1       局域网 vLLM / LM Studio
http://localhost:11434/v1        Ollama
```

系统自 **iOS 17 / macOS 14 起默认拒绝连接裸 IP**（公网与局域网皆然），并且一贯拒绝明文 HTTP。未放行时自定义厂商必然失败，
而传输层只能看到 `URLError`，界面上只会显示「网络不可用」。因此 `Movo/project.yml` 的 `info:` 段声明：

| 键 | 作用 |
|---|---|
| `NSAppTransportSecurity.NSAllowsArbitraryLoads` | 取消 ATS 的**协议限制**，明文 HTTP 与裸 IP 均可连接。不改动 URLSession 的默认服务器信任评估，HTTPS 连接（如 DeepSeek）仍按原样校验 |
| `NSLocalNetworkUsageDescription` | 局域网地址需要本地网络访问权限（iOS 14+ / macOS 15+）。这是独立于 ATS 的另一套机制，公网 IP 不触发 |

> ⚠️ **不要把 `NSAllowsLocalNetworking` 加回来。** Apple 明确规定：只要 Info.plist 中存在
> `NSAllowsLocalNetworking` / `NSAllowsArbitraryLoadsInWebContent` / `NSAllowsArbitraryLoadsForMedia` 中任意一个，
> iOS 10+ / macOS 10.12+ 就会**忽略 `NSAllowsArbitraryLoads` 并改用其默认值 NO**。
> 两者同时存在等于静默关掉这个例外，且不会有任何报错。

**取舍**：`NSAllowsArbitraryLoads` 放宽的是「允许明文」，不是「降低 HTTPS 校验」。副作用是 API Key 与整理内容可能以明文过网。

- 上架 App Store 需在审核时说明理由；Apple 认可的理由之一是「必须连接由第三方管理、不支持安全连接的服务器」。
- 能改成 HTTPS（反向代理加证书）就改：公网明文 HTTP 下，`Authorization: Bearer` 会被路径上任何人读到。
- 若将来只需服务固定域名，应换成更窄的 `NSExceptionDomains` + `NSExceptionAllowsInsecureHTTPLoads`。
- **自签名 HTTPS 证书**不被默认信任评估接受；`NSExceptionAllowsInsecureHTTPLoads` 是按域名生效的，用户自填地址无法事先枚举，
  因此自签名场景需要写自定义服务器信任评估代码，或让用户改用受信任证书。

`NSAppTransportSecurity` 是嵌套字典，**无法用 `INFOPLIST_KEY_*` 表达**，所以工程额外声明了一个由 `info:` 段生成的
`Movo/Info.plist`（不入库）。Xcode 会把 `settings` 里的全部 `INFOPLIST_KEY_*` 合并进该文件；产物里同时能看到
`NSAllowsArbitraryLoads`、`NSPrincipalClass`、`UIApplicationSceneManifest` 等键。

**失败原因必须可诊断**：`AITransport` 把 `URLError` 归一为 `AIFailureCause` 中的语义标识
（`ats_plain_http` / `tls_trust` / `dns` / `connect_refused` / `offline` / `connection_lost`），
`MovoError.diagnosticDetail` 给出可执行解释，`MovoError.message` 优先采用它；设置页「测试连接」
直接用 `diagnosticDetail`（那里没有待整理的原文，不该出现「原文已经保存」）。前三种属确定性失败，
`isRetryable` 返回 false，避免对着写错的地址反复重试。

**配置缺失 ≠ 整理失败**：`MovoError.isConfigurationGap` 标记 `noKey` 与 `providerNotConfigured`，
输入管线据此把用户送到设置页补全，而不是渲染成 M04-Failed「整理没能完成」（见 `Features/Capture/CaptureStatusScreens.swift`）。

**测试不触网**：`MovoAdapterTests`（29 个用例）与 `MovoPrivacyTests`（13 个用例）使用固定响应与请求抓取，跑测试无需任何 Key。

**日志脱敏**：`Movo/Intelligence/Support/RedactedLogger.swift` 只输出 `provider / model / status / latencyMs / tokens / itemCount / rejectedCount`，不输出正文与 Key。新增日志请遵守此约定。

### 7.4 语音 `[语音]`

| 文件 | 内容 |
|---|---|
| ★ `Movo/project.yml` | Info.plist 用途说明：`NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription` |
| `Movo/Resources/Movo-macOS.entitlements` | `com.apple.security.device.audio-input` = true（macOS 必需） |
| `Movo/Intelligence/Speech/SpeechTranscriptionService.swift` | 本机转写，不满足 on-device 条件则不开放录音 |
| `Movo/App/AppEnvironment.swift` → `startSpeechSession()` | 会话入口 |

iOS 侧麦克风与语音识别**不需要额外 entitlement**，仅靠 Info.plist 用途说明。

---

## 8. 排障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 克隆后找不到 `Movo.xcodeproj` | 该目录由 XcodeGen 生成，不入库 | `cd Movo && xcodegen generate --spec project.yml`，见 §2.3 |
| `error: no such module 'MovoKit'` | 工程未重新生成 | `xcodegen generate --spec project.yml` |
| 新增文件在 Xcode 里看不到 | 同上 | 同上 |
| `swift-plugin-server produced malformed response` | 沙箱拦截 `~/.swiftpm/security` | 换到 VS Code 内置终端跑，见 §3.6 |
| 自定义厂商「测试连接」失败，提示**网络不可用** | 明文 HTTP 或裸 IP 被 ATS 拦下；或缺少本地网络权限 | 见 §7.3「自定义厂商的网络要求」。错误文案会区分「明文 HTTP」「证书」「主机名」 |
| 已设 `NSAllowsArbitraryLoads: true` 却仍被 ATS 拦 | Info.plist 里同时存在 `NSAllowsLocalNetworking` 等键，导致前者被忽略 | 删掉那些键，只保留 `NSAllowsArbitraryLoads`，见 §7.3 的警告 |
| 自定义厂商提示**服务端拒绝了这次请求** | Base URL 或模型 ID 不对（400 / 404 / 422） | 请求发往 `<Base URL>/chat/completions`；自建服务通常要带 `/v1` |
| 自定义厂商提示**还没有填完自定义厂商信息** | Base URL 与模型 ID 没填全 | 设置 → AI 与数据 → 切到「自定义」，补齐两个字段（不是 Key 的问题） |
| 启动日志出现 `NSSecureCoding allowed classes list contains [NSObject class]` / `<decode: bad range for ...>` | **系统框架自身**在用 `NSKeyedUnarchiver` 解码时给出的告警（见下方说明） | 本项目无归档代码，无需处理 |
| shell 脚本报 `VAR?: unbound variable`（变量名后带乱码） | macOS bash 3.2 把紧跟变量的全角字符首字节吞进了变量名 | 变量展开改写成 `${VAR}`，见 §3.5 注 |
| 构建报 `targeted device family` / 架构错误 | destination 写错 | 真机用 `platform=iOS,id=00008150-000055A01AEA401C`；模拟器用 `platform=iOS Simulator,name="iPhone 17 Pro"` |
| 启动崩 `CKException: containerIdentifier can not be nil` | 无 iCloud entitlement 却触达 `CKContainer.defaultContainer` | §4.5 |
| macOS 起不来、无报错 | 用 `open` 看不到日志 | 改用直接执行包内二进制，见 §4.1 |
| 敲 `.app` 路径报 `permission denied` | `.app` 是目录，不是可执行文件 | 用 `open <路径>.app`，或执行 `<路径>.app/Contents/MacOS/Movo`，见 §4.1 |
| 数据没保存 | UI 未真正发出命令 | 查 `App/AppEnvironment.swift` 与 `Domain/Commands/` |
| 数据在预期路径找不到 | 未签名构建走用户级目录 | §4.4 |
| 同步一直 `unavailable` | 未配置 iCloud，或未登录，或无付费账号 | §7.2 |
| AI 请求 401 | Key 无效或与所选厂商不匹配 | 设置页「测试连接」；核对 Key 前缀 |
| AI 请求超时 | 网络或超时参数 | `Config/Defaults.json` 的 `connect_timeout_seconds` / `total_timeout_seconds` |
| AI 整理提示未开启或无 Key | 全局 AI 开关关闭或 Key 未填写 | 设置页开启 AI 开关并填入有效 Key |
| 通知不响 | 权限未授予或时刻配置 | 系统设置里给 Movo 通知权限；`Config/Defaults.json` 的 notification 段 |
| 真机装不上 | 签名 / 信任 / 开发者模式 | §5.5 |
| `No Accounts` | xcodebuild 未看到账号 | §5.1 走 GUI 首次部署 |

### 关于 `NSSecureCoding allowed classes list contains [NSObject class]` 告警

这条告警**不是本项目的代码问题**，可以忽略。已核实的依据：

1. `Movo/` 与 `Tests/` 共 95 个 Swift 文件里**没有任何** `NSKeyedUnarchiver` / `NSKeyedArchiver` / `NSSecureCoding` / `allowedClasses` 调用。
2. 该文案只存在于系统库 **Foundation** 中（`dyld_shared_cache_arm64e.01` 反查确认），是 `NSKeyedUnarchiver` 在安全解码校验时发出的。
3. 后半截 `<decode: bad range for [%{public}@] got [offs:... len:... within:...]>` 只存在于 **`libsystem_trace.dylib`** 与 **`LoggingSupport.framework`** —— 即**日志系统自身**。它是 os_log 格式化器解码某个日志参数失败时的输出，不是应用层的解码错误。粘贴里 `%{public}@` 未被替换成实际值，正是这个失败的佐证。
4. 全量 75 个单测在 `OS_ACTIVITY_DT_MODE=YES` 下运行，**一次都没出现**该告警。

Movo 代码中唯一会触发系统反序列化归档的调用点：

| 位置 | 调用 | 说明 |
|---|---|---|
| `Notifications/NotificationScheduler.swift:118` | `UNUserNotificationCenter.pendingNotificationRequests()` | 返回的 `UNNotificationRequest` 需在本进程反序列化，由 Apple 的 UserNotifications 框架执行 |
| `Notifications/NotificationScheduler.swift:94` | 经由 `pendingIdentifiers()`，每次启动的 `replaceAll` 都会走 | |
| `Features/Settings/SettingsSections.swift:459` | 设置页显示"待发通知数" | 该功能需要此 API，无法回避 |

另有可能的来源是 **AppKit 的窗口状态恢复**（`NSPersistentUIRemoteStorageClient`），它同样用 `NSKeyedUnarchiver` 解码保存的窗口状态，且发生在启动时。

**要定位具体是哪个框架**（需要你自己在终端跑，`log` 不能在受限沙箱中执行）：

```bash
# 一个终端：抓日志（--info/--debug 才会显示这类告警）
log stream --predicate 'process == "Movo"' --style compact --level debug > /tmp/movo.log

# 另一个终端：启动应用
open /Users/louis/codes/movo/.build/DerivedData/Build/Products/Debug/Movo.app

# 回来后检索：subsystem / category 字段会指明是哪个框架
grep -iE "NSSecureCoding|allowed classes" /tmp/movo.log
```

> 顺带一个实用知识：**Xcode 的控制台比终端多显示很多 os_log**，因为 Xcode 会设置 `OS_ACTIVITY_DT_MODE=YES` 把 os_log 镜像到 stderr。想在终端看到同样的输出：
>
> ```bash
> OS_ACTIVITY_DT_MODE=YES "$APP/Contents/MacOS/Movo"
> ```

### 常用清理命令

```bash
# 重新生成工程
cd /Users/louis/codes/movo/Movo && xcodegen generate --spec project.yml

# 清空构建缓存（排查"改了代码没生效"时用）
rm -rf /Users/louis/codes/movo/.build

# 重置 macOS 本地数据
rm -f ~/Library/Application\ Support/default.store*

# 卸载模拟器上的 App
xcrun simctl uninstall booted com.louis.movo

# 卸载真机上的 App
xcrun devicectl device uninstall app --device 00008150-000055A01AEA401C com.louis.movo
```

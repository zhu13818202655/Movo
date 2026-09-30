# Movo 代码代理协作指南

本文件适用于整个仓库。默认使用中文沟通和编写项目说明，代码标识符沿用现有英文命名。先阅读相关实现和测试，再进行范围明确的修改；保留用户已有改动。

## 项目与入口

Movo 是 iOS 26+ / macOS 26+ 的 Swift 6、SwiftUI 应用，使用 SwiftData 本地存储、可选 CloudKit 同步和用户自备 Key 的 AI 服务。

- 上手与命令：[README.md](README.md)。
- 开发与排障：[docs/Development.md](docs/Development.md)。
- 产品行为：[docs/PRD.md](docs/PRD.md)。
- 领域与流程设计：[docs/代码实施方案-V2.md](docs/代码实施方案-V2.md)。
- UI 规范：[docs/UI-Prompt.md](docs/UI-Prompt.md)、[docs/design/Movo.pen](docs/design/Movo.pen)。

按任务读取相关部分，无需每次通读全部资料。历史说明与实现不一致时，构建事实以 `Movo/project.yml`、`Scripts/verify.sh` 和源码为准；产品行为变更应核对 PRD，并在交付中说明发现的差异，不要把规划描述成已实现能力。

## 修改位置与架构边界

| 工作内容 | 优先查看 |
| --- | --- |
| 启动、服务装配、输入流程 | `Movo/App/AppEnvironment.swift`、`AppEnvironment+Capture.swift`、`MovoApp.swift` |
| 页面与路由 | `Movo/Features/`、`Movo/App/Navigation/ScreenHost.swift`、`Route.swift` |
| 业务行为与只读视图 | `Movo/Domain/Commands/`、`Policies/`、`Queries/` |
| 持久化与同步 | `Movo/Data/Local/`、`Movo/Data/Sync/` |
| AI、隐私、语音 | `Movo/Intelligence/` |
| 提醒、共享 UI、运行参数 | `Movo/Notifications/`、`DesignSystem/`、`Config/` |

1. `Domain` 不依赖 SwiftUI、SwiftData、CloudKit、UIKit/AppKit 或厂商 SDK。保留现有 Foundation / Observation 使用方式，通过 `DomainRepository` 隔离存储实现。
2. `DomainStore` 是 `@MainActor` 隔离的写入门面。页面业务变更走领域命令及批量、撤销入口，不从 UI 直接修改持久化实体；读取优先使用查询视图。
3. 保持写事务中的校验、实体修改、变更事件、索引及版本维护一致。新增命令考虑幂等、批次、修订号、撤销与后续编辑冲突，不覆盖较新的用户修改。
4. `MovoKit` 包含共享逻辑和 `DesignSystem`，后者使用 SwiftUI；不要误将整个 framework 当作纯领域模块。`Movo` target 负责页面与装配。
5. 平台特有 API 使用现有条件编译方式，公共改动同时考虑 iOS 和 macOS。复用设计令牌与组件，页面映射通过现有路由维护。
6. 保持 Swift 6 严格并发与 warnings-as-errors，不以关闭检查掩盖问题。跨隔离边界传递适当的 `Sendable` 值类型，避免传递 SwiftData `@Model` 对象。

## 不可混淆的业务语义

- `DateOnly` 表达日期及其来源时区，`DateTimeTZ` 表达时刻与时区；不要用裸 `Date` 替代“某天”。安排日期与硬截止日期分别处理。
- 行动记录、任务完成、结果测量是不同操作，不推断记录投入就代表完成或目标达成。
- 重复模板与当次实例有独立身份；完成当次不改变未来实例，修改频率不重写过去记录。
- 交付型、改善型和持续型计划遵循各自进度口径；缺失值不填零，分母为零不显示百分比，持续型不强制总进度 100%。
- 父子归属、子任务层级和依赖合法性通过已有策略校验，不在界面另建一套规则。
- 一级入口是「待办」，「今日」仅为日期筛选；内部 `.today` 路由与 `/today` 深链为兼容保留。手动创建直接执行 `CreateTask`，AI 整理使用独立入口。
- 一次性待办支持多级子任务，同一子树保持计划与阶段一致。移动、删除、恢复与撤销必须考虑全部后代及后续编辑；父节点汇总叶子进度，不一次勾选完成整棵树。重复模板暂不参与父子嵌套。
- 修改界面时同步核对 `docs/design/Movo.pen`。有 Pencil MCP 时通过它编辑并截图检查；检查组件实例的文字覆盖值，不能只修改组件源。设计稿需实际保存到文件。

## 隐私、AI 与数据约束

- API Key 仅通过 `AIKeyStore` 保存在设备专属 Keychain；不得写入源码、配置、SwiftData、CloudKit、日志或导出。测试使用替身和虚构 Key。
- 保留 `PrivacySplitter`、`ContextBuilder` 与本地路由的隐私边界；未获准的敏感内容不得发送到云 AI。计划的 AI 许可和同步许可互相独立。
- AI 输出必须经过 `ProposalValidator` 与执行策略；保留原文，失败或歧义走现有收件箱/确认流程。删除、批量变更等操作不能绕过产品要求的预览确认。
- 使用 `RedactedLogger` 记录必要元数据，不输出任务正文、输入原文、测量值、音频、Key 或厂商请求/响应正文。
- 语音保持本机转写与能力检查，不静默回退到云端。
- CloudKit 默认关闭。不要仅为修复启动或测试而启用云容器；不得同时启用 SwiftData 自动 CloudKit 同步和现有自定义同步。
- 存储模型与同步格式变化需检查编码兼容、已有数据、字段合并、删除墓碑和恢复行为，并补充对应验证。不要通过删除用户数据库解决迁移问题。

## 工程与代码习惯

- 工程定义只改 `Movo/project.yml`，不要手改或提交生成的 `Movo/Movo.xcodeproj`。修改工程定义或增删源码后重新生成。
- 不提交 `.build/`、DerivedData、个人 Xcode 状态、签名证书、描述文件或凭据。
- 当前应用使用系统框架。引入依赖前说明必要性，优先复用已有实现和协议。
- 沿用附近代码的缩进与命名；领域类型使用 PascalCase，持久化类型沿用 `M` 后缀，命令使用动词短语。避免与任务无关的全文件格式化。
- 易变参数集中在 `Movo/Config/`，不散落到领域逻辑；修改配置时同步检查加载器、默认回退与测试。
- 错误沿用 `MovoError` 和现有恢复入口，不用吞错或空成功态掩盖失败。
- 修改 `Scripts/verify.sh` 时保持 macOS Bash 3.2 兼容，注意 `set -u` 下空数组展开，以及紧邻中文标点的变量应使用 `${VAR}`。

## 验证流程

以下命令在 macOS 的仓库根目录执行：

```bash
# 工程配置变化或增删源码后先生成
(cd Movo && xcodegen generate --spec project.yml)

# 日常回归：macOS 构建与全部五组单元测试
bash Scripts/verify.sh --quick

# 代码变更交付前的完整验证：再覆盖 iOS 模拟器构建
bash Scripts/verify.sh
```

脚本仅在工程缺失时自动生成，不会刷新已存在的工程。日志位于 `.build/logs/`。定位问题可按 README 的命令使用 `-only-testing:<测试 target>`，无需每次重复运行无关检查。

- 业务变化或缺陷修复按风险补充有意义的回归测试：领域用 `MovoDomainTests`，存储用 `MovoDataTests`，隐私用 `MovoPrivacyTests`，厂商适配用 `MovoAdapterTests`，同步用 `MovoSyncTests`。
- 优先使用 `InMemoryRepository`、`TravelClock`、固定时区与设备 ID、内存密钥/通知服务及固定响应。单测不依赖真实 API Key、付费请求或个人 iCloud 数据。
- UI 变更检查双端布局与相关空态、错误态、加载态；语音、权限、通知和真实云同步需按影响范围进行设备验收，不能用单测通过代替。
- 纯文档修改检查路径、链接、命令与实现一致性，不必为文档运行完整应用构建。
- Windows / Linux 或缺少 Xcode 时进行可完成的静态检查，并明确未执行的 Apple 平台验证及原因，不声称构建或测试已通过。

## 交付说明

完成后简述改动、影响和实际验证结果；说明仍未验证的部分。修改运行方式、配置、架构或用户行为时，同步维护相应文档。避免将固定测试数、个人绝对路径或未完成验收写成长期有效的项目事实。

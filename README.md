# Movo · 渐成

Movo 是面向 iPhone 和 Mac 的个人待办与长期目标管理应用：从文字或语音记录开始，将事项整理为计划与任务，并持续记录行动、结果和回顾。

项目使用 Swift 6、SwiftUI 和 SwiftData，双端共享领域逻辑。AI 由客户端直连用户选择的 OpenAI 或 Claude API，无独立的 Movo AI 后端。

## 功能与当前边界

- **日常行动**：今日列表、独立任务、计划与阶段、子任务、重复行动和本地提醒。
- **长期跟踪**：行动记录、数值指标、趋势、计划历史、快照和周回顾。
- **输入整理**：文字输入、本机语音转写、AI 提案校验、批量预览、收件箱和撤销。
- **数据管理**：SwiftData 本地存储、搜索、Markdown / JSON 导出、最近删除与同步冲突处理。
- **可选云能力**：AI 需要在当前设备配置 API Key；CloudKit 同步已有实现，但工程默认未启用 iCloud 容器。

首次启动会在数据为空时装载演示内容。仓库包含应用代码与五组单元测试；需求文档中的规划和验收目标不等于已经完成的发布验收。

## 开发环境

| 项目 | 要求 / 当前配置 |
| --- | --- |
| 构建主机 | macOS，安装完整 Xcode 并选中对应开发者工具目录 |
| 系统部署目标 | iOS 26.0+、macOS 26.0+ |
| 工具链 | 支持项目 API 的 Swift 6 与 Apple SDK；`project.yml` 中 `xcodeVersion` 为 `27.0` |
| 工程生成 | XcodeGen，命令需可从终端调用 |
| iOS 验证 | 安装兼容的 iPhone 模拟器运行时；语音与设备能力另需真机验证 |
| 应用依赖 | Apple 系统框架，当前没有第三方运行时包依赖 |

Windows / Linux 可用于编辑源码与文档，无法完成本项目的 Xcode 构建、SwiftData 测试或 Apple 平台运行验证。仓库没有 `Package.swift`，测试通过 Xcode scheme 运行。

## 快速开始

以下命令均在 **macOS 的仓库根目录**执行。

### 1. 生成并打开工程

```bash
(cd Movo && xcodegen generate --spec project.yml)
open Movo/Movo.xcodeproj
```

在 Xcode 中选择 `Movo` scheme，选择 My Mac 或可用的 iPhone 模拟器，然后运行。

`Movo/Movo.xcodeproj` 是被 Git 忽略的生成物。修改工程配置请编辑 `Movo/project.yml`；修改该文件或增删源码后，重新生成工程。

### 2. 命令行构建 macOS 应用

```bash
xcodebuild build \
  -project Movo/Movo.xcodeproj \
  -scheme Movo -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData
```

macOS 和 iOS 模拟器使用无签名构建基线。iPhone 真机使用单独的自动签名配置：部署前检查 `project.yml` 中的开发团队、Bundle ID 与权限，改为你有权使用的配置，再重新生成工程。详细步骤见 [开发指南](docs/Development.md)。

### 3. 验证

```bash
# macOS 构建 + 五组单元测试
bash Scripts/verify.sh --quick

# macOS 构建 + iOS 模拟器构建 + 五组单元测试
bash Scripts/verify.sh
```

脚本只在工程不存在时自动生成工程，不会自动刷新已有工程。日志输出到 `.build/logs/`；iOS 构建会优先选择 iPhone 17 Pro，否则使用找到的可用 iPhone 模拟器。

针对单个测试组运行：

```bash
xcodebuild test \
  -project Movo/Movo.xcodeproj \
  -scheme Movo -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -only-testing:MovoDomainTests
```

| 测试 target | 主要覆盖 |
| --- | --- |
| `MovoDomainTests` | 领域命令、规则、查询与撤销 |
| `MovoDataTests` | SwiftData 仓储与数据往返 |
| `MovoPrivacyTests` | 隐私分流与云上下文限制 |
| `MovoAdapterTests` | AI 适配器的固定样例解析与请求构造 |
| `MovoSyncTests` | 字段合并、同步与删除恢复 |

单元测试不替代真实 iCloud 双端同步、语音权限和 UI 的设备验收。

## 配置与隐私

### AI

在应用设置中选择厂商和模型，录入 API Key 并测试连接。每台设备分别配置；Key 存入当前设备的 Keychain，不同步到 iCloud，不应进入日志或导出。

允许云处理的文字和上下文会发送给所选 AI 厂商。健康及敏感内容通过隐私分流和上下文校验限制发送；“密钥保存在本机”并不意味着所有 AI 处理都在本机完成。

### iCloud

默认 `INFOPLIST_KEY_MovoICloudContainerID` 为空，应用按本地模式运行。启用同步需要同时配置真实容器、签名与相应平台的 iCloud entitlements，并确认这些权限文件绑定到对应构建。具体参见 [开发指南的 iCloud 配置](docs/Development.md)。

计划的 `cloudAIEnabled` 与 `syncEnabled` 是独立开关。同步使用自定义 CloudKit 路径，不要同时开启 SwiftData 自动 CloudKit 同步。

### 语音与运行参数

语音通过 Apple Speech 在本机转写，依赖设备能力、语言资源及权限；不可用时不自动改为云端转写。

| 文件 | 用途 |
| --- | --- |
| `Movo/Config/Defaults.json` | 提醒时间、AI 阈值、超时、录音限制等 |
| `Movo/Config/ModelsCatalog.json` | 厂商端点和模型清单 |
| `Movo/Config/HealthKeywords.json` | 健康敏感词表 |
| `Movo/project.yml` | targets、编译选项、签名与 Info.plist 配置 |
| `Movo/Resources/*.entitlements` | 平台权限声明 |

## 代码导航

```text
Movo/
├── App/              应用入口、依赖装配、导航与输入管线
├── Features/         今日、计划、收件箱、回顾、搜索和设置页面
├── Domain/           领域模型、命令、查询、策略与仓储协议
├── Data/             本地存储、CloudKit 同步和导出
├── Intelligence/     AI 适配、提案处理、隐私和语音
├── Notifications/    本地提醒规划与投递
├── DesignSystem/     设计令牌和共享 SwiftUI 组件
├── Config/           运行参数资源
└── project.yml       XcodeGen 工程定义
Tests/                五组 macOS 单元测试
Scripts/verify.sh     双端构建与测试入口
docs/                 产品、开发和设计资料
```

`Movo` application target 包含 `App/` 与 `Features/`；`MovoKit` framework 包含共享领域、数据、智能、通知和设计系统。设计系统使用 SwiftUI，领域层不依赖 UI 或具体存储框架。

业务写操作通过 `DomainStore` 命令执行，页面读取查询视图；应用服务在 `AppEnvironment` 中装配。

## 项目文档

- [AGENTS.md](AGENTS.md)：代码代理协作约定、架构边界与验证要求。
- [开发指南](docs/Development.md)：代码定位、构建、调试、真机部署与排障。
- [产品需求](docs/PRD.md)：产品语义、交互规则与验收标准。
- [代码实施方案](docs/代码实施方案-V2.md)：领域模型、命令、隐私与同步设计。
- [UI 说明](docs/UI-Prompt.md) 与 [Pencil 设计稿](docs/design/Movo.pen)：视觉规范和页面设计。

构建参数与可执行命令以当前 `Movo/project.yml` 和 `Scripts/verify.sh` 为准；历史文档中的机器路径、数量统计和旧文件名可能不再适用。

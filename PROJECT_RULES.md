# My Quota Bar — 项目规则与背景

> 本文件是本项目唯一的权威背景文档。**新会话读此文件即可接上下文。**
> 每次架构性改动后必须同步更新本文件。

## 一句话目标

一个 **macOS 原生菜单栏应用**，常驻菜单栏，一键点开就能看到**我名下多个账号**里各项服务的剩余额度/用量。自己用 + 可发给朋友，纯本地，不上传任何数据，**零命令行依赖**。

## 为什么要做 / 核心定位

- 我有**多个账号**（目前是多个火山引擎账号），每个账号各有免费额度，所以才分账号。
- 不想每个账号单独开一个 App，**一个 App 管所有账号、所有平台**。
- 以后有新账号 / 新服务 / 新平台，直接往这个 App 里加，不再新建应用。
- 参考同级目录的 `~/workspace/codex-quota-menubar/`（样式可参考）——**但那是独立项目，绝不要改它**。

## 当前状态（2026-07，重构后）

**已完成并稳定运行**。核心能力：
- ✅ **多平台架构**：`Platform` 枚举（目前仅 `volcengine`），字段已埋入数据结构，加新平台不动 schema。
- ✅ **任意多账号**：每个账号一对 AK/SK，配置任意数量，可拖动排序。
- ✅ **火山 Agent Plan**：AK/SK 直调 OpenAPI `GetAFPUsage`（**已彻底移除 arkcli 依赖**）。
- ✅ **火山语音服务**：每账号可配 1–10 个语音应用，各自独立 AppID + 备注 + 额度。
- ✅ **测试驱动配置**：AK/SK、Agent Plan、每个语音应用都有独立「测试」按钮，绿/红反馈。
- ✅ **经典主从布局设置窗口** + **零命令行分发**。

## 关键设计原则（务必遵守）

### 1. 层级：平台 → 账号 → 服务 → 额度
```
平台（火山引擎 / 将来：硅基流动、阿里云…）
  └─ 账号（一份身份 = 一对 AK/SK = 一份免费额度）
       └─ 服务（Agent Plan / 语音应用1 / 语音应用2 / ...）
            └─ 该服务自己的额度信息（原样展示）
```
- 面板顶层**按账号分组**，账号内先 Agent Plan 后语音。
- 层级不要太深，一个面板平铺显示，不多级折叠。
- 账号名格式：面板里显示用户设的「账户名称」；平台名（如"火山引擎"）作为前缀语境。

### 2. 每个服务「照搬原样」，不统一格式、不做转换（最重要）
- **不**强行套用统一的 `used/total/百分比` 模型。
- 官方接口给什么字段就显示什么，**只做搬运，不做合并、不做统一抽象**。
  - **Agent Plan**：三个窗口 5 小时 / 每周 / 每月，各有已用、总额度、百分比、下次重置时间，单位 AFP。
  - **语音应用**：资源包 `purchased_amount` / `current_usage` / `expires`，单位照官方（"20.00 小时" / "20,000 次"）。
- 每个服务有**专属取数逻辑 + 专属展示卡片**，各服务互不影响。

### 3. 数值一律照官方原样，不压缩
- 保留官方返回的小数（去掉无意义末尾零），如 `1793.747 / 10000 AFP`。
- **禁止** k / w / 1.8K 这类友好压缩。和控制台网页对齐。

### 4. 菜单栏常驻显示：用户手动勾选一个
- 菜单栏图标旁常驻显示**一个**指标，由用户在「显示」设置里勾选；**不自动挑选、不轮换**。
- 图标窄（`imageScale(.small)`），跟随服务类型变化。

### 5. 防丢配置（关键约束）
- 所有持久化结构用**防御式 Codable**：缺字段给默认值、未知枚举回落，**旧配置永不因 schema 变动丢失**。
- `AccountConfig` / `SpeechApp` 都自定义了 `init(from:)`，加新字段时务必保持这个习惯。
- 有单测守这条底线（见"测试"节）。

## 技术选型（已定）

| 项 | 选择 |
|----|------|
| 语言 / UI | Swift 6 + SwiftUI `MenuBarExtra`（`.menuBarExtraStyle(.window)`） |
| 构建 | SPM + `build-app.sh`，universal（arm64 + x86_64），ad-hoc 本地签名（`codesign --sign -`），无需 Apple Developer 账号 |
| 分发 | 直接发 `outputs/My Quota Bar.app`。ad-hoc 签名未公证，对方首次打开需 `xattr -cr "路径"` 清除 quarantine（README 有说明）。**零 CLI 依赖，朋友只需填 AK/SK。** |
| 认证 | 账号级 AK/SK，火山签名 HMAC-SHA256（AWS V4 风格），见 `VolcSigner.swift` |
| 凭证存储 | AK/SK 加密存 macOS 钥匙串（按账号 UUID 隔离）；非敏感配置存 UserDefaults(JSON) |
| 定时刷新 | 每源独立 Timer；刷新中不重复发起；出错保留上次有效值；休眠/断网感知；`.default` RunLoop + tolerance 降耗 |
| 刷新间隔 | 默认 3 分钟（180s），可在「显示」设置按源独立调。上游有 5–30 分钟延迟 |
| 运行形态 | `LSUIElement=true`，无 Dock 图标，仅菜单栏 |

## 数据来源登记（官方接口变了照此更新）

### 火山 Agent Plan —— AK/SK 直调 OpenAPI（已验证 HTTP 200）
- **接口**：`GET https://ark.cn-beijing.volcengineapi.com/?Action=GetAFPUsage&Version=2024-01-01`
- **Service** `ark`，**Region** `cn-beijing`
- **认证**：账号 AK/SK（`VolcSigner`）
- **返回**：`Result.PlanType` + `AFPFiveHour` / `AFPWeekly` / `AFPMonthly`，各含 `Quota` / `Used` / `ResetTime`
- **注**：响应无账号 ID，身份另走 STS `GetCallerIdentity` 单独查。
- 实现：`AgentPlanProvider.swift`

### 火山语音 ASR / TTS —— AK/SK 公开 OpenAPI（已验证 HTTP 200）
- **接口**：`POST https://open.volcengineapi.com/?Action=ResourcePacksStatus&Version=2023-11-07`
- **Service** `speech_saas_prod`，**Region** `cn-north-1`
- **认证**：账号 AK/SK
- **请求体**：`{"AppID":<AppID>,"ResourceID":[...],"Type":["quota","prepaid"],"PageNumber":1,"PageSize":10,"States":["active"]}`
- **返回**（照搬原样）：`Result.Packs[].purchased_amount` / `current_usage` / `expires` / `type` / `instance_number`
- **重要限制**（已实测确认）：AK/SK **拿不到语音应用的官方名称**（所有"列应用/查应用"接口都 404，`alias`/`group_name` 返回空）。所以**语音应用名称只能用户手填备注**，拿不到就显示 AppID。
- **对应控制台**：豆包语音 → 各服务 → "服务包及使用详情"
- 实现：`SpeechProvider.swift`

### 账号身份 —— STS GetCallerIdentity
- **接口**：`GET https://open.volcengineapi.com/?Action=GetCallerIdentity&Version=2018-01-01`
- **Service** `sts`，**Region** `cn-north-1`
- **返回**：`Result.AccountId`（数字）、`Trn`（含 IAM 用户名，形如 `trn:iam::<id>:user/<名>`）
- **用途**：测试连接时拿账号 ID + 真实名称（IAM 用户名；若是默认 `user` 占位则回落账号 ID）自动填账户名称。
- 实现：`VolcSigner.fetchIdentity(...)` / `fetchAccountID(...)`

## 数据模型（核心）

- **`Platform`**（枚举，Codable）：`volcengine`。`displayName` 显示名；`from(_:)` 容错未知平台回落火山。加平台在此加 case。
- **`AccountConfig`**（Keychain.swift）：`id(UUID)` / `platform` / `alias` / `accountFullID?` / `enableAgentPlan` / `speechApps[]`。**自定义 Codable 防丢配置**。AK/SK 存钥匙串 `ak_<id>` / `sk_<id>`。
- **`SpeechApp`**：`id(UUID)` / `appID` / `label`。`displayLabel` = label 有值用 label，否则"应用 <AppID>"。**自定义 Codable**。
- **`AccountStore`**（Keychain.swift）：`load()`/`save()` JSON↔UserDefaults；`accessKeyID(for:)`/`secretAccessKey(for:)`/`setCredentials(...)`/`deleteCredentials(...)` 走钥匙串。
- **面板侧**：`Account` / `Service` / `ServiceContent`(枚举: `.agentPlan` / `.speech`)（QuotaModels.swift）。

## 项目结构

```
my-quota-bar/
├── PROJECT_RULES.md               # 本文件（唯一权威背景）
├── README.md                      # 使用/构建/分发说明
├── Package.swift
├── build-app.sh                   # 构建 + ad-hoc 签名（universal）
├── Resources/Info.plist           # LSUIElement=true, bundle id local.my.quota-bar
├── Sources/MyQuotaBar/
│   ├── MyQuotaBarApp.swift         # @main, MenuBarExtra + 设置 Window
│   ├── AppModel.swift              # 状态 + 账号CRUD + 定时刷新 + 菜单栏显示 + 测试方法
│   ├── Settings.swift              # 非账号设置持久化（菜单栏指标 / 刷新间隔）
│   ├── Keychain.swift              # 钥匙串封装 + AccountConfig + SpeechApp + AccountStore
│   ├── Models/
│   │   └── QuotaModels.swift       # Platform / Account / Service / 各服务原样数据结构
│   ├── Providers/
│   │   ├── VolcSigner.swift        # 共享 HMAC-SHA256 签名 + STS 身份查询
│   │   ├── AgentPlanProvider.swift # Agent Plan 取数 + test()
│   │   ├── SpeechProvider.swift    # 语音资源包取数 + test()
│   │   └── ProcessRunner.swift     # 子进程工具（当前无 CLI 依赖，保留）
│   └── Views/
│       ├── PopoverView.swift       # 面板主视图（按账号分组平铺）
│       ├── AccountSectionView.swift# 账号分组 + ServiceCardView 路由
│       ├── AgentPlanCardView.swift # Agent Plan 展示卡片
│       ├── SpeechCardView.swift    # 语音展示卡片
│       └── SettingsWindow.swift    # 设置窗口（账号主从布局 + 显示 Tab）
├── Tests/MyQuotaBarTests/
│   └── MyQuotaBarTests.swift       # 单测（17 个）
├── pics/                           # 截图（gitignore，含敏感信息）
└── outputs/                        # 构建产物 .app（gitignore）
```

## 设置窗口 UI（主从布局，经典 macOS 范式）

- **两个 Tab**：「账号」+「显示」。
- **账号 Tab = 左右主从**：
  - 左边栏：账号列表（选中高亮 + **拖动排序**，影响面板顺序），左下 `+`(添加) / `−`(删除选中，二次确认)。
  - 右侧详情：上「账号信息」(平台只读 / 名称 / 账号ID / AK / SK / 测试连接) + 下「服务」(Agent Plan 卡片 + 语音应用卡片们)。
  - 底部「保存修改」：有改动才可点，点后闪"✓ 已保存"停留当前账号（不跳走）。
- **添加账号**：独立小弹窗，平台 + AK/SK + 测试(可选，不挡保存) + 名称(测通自动填)。
- **服务卡片**：Agent Plan 和每个语音应用都是统一 `ServiceCardStyle` 圆角卡片，视觉同级。语音应用卡片：标题(备注/AppID) + AppID(带标题) + 备注(带标题) + 测试按钮 + 删除。
- **显示 Tab**：菜单栏显示哪个指标（Picker）；各源刷新间隔（**注意：间隔存 AppModel observable 属性，不是直读 UserDefaults，否则 Picker 会回弹**）。

## 开发约定（务必遵守）

- **每次改完代码，一律重建 + 杀旧进程 + 重新 open**，用户点开一定看到最新：
  ```bash
  cd ~/workspace/my-quota-bar && pkill -9 -f MyQuotaBar; sleep 2 && ./build-app.sh && open "outputs/My Quota Bar.app"
  ```
- SwiftUI 在 `MenuBarExtra(.window)` 里**不要用会塌成 0 高度的 `ScrollView`** 包主内容（面板会显空）；主面板用自然撑高的 `VStack`。
- **不得硬编码任何敏感信息**（AppID / AK / SK / 账号 ID）。仓库**公开**：AppID 用户填、AK/SK 存钥匙串、`pics/` 已 gitignore。
- **每源独立刷新间隔**（`AppModel.RefreshSource`），各自定时器互不影响。
- **关键纯逻辑必须有单测**（数值格式化、百分比除零保护、AFP 解析、显示名、倒计时文案、**schema 演进兼容**）。改相关逻辑后 `swift test` 确保绿。
- **凭证持久化**：AK/SK 一次配好永久存钥匙串，编辑账号自动回填，不需重复输入。改 `AccountConfig` 字段结构时务必保持防御式 Codable，否则旧配置会丢。

## Git 工作流（务必遵守）

- 远程：`https://github.com/tangyangguang/my-quota-bar.git`
- **每次改完、验证 OK 后 commit + push**，message 用中文。
  ```bash
  git add -A && git commit -m "…"
  for i in 1 2 3 4 5; do git push 2>&1 | tail -2 && git status -sb|head -1|grep -q ahead && sleep 4 || break; done
  ```
- 构建产物（`.build/`、`outputs/`）、截图（`pics/`）不入库。
- **稳定回滚点**：tag `stable-arkcli-v1`（commit `b437a96`）是旧的 arkcli 版本，保留作回滚。

## 加新平台 / 新服务（未来扩展指南）

**加新平台**（如硅基流动）：
1. `Platform` 枚举加 case + `displayName`。
2. 写该平台的 Provider（它的余额接口 + 它的认证方式）。
3. 添加账号弹窗按选中平台展示对应凭证输入（不同平台凭证形态可能不同）。
4. 火山账号完全不受影响，旧配置不丢。

**加新服务**（如火山下别的语音种类）：
1. `ServiceContent` 枚举加 case + 写对应 `*CardView`。
2. 写该服务的 Provider（取数 + test）。
3. `AccountConfig` 加对应开关字段（保持防御式 Codable）。
4. 用哪个加哪个，不用一次做完。

## 刻意不做（保持简洁）

- ❌ 不做账号密码登录 UI（只用 AK/SK）。
- ❌ 不做历史曲线、图表、系统通知推送。
- ❌ 不做统一额度抽象 / 格式转换（各服务原样展示）。
- ❌ 不做菜单栏轮换/自动挑选（用户勾选固定一个）。
- ❌ 不做云同步、不上传数据。
- ❌ 不动 codex-quota-menubar 项目。

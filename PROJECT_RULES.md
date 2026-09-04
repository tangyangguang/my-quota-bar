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

## 当前状态（2026-09，设置交互重构后）

**当前版本：1.1.0（build 2）稳定；设置交互重构见 `CHANGELOG.md` 未发布。** 核心能力：
- ✅ **多平台架构**：开放 `Platform` 标识 + `PlatformAdapter` 注册表（目前仅 `volcengine`）；未知平台原样保留，加新平台不破坏旧 schema。
- ✅ **任意多账号**：每个账号一对 AK/SK，配置任意数量，可拖动排序。
- ✅ **火山 Agent Plan**：AK/SK 直调 OpenAPI `GetAFPUsage`（**已彻底移除 arkcli 依赖**）。
- ✅ **火山语音服务**：每账号可配 1–10 个语音应用，各自独立 AppID + 备注 + 额度；**每个应用内 ASR / TTS 可分别独立开关**。
- ✅ **测试驱动配置**：AK/SK、Agent Plan、每个语音应用都有独立「测试」按钮，绿/红反馈。
- ✅ **设置「即时生效」**：改名 / 拨开关 / 增删语音应用 / 排序都立即落盘并刷新，无保存按钮；仅「更换密钥」先测试后保存。
- ✅ **开机自动启动**（`SMAppService`，通用页开关）+ **零命令行分发**。

## 关键设计原则（务必遵守）

### 1. 层级：平台 → 账号 → 服务 → 额度
```
平台（火山引擎 / 将来：硅基流动、阿里云…）
  └─ 账号（一份身份 = 一对 AK/SK = 一份免费额度）
       └─ 服务（Agent Plan / 语音应用1 / 语音应用2 / ...）
            └─ 该服务自己的额度信息（原样展示）
```
- 面板顶层**按账号分组**，账号内先 Agent Plan 后语音。
- 面板平铺为默认形态；账号和 Agent Plan 卡支持**折叠**（用户手动、状态持久化、新账号默认展开）。折叠不是隐藏：折叠态必须保留一行带额度色的摘要（各窗口/ASR·TTS 的剩余%），数字与展开态同源同字号。折叠 chevron 展开态 hover 才显示、折叠态常显。
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
- 菜单栏图标旁常驻显示**一个**指标，由用户在「通用」设置里勾选（也可在面板点卡片快捷钉选）；**不自动挑选、不轮换**。
- 图标窄（`imageScale(.small)`），跟随服务类型变化。

### 5. 防丢配置（关键约束）
- **账号 `id` 是稳定 UUID，绝不变更**：AK/SK 在钥匙串里按 `ak_<id>` / `sk_<id>` 存，只要 id 不变凭证就不丢。
- 持久化模型用编译器**合成 Codable**，字段与当前 schema 保持一致；历史遗留的多余字段（如已移除的 `enableSpeech`）解码时自动忽略。**不写旧格式兼容解码、不做数据迁移、不留兼容样板**。
- 未知平台 ID 原样保留并标记不支持，**绝不能误写成火山引擎**；`Platform` 是开放的 RawRepresentable，天然不丢未知值。
- `AccountStore` 保留备份回退 + 损坏写锁兜底：主配置损坏回退备份，都损坏则锁定写入，**绝不以空数组覆盖原数据**。
- 有单测守这条底线（见"测试"节）。

## 技术选型（已定）

| 项 | 选择 |
|----|------|
| 语言 / UI | Swift 6 + SwiftUI `MenuBarExtra`（`.menuBarExtraStyle(.window)`） |
| 构建 | SPM + `build-app.sh`，universal（arm64 + x86_64），本地自签名证书签名（证书名 `My Quota Bar Signing`，脚本首次运行自动生成并导入登录钥匙串，无需 Apple Developer 账号）。**不可退回 ad-hoc（`--sign -`）**：ad-hoc 身份随每次编译变化，钥匙串 AK/SK 会反复弹授权（每账号 2 次） |
| 分发 | 直接发 `outputs/My Quota Bar.app`。自签证书未公证，对方首次打开需 `xattr -cr "路径"` 清除 quarantine（README 有说明）。**零 CLI 依赖，朋友只需填 AK/SK。** |
| 认证 | 账号级 AK/SK，火山签名 HMAC-SHA256（AWS V4 风格），见 `VolcSigner.swift` |
| 凭证存储 | AK/SK 加密存 macOS 钥匙串（按账号 UUID 隔离）；非敏感配置存 UserDefaults(JSON) |
| 定时刷新 | 全 App 单一非重复调度 Timer；按源计算 nextAttempt；最多 4 个账号并发；失败指数退避；分项失败保留旧值；休眠/断网感知；Timer tolerance 降耗 |
| 刷新间隔 | 默认 3 分钟（180s），可在「通用」设置里调（UI 一个间隔，内部按源调度）。上游有 5–30 分钟延迟 |
| 开机启动 | `SMAppService.mainApp`，通用页开关；纯系统能力，不进配置 schema |
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
- **返回**：`Result.AccountId`（数字）、`Trn`。Trn 形如 `trn:iam::<id>:root`（主账号）或 `trn:iam::<id>:user/<名>`（子用户）；据此解析 `isRoot` 与子用户名，写入账号的 `iamIdentity`。**该接口只返回账号 ID 与 Trn，官方不开放手机号/邮箱查询，不要臆造手机号字段。**
- **用途**：测试连接时拿账号 ID + 真实名称（IAM 用户名；若是默认 `user` 占位则回落账号 ID）自动填账户名称。
- 实现：`VolcSigner.fetchIdentity(...)` / `fetchAccountID(...)`

## 数据模型（核心）

- **`Platform`**（开放标识 struct，Codable）：当前 `volcengine`。未知平台原样保留，`PlatformRegistry` 只公布当前可新建的平台。
- **`PlatformAdapter`**（Platforms/）：声明平台凭证字段、身份测试和服务目录；当前实现 `VolcenginePlatformAdapter`。
- **`AccountConfig`**（Keychain.swift）：`id(UUID)` / `platform` / `alias` / `accountFullID?` / `enableAgentPlan` / `speechApps[]` / `iamIdentity?`（身份标记 "root" / "user:<名>"，测试连接后写入，`identityBadge` 显示为「主账号 / 子用户 · 名」）。合成 Codable；AK/SK 存钥匙串 `ak_<id>` / `sk_<id>`。**没有独立语音总开关**：`hasActiveSpeech` 派生自 speechApps，`hasAnyService = enableAgentPlan || hasActiveSpeech`。
- **`SpeechApp`**：`id(UUID)` / `appID` / `label` / `enableASR` / `enableTTS`（合成 Codable）。`isActive` = AppID 为有效数字且 ASR/TTS 至少开一个；全不勾或 AppID 无效则不拉数、不出卡（配置仍保留）。`displayLabel` = label 有值用 label，否则"应用 <AppID>"。取数时只请求开启的子服务，关掉的不出卡、不报错。
- **`AccountStore`**（Keychain.swift）：`load()`/`save()` JSON↔UserDefaults；`accessKeyID(for:)`/`secretAccessKey(for:)`/`setCredentials(...)`/`deleteCredentials(...)` 走钥匙串。
- **面板侧**：`Account` / `Service` / `ServiceContent`(枚举: `.agentPlan` / `.speech`)（QuotaModels.swift）。

## 项目结构

```
my-quota-bar/
├── PROJECT_RULES.md               # 本文件（唯一权威背景）
├── README.md                      # 使用/构建/分发说明
├── CHANGELOG.md                   # 版本变化与当前稳定基线
├── Package.swift
├── build-app.sh                   # 构建 + ad-hoc 签名（universal）
├── Resources/Info.plist           # LSUIElement=true, bundle id local.my.quota-bar
├── Sources/MyQuotaBar/
│   ├── MyQuotaBarApp.swift         # @main, MenuBarExtra + 设置 Window
│   ├── AppModel.swift              # 状态 + 账号即时编辑方法 + 单调度器/并发闸门 + 菜单栏显示 + 测试方法
│   ├── Settings.swift              # 非账号设置持久化（菜单栏指标 / 刷新间隔）
│   ├── LoginItem.swift             # 开机自动启动（SMAppService）
│   ├── Keychain.swift              # 钥匙串封装 + AccountConfig + SpeechApp + AccountStore
│   ├── Models/
│   │   └── QuotaModels.swift       # Platform / Account / Service / 各服务原样数据结构
│   ├── Platforms/
│   │   └── PlatformAdapter.swift   # 平台协议、服务目录、平台注册表、火山适配器
│   ├── Providers/
│   │   ├── VolcSigner.swift        # 共享 HMAC-SHA256 签名 + STS 身份查询
│   │   ├── AgentPlanProvider.swift # Agent Plan 取数 + test()
│   │   └── SpeechProvider.swift    # 语音资源包分项并发取数 + test()
│   └── Views/
│       ├── PopoverView.swift       # 面板主视图（按账号分组平铺）
│       ├── AccountSectionView.swift# 账号分组 + ServiceCardView 路由
│       ├── AgentPlanCardView.swift # Agent Plan 展示卡片
│       ├── SpeechCardView.swift    # 语音展示卡片
│       └── SettingsWindow.swift    # 设置窗口（账号主从布局 + 显示 Tab）
├── Tests/MyQuotaBarTests/
│   └── MyQuotaBarTests.swift       # 单测（22 个）
├── pics/                           # 截图（gitignore，含敏感信息）
└── outputs/                        # 构建产物 .app（gitignore）
```

## 设置窗口 UI（主从布局 + 即时生效）

- **两个 Tab**：「账号」+「通用」。
- **核心范式：改了立即生效**（macOS 系统设置风格）。**没有保存按钮、没有草稿、没有未保存拦截**：
  - 改名 → `setAlias`（只落盘 + 改面板名，不拉网络）。
  - 拨 Agent Plan 开关、增删语音应用、改 AppID/备注/ASR·TTS 复选框 → 落盘后 `reconfigureService`（提升代数丢弃旧响应 → 清空该账号展示 → 按新配置重拉）。
  - 语音文本框（AppID/备注）用本地草稿，在 onSubmit / 复选框 / 测试 / 删除 / onDisappear 时把「AppID 有效」的应用同步到 model；空 AppID 草稿只留界面、不入库不拉数。`setSpeechApps` 与现状一致时跳过，避免无意义重拉。
- **账号 Tab = 左右主从**：
  - 左边栏：账号列表（选中高亮 + **拖动排序**，影响面板顺序），左下 `+`(添加) / `−`(删除选中，二次确认)。选中切换无拦截。
  - 右侧**单页滚动**，三个平级分组（与官方「账号 → 服务域 → 服务实例」层级对齐）：
    - 「账号」：平台只读 / 名称（即时）/ 账号 ID / **「更换密钥…」按钮**（AK/SK 不常驻输入框）。
    - 「套餐」：订阅套餐类服务，现在是 Agent Plan 卡片（`ServiceCardStyle`，开关 + 测试）；以后有别的套餐加这里。
    - 「语音」：语音服务域。标题行右侧「添加应用」；下面每个语音应用（AppID）直接平铺成与 Agent Plan **同级**的 `ServiceCardStyle` 卡片，**没有语音总开关、没有包裹卡**。
- **语音启用逻辑**：没有总开关。一个语音应用是否取数/显示，完全由它的 ASR/TTS 复选框决定——两个都不勾 = 不拉数、面板不显示（AppID/备注保留，等同关闭）；删除应用才彻底移除。
- **更换密钥**：独立弹窗，预填当前 AK/SK；改后必须先「测试连接」通过才能「保存密钥」；密钥真的变了才清身份缓存并重拉（`changeCredentials`）。
- **语音子服务开关**：每个语音应用卡片内有「语音识别 ASR」「语音合成 TTS」两个复选框；关掉的子服务不请求、不出卡（例如 ASR 用尽可只关 ASR 保留 TTS）。
- **添加账号**：独立小弹窗，平台 + AK/SK + 测试(可选，不挡保存) + 名称(测通自动填)；添加后自动选中，服务默认全关，自行拨开关即时生效。
- **通用 Tab**：菜单栏显示哪个指标（Picker）；**一个**「刷新间隔」（写所有源，间隔存 AppModel observable 属性、不是直读 UserDefaults，否则 Picker 回弹）；「开机自动启动」开关（SMAppService）；版本号。

## 开发约定（务必遵守）

- **每次改完代码，一律重建 + 杀旧进程 + 重新 open**，用户点开一定看到最新：
  ```bash
  cd ~/workspace/my-quota-bar && pkill -9 -f MyQuotaBar; sleep 2 && ./build-app.sh && open "outputs/My Quota Bar.app"
  ```
- SwiftUI 在 `MenuBarExtra(.window)` 里的滚动区必须先测量内容并设置非零显式高度，避免 `ScrollView` 塌成 0；内容未超上限时使用自然高度，超出后才滚动。
- **不得硬编码任何敏感信息**（AppID / AK / SK / 账号 ID）。仓库**公开**：AppID 用户填、AK/SK 存钥匙串、`pics/` 已 gitignore。
- **刷新间隔**：内部仍按 `AppModel.RefreshSource`（agentPlan / speech）分别调度，但全 App 只用一个调度 Timer，禁止按账号创建 Timer；设置 UI 只暴露一个「刷新间隔」，写入时同时设置所有源。请求经并发闸门限制为最多 4 个账号并发。
- **设置交互一律即时生效**，不要再引入「保存按钮 + 草稿 + 未保存拦截」；唯一例外是更换密钥（先测试通过才写入）。
- **关键纯逻辑必须有单测**（数值格式化、百分比除零保护、AFP 解析、显示名、倒计时文案、**schema 演进兼容**）。改相关逻辑后 `swift test` 确保绿。
- **凭证持久化**：AK/SK 一次配好永久存钥匙串，编辑账号自动回填。Keychain 必须原地 update、检查 OSStatus；两项写入失败要回滚，禁止先删旧值。
- **配置保护**：主 JSON 覆盖前保留最近有效备份；主配置损坏时回退备份，主备份都损坏则锁定写入，绝不能以空数组覆盖原始数据。
- **异步一致性**：账号配置带运行时代数 revision；账号修改/删除后旧请求结果必须丢弃，禁止“删除后又被旧响应加回来”。

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
1. 新增该平台的稳定 `Platform` ID，并实现 `PlatformAdapter`（凭证字段、身份测试、服务目录），注册进 `PlatformRegistry`。
2. 写该平台的 Provider（余额/额度接口及认证方式）。
3. 添加账号弹窗按 Adapter 的凭证描述展示对应输入（不同平台凭证形态可完全不同）。
4. 火山账号完全不受影响，旧配置不丢。

**加新服务**（如火山下别的语音种类）：
1. `ServiceContent` 枚举加 case + 写对应 `*CardView`。
2. 写该服务的 Provider（取数 + test）。
3. `AccountConfig` 加对应字段（合成 Codable，字段保持非可选、与当前 schema 一致）。
4. 用哪个加哪个，不用一次做完。

## 刻意不做（保持简洁）

- ❌ 不做账号密码登录 UI（只用 AK/SK）。
- ❌ 不做历史曲线、图表、系统通知推送。
- ❌ 不做统一额度抽象 / 格式转换（各服务原样展示）。
- ❌ 不做菜单栏轮换/自动挑选（用户勾选固定一个）。
- ❌ 不做云同步、不上传数据。
- ❌ 不动 codex-quota-menubar 项目。

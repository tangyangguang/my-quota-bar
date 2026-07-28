# My Quota Bar — 项目规则与背景

> 本文件是本项目唯一的权威背景文档。新会话读此文件即可接上下文。
> （旧的 PROJECT_BRIEF.md 已废弃删除，理解有偏差，一律以本文件为准。）

## 一句话目标

一个 **macOS 原生菜单栏应用**，常驻菜单栏，一键点开就能看到**我名下多个火山引擎账号**里各项服务的剩余额度/用量。自己用，只在自己的 Mac 上跑，纯本地，不上传任何数据。

## 为什么要做 / 核心定位

- 我有**多个火山引擎账号**（目前 2 个），每个账号各有免费额度，所以才分账号。
- 不想每个账号单独开一个 App，**一个 App 管所有账号**。
- 以后有新账号 / 新服务，直接往这个 App 里加，不再新建应用。
- 参考同级目录的 `~/workspace/codex-quota-menubar/`（Codex 额度菜单栏）——**样式可以接受、架构可参考，但那是独立项目，不要动它**。本项目是全新的、更通用的额度总控台。

## 关键设计原则（务必遵守）

### 1. 层级：账号 → 服务，一张面板平铺
```
账号（一个火山账号 = 一份身份 / 一份免费额度）
  └─ 服务（该账号下的某项：Agent Plan / ASR / TTS / ...）
       └─ 该服务自己的额度信息（原样展示）
```
- 顶层**按账号分组**（不是按服务类型分）。
- 层级**不要太深**，一个面板里直接平铺显示完，不要多级折叠、不要抽屉。
- 力求**简洁清晰**，方便个人快速一眼看懂。

### 2. 每个服务「照搬原样」，不统一格式、不做转换（最重要）
- **不**强行套用统一的 `used/total/百分比` 模型。
- 每个服务在火山控制台网页上**原本长什么样，就搬过来长什么样**：
  - **Agent Plan**：有多个窗口 —— 5 小时 / 每周(weekly) / 每月(monthly)，每个窗口有已用、总额度、百分比、下次重置时间。
  - **语音识别 ASR**：形如「已用多少小时 / 共多少小时（如 20h 免费额度）」。
  - **语音合成 TTS**：形如「总共多少次 / 已调用多少次」（按官方实际给的字段，可能是次数、字符数或时长，以官方为准）。
- 官方接口给什么字段就显示什么，**我们只做搬运，不做合并、不做统一抽象**。
- 因此每个服务有它**专属的取数逻辑 + 专属的展示卡片**，各服务互不影响。

### 3. 菜单栏常驻显示：用户手动勾选一个作为默认
- 菜单栏图标旁边常驻显示**一个**指标（一个百分比，或一个数字——取决于该指标本身形态）。
- 到底显示哪一个，由用户**在设置里勾选**决定；**不做自动挑选、不做轮换**。选哪个就固定显示哪个，逻辑最简单。默认固定显示 Agent Plan 的「5 小时」窗口。
- 有百分比的指标显示百分比；纯数字的指标显示数字。
- **菜单栏图标要省横向空间**：图标用 `imageScale(.small)`，且**图标跟随服务类型变化**（Agent Plan 用 `a.circle`，不同服务用不同的窄图标区分），间距压到最小。

### 3.5 数值一律「照官方原样」显示，不压缩
- 面板里的已用/总量等数字**原样展示**，保留官方返回的小数（去掉无意义的末尾零即可），例如 `1793.747 / 10000 AFP`、`25873.646 / 100000 AFP`。
- **禁止**做 k / w / 1.8K 这类友好压缩。官方返回什么就显示什么，和控制台网页对齐。
- 账号分组标题用**真实账号信息**（arkcli `viewer.user_name` + `account_id` 末 4 位），不要写死「账号A」这类占位名。

### 4. 数据来源要在本文件登记，官方变了就改代码
- 每接入一个服务，就在下方「服务数据来源登记」里记录：数据从哪来、字段结构、对应控制台哪个页面。
- **如果官方接口/网页字段变了，照着这份登记去更新对应服务模块即可**，不影响其他服务。

## 技术选型（已定）

| 项 | 选择 |
|----|------|
| 语言 / UI | Swift + SwiftUI `MenuBarExtra`（`.menuBarExtraStyle(.window)`），参考 codex-quota-menubar |
| 构建 | Swift Package Manager + `build-app.sh`，编译 universal（arm64 + x86_64），ad-hoc 本地签名（`codesign --sign -`），无需 Apple Developer 账号 |
| 分发 | 直接把 `outputs/My Quota Bar.app` 发给别人。因 ad-hoc 签名未公证，对方第一次打开会被 Gatekeeper 拦；需 `xattr -cr "路径/My Quota Bar.app"` 清除 quarantine 后双击即可（已实测有效）。README 有完整说明。 |
| 定时刷新 | Timer 定时刷新；刷新中不重复发起；出错保留上一次有效值 |
| 刷新间隔 | 5 分钟（300s）。因 arkcli 数据本身有 5–30 分钟延迟，无需高频 |
| 运行形态 | `LSUIElement=true`，无 Dock 图标，仅菜单栏 |

## 账号与服务现状

### 账号 A：Agent Plan（arkcli profile，类型 agent-plan）
- **服务：Agent Plan** —— 三个窗口（5h / weekly / monthly）。
- profile 名 **不写死**：App 启动时调 `arkcli profile list` 自动发现，默认选第一个 `type=agent-plan` 的；用户可在设置「密钥」Tab 下拉改选（持久化到 UserDefaults）。这样别人装了用自己的 arkcli 登录态即可。
- 开发机器上当前的示例 profile：`agent-plan_cn-beijing_personal`（仅供参考，代码里不硬编码）。
- 数据来源：✅ 已确认可行，见下方登记。

### 账号 B：`platform_cn-beijing_accountwide`（控制台按量 / 语音服务身份）
- **服务：语音识别 ASR**（约 20h 免费额度） + **语音合成 TTS**（次数/字符/时长待定）。
- 数据来源：⚠️ 待调研。arkcli **明确不支持**语音模型用量查询，需走火山语音 OpenAPI（可能需账号 B 的 AK/SK）。
- 状态：**第二步实现。**待确认：控制台哪个页面看到 ASR 免费额度、TTS 单位是什么、账号 B 是否已有 AK/SK。

## 服务数据来源登记

### [账号A] Agent Plan —— arkcli
- **命令**：
  ```bash
  ARKCLI_CALLER_TYPE=ai_agent ARKCLI_CALLER_NAME=<agent> ARKCLI_SKILL_NAME=arkcli-usage \
  arkcli usage plan --profile agent-plan_cn-beijing_personal --format json
  ```
- **认证**：arkcli SSO 登录态；token 过期需在终端重新 `arkcli` 登录。
- **数据延迟**：5–30 分钟（上游 BFF 聚合），额度监控够用。
- **真实返回结构**（2026-07 实测）：
  ```json
  {
    "viewer": { "user_name": "...", "account_id": "...", "profile": "...", "region": "..." },
    "items": [
      {
        "product": "agent-plan", "edition": "personal", "tier": "medium", "subscribed": true,
        "periods": [
          { "label": "5h",      "used": 1706.99, "total": 10000,  "percent": 17.07, "reset_at": "2026-07-28T02:47:25+08:00" },
          { "label": "weekly",  "used": 9602.37, "total": 35000,  "percent": 27.44, "reset_at": "2026-08-03T00:00:00+08:00" },
          { "label": "monthly", "used": 25841.7, "total": 100000, "percent": 25.84, "reset_at": "2026-08-15T23:59:59+08:00" }
        ]
      }
    ]
  }
  ```
- **展示**：三行窗口（5小时/每周/每月），每行 = 进度条 + 百分比 + 已用/总量 + 重置时间。额度单位 AFP。

### [账号B] 语音 ASR / TTS —— ✅ 已确认可行（AK/SK 公开 OpenAPI）
- **接口**：火山引擎公开 OpenAPI 网关 `open.volcengineapi.com`
  - Method: `POST`，Query: `Action=ResourcePacksStatus&Version=2023-11-07`
  - Service: `speech_saas_prod`，Region: `cn-north-1`
- **认证**：账号级 AK/SK（火山签名 HMAC-SHA256，AWS V4 风格）。环境变量：
  - `VOLC_ACCESS_KEY_ID`（AK，形如 AKLT...）
  - `VOLC_SECRET_ACCESS_KEY`（SK）
- **AppID**：`<你的AppID>`（应用 app1）。后续多 app 可扩展。
- **请求体**（已实测 HTTP 200）：
  ```json
  // ASR（语音识别，小时）
  {"AppID":<你的AppID>,"ResourceID":["volc.seedasr.sauc.duration"],"Type":["quota","prepaid"],"PageNumber":1,"PageSize":10,"States":["active"]}
  // TTS（语音合成，次数）
  {"AppID":<你的AppID>,"ResourceID":["volc.tts.default"],"Type":["quota","prepaid"],"PageNumber":1,"PageSize":10,"States":["active"]}
  ```
- **返回字段**（照搬原样）：`Result.Packs[].purchased_amount`（如 "20.00 小时" / "20,000 次"）、`current_usage`（如 "8.79 小时" / "34 次"）、`expires`、`type`（试用包）、`instance_number`。
- **对应控制台**：豆包语音 → 各服务 → “服务包及使用详情”。
- **注**：控制台网页走的是 `console.volcengine.com/api/top/...` 内部接口（cookie 认证），但同一 Action 在公开网关上用 AK/SK 也能调（已验证），故**首选 AK/SK**，不用 cookie（cookie 会过期）。
- **签名算法参考**：`/tmp/sniff/sign_test.py`（Python 验证版）；Swift 实现在 `SpeechProvider.swift`。

## 项目结构

```
my-quota-bar/
├── PROJECT_RULES.md               # 本文件（唯一权威背景）
├── README.md                      # 使用/构建说明
├── Package.swift
├── build-app.sh                   # 构建 + ad-hoc 签名
├── Resources/Info.plist
├── Sources/MyQuotaBar/
│   ├── MyQuotaBarApp.swift         # @main, MenuBarExtra 入口
│   ├── AppModel.swift              # 状态 + 定时刷新 + 菜单栏显示项选择
│   ├── Settings.swift              # 用户设置（菜单栏显示哪个指标）持久化
│   ├── Models/
│   │   └── QuotaModels.swift       # Account / Service / 各服务原样数据结构
│   ├── Providers/
│   │   ├── ProcessRunner.swift     # 子进程执行工具
│   │   └── ArkPlanProvider.swift   # 账号A: arkcli 取 Agent Plan
│   │   └── (后续) SpeechProvider.swift
│   └── Views/
│       ├── PopoverView.swift       # 面板主视图（按账号分组平铺）
│       ├── AccountSectionView.swift# 账号分组
│       └── AgentPlanCardView.swift # Agent Plan 专属展示卡片
└── outputs/                        # 构建产物 .app
```

## 开发约定（务必遵守）

- **每次改完代码，一律重新构建 + 杀掉旧进程 + 重新 open 启动**，让用户点开看到的一定是最新效果。用户无法看到未重启的改动。
  ```bash
  pkill -9 -f MyQuotaBar; sleep 2; ./build-app.sh; open "outputs/My Quota Bar.app"
  ```
- SwiftUI 在 `MenuBarExtra(.window)` 里**不要用会塌缩成 0 高度的 `ScrollView`** 包主内容，直接用 `VStack` 自然撑高（否则面板看起来是空的）。
- 子进程调用 arkcli 时必须**补全 PATH**（`/opt/homebrew/bin` 等），否则 GUI app 环境找不到 node，报 `env: node: No such file or directory`。
- **信息层级：平台 → 账号 → 服务 → 额度**。平台名（如“火山引擎”）永远在最前；账号名格式统一为 `平台 · 账号名 (…尾号)`；服务作为卡片挂在账号下（Agent Plan / 语音识别 ASR / 语音合成 TTS 各算一个服务）。不要把服务名当账号名。
- **不得硬编码任何敏感信息**（AppID / AK / SK / 账号 ID）到代码里。仓库是**公开**的：
  - 语音 AppID 由用户在设置里填（默认空）；AK/SK 存钥匙串。
  - `pics/`（控制台截图，含账号/密钥）已在 `.gitignore`，不入库。
- **每个数据源独立刷新间隔**（`AppModel.RefreshSource`），各自一个定时器，互不影响。
- **关键纯逻辑必须有单测**（不求多，只盖易错/重要点）：数值格式化、百分比计算（除零保护）、譍量抽数、Agent Plan JSON 解析、倒计时文案。改动相关逻辑后跑 `swift test` 确保绿。

## Git 工作流（务必遵守）

- 远程仓库：`https://github.com/tangyangguang/my-quota-bar.git`
- **每次改完、验证无问题后，都要 commit 并 push 到远程**。commit message 用中文简述本次改动。
  ```bash
  git add -A && git commit -m "…" && git push
  ```
- 构建产物（`.build/`、`outputs/`）、截图（`pics/`）不入库。

## 实现节奏

1. **[✅ 已完成] 第一步：账号 A · Agent Plan** —— 完整可用的菜单栏 App，能看三窗口，真实账号名、原样数值、窄图标、5h 默认显示、自动刷新、失败保留旧值。
2. **[✅ 已完成] 第二步：账号 B · 语音 ASR/TTS** —— AK/SK 签名调 `ResourcePacksStatus`，钥匙串存储，独立设置窗口（显示/服务开关/密钥三 Tab），服务可显示/隐藏，每源独立刷新间隔。
3. 以后随时按「平台 · 账号 → 服务」模式加新账号/新服务，每个服务写自己的 Provider + 展示卡片。已预留多账号（含同类型多个语音账号）结构。

## 刻意不做（保持简洁）

- ❌ 不做账号登录 UI（凭证走 arkcli profile / 本地配置）。
- ❌ 不做历史曲线、图表、系统通知推送。
- ❌ 不做统一额度抽象 / 格式转换（各服务原样展示）。
- ❌ 不做菜单栏轮换/自动挑选（用户勾选固定一个）。
- ❌ 不做云同步、不上传数据。
- ❌ 不动 codex-quota-menubar 项目。

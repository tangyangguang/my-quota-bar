# My Quota Bar

一个 macOS 菜单栏应用，常驻菜单栏查看多个火山引擎账号下各项服务的剩余额度。**本机应用，纯本地运行，不上传任何数据。**

> 项目背景与设计原则见 [PROJECT_RULES.md](./PROJECT_RULES.md)（唯一权威文档）。

## 信息层级

**平台 → 账号 → 服务 → 额度**。平台名永远在最前，账号名格式统一为 `平台 · 账号名 (…尾号)`，服务作为卡片挂在账号下。

## 当前支持

- **火山引擎 · Agent Plan**
  - 5 小时 / 每周 / 每月 三个窗口：进度条 + 剩余百分比 + 已用/总量 + 重置时间
  - 数据来源：本机 `arkcli usage plan`（走 arkcli 登录态，App 里选自己的 profile）
- **火山引擎 · 语音服务**（ASR 语音识别 / TTS 语音合成）
  - 已用/共 小时（ASR）、已用/共 次（TTS）
  - 数据来源：火山公开 OpenAPI `ResourcePacksStatus`，用账号级 AK/SK 签名调用
  - 需在设置里填入 AK/SK + 应用 AppID（存 macOS 钥匙串）

## 安装 & 配置（给第一次用的人）

### 0. 环境要求
- macOS 14 及以上
- 安装 Swift 6（装 Xcode 或 Command Line Tools 即可）
- 如需看 Agent Plan：安装火山官方 `arkcli` 并登录（`brew ...` 或官方方式安装后运行 `arkcli` 登录）

### 1. 构建 App
```bash
git clone https://github.com/tangyangguang/my-quota-bar.git
cd my-quota-bar
./build-app.sh
open "outputs/My Quota Bar.app"
```
菜单栏会出现一个图标 + 一个数字。

### 2. 配置 Agent Plan（用你自己的账号）
1. 先确保本机装了 arkcli 且已登录：终端运行 `arkcli profile list` 能看到你的 profile。
2. 点菜单栏图标 → 「设置」→「密钥」Tab → 顶部「火山引擎 · Agent Plan」。
3. 在下拉里**选择你自己的 profile**（类型是 `agent-plan` 的那个）。首次启动 App 会自动尝试选中第一个 agent-plan 类型的 profile，通常无需手动改。
4. 凭证走本机 arkcli 登录态，**不用在 App 里填任何密钥**。

> 换句话说：每个人指定的是「自己电脑上 arkcli 里的哪个 profile」，所以你朋友装了 App、用他自己的 arkcli 登录，选他自己的 profile 即可，互不影响。

### 3. 配置语音服务（可选）
1. 在火山引擎控制台「访问控制」创建一对 **Access Key ID / Secret Access Key**。
2. 找到语音应用的 **AppID**（豆包语音控制台里的应用 ID）。
3. 「设置」→「密钥」Tab →「火山引擎 · 语音服务」，填入 AK / SK / AppID，点「保存并刷新」。
4. 不配置就不显示语音，配置后自动出现。密钥加密存入 macOS 钥匙串，纯本地。

## 使用

点开菜单栏图标看全部账号服务；点「设置」打开独立设置窗口：
- **显示**：菜单栏常驻显示哪个指标；各服务独立的刷新间隔
- **服务**：勾选每个服务显示/隐藏（如额度用完不想看）
- **密钥**：Agent Plan profile 选择；语音服务 AK/SK / AppID（小眼睛可显示明文核对）

特性：各数据源独立定时刷新、刷新失败保留上一次有效值、纯本地不上传。

## 加新账号 / 新服务（给开发者）

见 PROJECT_RULES.md。要点：每个服务「照搬原样」，写自己的 Provider（取数）+ 展示卡片（`ServiceContent` 加 case + 对应 `*CardView`），并在 `AppModel` 登记账号/服务。已预留多账号（含同类型多个账号）结构。

## 测试

关键逻辑有单测（`Tests/MyQuotaBarTests/`，不求多、只盖数据正确性命脉）：

```bash
swift test
```

覆盖：数值格式化（去尾零/限位）、百分比计算（除零/越界裁剪）、语音数值抽取（千分位逗号）、Agent Plan JSON 解析（字段缺失/窗口排序/异常抛错）、重置倒计时文案（分/时/天边界）。

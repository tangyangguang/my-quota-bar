# My Quota Bar

一个 macOS 菜单栏应用，常驻菜单栏查看多个火山引擎账号下各项服务的剩余额度。纯本地运行，不上传任何数据。自己用。

> 项目背景与设计原则见 [PROJECT_RULES.md](./PROJECT_RULES.md)（唯一权威文档）。

## 信息层级

**平台 → 账号 → 服务 → 额度**。平台名永远在最前，账号名格式统一为 `平台 · 账号名 (…尾号)`，服务作为卡片挂在账号下。

## 当前支持

- **火山引擎 · Agent Plan**（`agent-plan_cn-beijing_personal` profile）
  - 5 小时 / 每周 / 每月 三个窗口：进度条 + 剩余百分比 + 已用/总量 + 重置时间
  - 数据来源：`arkcli usage plan`（需本机已安装 arkcli 且登录）
- **火山引擎 · 语音服务**（ASR 语音识别 / TTS 语音合成）
  - 已用/共 小时（ASR）、已用/共 次（TTS）
  - 数据来源：火山公开 OpenAPI `ResourcePacksStatus`，用账号级 AK/SK 签名调用
  - 需在设置里填入 AK/SK + 应用 AppID（存 macOS 钥匙串）

## 使用

菜单栏出现图标 + 一个百分比/数字。点开看全部账号服务；点「设置」打开独立设置窗口：
- **显示**：菜单栏常驻显示哪个指标；各服务独立的刷新间隔
- **服务**：勾选每个服务显示/隐藏（如额度用完不想看）
- **密钥**：语音服务 AK/SK / AppID（小眼睛可显示明文核对）

特性：各数据源独立定时刷新、刷新失败保留上一次有效值、纯本地不上传。

## 构建

```bash
./build-app.sh
open "outputs/My Quota Bar.app"
```

要求：macOS 14+、Swift 6、本机安装 `arkcli` 并已配置对应 profile。

## 加新账号 / 新服务

见 PROJECT_RULES.md。要点：每个服务「照搬原样」，写自己的 Provider（取数）+ 展示卡片（`ServiceContent` 加 case + 对应 `*CardView`），并在 `AppModel` 登记账号/服务。已预留多账号（含同类型多个账号）结构。

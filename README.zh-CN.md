<div align="center">

<img src="docs/assets/icon-256.png" alt="Decaf 应用图标" width="80" height="80">

# Decaf

**Agent 干活时，让 Mac 保持唤醒；一天结束，留下一张 token 咖啡小票。**

原生 macOS 菜单栏工具：自动检测 Agent，统一统计 Claude Code + Codex 的每日／每月用量。

[开始使用](#开始使用) · [三个用途](#三个用途) · [使用指南](docs/usage.zh-CN.md) · [English](README.md)

</div>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/home-dark.png">
  <img src="docs/assets/home-light.png" alt="Decaf 自动检测 Agent 并保持唤醒，统一统计 Claude Code 与 Codex 的每日和每月 token" width="960">
</picture>

<sub>Decaf 0.3.0 首页：自动防休眠、token 统计和 Your rhythm。原生界面，使用示例数据。</sub>

> **v0.3.3 — 换账号，接着聊。** 从独立侧栏页面迁移本地 Claude Code 会话，支持已验证的 Claude Desktop 版本。[使用方法 →](docs/usage.zh-CN.md#迁移会话) · [升级 →](docs/usage.zh-CN.md#更新)

## 三个用途

- **自动防休眠。** 检测到 Agent 活动就保持唤醒，活动结束后按对应缓冲时间释放。两个工具各自保活，一个结束不影响另一个；也支持手动定时和电量保护。
- **统一 token 统计。** Claude Code + Codex 每日、自然月和历史用量，合计或分工具查看，并能检查缓存明细和导入状态。
- **留下自己的记录。** Your rhythm 活动与月卡，在本机预览、复制或保存；月卡默认隐藏 token 数字。[详细使用指南 →](docs/usage.zh-CN.md)

<details>
<summary>16 秒真实操作：运行 Agent → 月度统计 → 保存卡片</summary>

<picture>
  <source media="(prefers-reduced-motion: reduce)" srcset="docs/assets/home-light.png">
  <img src="docs/assets/decaf-live-demo.gif" alt="真实操作录屏：运行 Codex、查看月度统计、保存月卡；历史用量为示例数据" width="840">
</picture>

录制于 0.2.x 界面。实际运行 Codex，打开真实菜单和月度统计，再通过原生保存窗口导出 PNG。录制使用隔离演示程序，月度历史为示例数据；只剪掉操作间的停顿。Codex 的文件活动缓冲可能在任务结束后继续保活。[查看 MP4](docs/assets/decaf-live-demo.mp4)。

</details>

## 开始使用

需要 **macOS 14 或更新版本**。

1. **装好它。**

   ```sh
   brew install --cask AlanY1an/decaf/decaf
   ```

   也可以[下载 DMG](https://github.com/AlanY1an/decaf/releases/latest)。

2. **找到杯子。** 从「应用程序」打开 Decaf，看菜单栏。Claude Code hooks 可选，Settings 会先展示安装改动。
3. **跑一个任务。** 在杯子菜单里看检测状态；点 **Open Decaf…** 看保活状态和两个工具的用量，再用 **Daily / Monthly** 切换范围。[首次使用指南 →](docs/usage.zh-CN.md)

<details>
<summary>附加功能：Your brew 个人页和月卡</summary>

从杯子菜单打开 **Open Decaf…**，首页的 Your rhythm 展示活动记录。选好月份后点 **Share your brew** 看月卡；昵称和咖啡印章在 **Settings → Your profile** 中修改。默认不显示 token 数字。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/profile-previous-month-card-dark.png">
  <img src="docs/assets/profile-previous-month-card-light.png" alt="Your brew 月卡：咖啡印章、有记录的活动，以及 Claude Code 和 Codex，隐藏 token 数字" width="360">
</picture>

<sub>昵称与数据均为示例。<a href="docs/usage.zh-CN.md#your-brew">看看个人页和卡片选项 →</a></sub>

</details>

## 数据留在你这里

Agent 检测和 token 统计留在本机。仅在主动检查或下载更新时访问 GitHub，不做后台检查或系统信息采集。用量包含缓存 token，只覆盖这台 Mac 可用的记录，缺失的历史不会凭空补齐。这是有记录的 token，不是账号账单，也不是生产力分数。[数据来源与边界 →](docs/usage.zh-CN.md#数据留在哪里)

保活会遵守电量等安全限制；合盖仍然允许休眠。Codex 检测属于近似判断。[检测方式 →](docs/usage.zh-CN.md#功能与边界)

## 一起把它做得好用

用 Claude Code、Codex 或两个一起，试一个正常的工作日：首次导入看懂了吗？Mac 该醒的时候醒着吗？明天还想打开吗？[留个简短反馈 →](https://github.com/AlanY1an/decaf/issues/new?template=feedback.yml)

欢迎代码、文档和无障碍改进。[参与开发](CONTRIBUTING.md) · [报告问题](https://github.com/AlanY1an/decaf/issues/new/choose) · [卸载](docs/usage.zh-CN.md#卸载) · [MIT](LICENSE)

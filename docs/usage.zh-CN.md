# 使用 Decaf

[← 首页](../README.zh-CN.md) · [English](usage.md)

**v0.3.0** 把自动防休眠、Claude Code/Codex 用量和 Your brew 整合到 Home，设置页就在旁边。[界面说明](interface.md)。

[安装](#安装) · [更新](#更新) · [首次使用](#首次使用) · [功能边界](#功能与边界) · [隐私](#数据留在哪里) · [卸载](#卸载)

## 安装

需要 **macOS 14 或更新版本**。

```sh
brew install --cask AlanY1an/decaf/decaf
```

也可以从 [GitHub Releases](https://github.com/AlanY1an/decaf/releases/latest) 下载 DMG。

从「应用程序」打开 **Decaf**，然后找菜单栏里的咖啡杯。它没有 Dock 图标。Claude Code hooks 可选，安装前会展示具体改动。

## 更新

先从杯子菜单退出 Decaf，再按原来的安装方式升级：

- **Homebrew 安装：** 运行下面的命令，再从「应用程序」打开 Decaf。
- **DMG 安装：** [下载最新版本](https://github.com/AlanY1an/decaf/releases/latest)，
  打开 DMG，把 Decaf 拖到「应用程序」并选择替换，然后重新打开。

```sh
brew update
brew upgrade --cask AlanY1an/decaf/decaf
```

**从 0.2.0 或更早版本升级：** 0.3.0 包含 0.2.1 的 Codex 用量恢复修复。重新打开后，等待导入完成，
再进入 **Home → Monthly**，选择 **Codex** 并查看受影响的月份。
Decaf 会自动备份旧 Codex 缓存，重新读取本机仍保留的活动及归档日志，补计因
父／子任务计数混用或遗漏已完成响应而跳过的用量。去重修正也可能让数字降低。
恢复依赖本机原始日志；已删除或只存在于远程的日志无法重建。无需删除缓存或重装。

不需要卸载。原有设置、集成路径和左键操作习惯会保留。从 0.1.0 升级时，
首次启动会先备份旧用量文件，再从可用日志重建统计。请等待导入完成；修正后的
数字可能与旧版不同。已缺失的源日志无法恢复，旧文件保留在
`~/Library/Application Support/Decaf/Backups/`。升级时不要执行
`brew uninstall --zap` 或删除应用数据目录。

从 v0.2.0 起，杯子菜单或 **Settings → General** 的 **Updates…** 会显示
当前版本和升级说明。只有主动点击才会在浏览器打开发布页，没有后台检查和
自动安装。v0.1.0 本身没有应用内更新通道。想收到以后新版本的通知，可以到
[GitHub 仓库](https://github.com/AlanY1an/decaf) 选择 **Watch → Custom → Releases**。

改动见 [更新日志](../CHANGELOG.md)。升级命令和订阅方式分别见
[Homebrew 官方说明](https://docs.brew.sh/Manpage)与
[GitHub 通知设置](https://docs.github.com/en/subscriptions-and-notifications/get-started/configuring-notifications)。

## 从源码构建

安装 Xcode 后运行：

```sh
git clone https://github.com/AlanY1an/decaf.git
cd decaf
Scripts/bootstrap.sh
Scripts/run.sh
```

这会在本机构建并打开当前源码。测试和开发说明见 [Contributing](../CONTRIBUTING.md)。

## 首次使用

1. 在这台 Mac 上运行 Claude Code、Codex，或者同时使用两者。
2. 打开咖啡杯菜单 → **Open Decaf…**，查看保活状态、每日统计和 Your rhythm。**Pause auto** 暂停两款工具的自动保活，手动保持仍由杯子菜单控制。新安装默认点击打开菜单；老用户保留左键切换保活、右键打开菜单的习惯。可在 **Settings → General → Left-click the cup** 中选择。
3. 切到 **Monthly** 看本月至今，用左右箭头查看已保存的历史月份；点柱子查看某天，点图表右上的月度合计返回整月。点工具名称筛选。月度小票还显示有记录的天数，以及这些天的日均用量；同一天用了两个工具，只算一天。
4. 点读取状态这一行，查看两个工具各自读取的日志数、读取时间、最早记录和导入问题。没有日志、正在导入和当天没记录会分别显示；最早日期不代表历史完整。遇到用量问题，可以点 **Copy support summary** 复制版本和导入状态，不包含用量数字或日志内容。
5. **The little details** 旁显示缓存读取占全部 token 的比例，展开可看输入、输出和缓存明细。点 **Copy card**，把当前日期或月份、当前筛选范围的小票复制为 PNG，自行粘贴分享。Decaf 不会上传它。

## Your brew

Your brew 已整合到 **Home**。从杯子菜单点 **Open Decaf…**（**⇧⌘P**），或从 Finder / Spotlight 重新打开 Decaf，即可进入首页。关闭窗口后，菜单栏检测继续运行。**Settings…** 或 **⌘,** 在同一窗口打开设置。

**Your rhythm** 展示两款工具合计的 90 天活动。选择 **Monthly** 后用月份箭头回看历史，活动图截止于所选月份的最后一天。工具筛选只影响 token 面板，活动图仍合计两个工具。空白日期可能是缺失的历史，同一天使用两款工具只算一个活跃日。

**Share your brew** 会预览所选月份实际导出的 PNG，再由你复制或保存。卡片可选择 **System / Light / Dark** 配色，默认隐藏 token 数字及其强度，勾选 **Show token totals** 才会加入。到 **Settings → Your profile** 修改可选昵称、咖啡图标和默认分享选项。从设置返回首页时，会保留所选月份、工具筛选和滚动位置。动画遵循系统「减少动态效果」设置。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/home-dark.png">
  <img src="assets/home-light.png" alt="Decaf 首页：自动防休眠、双平台用量和 Your rhythm 活动格子" width="960">
</picture>

<sub>0.3.0 首页：原生界面，昵称与数据均为示例。</sub>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/profile-previous-month-card-dark.png">
  <img src="assets/profile-previous-month-card-light.png" alt="Your brew 月度分享卡：咖啡印章、活动日历和双工具组合，隐藏 token 数字" width="360">
</picture>

<sub>留住这个月。示例数据，本机生成，随时复制或保存。</sub>

**菜单栏选项：** 可选择在杯子旁显示今日合计 token，也可以只保留图标。菜单打开时按 **⇧⌘U** 进入统计。首次引导分别检测两个工具，并可直接打开用量页面。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/usage-card-dark.png">
  <img src="assets/usage-card-light.png" alt="Decaf 小票示例：日期、两个工具的 token 用量和仓库地址" width="420">
</picture>

<sub>复制出来的小票。使用示例数据，不含项目名、路径、提示词或账号信息。</sub>

## 功能与边界

| | v0.1.0 | v0.3.0 |
| --- | --- | --- |
| Claude Code 防休眠 | 可选 hooks，文件活动作为后备 | 相同 |
| Codex 防休眠 | — | 任务日志 + 进程检查，文件活动作为后备 |
| Claude Code + Codex 每日 / 每月统计 | — | 总量、分工具明细、每日趋势、历史月份 |
| Home + Settings | — | 保活状态、用量、活动和设置整合到同一窗口 |
| Your brew | — | 本地昵称与图标、90 天活动和月度分享卡 |
| 复制每日 / 每月小票 | — | 本机生成 PNG |
| 手动保持、定时与电量保护 | 支持 | 支持 |

月度统计汇总本机已保存的记录，包含缓存 token；缺失的会话不会计入，也不代表整个账号的用量。

**可以同时使用两个工具。** 用量分别记录，再汇总成每日总量；保活请求各自管理，一个结束不会撤掉另一个的保活。

Claude Code hooks 提供回合信号。Codex 会在本地日志记录了未结束的任务、且 Codex 进程仍打开该日志用于写入时，延长静默任务的保活。任务完成、取消或写入进程关闭日志后会撤销这部分延长；普通文件活动仍有五分钟空闲窗口。连续两小时没有任务进展也会撤销延长。日志不能可靠反映等待授权的状态，因此仍属于近似判断。需要时可以手动保持唤醒。

低电量模式、电量过低等安全条件可以暂停保活。合盖仍然允许 Mac 休眠。

## 数据留在哪里

- **应用不发网络请求，没有分析追踪或后台更新检查。** 更新需要手动操作，主动点击发布页链接才会打开浏览器。
- 在本机解析已有日志，提取检测和统计需要的元数据，不保存或上传对话正文。
- Decaf 读取 Claude Code 日志（包含子代理）和 Codex 活跃及归档日志（默认 `~/.codex/sessions` 与 `archived_sessions`，支持 `CODEX_HOME`）。
- 统计升级会先备份旧账本，再重建可用历史；无法确定的计数变化会提示需要核对。
- 用量包含缓存 token，只覆盖本机可用记录；不代表账号全部用量、订阅额度、实际花费或生产力。
- 每日／每月小票导出选定日期和工具的 token 总量；个人卡片导出自选昵称／图标、所选月份有记录的活动和工具，token 数字默认隐藏、可主动开启。卡片都包含 Decaf 仓库地址，由你决定是否分享。
- 昵称、图标和分享偏好仅保存在本地，不会自动读取系统账号身份。在 Settings → Your profile 清空昵称即可恢复通用卡片。
- 可选 Claude hooks 和状态栏集成只修改 Decaf 自己的条目；设置中提供改动预览和卸载入口。

具体数据流见 [架构说明](architecture.md)。

## 卸载

如果启用了集成，先在 **Settings → Agents** 卸载 hooks 和状态栏集成，再退出 Decaf：

```sh
brew uninstall --cask AlanY1an/decaf/decaf
```

DMG 安装的用户可以把 Decaf 移出「应用程序」。退出会释放它持有的电源断言。

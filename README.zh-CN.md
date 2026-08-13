<div align="center">

<img src="docs/assets/icon-256.png" alt="Decaf 应用图标" width="180" height="180">

# Decaf

**把 `caffeinate` 命令做成会自己判断的菜单栏应用。**

Claude Code 真正在干活的时候不让 Mac 休眠——活干完了,或者只是在等你回话,立刻放行。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/menubar-icons-dark.png">
  <img src="docs/assets/menubar-icons-light.png" alt="菜单栏图标的四种状态:空闲、手动保持、agent 工作中并显示会话数、被安全保护暂停" width="480">
</picture>

<sub>四种状态。第一种下 Mac 正常休眠。</sub>

<p>
  <a href="https://github.com/AlanY1an/decaf/releases/latest"><img src="https://img.shields.io/badge/Download-.dmg-brightgreen?style=flat-square" alt="下载"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="需要 macOS 14 或更新版本">
  <a href="https://github.com/AlanY1an/homebrew-decaf"><img src="https://img.shields.io/badge/Homebrew-tap-orange?style=flat-square" alt="Homebrew tap"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-lightgrey?style=flat-square" alt="MIT 许可证"></a>
  <a href="https://github.com/AlanY1an/decaf/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/AlanY1an/decaf/ci.yml?style=flat-square&label=CI" alt="CI 状态"></a>
</p>

<a href="README.md">English</a>

</div>

---

## 它解决什么问题

你跑一个长任务,走开一会儿,回来发现它在第十分钟就停了——因为 Mac 睡了。

防休眠工具都是开关:开,或者关。开着不管,笔记本因为你开了个终端就整晚不睡。关着不管,你就得记得开。

那些「AI 感知」的进了一步,只要 agent 进程还活着就保持。这确实更好,但在最要紧的那种情况下**依然是错的**:**一个停在提示符前等你的 agent,和一个正在埋头思考的 agent,长得一模一样。** 前者应该让 Mac 睡,后者绝不能。

把这两者分开,就是这个产品的全部。

## 它做什么

- **一个回合在跑就保持唤醒**,结束几分钟后放手。
- **agent 在等你的时候让 Mac 睡。** 空闲的提示符不是干活。
- **不会放弃安静的长任务。** 一个跑 20 分钟的构建看着像闲着,其实不是。
- **扛得住自动循环。** agent 自己安排了下次唤醒时,Decaf 陪它一起等,而不是在间隙里睡过去。
- **也能当普通开关用。** 保持 30 分钟、到下午 6 点、或者无限期。
- **该让路时让路。** 低电量模式、快速用户切换、电量过低都会释放。合盖永远优先。

目前只支持 Claude Code。Codex 和 opencode 在路线图上。

## 安装

```sh
brew install --cask AlanY1an/decaf/decaf
```

或者从 [最新 release](https://github.com/AlanY1an/decaf/releases/latest) 下载 DMG。需要 **macOS 14 或更新版本**。

装完即用。首次启动时它会问要不要往 Claude Code 里装 hooks——装了之后精度从「大约五分钟」变成「精确到回合」。一次点击,可选,可撤销。

## 隐私

Decaf 监视 `~/.claude`,这件事值得一个直接的回答。

- **不发任何网络请求。** 没有遥测、没有分析,连更新检查都没有。
- **绝不读你的对话。** 它读时间戳、标识符和 token 计数——不读提示词,也不读回复。这条边界由代码结构本身保证并有测试钉住,不是靠自觉。
- **只写**自己的文件夹,以及你允许之后 `~/.claude/settings.json` 里它自己那几条。两者都能在设置里撤销。

而且**在写任何东西之前**,你会先看到它到底要写什么:

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/consent-sheet-dark.png">
  <img src="docs/assets/consent-sheet-light.png" alt="安装同意弹窗,列出 Decaf 会写入的文件,并预览将要合并进 ~/.claude/settings.json 的确切 JSON" width="520">
</picture>

## 设置

六项,不多不少。

| | |
| --- | --- |
| **为 agent 自动保持唤醒** | 默认开。关掉后完全不管 agent。 |
| **释放宽限期** | 回合结束后再保持多久。1–10 分钟,默认 3。 |
| **保持唤醒时的屏幕** | 正常休眠,或保持常亮。另有**立即关闭屏幕**。 |
| **电量门限** | 低于此电量停止保持。默认 20%。 |
| **默认手动时长** 和 **「直到」时刻** | 一键保持的行为。 |
| **登录时启动** | |

## 卸载

```sh
brew uninstall --cask AlanY1an/decaf/decaf
```

如果装过 hooks,**先**用 设置 → Agents → **卸载 Hooks**——它只移除 Decaf 的条目,其余原样不动。

电源断言随进程消亡,所以**退出或删除 Decaf 绝不可能让你的 Mac 从此无法休眠**。

## 路线图

- [x] Claude Code —— 精确检测、零配置兜底、自动循环
- [x] 手动保持、屏幕策略、电量门限
- [x] Token 用量与速率限制,每个数字都标注「官方」还是「估算」
- [ ] Codex、opencode
- [ ] 定时时间窗
- [ ] 自动更新
- [ ] 合盖模式,会有醒目警告

## 常见问题

**既然干的是 `caffeinate` 的活,为什么叫 Decaf(低因)?**
因为这活的关键是**知道什么时候停**。这个品类里的东西全都以兴奋剂命名,而且每一个都是你必须记得关掉的开关。Decaf 是那个会自己放下的。副标题保留 `caffeinate` 这个词,因为那是你熟悉的命令;但应用本身刻意不叫这个名字,这样它永远不可能遮蔽 `/usr/bin/caffeinate`。

**和 KeepingYouAwake、Amphetamine 有什么区别?**
那些是开关,而且是好开关。Decaf 是**做判断**的。如果你要的就是一个开关,KeepingYouAwake 维护得很好,你应该用它。(需要的时候 Decaf 也可以是那个开关。)

**必须装 hooks 吗?**
不必。不装的话它改看文件活动——分辨率大约五分钟而不是即时——菜单里会明说当前跑的是哪种。

**为什么不上 Mac App Store?**
沙盒让 Decaf 做的事**不可能实现**,不是「不太方便」。这是永久决定,不是待办事项。

**会耗电吗?**
它只能阻止休眠,而且低于 20% 就停手。默认设置下 agent 不干活时 Mac 就正常休眠——对多数人来说,这比一个忘了关的开关更省电。

## 参与开发

```sh
git clone https://github.com/AlanY1an/decaf.git
cd decaf
Scripts/bootstrap.sh
swift test --package-path Core
```

它到底怎么工作的:[`docs/architecture.md`](docs/architecture.md)(英文)。

## 许可证

MIT,见 [LICENSE](LICENSE)。

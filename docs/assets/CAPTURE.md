# 拍摄指南：`docs/assets/states.webp`

这个目录里除了 `states.webp` 之外的每张图，都是**离屏渲染真实 SwiftUI 视图**得到的，
不需要任何权限，用 `Scripts/` 之外的一个独立 harness 一条命令就能重跑（见文末）。

`states.webp` 是唯一一张**只有你能拍**的图，原因很具体：

`MenuBarExtra(.menu)` 渲染的是一个真正的 `NSMenu`（`DecafApp.swift:33`
`.menuBarExtraStyle(.menu)`）。`NSMenu` 由 WindowServer 绘制在一个独立的、
不属于本进程的窗口里。它**不能**被 `NSHostingView` + `cacheDisplay` 抓下来，
也不能用 `NSMenu.popUp` 之外的方式程序化打开，而在没有屏幕录制权限时
`screencapture` 只会返回 `could not create image from display`。

**所以：绝对不要用一张"长得像菜单"的 SwiftUI 仿制图去顶替它。**那是一张
关于产品的假照片。这个目录里没有任何这样的文件；如果将来有人加了，
文件名里必须带 `illustration`，并且不许接进 README。

---

## 0. 先决条件

```sh
# 1) 构建并运行 Decaf（会把 decaf-bridge 装进 app bundle 的 Helpers/）
cd /Users/alan/Project/Caffeinate
Scripts/run.sh

# 2) 确认 socket 已经起来 —— 后面每一步都靠它
ls -l "$HOME/Library/Application Support/Decaf/agent.sock"

# 3) 记下 bridge 的路径（安装 hooks 后它会被复制到这里）
BRIDGE="$HOME/Library/Application Support/Decaf/bin/decaf-bridge"
ls -l "$BRIDGE"
```

如果第 3 步不存在，说明还没装过 hooks；先在 **Settings › Agents › Install Hooks…**
装一次（这会写 `~/.claude/settings.json`，见下面的 ⚠️ 说明）。

外观与窗口设置，四张图必须完全一致：

| 项 | 值 |
|---|---|
| 外观 | System Settings › Appearance › **Light**（浅色在 GitHub 两种主题下都能看） |
| 强调色 | **Blue**（默认）。不要用 Graphite —— 它会让 hero 图标失去唯一的彩色块 |
| 显示器 | Retina（2x）。截图必须是 2x 像素 |
| 壁纸 | 纯色深灰或纯白。菜单栏背景取自壁纸，四张图必须同一张壁纸 |
| 菜单栏 | 关掉「自动隐藏菜单栏」；把 Decaf 图标 ⌘-拖到靠右、时钟左边 |
| 其它菜单栏图标 | 尽量清空/隐藏（Bartender 之类），画面里只留 Decaf 和时钟 |

拍摄命令（需要屏幕录制权限 —— 你本人授权一次即可，agent 没有）：

```sh
# 交互式框选，带阴影，写 PNG。菜单打开时按下快捷键即可
screencapture -i -o ~/Desktop/state-1.png
```

`-o` 去掉窗口投影。**四张都要用 `-o`**，否则拼接时阴影会互相叠。

---

## 1. 四个状态：分别是什么，以及怎么逼出来

下面每一节先给"菜单里应该出现的字面文字"（可以照着核对拍对没拍对），
再给强制进入该状态的命令。所有文案的来源是
`Core/Sources/DecafCore/AppState/MenuPresentation.swift`。

一个贯穿全篇的辅助函数，先贴到你的 shell 里：

```sh
BRIDGE="$HOME/Library/Application Support/Decaf/bin/decaf-bridge"
SID="11111111-2222-3333-4444-555555555555"   # 随便一个 UUID，四个状态复用同一个
CWD="$HOME/Project/Caffeinate"               # 决定菜单里显示的项目名

# 向 Decaf 发一帧 hook 事件。$1 = 事件名，$2 = Notification matcher（可省）
emit() {
  printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s"}' "$SID" "$1" "$CWD" \
    | "$BRIDGE" ${2:+"$2"}
}
```

这就是当年那次端到端探针用的同一条路径：bridge 从 stdin 读 JSON，
从 argv 读 matcher，把一行 `WireEvent` 写进 socket
（`Core/Sources/decaf-bridge/main.swift:218-249`）。它无论如何都 `exit(0)`，
所以**没有输出就是正常的**；判断有没有生效要看菜单，不要看终端。

> ⚠️ **哪些步骤会碰你真实的 `~/.claude`**
>
> - 状态 1、3、4 用的 `emit` **完全不碰** `~/.claude`。它只往 Decaf 自己的
>   socket 写一行，状态活在 Decaf 进程内存里，退出 Decaf 就没了。
> - **状态 2 会碰**：它需要 hooks 被卸载（改写 `~/.claude/settings.json`），
>   并且需要 `~/.claude/projects/` 下有真实文件写入。两处的还原命令都在下面。
> - 状态 3 也需要在 `~/.claude/projects/` 下写一个 transcript 文件。
>
> 你的机器上 hooks 是**已安装**状态，所以状态 1、3、4 现在就能直接拍；
> 只有状态 2 需要先卸载再装回。**把状态 2 放到最后拍**，拍完立刻装回。

---

### 状态 1 — 装了 hooks，一个 turn 正在进行

**菜单应该显示**

```
Claude Code working                      ← 状态行（禁用文字）
Caffeinate — working for 1 min           ← session 行；"Caffeinate" 来自 $CWD 的目录名
                                         ← 没有 precision 行（hooks 是精确的，无需限定）
✓ Auto Keep Awake for Agents
─────────
Keep Awake ...
```

**怎么逼出来**

```sh
emit SessionStart
emit UserPromptSubmit
```

`UserPromptSubmit` → `.working`（`SessionRegistry.swift:342`），session 进入
`.working`，图标换成带角标的杯子，状态行变成 `Claude Code working`。

session 行里的 `working for N min` 至少显示 `1 min`（`MenuTextFormatter.durationText`
对 0 分钟取 `max(1, …)`），所以发完立刻拍就行，不用等。

想让它显示更长的时间，把 `UserPromptSubmit` 的时间戳往前挪是不行的 ——
bridge 自己写 `ts`。真想要"working for 12 min"就等 12 分钟，或者接受 `1 min`。

**拍完清掉**

```sh
emit SessionEnd
```

---

### 状态 2 — 没有 hooks，退回文件活动检测

**菜单应该显示**

```
Claude Code working
Detection: file activity (approximate)     ← precision 行
Install hooks for precise detection…       ← 它下面的按钮
✓ Auto Keep Awake for Agents
```

**为什么不能靠 `emit` 拍出来。** 这是最容易踩空的一格：precision 是
`.fileActivity` 时，`DetectionCoordinator` 的 `switch` 根本不会把 wire session
算成 hold source（`DetectionCoordinator.swift:562` 起，只有 `.hooks` /
`.hooksPartial` 分支收集 session）。所以在这个状态下发多少 `UserPromptSubmit`
都不会让菜单动 —— 唯一能撑起 hold 的是 L2 的文件活动窗口。

**怎么逼出来**

```sh
# a) 卸载 hooks：Settings › Agents › Uninstall Hooks
#    （或者点 "Remove all integrations…"）。这会改写 ~/.claude/settings.json，
#    只删 Decaf 自己那几条。等 Agents 页的 hero 变成 "Watching file activity"。

# b) 制造一次 ~/.claude/projects 下的文件活动
SHOOT="$HOME/.claude/projects/decaf-shoot"
mkdir -p "$SHOOT"
touch "$SHOOT/$SID.jsonl"
```

`FSEventsWatcher` 只把 `~/.claude/projects/` 下的路径算作 activity
（`FSEventsWatcher.swift:14`），`settings.json` 被显式排除，所以必须是
`projects/` 下面的文件。文件名必须是 `<session-uuid>.jsonl` —— 文件名**就是**
session id（`DetectionCoordinator.swift:388`）。

L2 窗口是自限的，安静几分钟后会自己塌掉，所以**动作要快**：
`touch` 完立刻开菜单拍。要续命就再 `touch` 一次。

**拍完还原（两步都要做）**

```sh
rm -rf "$HOME/.claude/projects/decaf-shoot"     # 只删这一个目录
# 然后 Settings › Agents › Install Hooks… 把 hooks 装回去
```

---

### 状态 3 — agent 处在一个"已声明的等待"里

> **先读这段，README 现在的分镜说法是错的。**
> README 里 ASSET 2 写的是「Status: "Claude Code working" + the wait line」。
> **菜单里没有 wait line。** 从 `MenuTopRow`（`App/MenuLayout.swift:47-63`）看，
> 顶部区域一共只有五种行：status / session / overflow / precisionDetail /
> precisionAction。`WaitInfo` 到了 `HoldSource` 就停住了，从来没进过
> `AppStateSnapshot`。
>
> 但这一格照样拍得到，而且比 README 想要的那行字更好 —— wait 是通过**把
> "允许睡眠"的时刻往后推**体现出来的，那个时刻**印在状态行上**。

**菜单应该显示**

```
Just finished · Sleep allowed after 1:35 PM     ← 关键：这个时刻在半小时之后
Caffeinate — grace period
```

这就是整格的论点，而且是字面可读的：turn 已经结束了（`Just finished`），
按 grace period 本该 **3 分钟后**放行，但状态行上写的是**半小时后**。

机制在 `CompositionRoot.swift:453`：

```swift
case .grace(let until): phase = .graceIdle(until: max(until, session.waitUntil ?? until))
```

grace 截止时刻和 wait 截止时刻取大者，`MenuCopy.baseStatusLine` 再把它渲染成
`Just finished · Sleep allowed after <时刻>`（`MenuPresentation.swift:127`）。

**拍之前先对表**：状态行上的时刻减去当前时间应当≈30 分钟。如果只有 ≈3 分钟，
说明 wait signal 那行 JSON 被丢掉了，这一格就没有意义 —— 回去逐条对下面的清单。

**怎么逼出来**

```sh
SHOOT="$HOME/.claude/projects/decaf-shoot"
mkdir -p "$SHOOT"

emit SessionStart
emit UserPromptSubmit

# 往 transcript 里追加一条声明了 30 分钟等待的 assistant 记录
python3 - "$SHOOT/$SID.jsonl" "$SID" <<'PY'
import json, sys, datetime
path, sid = sys.argv[1], sys.argv[2]
record = {
    "type": "assistant",
    "isSidechain": False,
    "sessionId": sid,
    "timestamp": datetime.datetime.now(datetime.timezone.utc)
                  .strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
    "message": {"content": [
        {"type": "tool_use", "name": "ScheduleWakeup", "input": {"delaySeconds": 1800}}
    ]},
}
with open(path, "a") as f:
    f.write(json.dumps(record) + "\n")
PY

emit Stop      # turn 结束了 —— 没有 wait 的话现在就该进 grace 并释放
```

要点，全部来自 `WaitSignalParser.swift:186-250`，写错任何一条这行都会被静默丢弃：

- `type` 必须是 `"assistant"`；
- `isSidechain` 必须不是 `true`；
- `sessionId` 必须和 `emit` 用的 `$SID` **以及文件名**三者一致；
- `timestamp` 必须是 ISO8601 UTC；
- 工具名必须是白名单里的四个之一：`ScheduleWakeup` / `Monitor` /
  `CronCreate` / `CronDelete`（`WaitSignalParser.swift:88-93`）；
- 只有 `delaySeconds` / `timeout_ms` / `stop` / `cron` / `id` 这五个 input key
  会被读。

另外 `waitUntil` 会被硬夹到 `now + 1h`（`defaultWaitCap`），所以
`delaySeconds` 写 1800 是安全的，写 86400 也只会得到 1 小时。

**第二道验证**（状态行的时刻已经是第一道）

```sh
# Stop 之后等过 grace period（默认 3 分钟）再跑：assertion 还在 = wait 生效
pmset -g assertions | grep -i decaf
```

**拍完清掉**

```sh
emit SessionEnd
rm -rf "$HOME/.claude/projects/decaf-shoot"
```

---

### 状态 4 — agent 停在提示符前，等你输入

**菜单应该显示**

```
Idle — not preventing sleep      ← 一字不差，来自 MenuPresentation.swift:162
✓ Auto Keep Awake for Agents
```

**怎么逼出来**

```sh
emit SessionStart
emit UserPromptSubmit          # 先让它 working，这样这一格是"从工作退回空闲"
emit Notification idle_prompt  # ← matcher 走 argv，不是 stdin
```

`idle_prompt` → `.idle`（`SessionRegistry.swift:371`），而且它是**权威的**turn
结束信号：它会把剩余的 grace 窗口直接砍断，不用等 3 分钟。这正是这一格
和"刚结束"那种状态的区别 —— 拍到的是 `Idle — not preventing sleep`，
不是 `Just finished · Sleep allowed after 4:07 PM`。

⚠️ 别用 `emit Notification permission_prompt` 拍这一格。permission prompt 走的是
`.awaitingPermission`，会开一个 5 分钟的窗口**继续 hold**
（`SessionRegistry.swift:349-368`），菜单会显示 working 而不是 idle。
（README 老版本的状态 3 就是 permission prompt，2026-08-07 改掉了，
理由正是这个。）

**拍完清掉**

```sh
emit SessionEnd
```

---

## 2. 裁切、尺寸、拼接

四张单图：

- 每张裁成**同样的宽高**。以最宽的那张为准（多半是状态 2，它多两行）。
- 裁切框：上边从菜单栏顶端开始（**包含**菜单栏和 Decaf 图标本身 —— 图标
  是"这是个菜单栏应用"的唯一证据），左右在菜单气泡外各留 8 px，
  下边到菜单最后一行下面 8 px。不要把整个屏幕拍进来。
- 目标：每张 **500 px 宽（2x）**，即 250 pt。四张拼起来 2000 px，
  README 里 `width="820"` 显示，正好 2.4x 下采样，视网膜上很锐利。

拼接（ImageMagick；`brew install imagemagick`）：

```sh
cd ~/Desktop
# 统一高度（以最高的一张为准，其余底部补透明），再横向拼
magick state-1.png state-2.png state-3.png state-4.png \
  -background none -gravity north +append states.png

# 转 webp。q 82 在这种大色块 UI 上肉眼无损，体积约为 PNG 的 1/4
magick states.png -quality 82 -define webp:method=6 states.webp

# 检查：宽 ~2000，体积应当在 150 KB 以内
magick identify states.webp
ls -lh states.webp

cp states.webp /Users/alan/Project/Caffeinate/docs/assets/states.webp
```

没有 ImageMagick 的话，`sips` 能转格式但**不能**拼接，得手动在
Preview 里拼；那种情况下宁可只拍 2 张（状态 3 和 4，它们才是产品本身），
也不要凑一张歪的四联图。

拼好之后回 `README.md`，把 ASSET 2 那段注释掉的 `<img>` 和它的 `<sub>` caption
放回来（那里有一行 `<!-- RESTORE ... -->` 注释指着这个文件）。

**caption 建议**（README 现有那句 "Same agent, four situations. Only the last
one lets the Mac sleep." 仍然成立，但第 3 格的分格 caption 要改）：

| 格 | caption |
|---|---|
| 1 | Hooks installed — turn-precise. |
| 2 | No hooks, no config — still works, ~5 min resolution. |
| 3 | Turn over — but the agent scheduled its own wake-up, so sleep waits half an hour, not three minutes. |
| 4 | Waiting for your input — sleeps normally. |

第 3 格原来的 "Waiting on a clock, not on you — stays awake." 也成立。
唯一要避开的写法是暗示菜单上有一行专门的 "wait" 文字 —— 没有那行，
承载论点的是状态行上那个被推远的时刻。

---

## 3. 其余的图是怎么来的（可复现）

harness 在 `docs/assets/render/`，随仓库走。`build.sh` 每次都会从仓库的
`App/*.swift` 重新拷一份源码再编译，所以它渲染的永远是**当前 shipping 代码**，
不是某次快照。

```sh
cd docs/assets/render
./build.sh                          # 从 App/*.swift 重新拷贝并编译
./.build/release/DecafRender ..     # 输出目录 = docs/assets
```

`.build/` 和生成出来的 `Sources/DecafRender/App/` 都不该提交；仓库里只有
`Package.swift`、`build.sh`、`Resources/HarnessInfo.plist` 和两个 harness
源文件。

**可复现性实测**：换个目录重新构建再渲染一遍，20 张图里 18 张与仓库中的
逐字节相同。只有 `custom-hold-until-{light,dark}.png` 会变 —— 那个面板显示
「Keeps this Mac awake until 1:00 PM — 5 min from now」，是真的在读时钟。
这两张变了是对的，其余任何一张变了都说明 `App/` 动过。

它渲染的是真实的 `GeneralSettingsTab` / `AgentsSettingsTab` /
`SafetySettingsTab` / `InstallConsentSheet` / `OnboardingWindowController` /
`CustomHoldWindowController`，只有**输入**是摆出来的：一个用完即弃的
UserDefaults suite（所以是出厂默认值）、一个固定返回某个 `ClaudeCodeStatus`
的 provider、以及一个不存在的 home 目录 `/Users/you`（所以 consent sheet 里
不会出现你的真实用户名，而变更列表本身仍然是 Core 真算出来的）。

### 三个已知的渲染限制，看图时要知道

1. **Settings 的 tab 条（General | Agents | Safety）抓不下来。**
   它是 AppKit 的 vibrancy view，材质由 WindowServer 合成，`cacheDisplay`
   只能抓到上面的墨，抓不到底。实测：深色下那条带子每个像素 alpha 都是 0。
   所以这几张图是**按页渲染**的，故意裁掉了 tab 条 —— 与其发一条画了一半的
   带子，不如不画。
2. **开关、Picker、按钮是"非活跃窗口"的灰色，不是强调色蓝。**
   离屏窗口永远不可能是 key window（`makeKey()` 对未上屏的窗口无效），
   AppKit 于是用 unemphasized 配色画所有控件。开关的**位置**（左/右）仍然
   如实反映开关状态。如果 README 想要蓝色的开关，那几张 Settings 图得由你
   用正常截图重拍。
3. **Onboarding 只有第 1 步。** 第 2、3 步靠 `OnboardingView` 里的
   `@State private var step`，那是 `OnboardingWindow.swift` 文件私有的，
   外部设不了；合成一次 `NSEvent` 点 "Continue" 也不行 —— SwiftUI 的 hit
   testing 要求窗口在屏幕上，而这个窗口刻意永不上屏（试过，抓出来和第 1 步
   逐字节相同）。

### 渲染时发现的两个真实 UI 问题（不是渲染 bug）

- **Onboarding 第 1 步有文字被截断。** 那行「Hold ⌘ and drag any menu bar
  icon to move it…」在 520×420 的固定窗口里被压成一行并以 `…` 截断
  （浅色深色都一样，见 `onboarding-step1-light.png`）。原因是那两个 `Label`
  没有 `.fixedSize(horizontal: false, vertical: true)`，而窗口高度不够，
  SwiftUI 于是压缩它。
- **Agents 页装不下。** 三个页面的自然高度实测为 General 384 pt、
  **Agents 416 pt**、Safety 358 pt。窗口固定 445 pt，减去 tab 条约 30 pt
  只剩约 415 pt —— Agents 差约 1 pt，最后那张 "Remove all integrations" 卡片
  底边被切掉（能滚，但一进页面就是切的）。`SettingsView.swift` 里那段
  注释写的是「General 385 / Safety 350 / Agents 316」，是 `Auto Keep Awake
  for Agents` 那一节加进来之前的数字，已经过期了。445 需要重新量。

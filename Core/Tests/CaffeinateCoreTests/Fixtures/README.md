# Hook stdin fixtures(02-1 门禁:字段名校准)

本目录是 Claude Code hook 事件写入 hook 进程 stdin 的 JSON 样本,用于驱动
`DetectionTests.swift` 中的六事件映射(计划 02 §1.1)校验。

## 录制方式

2026-08-04 在**隔离沙箱**中用真实 Claude Code **2.1.203** 录制:
`CLAUDE_CONFIG_DIR` 指向临时目录(绝不触碰真实 `~/.claude`),其中的
settings.json 按计划 02 §1.5 形状配置全部六个事件 + 两种 Notification
matcher,hook command 为一个把 stdin 与 argv 追加到捕获文件的脚本,然后运行
`claude -p "reply with exactly: ok" --max-turns 1`。

沙箱内无登录凭据,回合以 `authentication_failed` 失败——这反而完整触发并录到了
`StopFailure`(计划 R1 里最担心与实况不符的事件名,已实证存在且同名)。

## 逐文件状态

| 文件 | 状态 | 说明 |
|---|---|---|
| `session_start.json` | **真实录制** | 含 `source":"startup"` 附加字段 |
| `user_prompt_submit.json` | **真实录制** | 含 `prompt_id` / `permission_mode` / `prompt` 附加字段 |
| `stop_failure.json` | **真实录制** | `StopFailure` 事件名与计划 02 §1.1 完全一致;含 `error` / `last_assistant_message` / `effort` 附加字段 |
| `session_end.json` | **真实录制** | 含 `reason":"other"` 附加字段 |
| `stop.json` | **PENDING-LIVE-VALIDATION** | 文档形状(`stop_hook_active` 字段);成功回合才会触发,沙箱无凭据无法录到 |
| `notification_permission_prompt.json` | **PENDING-LIVE-VALIDATION** | 文档形状;需真实权限弹窗场景 |
| `notification_idle_prompt.json` | **PENDING-LIVE-VALIDATION** | 文档形状;需真实闲置 60s 场景 |

真实录制的四个文件仅把路径值归一化(沙箱临时路径 → `/Users/alan/Project/X`
样例路径),**字段名与结构未做任何改动**。

## 已校准的关键事实

1. 字段名与计划一致:`session_id` / `hook_event_name` / `cwd`(caff-bridge
   只需这三个)+ `transcript_path` 恒在。
2. `StopFailure` 事件名实证存在,与计划 02 §1.1 表逐字一致。
3. Notification 的 matcher **不在 stdin 里**;按计划 02 §1.5 经 argv 传递
   (本目录两个 notification fixture 的 matcher 语义由文件名承载,测试按
   settings.json 的 argv 约定映射)。matcher 值
   `permission_prompt` / `idle_prompt` 尚未在真实环境验证(见上表)。
4. 转录目录布局实证:`$CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/<session_id>.jsonl`
   (默认即 `~/.claude/projects/...`),与 L2 FSEvents 的 `projects/` 前缀
   过滤设计吻合。

## 待办(V1.x 前补录)

在已登录的真实环境重跑同一录制脚本,补录 `Stop` 与两种 Notification,
替换三个 PENDING 文件并更新本表。

---

# 转录行 fixture:`wait_signals.jsonl`(计划 08 实现步骤 1)

上面的 JSON 文件是 **hook stdin** 样本;`wait_signals.jsonl` 是另一类东西——
**转录文件本身的行**(`~/.claude/projects/<slug>/<session-uuid>.jsonl`,每行一条
JSON),用于驱动 `WaitSignalParserTests.swift`。

记录形状取自计划 08「证据(2026-08-05 本机实测)」一节已实测的四个白名单工具
(`ScheduleWakeup` / `Monitor` / `CronCreate` / `CronDelete`),路径、会话 id 与
job id 已改为样例值;**字段名与嵌套结构未改动**。

| 行 | 内容 | 用途 |
|---|---|---|
| 1 | `ScheduleWakeup { delaySeconds: 420 }` | 实证复现里那条决定性记录的形状 |
| 2 | `ScheduleWakeup { stop: true }` | 循环终止 → `WaitTermination` |
| 3 | `Monitor { timeout_ms: 900000 }` | 毫秒换算 |
| 4 | `CronCreate { cron: "17 4 * * *" }` | cron next-fire 计算 |
| 5 | 紧跟其后的 `tool_result` | job id 定点狙击(仅这一行可读) |
| 6 | `CronDelete { id }` | 按 job id 取消 |
| 7 | `Bash`(白名单外) | 未知工具静默忽略 |
| 8 | `isSidechain: true` 的 `ScheduleWakeup` | 子 agent 记录忽略 |
| 9–11 | 缺字段 / 类型不符 / 半行截断 | 硬边界 1:一律吞掉 |
| 12 | `delaySeconds: 86400` | 硬边界 2:截断到 `waitCap` |
| 13 | 一行内并列多个 `tool_use` | 不得漏掉第二个信号 |

## 隐私哨兵(不要删)

每一条记录的 `prompt` / `reason` 里都埋了同一个字符串
`SENTINEL-DO-NOT-LEAK-7f3a91`。`WaitSignalParserTests` 里的
`neverEmitsPromptOrReasonContent` 递归展开全部解析输出与全部 diagnostic,断言这个
哨兵一个字符都不会出现——这是计划 08 硬边界 3(**只读最小字段,绝不触碰内容**)的
测试侧闸门。`fixtureFileIsIntactAndCarriesTheSentinel` 另外断言哨兵确实还在文件里,
防止有人删掉哨兵之后隐私测试变成空跑。

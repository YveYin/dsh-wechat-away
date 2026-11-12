# dsh-wechat-away

> 离开电脑时，让 DeepSeek Harness 替你看着微信：有人来信就回一句「我是华一阳的 AI 助手…」，并把每条消息记到账上。

这是一个 [DeepSeek Harness](https://github.com/deepseek-ai) 的 **Host 侧插件**。它不接管微信协议，而是通过 Windows UI Automation 与本机微信桌面版交互——读会话列表、判断有没有新消息、必要时切进会话把回复发出去。

只依赖 Node 内置模块和一个随包发布的 PowerShell 桥脚本，**没有任何 npm 依赖**。

## 它能做什么

- **值守模式**：说一句「我去上实验课，两小时回来」，进入值守；说「我回来了」，结束并出清单。
- **只回私聊**：群聊默认只记录不回复（可配）；公众号/服务号/微信团队等一律静默；被设为「消息免打扰」的会话也静默。
- **回复带上下文**：自动带上「我是谁的 AI 助手」「他正在做什么」「大概什么时候回」，并根据活动选择自洽的说法（上课→看不了手机，洗澡/考试→手机不在身边）。
- **不刷屏**：同一个人一分钟内连发多条只回一条；冷却期内攒下的消息，等静默满一分钟再补一条「以上内容我都收到了，会转述给他」。
- **全程记账**：每条来信写进 `inbox.jsonl`，值守结束生成中文汇总（谁、几点、说了什么、回了还是只记录）。
- **两个入口**：桌面快捷方式（WinForms 两步向导）和手机网页（经 Tailscale 远程访问）。

## 它是怎么工作的

```
┌──────────────┐   watch/read/send   ┌────────────────┐
│  index.js    │ ──────────────────► │  wx_ctl.ps1    │ ──UI Automation──► 微信桌面版
│  (Host 插件) │ ◄────────────────── │  (PowerShell)  │ ◄──合成鼠标/键盘──
└──────┬───────┘     JSON via file   └────────────────┘
       │
       ├─ state/inbox.jsonl / digest.md / last-summary.md
       ├─ web.js  → http://0.0.0.0:4318/away  （手机端页面）
       └─ state/requests/*.json  ← 向导和网页提交的开始/结束请求
```

关键点：

- 微信 4.x 的 UI Automation `Invoke` / `Select` 是空壳（调用成功但没反应），所以切换会话、点发送都靠**向窗口投递合成鼠标消息**（`WM_LBUTTONDOWN` / `WM_LBUTTONUP`），不移动真实光标、不抢焦点。
- 「有没有新消息」靠**红点像素**判断：读会话行左侧竖条，找红色圆点；圆点里带白色数字=正常未读，纯红点=消息免打扰。
- 「消息是谁发的」靠**气泡颜色**：自己发的是绿色（实测 `#9DF29F`），对方是白色；截屏用 `PrintWindow(PW_RENDERFULLCONTENT)`，窗口在后台也能拿到。

## 安装

1. 把这个仓库放进 DSH 的工作区目录（例如 `D:\...\工作区\dsh-wechat-away`）。
2. 用 DSH 的插件管理器安装：

   ```
   plugin_manager install_bundle target="link:D:/.../工作区/dsh-wechat-away"
   ```

   或在 profile 的 `package.json` 里加依赖后重启 DSH。
3. 确认 `cordis.patch.yml` 里的路径（相对路径以插件目录为基准），按需改 `ownerName`、`webPort` 等。

## 配置（cordis.patch.yml）

| 键 | 默认 | 说明 |
|---|---|---|
| `scriptPath` | `./scripts/wx_ctl.ps1` | PowerShell 桥脚本位置 |
| `stateDir` | `./state` | 状态、日志、inbox 的存放目录 |
| `ownerName` | `华一阳` | 回复里「我是谁的 AI 助手」 |
| `scanIntervalMinutes` | `0.033` | 巡检间隔（分钟），0.033≈2 秒 |
| `cooldownMinutes` | `1` | 同一会话两次回复的最小间隔 |
| `quietHours` | `[23, 7]` | 静默时段，只记录不回复 |
| `autoReplyGroups` | `false` | 是否也回群聊 |
| `excludes` | `[]` | 会话名黑名单，只记录 |
| `allowSessions` | `[]` | 会话名白名单，强制当私聊 |
| `webPort` | `4318` | 手机端网页端口，0=关闭 |
| `deadlineGraceMinutes` | `10` | 到点提醒的宽限 |

## 已知限制

- **仅 Windows + 微信桌面版 4.x**，且依赖微信的界面结构，微信大版本更新可能失效。
- 微信窗口被其他窗口完全遮挡时，点击可能落空（脚本会重试并报 `session-select-failed`）。
- 置顶会话在「N 个置顶」折叠条后面时，列表里看不到它；只有带红点才会浮出来，因此「标回未读」对这类会话仍不完善。
- 微信偶发把自己 UI Automation 树弄空（`desc=1`），此时只能重启微信。
- 值守期间需要一台不锁屏、微信已登录的电脑。

## 隐私

插件只在本机读写：读微信窗口的界面元素与截图，写自己的 `state/` 目录。**不上传任何聊天内容**。手机端页面只暴露「开始/结束/查看汇总」，需要一个本地生成的访问令牌（`state/web-token.txt`）。

## 许可

MIT

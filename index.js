/**
 * dsh-wechat-away —— 离开电脑时让微信自动回复的 Host 侧插件。
 *
 * 只使用 Node 内置模块，不依赖任何第三方包：
 *   - 通过一个 PowerShell 桥脚本（默认 wx_ctl.ps1）读取微信会话列表、发送消息；
 *   - 定时扫描会话列表，用 preview/time 与快照对比，判断是否有新消息；
 *   - 按排除名单 / 群聊 / 静默时段 / 冷却 / 自回显规则决定「只记录」还是「自动回复」；
 *   - 所有来信追加写入 inbox.jsonl，供 wechat_inbox 工具查询。
 *
 * 注册三个模型可调用的工具：
 *   - wechat_away     开始 / 结束 / 查询值守
 *   - wechat_inbox    查询来信记录
 *   - wechat_scan_now 立刻扫描一次（人工验证用）
 *
 * 桥脚本契约（由 -Out 指定的文件返回 JSON，UTF-8 无 BOM）：
 *   watch:     {ok, mode, ms, foldState, atTop, foldRow, chatOpen, selectedRow, rows:[{name,preview,
 *               time,y,pinned,selected,foldBar,unread,badgePx,...}]}  —— 视口快照，约 650ms
 *   probe:     {ok, rows:[{name,title,preview,time,kind,unread,foldBar,...}]} —— -Scroll 全量，约 34s
 *   preflight: {ok, session, kindHint, chatTitle?, isGroupTitle?, titleKindConfidence?, kindSource?, tail}
 *                                                       —— 只切会话，不写输入框
 *   read:      {ok, session, messages:[{text,y,dir,greenPx,side,cls}]}
 *   send:      {ok, session, sent, verified, buttonWasEnabled, lastMessage, error?}
 *   deselect:  {ok, changed, method, wasOpen, chatOpen, before, after, ms} —— 收起会话面板
 */

import { spawn } from 'node:child_process'
import { access, appendFile, mkdir, readdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { isAbsolute, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { readFileSync } from 'node:fs'
import { startAwayWeb } from './web.js'

/** 插件根目录：配置里的相对路径都以它为基准，方便整包搬家。 */
const PLUGIN_ROOT = fileURLToPath(new URL('.', import.meta.url))
/** 配置项是相对路径时按插件根目录解析，绝对路径原样使用。 */
function resolveFromRoot(value) {
  return isAbsolute(value) ? value : join(PLUGIN_ROOT, value)
}
/** PowerShell 桥脚本（随包发布）。 */
const DEFAULT_SCRIPT_PATH = join(PLUGIN_ROOT, 'scripts', 'wx_ctl.ps1')
/** 状态、快照、日志的存放目录。 */
const DEFAULT_STATE_DIR = join(PLUGIN_ROOT, 'state')
/** 默认的“本人”名字。留空表示还没设置：首次运行由向导或手机页问一次，存进 state.ownerName。 */
const DEFAULT_OWNER = ''

/** 定时器 60 秒一跳，到点才真正扫描。 */
const TICK_MS = 1_000
/** 桌面快捷方式写请求的目录（相对 stateDir）。 */
const REQUESTS_DIR = 'requests'
/** 心跳文件：向导用它判断 Host 是否活着。 */
const HEARTBEAT_FILE = 'heartbeat'
/** 最近一次「结束值守」的汇总，向导直接读这个文件显示。 */
const SUMMARY_FILE = 'last-summary.md'
/** 心跳超过这个时间没更新，向导就认为 DSH 没在运行。 */
const HEARTBEAT_STALE_MS = 15_000
/** 心跳最小写入间隔，避免每 1 秒都碰一次磁盘。 */
const HEARTBEAT_INTERVAL_MS = 2_000
/** 单次桥脚本调用的超时。 */
const BRIDGE_TIMEOUT_MS = 60_000
/** 全量 probe -Scroll 要滚完整个会话列表（约 34 秒），单独给一个更宽的超时。 */
const PROBE_TIMEOUT_MS = 180_000
/** 回复完收起会话面板的调用超时；实测 0.4~1.2s，5s 足够且绝不能拖住扫描。 */
const DESELECT_TIMEOUT_MS = 5_000
/** 读会话时取最近几条消息，用来挑出「对方最后说的那句」；只记录路径也要读到真实文本。 */
const SELF_UNREAD_TTL_MS = 10 * 60_000
const READ_LIMIT = 20
/** markunread 要滚列表找行、开右键菜单再点菜单项，比回复慢，单独给一个更宽的超时。 */
const MARK_UNREAD_TIMEOUT_MS = 25_000
/** 同一条文本最多重试发送几次（不含第一次）。 */
const MAX_SEND_RETRIES = 2
/** handled 最多保留多少条，按时间淘汰。 */
const HANDLED_LIMIT = 200
/** 未播报摘要最多攒多少条，防止长时间不上报时状态文件无限变大。 */
const PENDING_DIGEST_LIMIT = 200
/** 单行摘要里最多列几个人名，多出来的用「等 N 条」收尾。 */
const DIGEST_ENTRY_LIMIT = 3

const STATE_FILE = 'state.json'
const INBOX_FILE = 'inbox.jsonl'
const DIGEST_FILE = 'digest.md'
const LOG_FILE = 'wechat-away.log'

/** 紧急关键词：命中即标记 urgent。 */
const URGENT_PATTERN = /急|马上|立刻|电话|速回|紧急|快点/u
/** 微信的「[1条]」「[3条]」合并提示，不是发送者昵称，统计前缀前要先剥掉。 */
const MERGED_NOTICE_PATTERN = /^\[\d+\s*条\]\s*/u
/** 会话名含这些词时使用更客气的模板。 */
const POLITE_KEYWORDS = ['老师', '导员', '主任', '书记']
/**
 * 内置的服务号 / 系统账号黑名单：名字里含这些关键词的会话一律只记录、绝不自动回复。
 * 公众号推送、微信支付、文件传输助手和个人私聊共用同一个会话列表，只能按名字拦。
 */
const SERVICE_KEYWORDS = [
  '公众号',
  '服务号',
  '微信团队',
  '微信游戏',
  '微信支付',
  '服务通知',
  '文件传输助手',
]
/** kind 的中文标签，渲染和汇总共用。 */
const KIND_LABELS = {
  private: '私聊',
  group: '群聊',
  unknown: '未确认',
}

/** 日常语气模板，必须包含“AI 助手”和当时的活动。 */
const CASUAL_TEMPLATES = [
  '嗨～我是{owner}的 AI 助手 🤖 他这会儿{activity}，{reason}，您有事可以直接说，消息我会记下哒，{when}就转告他～(◦˙▽˙◦)',
]

/** 对老师、导员、领导等使用的客气模板。 */
const POLITE_TEMPLATES = [
  '老师好，我是{owner}的 AI 助手。他现在{activity}，{reason}，您有事可以直接说，消息我会记下并转告他，{when}会尽快回复您。',
]

/**
 * 「为什么看不了手机」要和活动自洽：上课说看不了手机，洗澡才说手机不在身边。
 * 返回空串表示活动里已经说明了原因（比如"手机被占用了"），不再重复。
 */
const PHONE_STATE_RULES = [
  { test: /手机/u, reason: '' },
  { test: /洗澡|泡澡|冲凉|游泳|洗漱|考试|考试中|监考/u, reason: '手机不在身边' },
  { test: /睡觉|午睡|眯一会儿|躺着|休息/u, reason: '手机不在身边' },
  { test: /上课|实验|开会|会议|讲座|答辩|培训|自习|图书馆|听课/u, reason: '暂时看不了手机' },
  { test: /打游戏|游戏|开黑/u, reason: '暂时看不了手机' },
  { test: /吃饭|食堂|聚餐|饭局|干饭/u, reason: '手机不在手边' },
  { test: /跑步|打球|健身|锻炼|运动|训练/u, reason: '手机不在身边' },
  { test: /开车|骑车|地铁|公交|路上|出门|逛街|买菜|赶车/u, reason: '手机不在手边' },
]

function describePhoneState(activity) {
  const text = typeof activity === 'string' ? activity : ''
  for (const rule of PHONE_STATE_RULES) {
    if (rule.test.test(text)) return rule.reason
  }
  return '暂时看不了手机'
}

/** 不同 action 的中文标签，渲染和汇总共用。 */
const ACTION_LABELS = {
  replied: '已回复',
  recorded: '仅记录',
  skipped: '已跳过',
  failed: '回复失败',
  system: '系统事件',
}

/** 读取字符串配置，空串视为缺省。 */
function text(value, fallback) {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : fallback
}

/** 读取正数配置。 */
function positive(value, fallback) {
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : fallback
}

/** 巡检间隔下限 6 秒、上限 24 小时，避免把微信当轮询靶子。 */
function clampInterval(minutes) {
  if (!Number.isFinite(minutes) || minutes <= 0) return 0.033
  return Math.min(24 * 60, Math.max(0.02, minutes))
}

/** 读取非负数配置。 */
function nonNegative(value, fallback) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : fallback
}

/** 规范化静默时段 [开始小时, 结束小时]，支持跨午夜。 */
function normalizeQuietHours(value, fallback) {
  if (!Array.isArray(value) || value.length !== 2) return [...fallback]
  const start = Number(value[0])
  const end = Number(value[1])
  if (!Number.isInteger(start) || !Number.isInteger(end)) return [...fallback]
  if (start < 0 || start > 23 || end < 0 || end > 23) return [...fallback]
  return [start, end]
}

/** 规范化会话名数组。 */
function normalizeExcludes(value) {
  if (!Array.isArray(value)) return []
  return value
    .filter((item) => typeof item === 'string' && item.trim().length > 0)
    .map((item) => item.trim())
}

/** 把原样配置补全成完整配置。 */
function resolveConfig(raw) {
  const value = raw !== null && typeof raw === 'object' ? raw : {}
  return {
    enabled: value.enabled !== false,
    scriptPath: resolveFromRoot(text(value.scriptPath, DEFAULT_SCRIPT_PATH)),
    stateDir: resolveFromRoot(text(value.stateDir, DEFAULT_STATE_DIR)),
    // 巡检间隔（分钟，可为小数）。默认 30 秒：值守时尽快发现新消息；0.25 = 15 秒。
    scanIntervalMinutes: clampInterval(positive(value.scanIntervalMinutes, 0.033)),
    quietHours: normalizeQuietHours(value.quietHours, [23, 7]),
    cooldownMinutes: nonNegative(value.cooldownMinutes, 1),
    /** 只有显式打开才自动回复群聊；replyToGroups 是旧字段，保留兼容。 */
    autoReplyGroups: value.autoReplyGroups === true || value.replyToGroups === true,
    excludes: normalizeExcludes(value.excludes),
    /** 排除名单：名字命中即只记录、不回复；与 start 传的 excludes 取并集。 */
    excludeSessions: normalizeExcludes(value.excludeSessions),
    allowSessions: normalizeExcludes(value.allowSessions),
    denySessions: normalizeExcludes(value.denySessions),
    ownerName: text(value.ownerName, DEFAULT_OWNER),
    deadlineGraceMinutes: nonNegative(value.deadlineGraceMinutes, 10),
    /** 普通新消息的合并播报间隔（分钟）；紧急消息不受它限制。 */
    digestEveryMinutes: positive(value.digestEveryMinutes, 20),
    /** 是否弹 Windows 系统通知；关掉后仍然写 digest.md。 */
    notify: value.notify !== false,
    /**
     * 只记录不回复时，也切进会话读真实文本（列表预览只给「[N条] 啊」这种残缺内容），
     * 读完收起会话并用右键菜单「标为未读」把红点还回去。关掉后完全退回旧行为。
     */
    readRecordedChat: value.readRecordedChat !== false,
    /** 手机端网页服务的端口；0 表示关闭。 */
    webPort: nonNegative(value.webPort, 4318),
  }
}

/** 状态文件的默认形状。 */
function defaultState() {
  return {
    active: false,
    activity: '',
    until: '',
    /** 「回来时间」是时刻还是时长；决定自动回复里怎么说。 */
    untilMode: 'clock',
    /** 时长模式下用户原话，例如「2 小时」「一个半小时」。 */
    untilText: '',
    /** 到点后是否自动结束值守（快捷方式启动时置 false：只提醒，不自动停）。 */
    autoEndOnDeadline: true,
    /** 到点提醒是否已经发过，避免每 2 秒重复弹通知。 */
    deadlineNotified: false,
    startedAt: '',
    excludes: null,
    /** 本人称呼：首次运行问一次后一直沿用（state 优先于配置）。 */
    ownerName: '',
    intervalMinutes: null,
    lastScanAt: '',
    nextScanAt: '',
    baselineAt: '',
    /** start 时所有未读会话的名字：这些老未读不算新来信。 */
    baselineUnread: [],
    /**
     * 上一轮 watch 看到的「正在打开的会话」快照（name/preview/time）。
     * 微信会把打开中的会话立刻标已读，永远不长红点，只能靠 preview/time 变化兜底发现新消息。
     */
    lastSelectedRow: null,
    lastEndedAt: '',
    endedReason: '',
    lastReplies: {},
    /** 本次值守里每个会话回过几次（name → count），用于「回过就不再刷屏」。 */
    replyCounts: {},
    /** 已经处理过的列表行（name → {preview, time, at}），同一条消息只记一次。 */
    seenRows: {},
    /** 本次值守里已经回过谁、回的是哪句（name → {text, at}）。 */
    handled: {},
    /**
     * 我们自己贴回去的红点（name → {text, at}）。这些未读不是新来信，扫描时要跳过，
     * 否则「标未读 → 下一轮又当成新消息 → 再标未读」会自环。
     */
    selfUnread: {},
    /** 发送失败的重试计数（name → {text, attempts}），同一文本最多重试 2 次。 */
    sendFailures: {},
    /** 最近一条播报出去的摘要；status 会带上它。 */
    lastDigest: { at: '', text: '' },
    /** 还没播报的新来信，攒到 digestEveryMinutes 再合并发一条。 */
    pendingDigest: [],
    /**
     * 静默窗口里被跳过的来信（name → {count, at}）。等距上次回复满 cooldown 分钟
     * 且对方不再发新的，就补一条 follow-up 把这几条一起应答，避免"发了没人理"。
     */
    pendingFollowUp: {},
  }
}

/** 每人上次自动回复的记录，用来做冷却和自回显判断。 */
function normalizeReplies(raw) {
  const result = {}
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return result
  for (const [session, entry] of Object.entries(raw)) {
    if (session === '' || entry === null || typeof entry !== 'object') continue
    if (typeof entry.at !== 'string') continue
    result[session] = {
      at: entry.at,
      text: typeof entry.text === 'string' ? entry.text : '',
    }
  }
  return result
}

/** handled 的规范化：只认 {text, at}，并按时间淘汰到 200 条以内。 */
function normalizeHandled(raw) {
  const result = {}
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return result
  for (const [session, entry] of Object.entries(raw)) {
    if (session === '' || entry === null || typeof entry !== 'object') continue
    if (typeof entry.text !== 'string' || entry.text === '') continue
    result[session] = { text: entry.text, at: typeof entry.at === 'string' ? entry.at : '' }
  }
  return trimHandled(result)
}

/** 按 at 从新到旧只保留前 HANDLED_LIMIT 条，防止 handled 无限变长。 */
function trimHandled(handled) {
  const entries = Object.entries(handled)
  if (entries.length <= HANDLED_LIMIT) return handled
  const stamp = (entry) => {
    const value = Date.parse(entry.at)
    return Number.isNaN(value) ? 0 : value
  }
  entries.sort((left, right) => stamp(right[1]) - stamp(left[1]))
  return Object.fromEntries(entries.slice(0, HANDLED_LIMIT))
}

/** 发送失败计数的规范化；坏数据直接丢掉，绝不能让它把会话永久锁死。 */
function normalizeFailures(raw) {
  const result = {}
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return result
  for (const [session, entry] of Object.entries(raw)) {
    if (session === '' || entry === null || typeof entry !== 'object') continue
    if (typeof entry.text !== 'string' || entry.text === '') continue
    const attempts = Number.isFinite(entry.attempts) && entry.attempts >= 0 ? Math.floor(entry.attempts) : 0
    result[session] = { text: entry.text, attempts }
  }
  return result
}

/** lastDigest 的规范化：只认 {at, text}，坏数据当空。 */
function normalizeLastDigest(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return { at: '', text: '' }
  return {
    at: typeof raw.at === 'string' ? raw.at : '',
    text: typeof raw.text === 'string' ? raw.text : '',
  }
}

/** pendingDigest 的规范化：丢掉没有会话名的条目，按时间保留最近 200 条。 */
function normalizePendingDigest(raw) {
  if (!Array.isArray(raw)) return []
  const result = []
  for (const entry of raw) {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) continue
    const session = typeof entry.session === 'string' ? entry.session.trim() : ''
    if (session === '') continue
    result.push({
      at: typeof entry.at === 'string' ? entry.at : '',
      session,
      text: typeof entry.text === 'string' ? entry.text : '',
      action: typeof entry.action === 'string' && entry.action !== '' ? entry.action : 'recorded',
    })
  }
  return result.slice(-PENDING_DIGEST_LIMIT)
}

/** lastSelectedRow 的规范化：只认 {name, preview, time}，没有名字就当没有快照。 */
function normalizeLastSelectedRow(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const name = typeof raw.name === 'string' ? raw.name.trim() : ''
  if (name === '') return null
  return {
    name,
    preview: typeof raw.preview === 'string' ? raw.preview : '',
    time: typeof raw.time === 'string' ? raw.time : '',
  }
}

/** 状态文件损坏时补成默认值并继续，绝不抛异常。 */
/** 只保留形如 {preview, time, at} 的已见行记录。 */
function normalizeSeen(raw) {
  if (raw === null || raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const out = {}
  for (const [name, value] of Object.entries(raw)) {
    if (typeof name !== 'string' || name === '') continue
    if (value === null || typeof value !== 'object') continue
    const preview = typeof value.preview === 'string' ? value.preview : ''
    const time = typeof value.time === 'string' ? value.time : ''
    const at = Number.isFinite(Number(value.at)) ? Number(value.at) : 0
    out[name] = { preview, time, at }
  }
  return out
}

/** 只保留形如 {text, at} 的自贴未读记录。 */
/** pendingFollowUp 的规范化：只认 {count, at}，条数为 0 的条目丢弃。 */
function normalizePendingFollowUp(raw) {
  if (raw === null || raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const out = {}
  for (const [name, value] of Object.entries(raw)) {
    if (typeof name !== 'string' || name === '') continue
    if (value === null || typeof value !== 'object') continue
    const count = Number.isFinite(Number(value.count)) ? Math.max(0, Math.trunc(Number(value.count))) : 0
    if (count <= 0) continue
    out[name] = { count, at: Number.isFinite(Number(value.at)) ? Number(value.at) : 0 }
  }
  return out
}

function normalizeSelfUnread(raw) {
  if (raw === null || raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const out = {}
  for (const [name, value] of Object.entries(raw)) {
    if (typeof name !== 'string' || name === '') continue
    if (value === null || typeof value !== 'object') continue
    const key = typeof value.key === 'string'
      ? value.key
      : (typeof value.text === 'string' ? value.text : '')
    const at = Number.isFinite(Number(value.at)) ? Number(value.at) : 0
    out[name] = { key, at }
  }
  return out
}

/** 只保留最近 300 个已见行，避免状态文件无限增长。 */
function seenKeyOf(value) {
  return stripMergedNotice(typeof value === 'string' ? value : '').replace(/\s+/gu, ' ').trim()
}

/** 预览开头的未读条数（`[3条] …`）；没有就返回 0。 */
function unreadCountOf(value) {
  const text = typeof value === 'string' ? value : ''
  const found = /^\[(\d+)\s*条\]/u.exec(text)
  return found === null ? 0 : Number(found[1])
}

function trimSeen(seen) {
  const entries = Object.entries(seen)
  if (entries.length <= 300) return seen
  entries.sort((left, right) => (left[1].at ?? 0) - (right[1].at ?? 0))
  const drop = entries.slice(0, entries.length - 300)
  for (const [name] of drop) delete seen[name]
  return seen
}

/** 只保留正整数计数，坏值丢弃。 */
function normalizeCounts(raw) {
  if (raw === null || raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) return {}
  const out = {}
  for (const [name, value] of Object.entries(raw)) {
    const n = Number(value)
    if (typeof name === 'string' && name !== '' && Number.isFinite(n) && n > 0) out[name] = Math.floor(n)
  }
  return out
}

function normalizeState(raw) {
  const base = defaultState()
  if (raw === null || raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) return base
  return {
    active: raw.active === true,
    activity: typeof raw.activity === 'string' ? raw.activity : '',
    until: typeof raw.until === 'string' ? raw.until : '',
    startedAt: typeof raw.startedAt === 'string' ? raw.startedAt : '',
    excludes: Array.isArray(raw.excludes) ? normalizeExcludes(raw.excludes) : null,
    ownerName: typeof raw.ownerName === 'string' ? raw.ownerName.trim().slice(0, 24) : '',
    intervalMinutes: Number.isFinite(raw.intervalMinutes) && raw.intervalMinutes > 0 ? raw.intervalMinutes : null,
    lastScanAt: typeof raw.lastScanAt === 'string' ? raw.lastScanAt : '',
    nextScanAt: typeof raw.nextScanAt === 'string' ? raw.nextScanAt : '',
    baselineAt: typeof raw.baselineAt === 'string' ? raw.baselineAt : '',
    // 老未读基线：{name, preview} 对；旧格式（纯字符串）仍然接受。
    baselineUnread: normalizeBaseline(raw.baselineUnread),
    lastSelectedRow: normalizeLastSelectedRow(raw.lastSelectedRow),
    lastEndedAt: typeof raw.lastEndedAt === 'string' ? raw.lastEndedAt : '',
    endedReason: typeof raw.endedReason === 'string' ? raw.endedReason : '',
    lastReplies: normalizeReplies(raw.lastReplies),
    replyCounts: normalizeCounts(raw.replyCounts),
    seenRows: normalizeSeen(raw.seenRows),
    selfUnread: normalizeSelfUnread(raw.selfUnread),
    pendingFollowUp: normalizePendingFollowUp(raw.pendingFollowUp),
    handled: normalizeHandled(raw.handled),
    sendFailures: normalizeFailures(raw.sendFailures),
    lastDigest: normalizeLastDigest(raw.lastDigest),
    pendingDigest: normalizePendingDigest(raw.pendingDigest),
  }
}

/** inbox 一行记录的规范化，兼容手工编辑过的文件。 */
function normalizeRecord(raw) {
  if (raw === null || typeof raw !== 'object') return undefined
  const ts = typeof raw.ts === 'string' ? raw.ts : ''
  const session = typeof raw.session === 'string' ? raw.session : ''
  if (ts === '' || session === '') return undefined
  const record = {
    ts,
    session,
    message: typeof raw.message === 'string' ? raw.message : '',
    kind: raw.kind === 'private' || raw.kind === 'group' ? raw.kind : 'unknown',
    action: typeof raw.action === 'string' && raw.action !== '' ? raw.action : 'recorded',
    reply: typeof raw.reply === 'string' ? raw.reply : '',
    urgent: raw.urgent === true,
    quiet: raw.quiet === true,
  }
  if (typeof raw.reason === 'string' && raw.reason !== '') record.reason = raw.reason
  // 这两个是后加的可选字段：老记录没有就保持缺省，避免把旧文件改坏。
  if (typeof raw.deselected === 'boolean') record.deselected = raw.deselected
  if (typeof raw.kindSource === 'string' && raw.kindSource !== '') record.kindSource = raw.kindSource
  return record
}

/** 把 ISO 时间格式化成 HH:mm（本地时区）。 */
function clockText(iso) {
  if (typeof iso !== 'string' || iso === '') return ''
  const date = new Date(iso)
  if (Number.isNaN(date.getTime())) return ''
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

/** 把分钟数格式化成人话。 */
function formatMinutes(minutes) {
  if (Number.isFinite(minutes) && minutes > 0 && minutes < 1) {
    return `${Math.max(1, Math.round(minutes * 60))} 秒`
  }
  const value = Math.max(0, Math.round(minutes))
  if (value < 60) return `${value} 分钟`
  const hours = Math.floor(value / 60)
  const rest = value % 60
  return rest === 0 ? `${hours} 小时` : `${hours} 小时 ${rest} 分钟`
}

/** 把毫秒差格式化成时长。 */
function formatDuration(ms) {
  return formatMinutes(ms / 60_000)
}

/** 截断长文本，避免工具输出被单条消息撑爆。 */
function shorten(value, limit = 40) {
  if (typeof value !== 'string') return ''
  const flat = value.replace(/\s+/gu, ' ').trim()
  return flat.length <= limit ? flat : `${flat.slice(0, limit)}…`
}

/** 把若干条来信压成一行短名单：名字「内容」→ 动作；最多列 3 条。 */
function digestEntriesText(entries) {
  const list = entries.slice(0, DIGEST_ENTRY_LIMIT).map((entry) => {
    const action = ACTION_LABELS[entry.action] ?? entry.action
    return `${entry.session}「${shorten(entry.text, 20)}」→ ${action}`
  })
  const extra = entries.length - list.length
  const joined = list.join('；')
  return extra > 0 ? `${joined}；等 ${extra} 条` : joined
}

/** 单行摘要，例如「值守摘要 18:44 · 小比格「在吗」→ 已回复」。 */
function buildDigestText(entries, atIso, urgent = false) {
  const flag = urgent ? '紧急 · ' : ''
  return `值守摘要 ${clockText(atIso)} · ${flag}${digestEntriesText(entries)}`
}

/**
 * 探测 Host 侧可用的通知服务（notifications / toast / ui），取第一个能调用的方法。
 * 没有可用服务时返回 null，调用方退回到 Windows toast 和 digest.md。
 */
function findHostNotifier(ctx) {
  if (ctx === null || typeof ctx !== 'object' || typeof ctx.get !== 'function') return null
  for (const key of ['notifications', 'toast', 'ui']) {
    let service
    try {
      service = ctx.get(key)
    } catch {
      continue
    }
    if (service === null || (typeof service !== 'object' && typeof service !== 'function')) continue
    for (const method of ['notify', 'show', 'toast', 'push', 'send']) {
      if (typeof service[method] !== 'function') continue
      return { key, method, run: (title, body) => service[method](title, body) }
    }
  }
  return null
}

/** 统一的错误文本。 */
function describeError(error) {
  return error instanceof Error ? error.message : String(error)
}

/** 判断某个时刻是否落在静默时段内（本地时区，支持跨午夜）。 */
function inQuietHours(hours, date) {
  if (!Array.isArray(hours) || hours.length !== 2) return false
  const [start, end] = hours
  if (!Number.isInteger(start) || !Number.isInteger(end)) return false
  // 起止相同视为“不启用静默”，否则会被理解成全天静默。
  if (start === end) return false
  const hour = date.getHours()
  return start < end ? hour >= start && hour < end : hour >= start || hour < end
}

/** 解析 until：支持完整 ISO 时间或当天的 "17:15"。返回 ISO 字符串，无法识别返回空串。 */
function parseUntil(raw) {
  if (typeof raw !== 'string') return ''
  const value = raw.trim()
  if (value === '') return ''
  const clock = /^(\d{1,2}):(\d{2})$/u.exec(value)
  if (clock !== null) {
    const hour = Number(clock[1])
    const minute = Number(clock[2])
    if (!Number.isInteger(hour) || !Number.isInteger(minute) || hour > 23 || minute > 59) return ''
    const date = new Date()
    date.setHours(hour, minute, 0, 0)
    return date.toISOString()
  }
  const parsed = new Date(value)
  return Number.isNaN(parsed.getTime()) ? '' : parsed.toISOString()
}

/** 剥掉微信的「[N条]」合并提示，剩下的才是真正的消息文本。 */
function stripMergedNotice(value) {
  if (typeof value !== 'string') return ''
  return value.trim().replace(MERGED_NOTICE_PATTERN, '').trim()
}

/** 会话名是否命中内置的服务号 / 系统账号黑名单（包含匹配，不区分大小写）。 */
function isServiceSession(session) {
  const name = typeof session === 'string' ? session.trim().toLowerCase() : ''
  if (name === '') return false
  return SERVICE_KEYWORDS.some((keyword) => name.includes(keyword.toLowerCase()))
}

/**
 * 「消息免打扰」：最可靠的是红点形态——纯红圆点（盘里没有白色数字）就是免打扰，
 * 带白色数字的才是普通未读。行 UIA Name 里的「消息免打扰」只在「没有未读」时出现，
 * 一旦有未读就被「[N条]」挤掉，所以它只能当正向证据，
 * 绝不能拿 mutedByName===false 反证「不是免打扰」。
 * 小铃铛像素（mutedByBell，行右侧预览文字右边那枚带斜杠的铃铛）是辅助证据，命中即免打扰。
 */
function isMutedRow(row) {
  if (row === null || typeof row !== 'object' || row.unread !== true) return false
  if (row.badgeDigit === false) return true
  if (row.mutedByName === true) return true
  return row.mutedByBell === true
}

/**
 * watch / probe 的行归一到同一形状：probe 有 title/kind，watch 只有 name。
 * kind 只有 probe 会给，watch 一律 unknown（需要时再走 preflight 确认）。
 */
function normalizeWatchRow(raw) {
  if (raw === null || typeof raw !== 'object') {
    return {
      name: '',
      title: '',
      preview: '',
      time: '',
      y: 0,
      pinned: false,
      selected: false,
      foldBar: false,
      unread: false,
      kind: 'unknown',
      badgePx: 0,
      badgeTight: 0,
      badgeBox: '',
      badgeWhitePx: 0,
      badgeDigit: undefined,
      mutedByName: undefined,
      mutedByBell: undefined,
      bellPx: 0,
    }
  }
  const name = typeof raw.name === 'string' ? raw.name.trim() : ''
  const title = typeof raw.title === 'string' && raw.title.trim() !== '' ? raw.title.trim() : name
  const kind = raw.kind === 'private' || raw.kind === 'group' ? raw.kind : 'unknown'
  return {
    name,
    title,
    preview: typeof raw.preview === 'string' ? raw.preview : '',
    time: typeof raw.time === 'string' ? raw.time : '',
    y: Number.isFinite(raw.y) ? raw.y : 0,
    pinned: raw.pinned === true,
    selected: raw.selected === true,
    foldBar: raw.foldBar === true,
    unread: raw.unread === true,
    kind,
    badgePx: Number.isFinite(raw.badgePx) ? raw.badgePx : 0,
    badgeTight: Number.isFinite(raw.badgeTight) ? raw.badgeTight : 0,
    badgeBox: typeof raw.badgeBox === 'string' ? raw.badgeBox : '',
    badgeWhitePx: Number.isFinite(raw.badgeWhitePx) ? raw.badgeWhitePx : 0,
    // 旧版 ps1 没有这个字段：保持 undefined（绝不当成 false/免打扰）。
    badgeDigit: raw.badgeDigit === true ? true : raw.badgeDigit === false ? false : undefined,
    // 新版 ps1 直接给「消息免打扰」标记（来自 UIA Name），比像素判据可靠。
    mutedByName: raw.mutedByName === true ? true : raw.mutedByName === false ? false : undefined,
    // 小铃铛像素检测：命不命中都只作辅助，缺失时保持 undefined。
    mutedByBell: raw.mutedByBell === true ? true : raw.mutedByBell === false ? false : undefined,
    bellPx: Number.isFinite(raw.bellPx) ? raw.bellPx : 0,
  }
}

/** watch 的 selectedRow 归一：只要 {name, preview, time, unread}；没名字就当没有。 */
function normalizeSelectedRow(raw) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null
  const name = typeof raw.name === 'string' ? raw.name.trim() : ''
  if (name === '') return null
  return {
    name,
    preview: typeof raw.preview === 'string' ? raw.preview : '',
    time: typeof raw.time === 'string' ? raw.time : '',
    unread: raw.unread === true,
  }
}

/** 从一批行里取「带红点」的会话名：折叠条行、无名行都不算，最后去重。 */
function unreadNames(rows) {
  const names = new Set()
  for (const row of rows) {
    if (row === null || typeof row !== 'object') continue
    if (row.foldBar === true || row.unread !== true) continue
    const name = typeof row.title === 'string' && row.title.trim() !== ''
      ? row.title.trim()
      : (typeof row.name === 'string' ? row.name.trim() : '')
    if (name === '') continue
    names.add(name)
  }
  return [...names]
}

/**
 * 基线条目：{ name, preview }。
 * 只按名字排除会让「同一个人之后再发新消息」永远被当成老未读；
 * 记下当时的预览文本，只有预览没变才算同一条老消息。
 */
function unreadBaseline(rows) {
  const seen = new Map()
  for (const row of rows) {
    if (row === null || typeof row !== 'object') continue
    if (row.foldBar === true || row.unread !== true) continue
    const name = typeof row.title === 'string' && row.title.trim() !== ''
      ? row.title.trim()
      : (typeof row.name === 'string' ? row.name.trim() : '')
    if (name === '') continue
    const preview = typeof row.preview === 'string' ? row.preview : ''
    if (!seen.has(name)) seen.set(name, preview)
  }
  return [...seen.entries()].map(([name, preview]) => ({ name, preview }))
}

/** 把 baselineUnread 归一成 Map<name, preview|null>；null 表示旧格式（只认名字）。 */
function baselineMap(value) {
  const map = new Map()
  if (!Array.isArray(value)) return map
  for (const item of value) {
    if (typeof item === 'string') {
      const name = item.trim()
      if (name !== '') map.set(name, null)
      continue
    }
    if (item === null || typeof item !== 'object') continue
    const name = typeof item.name === 'string' ? item.name.trim() : ''
    if (name === '') continue
    map.set(name, typeof item.preview === 'string' ? item.preview : '')
  }
  return map
}

/** 归一 baselineUnread：字符串（旧格式）原样保留，对象只留 {name, preview}，按名字去重。 */
function normalizeBaseline(value) {
  if (!Array.isArray(value)) return []
  const out = []
  const seen = new Set()
  for (const item of value) {
    if (typeof item === 'string') {
      const name = item.trim()
      if (name === '' || seen.has(name)) continue
      seen.add(name)
      out.push(name)
      continue
    }
    if (item === null || typeof item !== 'object') continue
    const name = typeof item.name === 'string' ? item.name.trim() : ''
    if (name === '' || seen.has(name)) continue
    seen.add(name)
    out.push({ name, preview: typeof item.preview === 'string' ? item.preview : '' })
  }
  return out
}

/**
 * 挑出对方最后说的那句：优先最后一条 dir==='in'；
 * 全是 unknown（时间戳、撤回、图片）时退化成最后一条非 out 文本。
 */
function pickIncomingText(messages) {
  const list = []
  for (const message of messages) {
    if (message === null || typeof message !== 'object') continue
    const body = stripMergedNotice(typeof message.text === 'string' ? message.text : '')
    if (body === '') continue
    list.push({ dir: message.dir === 'in' || message.dir === 'out' ? message.dir : 'unknown', text: body })
  }
  for (let index = list.length - 1; index >= 0; index -= 1) {
    if (list[index].dir === 'in') return list[index].text
  }
  for (let index = list.length - 1; index >= 0; index -= 1) {
    if (list[index].dir !== 'out') return list[index].text
  }
  return ''
}

/** 本地时区的日期键，用于 digest.md 按日期分段。 */
function localDayKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}

/** 一次扫描的默认结果形状。 */
function emptyScan(trigger) {
  return {
    ok: false,
    trigger,
    source: '',
    scannedAt: new Date().toISOString(),
    sessions: 0,
    newMessages: 0,
    replied: 0,
    recorded: 0,
    skipped: 0,
    failed: 0,
    silent: 0,
    details: [],
    summary: '',
  }
}

/** 把纯文本包成一个 text 块（与参考插件的 render 返回形状一致）。 */
function blocks(value) {
  return [{ type: 'text', text: value }]
}

/** 一条记录「回没回」的中文说明，汇总和摘要共用。 */
function actionLabel(record) {
  if (record.action === 'replied') return '已回复'
  if (record.action === 'failed') return '回复失败'
  if (record.action === 'skipped') return `已跳过${record.reason === undefined ? '' : `（${record.reason}）`}`
  return `仅记录${record.reason === undefined ? '' : `（${record.reason}）`}`
}

/** 从一批 inbox 记录生成值守汇总（谁 / 几点 / 说了什么 / 回没回 / 标急）。 */
function buildStopSummary(records, startedAt, endedAt) {
  const start = Date.parse(startedAt)
  const end = Date.parse(endedAt)
  const relevant = records.filter((record) => {
    if (record.action === 'system') return false
    const ts = Date.parse(record.ts)
    if (Number.isNaN(ts)) return false
    if (!Number.isNaN(start) && ts < start) return false
    if (!Number.isNaN(end) && ts > end) return false
    return true
  })

  const people = new Map()
  for (const record of relevant) {
    const entry = people.get(record.session) ?? { session: record.session, messages: [], urgent: false }
    entry.messages.push(record)
    if (record.urgent) entry.urgent = true
    people.set(record.session, entry)
  }

  const replied = relevant.filter((record) => record.action === 'replied').length
  const recorded = relevant.filter((record) => record.action === 'recorded').length
  const skipped = relevant.filter((record) => record.action === 'skipped').length
  const failed = relevant.filter((record) => record.action === 'failed').length
  const duration = Number.isNaN(start) || Number.isNaN(end) ? '' : `，历时 ${formatDuration(Math.max(0, end - start))}`
  const lines = [`值守结束（${clockText(startedAt)} – ${clockText(endedAt)}${duration}）。`]
  const digestLines = []

  if (relevant.length === 0) {
    lines.push('期间没有检测到新消息。')
    digestLines.push(`${clockText(endedAt)} 值守结束 · 期间没有检测到新消息`)
    return {
      text: lines.join('\n'),
      digestLines,
      stats: { total: 0, people: 0, replied: 0, recorded: 0, skipped: 0, failed: 0, urgent: 0 },
    }
  }

  // 汇总拆成两行短句：窄窗口里不会折行，每行都是独立一条。
  lines.push(`${people.size} 人来信，${relevant.length} 条新消息。`)
  lines.push(`回复 ${replied} · 记录 ${recorded} · 跳过 ${skipped} · 失败 ${failed}`)
  // 汇总与下面的人/消息明细之间留一个空行。
  lines.push('')
  let firstPerson = true
  for (const entry of people.values()) {
    // 每个用户之间空一行，用户名加「◆【】」标出来，方便一眼扫到"谁"。
    if (!firstPerson) lines.push('')
    firstPerson = false
    const flags = [`${entry.messages.length} 条`]
    if (entry.urgent) flags.push('标急')
    lines.push(`◆【${entry.session}】（${flags.join('，')}）`)
    for (const record of entry.messages) {
      // 补发是我们主动发的一条，不是对方的来信，单独一行说明，别写成「他发了这句」。
      if (record.reason === 'follow-up-catchup') {
        lines.push(`  · ${clockText(record.ts)} 一分钟后无其他信息 → 已回复`)
        continue
      }
      const urgentText = record.urgent ? '（标急）' : ''
      lines.push(`  · ${clockText(record.ts)}「${shorten(record.message, 24)}」→ ${actionLabel(record)}${urgentText}`)
    }
  }

  digestLines.push(
    `${clockText(startedAt)} – ${clockText(endedAt)} 值守结束 · 共 ${people.size} 人来信、${relevant.length} 条新消息`
    + `（自动回复 ${replied}，仅记录 ${recorded}，跳过 ${skipped}，失败 ${failed}）`,
  )
  for (const record of relevant) {
    const urgentText = record.urgent ? '（标急）' : ''
    digestLines.push(`${record.session} ${clockText(record.ts)}「${shorten(record.message, 30)}」${actionLabel(record)}${urgentText}`)
  }

  return {
    text: lines.join('\n'),
    digestLines,
    stats: {
      total: relevant.length,
      people: people.size,
      replied,
      recorded,
      skipped,
      failed,
      urgent: [...people.values()].filter((entry) => entry.urgent).length,
    },
  }
}

/**
 * 创建插件实例：闭包持有配置与运行时状态，返回三个工具和定时器回调。
 * 所有 IO 都在这里面处理，apply() 只负责把工具/定时器挂到 ctx 上。
 */
export function createAwayPlugin(rawConfig, deps = {}) {
  const config = resolveConfig(rawConfig)
  const statePath = join(config.stateDir, STATE_FILE)
  const inboxPath = join(config.stateDir, INBOX_FILE)
  const digestPath = join(config.stateDir, DIGEST_FILE)
  const logPath = join(config.stateDir, LOG_FILE)
  const requestsDir = join(config.stateDir, REQUESTS_DIR)
  const heartbeatPath = join(config.stateDir, HEARTBEAT_FILE)
  const summaryPath = join(config.stateDir, SUMMARY_FILE)
  // 测试注入点：deps.callBridge(mode, extra, timeoutMs) 与真桥同签名、同返回形状。
  const callBridge = typeof deps.callBridge === 'function' ? deps.callBridge : callBridgeProcess
  // 测试注入点：deps.now() 假时钟、deps.notify(title, body) 收集通知。
  const nowDate = typeof deps.now === 'function' ? deps.now : () => new Date()
  const notifySink = typeof deps.notify === 'function' ? deps.notify : null
  // Host 通知服务（notifications / toast / ui）；没有就退回 Windows toast，再不行只靠 digest.md。
  const hostNotifier = findHostNotifier(deps.ctx)

  const runtime = {
    state: defaultState(),
    loaded: false,
    running: false,
    queue: Promise.resolve(),
    /** 最近一次调用本插件工具的会话 id，用于把结束汇总推回对话。 */
    lastSessionId: '',
    /** 上次写心跳的时间戳（毫秒）。 */
    lastHeartbeatAt: 0,
  }

  /** 串行化会改状态的调用，避免定时器和工具同时写状态文件。 */
  function serialize(task) {
    const result = runtime.queue.then(task, task)
    runtime.queue = result.then(() => undefined, () => undefined)
    return result
  }

  /** 追加一行日志；失败也绝不向上抛。 */
  async function logLine(level, message) {
    try {
      await mkdir(config.stateDir, { recursive: true })
      await appendFile(logPath, `[${new Date().toISOString()}] [${level}] ${message}\n`, 'utf8')
    } catch {
      // 日志写不进去时只能放弃，不能影响 Host。
    }
  }

  /** 读 JSON 文件，区分「不存在」和「损坏」，全部转成结构化结果。 */
  async function readJsonFile(path) {
    let raw
    try {
      raw = await readFile(path, 'utf8')
    } catch (error) {
      if (error !== null && typeof error === 'object' && error.code === 'ENOENT') return { ok: false, missing: true }
      return { ok: false, error: describeError(error) }
    }
    try {
      return { ok: true, value: JSON.parse(raw.replace(/^\uFEFF/u, '')) }
    } catch {
      return { ok: false, corrupted: true }
    }
  }

  /** 原子写 JSON（先写临时文件再 rename），避免半截文件。 */
  async function writeJson(path, value) {
    await mkdir(config.stateDir, { recursive: true })
    const temporary = `${path}.${process.pid}.${Date.now()}.tmp`
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
    await rename(temporary, path)
  }

  /** 拿（并缓存）状态；损坏时重置为默认值并记日志。 */
  async function currentState() {
    if (runtime.loaded) return runtime.state
    const file = await readJsonFile(statePath)
    if (file.ok) {
      runtime.state = normalizeState(file.value)
    } else if (file.corrupted === true) {
      runtime.state = defaultState()
      await logLine('warn', 'state.json 损坏，已重置为默认值')
    } else if (file.missing !== true) {
      runtime.state = defaultState()
      await logLine('warn', `state.json 读取失败（${file.error ?? '未知原因'}），已重置为默认值`)
    } else {
      runtime.state = defaultState()
    }
    runtime.loaded = true
    return runtime.state
  }

  /** 持久化状态。 */
  async function saveState(state) {
    await writeJson(statePath, state)
  }

  /** 读 inbox.jsonl；逐行解析，坏行跳过。 */
  async function readInboxRecords() {
    let raw
    try {
      raw = await readFile(inboxPath, 'utf8')
    } catch (error) {
      if (error !== null && typeof error === 'object' && error.code === 'ENOENT') return []
      throw error
    }
    const records = []
    for (const line of raw.split(/\r?\n/u)) {
      const trimmed = line.trim()
      if (trimmed === '') continue
      try {
        const record = normalizeRecord(JSON.parse(trimmed.replace(/^\uFEFF/u, '')))
        if (record !== undefined) records.push(record)
      } catch {
        // 单行损坏不影响其它记录。
      }
    }
    return records
  }

  /** 追加 inbox 记录（每行一个 JSON）。 */
  async function appendRecords(records) {
    if (records.length === 0) return
    await mkdir(config.stateDir, { recursive: true })
    await appendFile(inboxPath, `${records.map((record) => JSON.stringify(record)).join('\n')}\n`, 'utf8')
  }

  /** 追加摘要到 digest.md，按本地日期分段。 */
  async function appendDigest(lines) {
    const list = lines.filter((line) => typeof line === 'string' && line.trim() !== '')
    if (list.length === 0) return
    await mkdir(config.stateDir, { recursive: true })
    let existing = ''
    try {
      existing = await readFile(digestPath, 'utf8')
    } catch {
      existing = ''
    }
    const heading = `## ${localDayKey(new Date())}`
    const hasHeading = existing.split(/\r?\n/u).some((line) => line.trim() === heading)
    const prefix = hasHeading ? '' : `${existing === '' ? '' : '\n'}${heading}\n\n`
    await appendFile(digestPath, `${prefix}${list.map((line) => `- ${line}`).join('\n')}\n`, 'utf8')
  }

  /** 当前实际使用的通知通道，写进日志方便排查。 */
  function notificationMechanism() {
    if (!config.notify) return 'disabled'
    if (notifySink !== null) return 'injected'
    if (hostNotifier !== null) return `host:${hostNotifier.key}.${hostNotifier.method}`
    return 'windows-toast'
  }

  /**
   * 统一通知入口：Host 服务 → Windows toast；两者都不可用时只留 digest.md（调用方总会写）。
   * 任何失败都只记日志，绝不阻塞扫描。
   */
  function notify(title, body) {
    if (!config.notify) return false
    if (notifySink !== null) {
      try {
        notifySink(title, body)
        return true
      } catch (error) {
        void logLine('warn', `测试通知通道失败：${describeError(error)}`)
        return false
      }
    }
    if (hostNotifier !== null) {
      try {
        const result = hostNotifier.run(title, body)
        if (result !== null && typeof result === 'object' && typeof result.then === 'function') {
          result.catch((error) => void logLine('warn', `Host 通知失败：${describeError(error)}`))
        }
        return true
      } catch (error) {
        void logLine('warn', `Host 通知不可用，改用系统通知：${describeError(error)}`)
      }
    }
    return toastNotify(title, body)
  }

  /**
   * 弹一条 Windows 系统通知（WinRT toast）。
   * 用 spawn 异步触发、不等待结果；标题和正文通过环境变量传入，避免拼命令时的注入问题。
   * 这条通道允许失败：出错只写日志，绝不影响扫描。
   */
  function toastNotify(title, body) {
    const script = [
      '[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null',
      '[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null',
      '$t=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)',
      '$x=$t.GetXml()',
      '$nodes=$x.GetElementsByTagName("text")',
      '$nodes.Item(0).AppendChild($x.CreateTextNode($env:DSH_TOAST_TITLE)) | Out-Null',
      '$nodes.Item(1).AppendChild($x.CreateTextNode($env:DSH_TOAST_BODY)) | Out-Null',
      '$toast=[Windows.UI.Notifications.ToastNotification]::new($t)',
      "$ids=@('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe','Microsoft.Windows.PowerShell')",
      'foreach ($id in $ids) { try { [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($id).Show($toast); break } catch { } }',
    ].join('; ')
    try {
      const child = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
        windowsHide: true,
        stdio: ['ignore', 'ignore', 'pipe'],
        env: { ...process.env, DSH_TOAST_TITLE: title, DSH_TOAST_BODY: body },
      })
      let stderr = ''
      child.stderr?.on('data', (chunk) => {
        if (stderr.length < 2000) stderr += chunk.toString('utf8')
      })
      child.on('error', (error) => {
        void logLine('warn', `系统通知启动失败：${describeError(error)}`)
      })
      child.on('close', (code) => {
        if (code !== 0) void logLine('warn', `系统通知失败（退出码 ${code}）：${stderr.trim().slice(-300)}`)
      })
      child.unref()
      return true
    } catch (error) {
      void logLine('warn', `系统通知启动失败：${describeError(error)}`)
      return false
    }
  }

  /** 统一的「失败只记日志」包装。 */
  async function attempt(label, action) {
    try {
      return await action()
    } catch (error) {
      await logLine('error', `${label}失败：${describeError(error)}`)
      return undefined
    }
  }

  /** 真桥：调用一次 PowerShell 桥，返回 {ok:true,data} 或 {ok:false,error,code}。 */
  async function callBridgeProcess(mode, extra = {}, timeoutMs = BRIDGE_TIMEOUT_MS) {
    const outPath = join(
      tmpdir(),
      `dsh-wechat-away-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.json`,
    )
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', config.scriptPath, '-Mode', mode]
    if (extra.session !== undefined) args.push('-Session', extra.session)
    if (extra.text !== undefined) args.push('-Text', extra.text)
    if (extra.limit !== undefined) args.push('-Limit', String(extra.limit))
    if (extra.expectSession !== undefined) args.push('-ExpectSession', extra.expectSession)
    if (extra.scroll === true) args.push('-Scroll')
    if (extra.idle === true) args.push('-Idle')
    if (extra.allowFoldToggle === true) args.push('-AllowFoldToggle')
    args.push('-Out', outPath)

    try {
      await access(config.scriptPath)
    } catch {
      return { ok: false, error: `找不到微信 PowerShell 桥脚本：${config.scriptPath}`, code: 'script-missing' }
    }

    let child
    try {
      child = spawn('powershell.exe', args, { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] })
    } catch (error) {
      return { ok: false, error: `无法启动 powershell.exe：${describeError(error)}`, code: 'spawn-failed' }
    }

    let stderr = ''
    const closed = await new Promise((resolve) => {
      let settled = false
      const done = (value) => {
        if (settled) return
        settled = true
        resolve(value)
      }
      const timer = setTimeout(() => {
        try {
          child.kill()
        } catch {
          // 进程可能已经退出。
        }
        done({ kind: 'timeout' })
      }, timeoutMs)
      child.stderr?.on('data', (chunk) => {
        if (stderr.length < 4000) stderr += chunk.toString('utf8')
      })
      child.on('error', (error) => {
        clearTimeout(timer)
        done({ kind: 'error', error })
      })
      child.on('close', (code) => {
        clearTimeout(timer)
        done({ kind: 'closed', code })
      })
    })

    if (closed.kind === 'error') {
      return { ok: false, error: `powershell.exe 启动失败：${describeError(closed.error)}`, code: 'spawn-failed' }
    }

    let raw
    try {
      raw = await readFile(outPath, 'utf8')
    } catch {
      raw = undefined
    }
    rm(outPath, { force: true }).catch(() => {})

    if (closed.kind === 'timeout') {
      return {
        ok: false,
        error: `微信桥脚本 ${Math.round(timeoutMs / 1000)} 秒未返回（Mode=${mode}），已终止。`,
        code: 'timeout',
      }
    }
    if (raw === undefined) {
      const tail = stderr.trim().slice(-400)
      return {
        ok: false,
        error: `微信桥脚本没有写出结果文件（退出码 ${closed.code}${tail === '' ? '' : `；stderr: ${tail}`}）。`,
        code: 'no-output',
      }
    }
    let parsed
    try {
      parsed = JSON.parse(raw.replace(/^\uFEFF/u, ''))
    } catch {
      return { ok: false, error: '微信桥脚本的输出不是合法 JSON。', code: 'bad-json', detail: raw.slice(0, 300) }
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { ok: false, error: '微信桥脚本的输出不是 JSON 对象。', code: 'bad-json' }
    }
    if (parsed.ok === false) {
      const message = typeof parsed.error === 'string' && parsed.error !== ''
        ? parsed.error
        : `微信桥脚本返回失败（退出码 ${closed.code}）`
      return { ok: false, error: message, code: 'bridge-failed' }
    }
    return { ok: true, data: parsed }
  }

  /**
   * watch 模式：快速巡检视口，返回归一化后的会话行。
   * selectedRow 是「当前打开的那个会话」的快照（没打开任何会话时为 null），
   * 用来兜底发现「因为正开着而被立刻标已读」的新消息。
   */
  async function bridgeWatch() {
    const call = await callBridge('watch', {})
    if (!call.ok) return call
    const rows = Array.isArray(call.data.rows) ? call.data.rows : []
    return { ok: true, rows: rows.map(normalizeWatchRow), selectedRow: normalizeSelectedRow(call.data.selectedRow) }
  }

  /** probe 模式：全量滚动列表（约 34 秒），只在手动排查时使用。 */
  async function bridgeProbe() {
    const call = await callBridge('probe', { scroll: true }, PROBE_TIMEOUT_MS)
    if (!call.ok) return call
    const rows = Array.isArray(call.data.rows) ? call.data.rows : []
    // 全量 probe 不汇报当前选中行；给统一形状，调用方不用区分 undefined / null。
    return { ok: true, rows: rows.map(normalizeWatchRow), selectedRow: null }
  }

  /**
   * preflight 模式：切进会话看一眼，拿 kindHint 判群聊。
   * 桥脚本较新时会额外给 chatTitle / isGroupTitle / titleKindConfidence / kindSource；
   * 这些字段缺失时保持 null，让 confirmKindByPreflight 退回原来的 kindHint 逻辑。
   */
  async function bridgePreflight(session) {
    const call = await callBridge('preflight', { session })
    if (!call.ok) return call
    const data = call.data
    const hint = data.kindHint === 'private' || data.kindHint === 'group' ? data.kindHint : 'unknown'
    return {
      ok: true,
      kind: hint,
      chatTitle: typeof data.chatTitle === 'string' ? data.chatTitle.trim() : '',
      isGroupTitle: typeof data.isGroupTitle === 'boolean' ? data.isGroupTitle : null,
      confidence: Number.isFinite(data.titleKindConfidence) ? data.titleKindConfidence : null,
      kindSource: typeof data.kindSource === 'string' && data.kindSource !== '' ? data.kindSource : 'preview',
    }
  }

  /** read 模式：读最近的几条消息，用来挑出对方的新内容。 */
  async function bridgeRead(session) {
    const call = await callBridge('read', { session, limit: READ_LIMIT })
    if (!call.ok) return call
    return { ok: true, messages: Array.isArray(call.data.messages) ? call.data.messages : [] }
  }

  /**
   * markunread 模式：右键会话行 → 点菜单里的「标为未读」，把红点还回去。
   * 只用于「只记录不回复」的路径：已经回复过的会话本来就该是已读。
   */
  async function bridgeMarkUnread(session, options = {}) {
    const extra = { session }
    if (options.allowFoldToggle === true) extra.allowFoldToggle = true
    const call = await callBridge('markunread', extra, MARK_UNREAD_TIMEOUT_MS)
    if (!call.ok) return { ok: false, error: call.error }
    if (call.data.ok === false) {
      return {
        ok: false,
        error: typeof call.data.error === 'string' && call.data.error !== '' ? call.data.error : '桥脚本报告未标为未读',
      }
    }
    return {
      ok: true,
      changed: call.data.changed === true,
      method: typeof call.data.method === 'string' ? call.data.method : '',
      rowUnreadAfter: call.data.rowUnreadAfter === true,
    }
  }

  /** send 模式：带 ExpectSession 校验，返回 {ok, verified, lastMessage} 或 {ok:false,error}。 */
  async function bridgeSend(session, message) {
    const call = await callBridge('send', { session, text: message, expectSession: session })
    if (!call.ok) return { ok: false, error: call.error }
    if (call.data.sent === false) {
      return {
        ok: false,
        error: typeof call.data.error === 'string' && call.data.error !== '' ? call.data.error : '桥脚本报告未发送',
      }
    }
    return {
      ok: true,
      verified: call.data.verified === true,
      lastMessage: typeof call.data.lastMessage === 'string' ? call.data.lastMessage : '',
    }
  }

  /**
   * deselect 模式：把会话面板收起来，让微信回到「无选中会话」。
   * 回复完必须做这一步：微信会立刻把打开中的会话标已读，面板不收起来的话，
   * 刚回复的人再发消息也永远不会长红点，红点检测就看不到他。
   */
  async function bridgeDeselect(options = {}) {
    const call = await callBridge('deselect', options.idle === true ? { idle: true } : {}, DESELECT_TIMEOUT_MS)
    if (!call.ok) return { ok: false, error: call.error }
    // 桥脚本自己报告 ok=false（面板还在）也算失败；只是「本来就没打开」不算，仍算已收起。
    if (call.data.ok === false) {
      return {
        ok: false,
        error: typeof call.data.error === 'string' && call.data.error !== '' ? call.data.error : '桥脚本报告未收起会话',
      }
    }
    return { ok: true, changed: call.data.changed === true, wasOpen: call.data.wasOpen === true }
  }

  /**
   * 回复完之后尽力收起会话，返回是否成功（写进 inbox 的 deselected 字段）。
   * 这里只是「顺手关灯」：失败只记一行 deselect-failed，绝不改「已回复」的判定。
   */
  async function collapseChat(title) {
    try {
      const collapsed = await bridgeDeselect()
      if (collapsed.ok) return true
      await logLine('warn', `deselect-failed：回复 ${title} 后没能收起会话（${collapsed.error}）`)
      return false
    } catch (error) {
      await logLine('warn', `deselect-failed：回复 ${title} 后没能收起会话（${describeError(error)}）`)
      return false
    }
  }

  /**
   * 只记录不回复时，也要拿到真实内容、并把会话标回未读：
   * 1) read（会打开会话，微信随即把红点清掉）读出真实文本，写进 record.message；
   * 2) deselect 把会话收起来；
   * 3) markunread 用右键菜单「标为未读」把红点还回去，用户回来还能看到。
   *
   * 任何一步失败都只降级、绝不影响记录本身：
   * - read 失败退回列表预览（readVia='preview'，message 保持预览）；
   * - markunread 失败只 warn（markedUnread=false）；
   * - readRecordedChat=false 时完全退回旧行为（只补一句 readVia）。
   *
   * options.textKnown=true 表示调用方刚刚已经 read 过（文本已写进 record.message），
   * 这里只补 deselect + markunread。
   */
  async function settleRecordedChat(state, title, record, options = {}) {
    const textKnown = options.textKnown === true
    const enabled = config.readRecordedChat === true
    let haveText = textKnown
    if (!haveText) {
      if (!enabled) {
        record.readVia = 'preview'
        return record
      }
      const read = await bridgeRead(title)
      if (read.ok) {
        const incoming = pickIncomingText(read.messages)
        if (incoming !== '') {
          record.message = incoming
          if (URGENT_PATTERN.test(incoming)) record.urgent = true
          haveText = true
        }
      } else {
        await logLine('warn', `读取 ${title} 的真实内容失败，退回列表预览：${read.error}`)
      }
      if (!haveText) {
        record.readVia = 'preview'
        return record
      }
    }
    record.readVia = 'chat'
    // 顺序很重要：先标未读、再收起会话。
    // 会话开着时它的行就在列表顶上，右键找得到；一旦收起，置顶会话可能被
    // 「已置顶」折叠条挡住，右键就落空了。标完再收起也不会把红点清掉。
    if (enabled) {
      const marked = await bridgeMarkUnread(title, { allowFoldToggle: true })
      record.markedUnread = marked.ok === true
      // 无论标未读成功与否都要记账：这条文本已经处理过了，下一轮不能再当新来信。
      state.selfUnread[title] = { key: seenKeyOf(record.previewText ?? record.message ?? ''), at: Date.now() }
      if (!marked.ok) {
        await logLine('warn', `mark-unread-failed：${title} 没能标回未读（${marked.error}）`)
      }
    }
    record.deselected = await collapseChat(title)
    return record
  }

  /**
   * 把微信摆成"闲置态"：收起打开的会话。
   * 值守开始时必须做这一步：微信会把"当前打开会话"的新消息直接标成已读，
   * 不收起的话，那个人的来信永远不长红点，也就永远发现不了。
   * 列表回到顶部由 watch 自己保证（它就是滚到顶再读视口）。
   */
  async function ensureIdleUi() {
    try {
      // 先让 watch 把窗口恢复/滚到顶（最小化时 deselect 点不到任何东西），
      // 再把打开的会话收起，这样才是"闲置态"：列表在顶部、没有选中的会话。
      const watched = await bridgeWatch()
      if (watched.ok !== true) {
        return { ok: false, error: watched.error === undefined ? 'watch-failed' : watched.error }
      }
      const deselected = await bridgeDeselect({ idle: true })
      if (deselected.ok !== true) {
        return { ok: false, error: deselected.error === undefined ? 'deselect-failed' : deselected.error }
      }
      return { ok: true, changed: deselected.changed === true }
    } catch (error) {
      return { ok: false, error: describeError(error) }
    }
  }

  /** 当次值守生效的排除名单：start 传的 ∪ 配置 excludes ∪ 配置 excludeSessions，去重。 */
  function effectiveExcludes(state) {
    const merged = [
      ...(Array.isArray(state.excludes) ? state.excludes : []),
      ...config.excludes,
      ...config.excludeSessions,
    ]
    const seen = new Set()
    const result = []
    for (const item of merged) {
      if (typeof item !== 'string') continue
      const value = item.trim()
      if (value === '' || seen.has(value.toLowerCase())) continue
      seen.add(value.toLowerCase())
      result.push(value)
    }
    return result
  }

  /** 会话名是否命中某个名字列表（不区分大小写的包含匹配）。 */
  function matchesAny(list, session) {
    const needle = session.toLowerCase()
    return list.some((item) => {
      const value = item.toLowerCase()
      return value === needle || needle.includes(value)
    })
  }

  /** 会话名命中任一排除项，只记录不回复。 */
  function isExcluded(state, session) {
    return matchesAny(effectiveExcludes(state), session)
  }

  /** 黑名单：强制只记录，不回复。 */
  function isDenied(session) {
    return matchesAny(config.denySessions, session)
  }

  /**
   * 发送前的二次确认：watch 看不出群聊时切进会话看一眼。
   * 标题优先（群名带人数/前缀，比数「昵称: 」消息前缀可靠，也省一轮判定）：
   *   1. isGroupTitle === true  → group，kindSource = title，不再看 kindHint；
   *   2. isGroupTitle === false 且 chatTitle 非空 → private，kindSource = title；
   *   3. 否则退回 kindHint（group / private / unknown），kindSource = preview。
   * private 才回复；group 只记录；unknown（读不到/拿不准）放弃回复。
   */
  async function confirmKindByPreflight(title) {
    const call = await bridgePreflight(title)
    if (!call.ok) return { ok: false, error: call.error }
    if (call.isGroupTitle === true) {
      return { ok: true, kind: 'group', kindSource: 'title', title: call.chatTitle, confidence: call.confidence }
    }
    if (call.isGroupTitle === false && call.chatTitle !== '') {
      return { ok: true, kind: 'private', kindSource: 'title', title: call.chatTitle, confidence: call.confidence }
    }
    return { ok: true, kind: call.kind, kindSource: 'preview', title: call.chatTitle, confidence: call.confidence }
  }

  /** 纯表情/标点，或极短的确认词：对方只是「收到」，不值得再回一条。 */
  const ACK_WORDS = /^(?:收到|好的?|嗯+|哦+|噢+|ok|okay|行|可以|好嘞|谢谢|谢啦|辛苦了?|在吗|喂|哈+|嘿+|👌|👍)$/iu

  /** 表情包/图片/语音这类没文字的预览，回一句「收到了」也没意义。 */
  const MEDIA_PREVIEW = /^(?:动画表情|表情包?|图片|视频|语音|文件|位置|链接|小程序|转账|红包|名片|聊天记录)/u

  /** 判断一条来信是不是「仅确认/表情」，这类消息只记录、不再回复。 */
  function isBareAcknowledgement(value) {
    const raw = stripMergedNotice(value).trim()
    if (MEDIA_PREVIEW.test(raw.replace(/^\[[^\]]*\]/u, ''))) return true
    const body = raw.replace(/\s+/gu, '').replace(/\[[^\]]*\]/gu, '')
    if (body === '') return true
    if (ACK_WORDS.test(body)) return true
    // 只剩表情、符号、标点（没有任何文字）也算。
    return !/[\p{Script=Han}\p{L}\p{N}]/u.test(body)
  }

  /** 回复里怎么称呼本人：state.ownerName（首次运行存下的）→ 配置 ownerName → 中性称呼。 */
  function ownerLabel(state) {
    const fromState = text(state !== null && typeof state === 'object' ? state.ownerName : '', '')
    if (fromState !== '') return fromState
    const fromConfig = text(config.ownerName, '')
    return fromConfig !== '' ? fromConfig : '机主'
  }

  /** 同一会话的第二条及以后来信，用这句兜底，不再复述活动。 */
  function buildFollowUpText(state) {
    const owner = ownerLabel(state)
    const when = state.until !== '' ? `${clockText(state.until)} 之后` : '等他回来'
    return `以上内容我都收到了，会转述给${owner}，${when}他看到后会回您。`
  }

  /** 是否还在该会话的自动回复冷却期内。 */
  function isCoolingDown(lastReply) {
    if (config.cooldownMinutes <= 0) return false
    if (lastReply === null || typeof lastReply !== 'object') return false
    if (typeof lastReply.at !== 'string') return false
    const at = Date.parse(lastReply.at)
    if (Number.isNaN(at)) return false
    return nowDate().getTime() - at < config.cooldownMinutes * 60_000
  }

  /** 当次值守的扫描间隔。 */
  function intervalMinutesOf(state) {
    return Number.isFinite(state.intervalMinutes) && state.intervalMinutes > 0
      ? state.intervalMinutes
      : config.scanIntervalMinutes
  }

  /** 构造回复文案：随机挑一个变体，必须带“AI 助手”和活动。 */
  function buildReplyText(state, session) {
    const activity = text(state.activity, '在忙')
    const rawWhen = typeof state.untilText === 'string' ? state.untilText.trim() : ''
    const when = state.untilMode === 'duration' && rawWhen !== ''
      ? `大概${/后$/u.test(rawWhen) ? rawWhen : `${rawWhen}后`}`
      : state.until !== '' ? `${clockText(state.until)} 之后` : '稍后'
    const polite = POLITE_KEYWORDS.some((keyword) => session.includes(keyword))
    const variants = polite ? POLITE_TEMPLATES : CASUAL_TEMPLATES
    const template = variants[Math.floor(Math.random() * variants.length)]
    const reason = describePhoneState(activity)
    // 原因为空时整段（连同前面的逗号）一起去掉，避免出现「，。」这种破句。
    const base = reason === '' ? template.replace(/\{reason\}，/gu, '') : template
    return base.replace(/\{(owner|activity|reason|when)\}/gu, (_match, key) => {
      if (key === 'owner') return ownerLabel(state)
      if (key === 'activity') return activity
      if (key === 'reason') return reason
      return when
    })
  }

  /**
   * 对一条「不在基线里、且带红点」的会话行做过滤并（在允许时）回复。
   * 判定顺序：排除名单 → 黑名单 → 服务号 → 群聊 → 静默时段 → 冷却 → 去重 → 未值守
   *           → preflight 确认 → 读消息 → 发送 → 收起会话。
   * options.openChat=true 表示这是「正开着的会话」兜底候选：它没有红点，
   * 不能再因为本轮值守已经回过这个人就直接跳过，要靠 read 到的文本与 handled 比较去重。
   */
  async function evaluateWatchRow(row, state, options = {}) {
    const title = row.title !== '' ? row.title : row.name
    const preview = row.preview
    const urgent = URGENT_PATTERN.test(preview)
    const quiet = inQuietHours(config.quietHours, new Date())
    let kind = row.kind
    const record = {
      ts: new Date().toISOString(),
      session: title,
      message: preview,
      /** 列表里的原始预览（可能带「[N条]」前缀）；真实内容在 message。 */
      previewText: preview,
      kind,
      action: 'recorded',
      reply: '',
      urgent,
      quiet: false,
    }
    // 来源标记（如 open-chat）；后面的具体分支会覆盖成更精确的原因。
    if (typeof options.reason === 'string' && options.reason !== '') record.reason = options.reason
    const detail = `${title}（${KIND_LABELS[kind]}）：${shorten(preview)}`

    // 静默过滤放在最前面，而且故意写在 seenRows 之前：服务号 / 免打扰会话
    // 「不回复也不记录」——不进 inbox、不进 digest、不发通知，也不占去重表。
    // 这也优先于排除名单/黑名单：这两类对用户来说永远不该产生日志。
    if (isServiceSession(title)) {
      await logLine('debug', `忽略服务号 ${detail}`)
      return { skip: true, session: title, reason: 'service-silent' }
    }
    if (isMutedRow(row)) {
      await logLine('debug', `忽略免打扰 ${detail}`)
      return { skip: true, session: title, reason: 'muted-silent' }
    }

    // 我们自己贴回去的红点不算新来信：十秒到十分钟内同一条预览直接跳过。
    // 只有"预览和刚才那条一字不差"才算我们自己贴回去的红点。
    // 早先这里是"预览包含前 12 个字"，结果 [动画表情] / [图片] / 嗯 这类短消息
    // 会把同一会话后面几分钟的真实来信一起吞掉——连续发消息时尤其明显。
    const selfMark = state.selfUnread[title]
    if (row.unread === true && selfMark !== undefined) {
      const fresh = Date.now() - (selfMark.at ?? 0) < SELF_UNREAD_TTL_MS
      const same = seenKeyOf(preview) === seenKeyOf(selfMark.key ?? '')
      // 我们贴回去时只会有一个红点；条数变成 2 以上说明又来了新消息，
      // 哪怕内容一模一样也必须当成新来信处理。
      const onlyOurDot = unreadCountOf(preview) <= 1
      if (fresh && same && onlyOurDot) {
        return { skip: true, session: title, reason: 'self-unread' }
      }
      delete state.selfUnread[title]
    }

    // 自己刚发出去的那句话，会因为"贴回红点"而以未读形态再出现一次。
    // 那不是来信：只要预览里还是我们上一句回复，就整条忽略（不记录、不回复）。
    const lastReply = state.lastReplies[title]
    if (row.unread === true && lastReply !== undefined && typeof lastReply.text === 'string') {
      const shown = seenKeyOf(preview).replace(/…$/u, '').trim()
      const mine = seenKeyOf(lastReply.text)
      // 列表预览会把长句截断成「…」，所以只要求"预览是我们那句的开头"，且足够长，
      // 避免「嗯」「好的」这类短词把真实来信误判成自回声。
      if (shown.length >= 8 && mine.startsWith(shown)) {
        await logLine('debug', `忽略自回声 ${detail}`)
        return { skip: true, session: title, reason: 'self-echo' }
      }
    }

    // 同一条消息（同会话、同预览、同时间）只处理一次。
    // 微信的未读红点会一直亮着，冷却/表情跳过时如果不记账，下一轮还会被当成新来信。
    const stamp = typeof row.time === 'string' ? row.time : ''
    const seenKey = seenKeyOf(preview) + '#' + String(unreadCountOf(preview))
    const previousSeen = state.seenRows[title]
    if (stamp !== '' && previousSeen !== undefined
      && String(previousSeen.preview) === seenKey && previousSeen.time === stamp) {
      return { duplicate: true, session: title, message: preview, reason: 'duplicate-seen' }
    }
    state.seenRows[title] = { preview: seenKey, time: stamp, at: Date.now() }
    trimSeen(state.seenRows)

    if (isExcluded(state, title)) {
      record.reason = 'excluded'
      await logLine('info', `新消息 ${detail}（排除名单，仅记录）`)
      return settleRecordedChat(state, title, record)
    }
    if (isDenied(title)) {
      record.reason = 'denied'
      await logLine('info', `新消息 ${detail}（黑名单，仅记录）`)
      return settleRecordedChat(state, title, record)
    }
    if (kind === 'group' && !config.autoReplyGroups) {
      record.reason = 'group'
      await logLine('info', `新消息 ${detail}（群聊，仅记录）`)
      return settleRecordedChat(state, title, record)
    }
    if (quiet) {
      record.quiet = true
      record.reason = 'quiet'
      await logLine('info', `新消息 ${detail}（静默时段，仅记录）`)
      return settleRecordedChat(state, title, record)
    }
    // 同一会话的回复次数：0=还没回过（完整模板），1=回第二次（一句兜底），>=2=只记录。
    const repliedCount = state.replyCounts[title] ?? 0
    // repliedCount 现在只用来挑文案（首条完整模板 / 之后 follow-up），不再拦回复。
    // 上限不再是「回过 2 次就只记录」，而是「回复后静默一分钟」：
    // 一分钟内他接着发，只记账不打扰；超过一分钟再发新内容，就再回一条
    // （第 2 条起用 follow-up 文案，避免刷屏）。
    if (isCoolingDown(state.lastReplies[title])) {
      // 「嗯」「好的」这类纯应答不补发，只有真内容才记进待补发队列。
      const bare = isBareAcknowledgement(stripMergedNotice(preview))
      if (bare !== true) {
        const queued = state.pendingFollowUp[title]
        state.pendingFollowUp[title] = {
          count: (queued !== undefined ? queued.count : 0) + 1,
          at: nowDate().getTime(),
        }
      }
      record.action = 'skipped'
      record.reason = 'cooldown'
      await logLine('info', `新消息 ${detail}（冷却中，跳过）`)
      return settleRecordedChat(state, title, record)
    }
    // 同一人再次来信要照常处理：是否重复交给下面「read 文本 vs handled.text」判断。
    // （早退会让人在一次值守里被永久跳过，用户在手机上补发第二条就再也收不到回复。）
    if (state.active !== true) {
      record.reason = 'inactive'
      await logLine('info', `新消息 ${detail}（未值守，仅记录）`)
      return settleRecordedChat(state, title, record)
    }

    // watch 看不出是不是群聊时，切进会话用 preflight 的 kindHint 再确认一次。
    if (kind === 'unknown') {
      const confirmed = await confirmKindByPreflight(title)
      if (!confirmed.ok) {
        record.reason = 'unconfirmed'
        await logLine('warn', `无法确认 ${title} 是否群聊（${confirmed.error}），放弃自动回复`)
        return settleRecordedChat(state, title, record)
      }
      if (confirmed.kind === 'group') {
        record.kind = 'group'
        record.kindSource = confirmed.kindSource
        kind = 'group'
        if (!config.autoReplyGroups) {
          record.reason = 'group'
          await logLine('info', `新消息 ${detail}（preflight 确认是群聊，仅记录）`)
          return settleRecordedChat(state, title, record)
        }
      } else if (confirmed.kind === 'private') {
        record.kind = 'private'
        record.kindSource = confirmed.kindSource
        kind = 'private'
      } else {
        record.reason = 'unconfirmed'
        await logLine('warn', `${title} 的 preflight 拿不准是否群聊，放弃自动回复`)
        return settleRecordedChat(state, title, record)
      }
    }

    const read = await bridgeRead(title)
    if (!read.ok) {
      record.action = 'failed'
      record.reason = `read-failed: ${read.error}`
      await logLine('warn', `读取 ${title} 的消息失败：${read.error}`)
      return record
    }
    const incoming = pickIncomingText(read.messages)
    if (incoming === '') {
      record.reason = 'no-incoming'
      await logLine('info', `新消息 ${detail}（没读到对方的新内容，仅记录）`)
      return settleRecordedChat(state, title, record, { textKnown: true })
    }
    record.message = incoming
    if (URGENT_PATTERN.test(incoming)) record.urgent = true

    // 同名会话的同一条文本已经回过：不再重复回复。
    // 但如果列表里的未读条数比当时更多，说明对方又补了几条（哪怕字一样），
    // 那就是新消息，不能按「回过了」处理。
    const previous = state.handled[title]
    const nowCount = unreadCountOf(record.previewText ?? '')
    const prevCount = previous !== undefined && Number.isFinite(Number(previous.count))
      ? Number(previous.count)
      : 1
    if (previous !== undefined
      && stripMergedNotice(previous.text) === stripMergedNotice(incoming)
      && nowCount <= prevCount) {
      record.action = 'skipped'
      record.reason = 'handled'
      await logLine('info', `新消息 ${detail}（同一条内容已回复过，跳过）`)
      return settleRecordedChat(state, title, record, { textKnown: true })
    }

    // 已经回过这个人，对方只是补一句「收到」或表情：只记录，不再回。
    if (repliedCount >= 1 && isBareAcknowledgement(incoming)) {
      record.action = 'skipped'
      record.reason = 'ack-only'
      await logLine('info', `新消息 ${detail}（对方只是确认/表情，不再回复）`)
      return settleRecordedChat(state, title, record, { textKnown: true })
    }

    // 同一文本最多重试 MAX_SEND_RETRIES 次，避免桥一直失败时无限重发。
    const failure = state.sendFailures[title]
    if (failure !== undefined
      && stripMergedNotice(failure.text) === stripMergedNotice(incoming)
      && failure.attempts > MAX_SEND_RETRIES) {
      record.action = 'skipped'
      record.reason = 'retry-exhausted'
      await logLine('warn', `回复 ${title} 已失败 ${failure.attempts} 次，放弃重试（原文：${shorten(incoming)}）`)
      return settleRecordedChat(state, title, record, { textKnown: true })
    }

    const replyText = repliedCount === 0 ? buildReplyText(state, title) : buildFollowUpText(state)
    const sent = await bridgeSend(title, replyText)
    if (!sent.ok) {
      const attempts = failure !== undefined && stripMergedNotice(failure.text) === stripMergedNotice(incoming)
        ? failure.attempts + 1
        : 1
      state.sendFailures[title] = { text: incoming, attempts }
      record.action = 'failed'
      record.reason = sent.error
      await logLine('warn', `回复 ${title} 失败（第 ${attempts} 次）：${sent.error}（原文：${shorten(incoming)}）`)
      return record
    }
    record.action = 'replied'
    record.reply = replyText
    if (!sent.verified) record.reason = 'unverified'
    const at = nowDate().toISOString()
    state.handled[title] = { text: incoming, at, count: unreadCountOf(record.previewText ?? '') }
    delete state.pendingFollowUp[title]
    trimHandled(state.handled)
    delete state.sendFailures[title]
    state.lastReplies[title] = { at, text: replyText }
    state.replyCounts[title] = repliedCount + 1
    await logLine('info', `已回复 ${title}：${replyText}`)
    // 用户要的是"回来还能看见谁找过我"，所以回复完也把红点还回去。
    // 顺序：会话还开着时先标未读（这时行在列表顶上，右键一定找得到），再收起会话。
    // 自己点出来的未读不会再触发回复：下一轮同预览同时间会命中 seenRows。
    const markBack = await bridgeMarkUnread(title, { allowFoldToggle: true })
    record.markedUnread = markBack.ok === true
    if (markBack.ok) {
      state.selfUnread[title] = { key: seenKeyOf(replyText), at: Date.now() }
    }
    if (!markBack.ok) {
      await logLine('warn', `mark-unread-failed：${title} 回复后没能标回未读（${markBack.error}）`)
    }
    // 收起会话是尽力而为，失败只记日志（见 collapseChat）。
    record.deselected = await collapseChat(title)
    return record
  }

  /** 更新 lastScanAt / nextScanAt 并落盘（同时持久化 lastReplies）。 */
  async function scheduleNextScan(state) {
    state.lastScanAt = new Date().toISOString()
    state.nextScanAt = new Date(Date.now() + intervalMinutesOf(state) * 60_000).toISOString()
    await saveState(state)
  }

  /**
   * 建立基线：把当下所有带红点的会话名记下来，这些老未读不算新来信。
   * 只记录状态，不产生任何回复或 inbox 记录。
   */
  async function captureBaseline(state) {
    const watched = await bridgeWatch()
    if (!watched.ok) {
      await logLine('error', `建立基线失败：${watched.error}`)
      return { ok: false, error: watched.error, sessions: 0, names: [] }
    }
    const names = unreadNames(watched.rows)
    state.baselineUnread = unreadBaseline(watched.rows)
    // 基线也记下「当前打开着的会话」：下一轮只要 preview/time 变了就是新消息。
    state.lastSelectedRow = watched.selectedRow === null
      ? null
      : { name: watched.selectedRow.name, preview: watched.selectedRow.preview, time: watched.selectedRow.time }
    state.handled = {}
    state.replyCounts = {}
    state.seenRows = {}
    state.baselineAt = new Date().toISOString()
    state.nextScanAt = new Date(Date.now() + intervalMinutesOf(state) * 60_000).toISOString()
    await saveState(state)
    await logLine(
      'info',
      `基线已建立：视口 ${watched.rows.length} 行，其中老未读 ${names.length} 个`
        + `${names.length === 0 ? '' : `（${names.join('、')}）`}`,
    )
    return { ok: true, sessions: watched.rows.length, names }
  }

  /**
   * 主动摘要：紧急消息立即单独播报；普通消息先攒进 pendingDigest，
   * 距上一条播报满 digestEveryMinutes 才合并成一条发出去。
   * 返回本轮真正播报的文本，方便记日志（通知失败不影响扫描）。
   */
  async function publishDigest(state, records) {
    const fresh = records.filter((record) => record.action === 'replied' || record.action === 'recorded')
    if (fresh.length === 0) return []
    const now = nowDate()
    const at = now.toISOString()
    const announced = []
    // inbox 记录用 message，摘要条目用 text；这里统一成摘要需要的形状。
    const entryOf = (record) => ({ at, session: record.session, text: record.message, action: record.action })

    for (const record of fresh.filter((item) => item.urgent === true)) {
      const text = buildDigestText([entryOf(record)], at, true)
      notify('微信值守', text)
      await attempt('写摘要', () => appendDigest([text]))
      state.lastDigest = { at, text }
      announced.push(text)
    }

    for (const record of fresh.filter((item) => item.urgent !== true)) {
      state.pendingDigest.push(entryOf(record))
    }
    if (state.pendingDigest.length > PENDING_DIGEST_LIMIT) {
      state.pendingDigest = state.pendingDigest.slice(-PENDING_DIGEST_LIMIT)
    }

    // 上一条播报时间来自 lastDigest；为空说明本轮值守还没播报过，先让用户知道有消息。
    const lastAt = state.lastDigest.at === '' ? NaN : Date.parse(state.lastDigest.at)
    const intervalMs = config.digestEveryMinutes * 60_000
    const due = Number.isNaN(lastAt) || now.getTime() - lastAt >= intervalMs
    if (due && state.pendingDigest.length > 0) {
      const entries = state.pendingDigest
      const text = buildDigestText(entries, at)
      notify('微信值守', text)
      await attempt('写摘要', () => appendDigest([text]))
      state.lastDigest = { at, text }
      state.pendingDigest = []
      announced.push(text)
    }

    return announced
  }

  /** 真正的一次扫描：watch 看视口红点 → 去掉基线里的老未读 → 分类 → 回复/记录 → 写回。 */
  /**
   * 补发：静默窗口里攒下的来信，等距上次回复满 cooldown 分钟、对方也不再发新的，
   * 就主动补一条 follow-up 一次应答，避免"他连发几条、我只回了第一条"。
   */
  async function flushFollowUps(state) {
    const out = []
    if (config.cooldownMinutes <= 0) return out
    if (state.active !== true) return out
    const windowMs = config.cooldownMinutes * 60_000
    const now = nowDate().getTime()
    for (const [title, entry] of Object.entries(state.pendingFollowUp)) {
      if (state.excludes.includes(title) === false && isExcluded(state, title)) { delete state.pendingFollowUp[title]; continue }
      if (isServiceSession(title) === true) { delete state.pendingFollowUp[title]; continue }
      const last = state.lastReplies[title]
      const lastAt = last !== undefined && typeof last.at === 'string' ? Date.parse(last.at) : NaN
      if (Number.isNaN(lastAt)) continue
      if (now - lastAt < windowMs) continue
      const text = buildFollowUpText(state)
      const sent = await bridgeSend(title, text)
      const at = nowDate().toISOString()
      if (sent.ok === true) {
        delete state.pendingFollowUp[title]
        state.lastReplies[title] = { at, text }
        out.push({
          ts: at,
          session: title,
          message: `（静默窗口里补了 ${entry.count} 条）`,
          kind: 'private',
          action: 'replied',
          reply: text,
          urgent: false,
          reason: 'follow-up-catchup',
          catchUpCount: entry.count,
        })
        await logLine('info', `补发回复 ${title}：${text}`)
      } else {
        out.push({
          ts: at,
          session: title,
          message: `（静默窗口里补了 ${entry.count} 条）`,
          kind: 'private',
          action: 'failed',
          reply: '',
          reason: `follow-up-send-failed: ${sent.error}`,
        })
        await logLine('warn', `补发回复 ${title} 失败：${sent.error}`)
      }
    }
    return out
  }

  async function scanOnce(state, trigger, options = {}) {
    const scannedAt = new Date().toISOString()
    const full = options.full === true
    const source = full ? 'full' : 'watch'
    const listed = full ? await bridgeProbe() : await bridgeWatch()
    if (!listed.ok) {
      await logLine('error', `扫描失败（${trigger}）：${listed.error}`)
      // 仍然推进时间，避免桥一直不可用时每个心跳都重试。
      await attempt('更新扫描时间', () => scheduleNextScan(state))
      return {
        ...emptyScan(trigger),
        source,
        scannedAt,
        error: listed.error,
        summary: `扫描失败：${listed.error}`,
      }
    }

    // 只有「不在基线里」且带红点的行才算新来信。
    // 基线按 {名字, 预览} 记：同名会话只要预览变了就说明又来了新消息，照常处理。
    const baseline = baselineMap(state.baselineUnread)
    const candidates = listed.rows.filter((row) => {
      if (row.unread !== true) return false
      if (row.foldBar === true) return false
      const name = row.title !== '' ? row.title : row.name
      if (name === '') return false
      if (baseline.has(name)) {
        const basePreview = baseline.get(name)
        // null = 旧格式基线，只能按名字排除；否则预览没变就是同一条老未读。
        if (basePreview === null) return false
        const preview = typeof row.preview === 'string' ? row.preview : ''
        if (basePreview === preview) return false
      }
      return true
    })

    const records = []
    let silent = 0
    for (const row of candidates) {
      const record = await evaluateWatchRow(row, state)
      if (record.skip === true) { silent += 1; continue }
      if (record.duplicate !== true) {
        // 发送失败要留给下一轮重试，所以不能把它记成「已见过」。
        if (record.action === 'failed') delete state.seenRows[record.session]
        records.push(record)
      }
    }

    // 兜底：微信会把「当前打开着的会话」的新消息立刻标已读，永远不长红点，
    // 红点检测看不到这个人。所以再看一眼 selectedRow：同一个人 preview/time 变了，
    // 就当有新消息，走和红点候选一样的流程（preflight 判 kind → 只回私聊 → read → 回复）。
    const selected = listed.selectedRow ?? null
    const previousSelected = state.lastSelectedRow
    const selectedChanged = selected !== null
      && selected.unread !== true
      && previousSelected !== null
      && previousSelected.name === selected.name
      && (previousSelected.preview !== selected.preview || previousSelected.time !== selected.time)
    // 不管有没有变化都先记下最新快照；null 表示当前没有打开任何会话。
    state.lastSelectedRow = selected === null
      ? null
      : { name: selected.name, preview: selected.preview, time: selected.time }

    const candidateNames = new Set(candidates.map((row) => (row.title !== '' ? row.title : row.name)))
    if (selectedChanged && !candidateNames.has(selected.name)) {
      const openRow = normalizeWatchRow({
        name: selected.name,
        title: selected.name,
        preview: selected.preview,
        time: selected.time,
        selected: true,
        unread: false,
      })
      const openRecord = await evaluateWatchRow(openRow, state, { openChat: true, reason: 'open-chat' })
      if (openRecord.skip === true) silent += 1
      else if (openRecord.duplicate !== true) records.push(openRecord)
    }

    // 静默窗口到点的补发，和本轮其它记录一起落盘。
    for (const extra of await flushFollowUps(state)) records.push(extra)

    // 先写状态（含 handled），再写 inbox：宁可少一条日志，也不要重复回复。
    await attempt('保存状态', () => scheduleNextScan(state))
    await attempt('写 inbox', () => appendRecords(records))

    const replied = records.filter((record) => record.action === 'replied').length
    const recorded = records.filter((record) => record.action === 'recorded').length
    const skipped = records.filter((record) => record.action === 'skipped').length
    const failed = records.filter((record) => record.action === 'failed').length
    const details = records.map((record) => ({
      session: record.session,
      message: record.message,
      kind: record.kind,
      action: record.action,
      urgent: record.urgent,
      ...record.reason === undefined ? {} : { reason: record.reason },
    }))

    // 有新记录时写一行短摘要；主动摘要紧急的马上发，普通的按 digestEveryMinutes 合并。
    if (records.length > 0) {
      const digestLine = `${clockText(scannedAt)} ${state.active === true ? '值守中' : '未值守'} · ${records.length} 条新消息`
        + `（${replied} 条已自动回复，${recorded} 条仅记录`
        + `${skipped > 0 ? `，${skipped} 条跳过` : ''}${failed > 0 ? `，${failed} 条失败` : ''}）`
      await attempt('写摘要', () => appendDigest([digestLine]))
      await attempt('主动摘要', () => publishDigest(state, records))
      // publishDigest 会改 lastDigest / pendingDigest，单独再落一次盘。
      await attempt('保存状态', () => saveState(state))
    }

    const triggerLabel = trigger === 'timer' ? '例行' : '手动'
    const lines = []
    lines.push(`本次扫描（${triggerLabel}，${clockText(scannedAt)}）完成：会话 ${listed.rows.length} 个。`)
    if (records.length === 0) {
      lines.push('没有发现新消息。')
    } else {
      lines.push(`新消息 ${records.length} 条：已回复 ${replied}，仅记录 ${recorded}，跳过 ${skipped}，失败 ${failed}。`)
    }
    if (silent > 0) lines.push(`另有 ${silent} 条服务号/免打扰消息已静默忽略（不记录）。`)
    if (state.active !== true) lines.push('当前不在值守状态：只记录，不发送。')

    return {
      ok: true,
      trigger,
      source,
      scannedAt,
      sessions: listed.rows.length,
      newMessages: records.length,
      replied,
      recorded,
      skipped,
      failed,
      silent,
      details,
      summary: lines.join('\n'),
    }
  }

  /** 扫描入口：处理基线、并发保护。 */
  async function runScan(trigger, options = {}) {
    if (runtime.running) {
      return {
        ...emptyScan(trigger),
        summary: '已经有一次扫描在进行中，本次跳过。',
      }
    }
    runtime.running = true
    try {
      const state = await currentState()
      if (trigger === 'baseline') {
        const captured = await captureBaseline(state)
        return captured.ok
          ? {
            ...emptyScan(trigger),
            ok: true,
            source: 'watch',
            sessions: captured.sessions,
            summary: `已建立基线：视口 ${captured.sessions} 行，其中 ${captured.names.length} 个老未读不算新来信（只记录状态，不回复历史消息）。`,
          }
          : {
            ...emptyScan(trigger),
            ok: false,
            source: 'watch',
            error: captured.error,
            summary: `建立基线失败：${captured.error}`,
          }
      }
      // 还没有基线（首次扫描、stop 之后，或 start 时微信不可用）：本次只补基线，不做判定。
      if (state.baselineAt === '') {
        const captured = await captureBaseline(state)
        return captured.ok
          ? {
            ...emptyScan(trigger),
            ok: true,
            source: 'watch',
            sessions: captured.sessions,
            summary: `首次扫描只建立基线（视口 ${captured.sessions} 行，其中 ${captured.names.length} 个老未读），本次不回复；下一次扫描开始处理新消息。`,
          }
          : {
            ...emptyScan(trigger),
            ok: false,
            source: 'watch',
            error: captured.error,
            summary: `首次扫描需要建立基线，但失败了：${captured.error}`,
          }
      }
      return await scanOnce(state, trigger, options)
    } finally {
      runtime.running = false
    }
  }

  /** 结束值守并生成汇总；返回工具输出需要的字段。 */
  async function endAway(state, reason) {
    const endedAt = new Date().toISOString()
    state.active = false
    state.lastEndedAt = endedAt
    state.endedReason = reason
    state.nextScanAt = ''
    // 停止时清掉基线：下一轮值守要重新建立，不能把上一轮的老未读带过去。
    state.baselineUnread = []
    state.baselineAt = ''
    state.sendFailures = {}
    await attempt('保存状态', () => saveState(state))

    const records = await attempt('读取 inbox', () => readInboxRecords()) ?? []
    const summary = buildStopSummary(records, state.startedAt, endedAt)
    // 未播报的摘要直接丢弃：上面按会话列出的明细已经覆盖了这段值守里的全部记录，
    // 再补一段「未播报摘要」只是把同样的内容换个说法重复一遍。
    state.pendingDigest = []
    await attempt('保存状态', () => saveState(state))
    await attempt('写摘要', () => appendDigest(summary.digestLines))
    notify('微信值守结束', summary.digestLines[0] ?? '')
    await attempt('写 inbox', () => appendRecords([{
      ts: endedAt,
      session: '(system)',
      message: reason === 'deadline' ? '值守结束（已到截止时间）' : '值守结束（手动停止）',
      kind: 'unknown',
      action: 'system',
      reply: '',
      urgent: false,
      quiet: false,
    }]))
    await logLine('info', `值守结束：${reason}`)
    return {
      ok: true,
      active: false,
      activity: state.activity,
      until: state.until,
      startedAt: state.startedAt,
      nextScanAt: '',
      remainingMinutes: -1,
      recorded: summary.stats.total,
      summary: summary.text,
    }
  }

  /** start：写状态、刷基线、返回确认文本。 */
  async function startAway(input) {
    const state = await currentState()
    const activity = text(input.activity, state.activity !== '' ? state.activity : '在忙')
    const requestedUntil = typeof input.until === 'string' ? input.until.trim() : ''
    const until = parseUntil(requestedUntil)
    const excludes = Array.isArray(input.excludes) ? normalizeExcludes(input.excludes) : config.excludes
    const interval = positive(input.intervalMinutes, config.scanIntervalMinutes)
    const wasActive = state.active === true

    if (!wasActive) {
      state.startedAt = new Date().toISOString()
      state.lastEndedAt = ''
      state.endedReason = ''
      // 新一轮值守不继承上一轮的去重/重试计数，基线和摘要也重新开始。
      state.handled = {}
      state.sendFailures = {}
      state.baselineUnread = []
      // 新基线还没建立，旧值守的「打开着的会话」快照已经不可信。
      state.lastSelectedRow = null
      state.lastDigest = { at: '', text: '' }
      state.pendingDigest = []
    }
    state.active = true
    state.activity = activity
    state.until = until
    state.untilMode = input.mode === 'duration' ? 'duration' : 'clock'
    state.untilText = typeof input.untilText === 'string' ? input.untilText.trim() : ''
    state.deadlineNotified = false
    state.autoEndOnDeadline = input.autoEndOnDeadline !== false
    state.excludes = excludes
    state.intervalMinutes = interval
    state.baselineAt = ''
    state.nextScanAt = new Date(Date.now() + interval * 60_000).toISOString()
    await saveState(state)
    await logLine('info', `开始值守：activity=${activity} until=${until === '' ? '(无)' : until} excludes=${excludes.length}`)

    // 先把微信切回闲置态（没有打开的会话），否则"当前打开的会话"会把新消息吃掉。
    const idle = await ensureIdleUi()
    if (idle.ok !== true) {
      await logLine('warn', `未能把微信切到闲置状态：${idle.error}`)
    } else if (idle.changed === true) {
      await logLine('info', '已收起打开的会话：值守从闲置态开始')
    }

    const baseline = await runScan('baseline')

    const lines = []
    lines.push(wasActive ? '值守中（已更新参数）。' : '已开始值守。')
    lines.push(`活动：${activity}`)
    lines.push(until === ''
      ? '截止：未设置（不会自动结束，需要手动 stop）'
      : `截止：${clockText(until)}（超过 ${config.deadlineGraceMinutes} 分钟后自动结束）`)
    lines.push(`扫描间隔：${formatMinutes(interval)}；下次扫描约 ${clockText(state.nextScanAt)}`)
    if (excludes.length > 0) lines.push(`排除：${excludes.join('、')}`)
    lines.push(config.autoReplyGroups
      ? '群聊：允许自动回复（autoReplyGroups=true）'
      : '群聊：一律只记录、不自动回复（autoReplyGroups=false）')
    lines.push('扫描发现新消息时会写入 digest.md 并弹一条系统通知；stop 时给出完整清单。')
    if (requestedUntil !== '' && until === '') {
      lines.push(`注意：until "${requestedUntil}" 无法识别，已按“未设置截止”处理。`)
    }
    if (baseline.ok) {
      const oldUnread = state.baselineUnread.length
      lines.push(`基线：已记录 ${baseline.sessions} 行的当前状态，其中 ${oldUnread} 个老未读不算新来信；开始值守前已收到的消息不会被自动回复。`)
    } else {
      lines.push(`注意：建立基线失败（${baseline.error}）。下一次扫描会先尝试补基线，期间不会回复。`)
    }

    return {
      ok: true,
      active: true,
      activity,
      until,
      startedAt: state.startedAt,
      nextScanAt: state.nextScanAt,
      remainingMinutes: state.until === '' ? -1 : Math.max(0, Math.ceil((Date.parse(state.until) - Date.now()) / 60_000)),
      recorded: 0,
      summary: lines.join('\n'),
    }
  }

  /** status：是否值守、剩余时间、下次扫描、已记录条数。 */
  async function statusAway() {
    const state = await currentState()
    const active = state.active === true
    const untilMs = state.until === '' ? NaN : Date.parse(state.until)
    const remainingMinutes = Number.isFinite(untilMs) ? Math.max(0, Math.ceil((untilMs - Date.now()) / 60_000)) : -1

    let recorded = 0
    if (active && state.startedAt !== '') {
      const records = await attempt('读取 inbox', () => readInboxRecords()) ?? []
      const startedAt = Date.parse(state.startedAt)
      recorded = records.filter((record) => {
        if (record.action === 'system') return false
        const ts = Date.parse(record.ts)
        return Number.isFinite(ts) && (Number.isNaN(startedAt) || ts >= startedAt)
      }).length
    }

    const lines = []
    if (active) {
      lines.push(`值守中：${state.activity === '' ? '（未填写活动）' : state.activity}`)
      const startedAt = Date.parse(state.startedAt)
      const elapsed = Number.isNaN(startedAt) ? '' : `（已 ${formatDuration(Date.now() - startedAt)}）`
      lines.push(`开始：${clockText(state.startedAt) || '未知'}${elapsed}`)
      lines.push(state.until === ''
        ? '截止：未设置'
        : `截止：${clockText(state.until)}（剩余 ${formatMinutes(remainingMinutes)}；超过 ${config.deadlineGraceMinutes} 分钟后自动结束）`)
      lines.push(`下次扫描：${clockText(state.nextScanAt) || '待定'}（每 ${formatMinutes(intervalMinutesOf(state))} 一次）`)
      lines.push(`已记录：${recorded} 条`)
      const excludes = effectiveExcludes(state)
      if (excludes.length > 0) lines.push(`排除：${excludes.join('、')}`)
    } else {
      lines.push('当前不在值守状态。')
      if (state.lastEndedAt !== '') lines.push(`上次值守结束于 ${clockText(state.lastEndedAt)}。`)
    }
    if (state.lastDigest.text !== '') lines.push(`最近一条摘要：${state.lastDigest.text}`)

    return {
      ok: true,
      active,
      activity: state.activity,
      ownerName: text(state.ownerName, text(config.ownerName, '')),
      until: state.until,
      startedAt: state.startedAt,
      nextScanAt: state.nextScanAt,
      remainingMinutes,
      recorded,
      summary: lines.join('\n'),
    }
  }

  /** digest：返回最近的摘要文本（digest.md 尾部）。 */
  async function digestAway() {
    const state = await currentState()
    const stored = await attempt('读取摘要', () => readFile(digestPath, 'utf8'))
    const lines = typeof stored === 'string' ? stored.split(/\r?\n/u) : []
    const tail = lines.slice(-60).join('\n').trim()

    const active = state.active === true
    const untilMs = state.until === '' ? NaN : Date.parse(state.until)
    const remainingMinutes = Number.isFinite(untilMs) ? Math.max(0, Math.ceil((untilMs - Date.now()) / 60_000)) : -1
    const startedAt = Date.parse(state.startedAt)
    const records = active && state.startedAt !== '' ? await attempt('读取 inbox', () => readInboxRecords()) ?? [] : []
    const recorded = records.filter((record) => {
      if (record.action === 'system') return false
      const ts = Date.parse(record.ts)
      return Number.isFinite(ts) && (Number.isNaN(startedAt) || ts >= startedAt)
    }).length

    const summary = tail === ''
      ? '还没有摘要记录：值守期间没有产生新消息。'
      : `最近摘要（${digestPath}）：\n${tail}`

    return {
      ok: true,
      active,
      activity: state.activity,
      until: state.until,
      startedAt: state.startedAt,
      nextScanAt: state.nextScanAt,
      remainingMinutes,
      recorded,
      summary,
    }
  }

  /** wechat_away 的 action 分发。 */
  async function handleAway(input) {
    const action = typeof input.action === 'string' ? input.action : ''
    if (action === 'start') return startAway(input)
    if (action === 'stop') {
      const state = await currentState()
      if (state.active !== true) {
        return {
          ok: true,
          active: false,
          activity: '',
          until: '',
          startedAt: state.startedAt,
          nextScanAt: '',
          remainingMinutes: -1,
          recorded: 0,
          summary: '当前不在值守状态，无需停止。',
        }
      }
      const ended = await endAway(state, 'manual')
      // 手动 stop 也把汇总落盘，手机/桌面向导的「看上次汇总」才能看到最新一份。
      await publishSummary(state, ended.summary)
      return ended
    }
    if (action === 'status') return statusAway()
    if (action === 'digest') return digestAway()
    return {
      ok: false,
      active: false,
      activity: '',
      until: '',
      startedAt: '',
      nextScanAt: '',
      remainingMinutes: -1,
      recorded: 0,
      summary: `未知 action：${action === '' ? '(空)' : action}，只支持 start / stop / status / digest。`,
    }
  }

  /** 失败时的 wechat_away 输出。 */
  function awayFailure(message) {
    return {
      ok: false,
      active: false,
      activity: '',
      until: '',
      startedAt: '',
      nextScanAt: '',
      remainingMinutes: -1,
      recorded: 0,
      summary: `wechat_away 执行失败：${message}`,
    }
  }

  /** wechat_inbox：读 inbox.jsonl 并按条件过滤。 */
  async function queryInbox(input) {
    const limitRaw = Number.isFinite(input.limit) ? Math.floor(input.limit) : 20
    const limit = Math.min(500, Math.max(1, limitRaw))
    const onlyUnreplied = input.onlyUnreplied === true
    const sinceRaw = typeof input.since === 'string' ? input.since.trim() : ''
    const since = sinceRaw === '' ? NaN : Date.parse(sinceRaw)

    if (sinceRaw !== '' && Number.isNaN(since)) {
      return {
        ok: false,
        total: 0,
        returned: 0,
        records: [],
        error: `since "${sinceRaw}" 不是合法时间（用 ISO 格式，例如 2026-11-10T09:00:00+08:00）。`,
      }
    }

    let records
    try {
      records = await readInboxRecords()
    } catch (error) {
      await logLine('error', `读取 inbox 失败：${describeError(error)}`)
      return { ok: false, total: 0, returned: 0, records: [], error: `读取 inbox.jsonl 失败：${describeError(error)}` }
    }

    const filtered = records
      .filter((record) => record.action !== 'system')
      .filter((record) => Number.isNaN(since) || Date.parse(record.ts) >= since)
      .filter((record) => !onlyUnreplied || record.action !== 'replied')
      // 新的在前，方便“最近谁找过我”。
      .sort((left, right) => Date.parse(right.ts) - Date.parse(left.ts))

    return {
      ok: true,
      total: filtered.length,
      returned: Math.min(limit, filtered.length),
      records: filtered.slice(0, limit),
    }
  }

  /** 写心跳文件，让桌面快捷方式知道 Host 还在。 */
  async function heartbeatTick() {
    const now = Date.now()
    if (now - runtime.lastHeartbeatAt < HEARTBEAT_INTERVAL_MS) return
    runtime.lastHeartbeatAt = now
    try {
      await mkdir(config.stateDir, { recursive: true })
      await writeFile(heartbeatPath, new Date(now).toISOString(), 'utf8')
    } catch {
      // 心跳写不进去不影响值守本身。
    }
  }

  /** 把结束汇总写进 last-summary.md（桌面向导与手机页读）。不再推送到对话，避免每轮值守结束多花一次模型调用。 */
  async function publishSummary(state, summary) {
    try {
      await writeFile(summaryPath, typeof summary === 'string' ? summary : '', 'utf8')
    } catch (error) {
      await logLine('warn', `汇总写入失败：${describeError(error)}`)
    }
    await logLine('info', '结束汇总已写入 last-summary.md（不推送到对话）')
  }

  /** 执行一条桌面快捷方式写下的请求。 */
  async function applyRequest(state, payload) {
    const action = typeof payload.action === 'string' ? payload.action : ''
    if (action === 'start') {
      const activity = typeof payload.activity === 'string' ? payload.activity : ''
      let untilAt = typeof payload.untilAt === 'string' ? payload.untilAt : ''
      const untilText = typeof payload.untilText === 'string' ? payload.untilText : ''
      const mode = payload.mode === 'duration' ? 'duration' : 'clock'
      const durationMinutes = Number(payload.durationMinutes)
      if (untilAt === '' && Number.isFinite(durationMinutes) && durationMinutes > 0) {
        untilAt = new Date(Date.now() + durationMinutes * 60_000).toISOString()
      }
      const result = await startAway({
        activity,
        until: untilAt !== '' ? untilAt : untilText,
        mode,
        untilText,
        autoEndOnDeadline: false,
      })
      await logLine('info', `快捷方式开始值守：activity=${activity} mode=${mode} until=${untilAt !== '' ? untilAt : untilText} 结果=${result.active === true ? 'active' : 'inactive'}`)
      return
    }
    if (action === 'set-owner') {
      const ownerName = text(payload.ownerName, '').slice(0, 24)
      if (ownerName === '') {
        await logLine('warn', '设置本人称呼失败：内容为空')
        return
      }
      state.ownerName = ownerName
      await saveState(state)
      await logLine('info', `已记住本人称呼：${ownerName}`)
      return
    }
    if (action === 'stop') {
      const result = await endAway(state, 'shortcut')
      await publishSummary(state, result.summary)
      return
    }
    await logLine('warn', `未知的快捷方式请求：${action === '' ? '(空)' : action}`)
  }

  /** 读出 requests/ 里所有请求文件并逐个执行；处理完就删。 */
  async function drainRequests(state) {
    let names = []
    try {
      names = await readdir(requestsDir)
    } catch {
      return
    }
    const pending = names.filter((name) => /^req-\d+\.json$/u.test(name)).sort()
    for (const name of pending) {
      const file = join(requestsDir, name)
      let payload = null
      try {
        payload = JSON.parse(await readFile(file, 'utf8'))
      } catch {
        payload = null
      }
      try {
        await rm(file, { force: true })
      } catch {
        // 删不掉就下一轮再试。
      }
      if (payload === null || typeof payload !== 'object') continue
      try {
        await applyRequest(state, payload)
      } catch (error) {
        await logLine('warn', `快捷方式请求失败：${describeError(error)}`)
      }
    }
  }


  return {
    config,

    /** 预热：建目录、写一行启动日志。 */
    async ready() {
      try {
        await mkdir(config.stateDir, { recursive: true })
        await logLine('info', `插件已加载：enabled=${config.enabled}，扫描间隔 ${formatMinutes(config.scanIntervalMinutes)}`
          + `，通知通道 ${notificationMechanism()}，摘要间隔 ${config.digestEveryMinutes} 分钟`)
      } catch {
        // 目录建不出来时保持静默，后续操作会各自报错。
      }
    },

    /** 定时器回调：到期自动扫描，超过 until 宽限期自动结束，任何异常都不外抛。 */
    async tick() {
      if (!config.enabled) return
      try {
        await serialize(async () => {
          const state = await currentState()
          await heartbeatTick()
          await drainRequests(state)
          if (state.active !== true) return
          const now = Date.now()
          const untilMs = state.until === '' ? NaN : Date.parse(state.until)
          if (Number.isFinite(untilMs) && now > untilMs) {
            if (state.autoEndOnDeadline === false) {
              // 快捷方式启动的值守：到点只提醒，不自动停。
              if (state.deadlineNotified !== true) {
                state.deadlineNotified = true
                await saveState(state)
                notify('值守到点了', `原定 ${clockText(state.until)} 回来（${state.activity === '' ? '在忙' : state.activity}）。记得回来说一声，我好结束值守。`)
              }
            } else if (now > untilMs + config.deadlineGraceMinutes * 60_000) {
              await endAway(state, 'deadline')
              return
            }
          }
          const next = state.nextScanAt === '' ? NaN : Date.parse(state.nextScanAt)
          if (Number.isFinite(next) && now < next) return
          await runScan('timer')
        })
      } catch (error) {
        await logLine('error', `定时器异常：${describeError(error)}`)
      }
    },

    tools: {
      /** 工具 1：wechat_away。 */
      away: {
        name: 'wechat_away',
        description:
          'Start, stop, inspect, or summarize WeChat away mode. While away mode is active the plugin scans WeChat '
          + 'Desktop every N minutes, auto-replies to new one-to-one chats with an "AI assistant" notice that '
          + 'mentions the current activity and when the owner will be back, and records every incoming message in a '
          + 'queryable inbox log. Group chats are never auto-replied by default, and ambiguous sessions are treated '
          + 'as groups, so missing a private reply is preferred over posting in a group. Every scan that finds new '
          + 'messages appends a short digest to digest.md; urgent messages also push a one-line summary notification '
          + 'immediately, while ordinary messages are batched into one notification every digestEveryMinutes. Call it '
          + 'with action="start" '
          + 'when the user says they are leaving, stepping away, going to class/an exam/a meeting, or asks you to '
          + 'watch WeChat / auto-reply for them; pass activity (what they are doing, e.g. "在上实验课") and until '
          + '(ISO time or a same-day clock time like "17:15"). Call it with action="stop" when they are back or ask '
          + 'to stop replying; the result is a full summary of who wrote, when, what they said, whether they got a '
          + 'reply, and whether it looked urgent. Use action="status" to check whether away mode is on, how much '
          + 'time is left, when the next scan happens, and how many messages were logged. Use action="digest" when '
          + 'the user asks who messaged them while they were away or wants the latest digest text.',
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['action'],
          properties: {
            action: {
              type: 'string',
              enum: ['start', 'stop', 'status', 'digest'],
              description: 'start = begin watching WeChat; stop = end the session and get a full summary; status = report current state; digest = return the latest digest text.',
            },
            activity: {
              type: 'string',
              description: 'What the owner is doing, used verbatim in the auto-reply, e.g. "在上实验课" or "在开会". Defaults to "在忙".',
            },
            until: {
              type: 'string',
              description: 'When the owner expects to be back: a full ISO timestamp, or a same-day clock time such as "17:15". After this time plus the grace period away mode ends automatically. Omit for no deadline.',
            },
            excludes: {
              type: 'array',
              items: { type: 'string' },
              description: 'Session names that must only be logged, never auto-replied (substring match). Overrides the plugin config for this session.',
            },
            intervalMinutes: {
              type: 'number',
              description: 'Override the scan interval in minutes for this session.',
            },
          },
        },
        output: {
          schema: {
            type: 'object',
            additionalProperties: false,
            required: ['ok', 'active', 'activity', 'until', 'summary'],
            properties: {
              ok: { type: 'boolean', description: 'Whether the action succeeded.' },
              active: { type: 'boolean', description: 'Whether away mode is active after this call.' },
              activity: { type: 'string', description: 'The activity text currently used in auto-replies.' },
              ownerName: { type: 'string', description: 'Owner name used in replies; empty means it was never set.' },
              until: { type: 'string', description: 'ISO deadline, or an empty string when there is none.' },
              startedAt: { type: 'string', description: 'ISO time this away session started.' },
              nextScanAt: { type: 'string', description: 'ISO time of the next scheduled scan.' },
              remainingMinutes: { type: 'number', description: 'Minutes until the deadline; -1 when no deadline is set.' },
              recorded: { type: 'number', description: 'Messages logged during this away session.' },
              summary: { type: 'string', description: 'Human-readable confirmation, status report, or stop summary.' },
            },
          },
          render(_args, value) {
            return blocks(value.summary)
          },
        },
        isConcurrencySafe: () => false,
        async execute(args) {
          const input = args !== null && typeof args === 'object' ? args : {}
          // 记下当前会话，结束值守时把汇总推回这个对话。
          try {
            const initiator = deps.ctx === undefined ? null : deps.ctx.get('agents').currentInitiator()
            if (initiator !== undefined && initiator !== null) runtime.lastSessionId = String(initiator.id)
          } catch {
            // 拿不到会话身份不影响工具本身。
          }
          try {
            return await serialize(() => handleAway(input))
          } catch (error) {
            await logLine('error', `wechat_away 执行失败：${describeError(error)}`)
            return awayFailure(describeError(error))
          }
        },
      },

      /** 工具 2：wechat_inbox。 */
      inbox: {
        name: 'wechat_inbox',
        description:
          'Query the WeChat away-mode inbox: every incoming message the plugin saw, with its session, text, what '
          + 'the plugin did (replied / recorded / skipped / failed), the reply text, and whether it looked urgent. '
          + 'Call it when the user asks who messaged them while they were away, what they missed, whether anything '
          + 'was urgent, or whether the AI already replied. Defaults to the 20 newest records.',
        parameters: {
          type: 'object',
          additionalProperties: false,
          properties: {
            since: {
              type: 'string',
              description: 'Only return records at or after this ISO timestamp, e.g. "2026-11-10T09:00:00+08:00".',
            },
            limit: {
              type: 'number',
              description: 'Maximum number of records to return (1-500). Defaults to 20.',
            },
            onlyUnreplied: {
              type: 'boolean',
              description: 'When true, hide records the plugin already auto-replied to.',
            },
          },
        },
        output: {
          schema: {
            type: 'object',
            additionalProperties: false,
            required: ['ok', 'total', 'records'],
            properties: {
              ok: { type: 'boolean' },
              total: { type: 'number', description: 'How many records matched the filters (before the limit).' },
              returned: { type: 'number', description: 'How many records are in this response.' },
              error: { type: 'string', description: 'Set when the query failed.' },
              records: {
                type: 'array',
                items: {
                  type: 'object',
                  additionalProperties: false,
                  required: ['ts', 'session', 'message', 'kind', 'action', 'reply', 'urgent'],
                  properties: {
                    ts: { type: 'string', description: 'ISO time the message was detected.' },
                    session: { type: 'string', description: 'WeChat session title.' },
                    message: { type: 'string', description: 'Message preview as shown in the session list.' },
                    kind: {
                      type: 'string',
                      enum: ['private', 'group', 'unknown'],
                      description: 'private = confirmed one-to-one; group = looks like or confirmed as a group; unknown = could not confirm.',
                    },
                    action: {
                      type: 'string',
                      description: 'replied | recorded | skipped | failed; action=system records are hidden.',
                    },
                    reply: { type: 'string', description: 'Text sent, when action is replied.' },
                    urgent: { type: 'boolean', description: 'Whether the preview matched the urgent keywords.' },
                    quiet: { type: 'boolean', description: 'Whether the message arrived inside quiet hours.' },
                    reason: {
                      type: 'string',
                      description: 'Why the plugin did not send: excluded | denied | group | quiet | cooldown | self-echo | inactive | unconfirmed | open-chat, or the send error.',
                    },
                    deselected: {
                      type: 'boolean',
                      description: 'After a reply, whether collapsing the chat panel succeeded (false only logs deselect-failed).',
                    },
                    kindSource: {
                      type: 'string',
                      description: 'How kind was decided: title (chat title) or preview (kindHint / message prefixes).',
                    },
                  },
                },
              },
            },
          },
          render(_args, value) {
            const lines = []
            if (!value.ok) {
              lines.push(value.error ?? '查询来信记录失败。')
              return blocks(lines.join('\n'))
            }
            lines.push(`微信来信记录：匹配 ${value.total} 条，显示 ${value.records.length} 条。`)
            if (value.records.length === 0) {
              lines.push('没有符合条件的记录。')
              return blocks(lines.join('\n'))
            }
            for (const record of value.records) {
              const flags = [KIND_LABELS[record.kind] ?? record.kind, ACTION_LABELS[record.action] ?? record.action]
              if (record.urgent) flags.push('急')
              if (record.quiet) flags.push('静默')
              if (record.reason !== undefined) flags.push(record.reason)
              lines.push(`[${clockText(record.ts)}] ${record.session} · ${flags.join(' · ')}`)
              lines.push(`  “${shorten(record.message, 60)}”`)
              if (record.reply !== '') lines.push(`  回复：${record.reply}`)
            }
            return blocks(lines.join('\n'))
          },
        },
        isConcurrencySafe: () => true,
        async execute(args) {
          const input = args !== null && typeof args === 'object' ? args : {}
          // 记下当前会话，结束值守时把汇总推回这个对话。
          try {
            const initiator = deps.ctx === undefined ? null : deps.ctx.get('agents').currentInitiator()
            if (initiator !== undefined && initiator !== null) runtime.lastSessionId = String(initiator.id)
          } catch {
            // 拿不到会话身份不影响工具本身。
          }
          try {
            return await queryInbox(input)
          } catch (error) {
            await logLine('error', `wechat_inbox 执行失败：${describeError(error)}`)
            return {
              ok: false,
              total: 0,
              returned: 0,
              records: [],
              error: `wechat_inbox 执行失败：${describeError(error)}`,
            }
          }
        },
      },

      /** 工具 3：wechat_scan_now。 */
      scanNow: {
        name: 'wechat_scan_now',
        description:
          'Run one WeChat away scan immediately, regardless of the schedule, and return what it found and did. '
          + 'Use it to verify the setup after starting away mode, when the user asks "check WeChat now", or after '
          + 'changing the bridge script. It sends replies only when away mode is active; when inactive it only '
          + 'records what it sees, so it is safe for a dry check. Group chats and sessions it cannot confirm as '
          + 'one-to-one are only recorded, never replied to, unless autoReplyGroups is explicitly enabled.',
        parameters: {
          type: 'object',
          additionalProperties: false,
          properties: {
            full: {
              type: 'boolean',
              description: 'Use the slow full-list probe (-Mode probe -Scroll, about 34 s) instead of the fast viewport watch. Only for manual troubleshooting.',
            },
          },
        },
        output: {
          schema: {
            type: 'object',
            additionalProperties: false,
            required: ['ok', 'scannedAt', 'sessions', 'newMessages', 'replied', 'recorded', 'skipped', 'failed', 'summary'],
            properties: {
              ok: { type: 'boolean', description: 'Whether the scan itself ran (false when the bridge failed).' },
              trigger: { type: 'string', description: 'timer | manual | baseline.' },
              source: { type: 'string', description: 'watch = fast viewport scan; full = slow full-list probe.' },
              scannedAt: { type: 'string', description: 'ISO time of this scan.' },
              sessions: { type: 'number', description: 'How many sessions the WeChat list reported.' },
              newMessages: { type: 'number', description: 'How many fresh messages were processed: unread sessions outside the startup baseline, plus an open chat whose preview/time changed.' },
              replied: { type: 'number', description: 'How many sessions were auto-replied.' },
              recorded: { type: 'number', description: 'How many were logged without a reply.' },
              skipped: { type: 'number', description: 'How many were skipped (cooldown or self-echo).' },
              silent: { type: 'number', description: 'Unread rows ignored on purpose (service accounts and muted chats).' },
              failed: { type: 'number', description: 'How many reply attempts failed.' },
              error: { type: 'string', description: 'Set when the scan could not run.' },
              details: {
                type: 'array',
                items: {
                  type: 'object',
                  additionalProperties: false,
                  required: ['session', 'message', 'kind', 'action', 'urgent'],
                  properties: {
                    session: { type: 'string' },
                    message: { type: 'string' },
                    kind: { type: 'string', enum: ['private', 'group', 'unknown'] },
                    action: { type: 'string' },
                    urgent: { type: 'boolean' },
                    reason: { type: 'string' },
                  },
                },
              },
              summary: { type: 'string', description: 'Human-readable scan report.' },
            },
          },
          render(_args, value) {
            const lines = [value.summary]
            for (const detail of value.details ?? []) {
              const flags = [KIND_LABELS[detail.kind] ?? detail.kind, ACTION_LABELS[detail.action] ?? detail.action]
              if (detail.urgent) flags.push('急')
              if (detail.reason !== undefined) flags.push(detail.reason)
              lines.push(`- ${detail.session} · ${flags.join(' · ')}：“${shorten(detail.message, 40)}”`)
            }
            return blocks(lines.join('\n'))
          },
        },
        isConcurrencySafe: () => false,
        async execute(args) {
          const input = args !== null && typeof args === 'object' ? args : {}
          // 记下当前会话，结束值守时把汇总推回这个对话。
          try {
            const initiator = deps.ctx === undefined ? null : deps.ctx.get('agents').currentInitiator()
            if (initiator !== undefined && initiator !== null) runtime.lastSessionId = String(initiator.id)
          } catch {
            // 拿不到会话身份不影响工具本身。
          }
          try {
            return await serialize(() => runScan('manual', { full: input.full === true }))
          } catch (error) {
            await logLine('error', `wechat_scan_now 执行失败：${describeError(error)}`)
            return {
              ...emptyScan('manual'),
              error: describeError(error),
              summary: `扫描失败：${describeError(error)}`,
            }
          }
        },
      },
    },
    /** 供网页层写日志用。 */
    log: (level, message) => void logLine(level, message),
  }
}

/** 手机端页面文件；插件安装后按相对路径读取，不打包进 JS。 */
const MOBILE_PAGE_URL = new URL('./ui/mobile.html', import.meta.url)

/** 读页面；读不到时给一个能看懂的错误页，而不是让服务崩掉。 */
function readMobilePage() {
  try {
    return readFileSync(MOBILE_PAGE_URL, 'utf8')
  } catch (error) {
    return `<!doctype html><meta charset="utf-8"><h1>页面文件缺失</h1><p>${String(error?.message ?? error)}</p>`
  }
}

/** 插件需要 tools 服务，其余服务都不依赖。 */
export const inject = ['tools']

/**
 * 挂载插件：注册三个工具 + 一个 60 秒心跳。
 * 心跳的 dispose 里 clearInterval，重载插件时不会留下野定时器。
 */
export function apply(ctx, config) {
  const away = createAwayPlugin(config, { ctx })

  ctx.effect(() => {
    const disposers = [
      ctx.tools.register(away.tools.away),
      ctx.tools.register(away.tools.inbox),
      ctx.tools.register(away.tools.scanNow),
    ]
    return () => {
      for (const dispose of disposers) {
        try {
          dispose()
        } catch {
          // 卸载阶段的异常不应该影响 Host。
        }
      }
    }
  }, 'dsh-wechat-away: tools')

  ctx.effect(() => {
    const timer = setInterval(() => {
      void away.tick()
    }, TICK_MS)
    timer.unref?.()
    return () => clearInterval(timer)
  }, 'dsh-wechat-away: scanner')

  ctx.effect(() => {
    const resolved = resolveConfig(config)
    if (resolved.webPort <= 0) return () => {}
    let closed = false
    const started = startAwayWeb({
      stateDir: resolved.stateDir,
      port: resolved.webPort,
      pageHtml: readMobilePage(),
      log: (message) => away.log('info', message),
    })
      .then((handle) => {
        away.log('info', `手机端网页已启动：0.0.0.0:${handle.port}`)
        if (closed) void handle.close()
        return handle
      })
      .catch((error) => {
        away.log('warn', `手机端网页启动失败：${String(error?.message ?? error)}`)
        return null
      })
    return () => {
      closed = true
      void started.then((handle) => {
        if (handle !== null) void handle.close()
      })
    }
  }, 'dsh-wechat-away: web')

  void away.ready()
}

/**
 * 离线测试用的纯函数出口；插件运行时不会用到这些名字。
 * 不属于工具的公共接口，改动不影响 Host 行为。
 */
export const internals = {
  resolveConfig,
  normalizeState,
  normalizeHandled,
  trimHandled,
  normalizeWatchRow,
  normalizeSelectedRow,
  normalizeLastSelectedRow,
  unreadNames,
  pickIncomingText,
  isServiceSession,
  isMutedRow,
  emptyScan,
  digestEntriesText,
  buildDigestText,
  normalizeLastDigest,
  normalizePendingDigest,
}

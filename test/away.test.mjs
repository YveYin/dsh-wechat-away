/**
 * 离线测试：用假的 callBridge 驱动插件，不碰微信、不写真实状态目录。
 * 跑法：node --test test/
 */
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { createAwayPlugin, internals } from '../index.js'

const {
  normalizeWatchRow,
  unreadNames,
  pickIncomingText,
  isServiceSession,
  isMutedRow,
  trimHandled,
  normalizeState,
  digestEntriesText,
  buildDigestText,
} = internals

/** 构造一个可控的假桥；每次调用都记下 mode 与参数。 */
function makeBridge(handlers) {
  const calls = []
  const callBridge = async (mode, extra = {}) => {
    calls.push({ mode, extra })
    const handler = handlers[mode]
    if (typeof handler !== 'function') {
      return { ok: false, error: `测试桥没有 mode=${mode}`, code: 'test-missing' }
    }
    return handler(extra, calls)
  }
  callBridge.calls = calls
  return callBridge
}

/** watch 的一行：默认是「带红点的普通会话」。 */
function watchRow(name, extra = {}) {
  return {
    name,
    preview: '在吗',
    time: '10:00',
    y: 0,
    pinned: false,
    selected: false,
    foldBar: false,
    unread: true,
    badgePx: 154,
    badgeTight: 154,
    badgeBox: '47,13 15x15',
    badgeZone: true,
    redRatio: 0.03,
    ...extra,
  }
}

/** selectedRow 默认为 null（没有打开任何会话），需要时用 extra 覆盖。 */
const watchEnvelope = (rows, extra = {}) => ({
  ok: true,
  data: {
    ok: true,
    mode: 'watch',
    count: rows.length,
    unreadCount: rows.filter((row) => row.unread).length,
    rows,
    selectedRow: null,
    ...extra,
  },
})

const selectedRow = (name, preview, time, extra = {}) => ({ name, preview, time, unread: false, ...extra })

const deselectEnvelope = { ok: true, data: { ok: true, mode: 'deselect', changed: true, wasOpen: true, chatOpen: false } }

const readEnvelope = (messages) => ({ ok: true, data: { ok: true, mode: 'read', total: messages.length, messages } })

const privateEnvelope = { ok: true, data: { ok: true, mode: 'preflight', kindHint: 'private' } }
const groupEnvelope = { ok: true, data: { ok: true, mode: 'preflight', kindHint: 'group' } }
const titlePrivateEnvelope = {
  ok: true,
  data: { ok: true, mode: 'preflight', kindHint: 'group', chatTitle: '小明', isGroupTitle: false, titleKindConfidence: 0.97 },
}
const titleGroupEnvelope = {
  ok: true,
  data: { ok: true, mode: 'preflight', kindHint: 'private', chatTitle: '班群（3）', isGroupTitle: true, titleKindConfidence: 0.99 },
}
const sentEnvelope = { ok: true, data: { ok: true, mode: 'send', sent: true, verified: true, lastMessage: 'ok' } }

async function newPlugin(t, handlers, config = {}, deps = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-wechat-away-test-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const bridge = makeBridge(handlers)
  const plugin = createAwayPlugin({
    stateDir: dir,
    scriptPath: 'C:/fake/wx_ctl.ps1',
    notify: false,
    quietHours: [0, 0],
    cooldownMinutes: 0,
    scanIntervalMinutes: 30,
    autoReplyGroups: false,
    ...config,
  }, { callBridge: bridge, ...deps })
  await plugin.ready()
  return { plugin, bridge, dir }
}

async function readState(dir) {
  return JSON.parse(await readFile(join(dir, 'state.json'), 'utf8'))
}

async function readInbox(dir) {
  try {
    return (await readFile(join(dir, 'inbox.jsonl'), 'utf8'))
      .split('\n')
      .filter((line) => line.trim() !== '')
      .map((line) => JSON.parse(line))
  } catch {
    return []
  }
}

// ---------------------------------------------------------------- watch 解析

test('unreadNames：折叠条行、无名行、无红点行都不算未读会话', () => {
  const rows = [
    normalizeWatchRow({ name: '', foldBar: true, unread: true }),
    normalizeWatchRow({ name: '26 下 宣传', foldBar: false, unread: true }),
    normalizeWatchRow({ name: '老同学', unread: false }),
    normalizeWatchRow({ name: '26 下 宣传', foldBar: false, unread: true }),
    normalizeWatchRow({ name: '   ', unread: true }),
  ]
  assert.deepEqual(unreadNames(rows), ['26 下 宣传'])
})

test('normalizeWatchRow：补齐缺省字段，保留 probe 的 kind', () => {
  const watch = normalizeWatchRow({ name: ' 张三 ', unread: true })
  assert.equal(watch.name, '张三')
  assert.equal(watch.title, '张三')
  assert.equal(watch.kind, 'unknown')
  assert.equal(watch.unread, true)
  assert.equal(watch.badgePx, 0)

  const probe = normalizeWatchRow({ name: '班群', title: '班群（3）', kind: 'group', unread: true })
  assert.equal(probe.title, '班群（3）')
  assert.equal(probe.kind, 'group')
})

test('pickIncomingText：取最后一条 in，没有 in 时取最后一条非 out', () => {
  assert.equal(pickIncomingText([
    { text: '10:00', dir: 'unknown' },
    { text: '我同意', dir: 'out' },
    { text: '你到哪了', dir: 'in' },
    { text: '[2条] 老师: 记得交作业', dir: 'in' },
  ]), '老师: 记得交作业')

  assert.equal(pickIncomingText([
    { text: '10:00', dir: 'unknown' },
    { text: '对方撤回了图片', dir: 'unknown' },
  ]), '对方撤回了图片')

  assert.equal(pickIncomingText([{ text: '我在', dir: 'out' }]), '')
  assert.equal(pickIncomingText([]), '')
})

test('isServiceSession：公众号 / 微信支付 / 文件传输助手等命中内置黑名单', () => {
  for (const name of ['微信支付', '某某公众号', '文件传输助手', '服务通知', '微信团队', '微信游戏']) {
    assert.equal(isServiceSession(name), true, name)
  }
  assert.equal(isServiceSession('26 下 宣传'), false)
  assert.equal(isServiceSession(''), false)
})

test('trimHandled：超过 200 条按时间淘汰最旧的', () => {
  const handled = {}
  for (let index = 0; index < 205; index += 1) {
    handled[`会话${index}`] = { text: 'x', at: new Date(2026, 0, 1, 0, index).toISOString() }
  }
  const trimmed = trimHandled(handled)
  assert.equal(Object.keys(trimmed).length, 200)
  assert.equal(trimmed['会话0'], undefined)
  assert.equal(trimmed['会话204'] !== undefined, true)
})

test('normalizeState：baselineUnread 去重、handled 只认 {text, at}', () => {
  const state = normalizeState({
    baselineUnread: ['甲', '甲', '乙'],
    handled: { 甲: { text: '在吗', at: '2026-01-01T00:00:00.000Z' }, 乙: { text: '' } },
  })
  assert.deepEqual(state.baselineUnread, ['甲', '乙'])
  assert.deepEqual(Object.keys(state.handled), ['甲'])
  assert.deepEqual(state.sendFailures, {})
})

// ---------------------------------------------------------------- start / 基线

test('start：把当下所有未读会话记成 baseline，不回复也不写 inbox', async (t) => {
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope([
      watchRow('', { foldBar: true }),
      watchRow('老未读甲'),
      watchRow('老未读乙'),
      watchRow('已读丙', { unread: false }),
    ]),
  })

  const started = await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  assert.equal(started.ok, true)
  assert.match(started.summary, /老未读/)

  const state = await readState(dir)
  assert.equal(state.active, true)
  assert.equal(state.baselineAt === '', false)
  assert.deepEqual(state.baselineUnread.map((item) => item.name).sort(), ['老未读甲', '老未读乙'].sort())

  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
  assert.deepEqual(await readInbox(dir), [])
})

test('扫描：基线里的老未读跳过，只回复基线外的新来信', async (t) => {
  let rows = [watchRow('老未读甲')]
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '10:00', dir: 'unknown' }, { text: '你在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  rows = [watchRow('老未读甲'), watchRow('新朋友', { preview: '[1条] 你在吗' })]

  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.ok, true)
  assert.equal(scanned.source, 'watch')
  assert.equal(scanned.newMessages, 1)
  assert.equal(scanned.replied, 1)
  assert.equal(scanned.sessions, 2)

  const sends = bridge.calls.filter((call) => call.mode === 'send')
  assert.equal(sends.length, 1)
  assert.equal(sends[0].extra.session, '新朋友')
  assert.equal(sends[0].extra.expectSession, '新朋友')
  assert.match(sends[0].extra.text, /AI 助手/)
  assert.match(sends[0].extra.text, /在上实验课/)

  const state = await readState(dir)
  assert.equal(state.handled['新朋友'].text, '你在吗')
  assert.equal(state.handled['老未读甲'], undefined)

  const inbox = await readInbox(dir)
  assert.equal(inbox.length, 1)
  assert.equal(inbox[0].session, '新朋友')
  assert.equal(inbox[0].action, 'replied')
})

test('没有新消息时不回复、不写 inbox，baseline 保持不变', async (t) => {
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope([watchRow('老未读甲')]),
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.newMessages, 0)
  assert.match(scanned.summary, /没有发现新消息/)
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
  assert.deepEqual((await readState(dir)).baselineUnread.map((item) => item.name), ['老未读甲'])
})

// ---------------------------------------------------------------- 过滤链

test('排除名单 excludeSessions：命中只记录，不发送', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  }, { excludeSessions: ['广告'] })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('某某广告号')]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.recorded, 1)
  assert.equal(scanned.details[0].reason, 'excluded')
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
  assert.equal((await readState(dir)).handled['某某广告号'], undefined)
})

test('内置黑名单：微信支付等服务号完全静默（不回复、不记录）', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '扣款成功', dir: 'in' }]),
    send: () => sentEnvelope,
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('微信支付')]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.ok, true)
  assert.equal(scanned.newMessages, 0)
  assert.equal(scanned.silent, 1)
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.recorded, 0)
  assert.deepEqual(scanned.details, [])
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'read').length, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'preflight').length, 0)
  assert.deepEqual(await readInbox(dir), [])
  const digest = await readFile(join(dir, 'digest.md'), 'utf8').catch(() => '')
  assert.doesNotMatch(digest, /微信支付/)
  const state = await readState(dir)
  assert.equal(state.seenRows['微信支付'], undefined)
  assert.equal(state.handled['微信支付'], undefined)
})

test('公众号 / 服务号 / 微信游戏：一次巡检里全部静默，不写 inbox 与 digest', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '推文更新', dir: 'in' }]),
    send: () => sentEnvelope,
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('公众号'), watchRow('服务号'), watchRow('微信游戏')]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.silent, 3)
  assert.equal(scanned.newMessages, 0)
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.recorded, 0)
  assert.deepEqual(scanned.details, [])
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
  assert.deepEqual(await readInbox(dir), [])
  const digest = await readFile(join(dir, 'digest.md'), 'utf8').catch(() => '')
  assert.doesNotMatch(digest, /公众号|服务号|微信游戏/)
  const state = await readState(dir)
  assert.deepEqual(Object.keys(state.seenRows), [])
})

test('免打扰会话（红点无数字 badgeDigit:false）静默，普通会话照常回复', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [
    watchRow('延大跑腿闲置19群', { badgeDigit: false, preview: '[4条] i n ssiw' }),
    watchRow('老同学'),
  ]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.silent, 1)
  assert.equal(scanned.newMessages, 1)
  assert.equal(scanned.replied, 1)
  assert.equal(scanned.details.length, 1)
  assert.equal(scanned.details[0].session, '老同学')
  const sends = bridge.calls.filter((call) => call.mode === 'send')
  assert.equal(sends.length, 1)
  assert.equal(sends[0].extra.session, '老同学')
  const inbox = await readInbox(dir)
  assert.equal(inbox.length, 1)
  assert.equal(inbox[0].session, '老同学')
  const digest = await readFile(join(dir, 'digest.md'), 'utf8').catch(() => '')
  assert.match(digest, /老同学/)
  assert.doesNotMatch(digest, /延大跑腿闲置19群/)
  const state = await readState(dir)
  assert.equal(state.seenRows['延大跑腿闲置19群'], undefined)
  assert.ok(state.seenRows['老同学'])
})

test('badgeDigit 缺失时按原逻辑回复（兼容旧版 ps1）', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('老同学')] // watchRow 不带 badgeDigit
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.silent, 0)
  assert.equal(scanned.replied, 1)
  assert.equal(scanned.newMessages, 1)
  assert.equal((await readInbox(dir)).length, 1)
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 1)
})

test('normalizeWatchRow / isMutedRow 的 badgeDigit 语义', () => {
  assert.equal(normalizeWatchRow(watchRow('x')).badgeDigit, undefined)
  assert.equal(normalizeWatchRow(watchRow('x', { badgeDigit: true })).badgeDigit, true)
  assert.equal(normalizeWatchRow(watchRow('x', { badgeDigit: false })).badgeDigit, false)
  assert.equal(normalizeWatchRow(watchRow('x', { badgeWhitePx: 10 })).badgeWhitePx, 10)
  assert.equal(normalizeWatchRow(watchRow('x')).badgeWhitePx, 0)

  assert.equal(isMutedRow({ unread: true, badgeDigit: false }), true)
  assert.equal(isMutedRow({ unread: true, badgeDigit: undefined }), false)
  assert.equal(isMutedRow({ unread: true, badgeDigit: true }), false)
  assert.equal(isMutedRow({ unread: false, badgeDigit: false }), false)
  assert.equal(isMutedRow(null), false)
})

test('免打扰：纯红点（badgeDigit:false）是主判据，mutedByName 只作正向证据', () => {
  // 行 Name 里的「消息免打扰」只在没有未读时出现，有未读就被「[N条]」挤掉，
  // 所以 mutedByName=false 绝不能反证「不是免打扰」——纯红点才是硬判据。
  assert.equal(isMutedRow({ unread: true, badgeDigit: false }), true)
  assert.equal(isMutedRow({ unread: true, badgeDigit: false, mutedByName: false }), true)
  assert.equal(isMutedRow({ unread: true, mutedByName: true, badgeDigit: true }), true)
  assert.equal(isMutedRow({ unread: true, mutedByName: true, badgeDigit: undefined }), true)
  // 带白色数字 = 普通未读，即使行文本里没有免打扰字样也照常回复。
  assert.equal(isMutedRow({ unread: true, badgeDigit: true, mutedByName: false }), false)
  assert.equal(isMutedRow({ unread: true, badgeDigit: undefined, mutedByName: false }), false)
  assert.equal(isMutedRow({ unread: false, mutedByName: true }), false)
  // 小铃铛像素只作辅助：命中即免打扰，不命中不影响结论。
  assert.equal(isMutedRow({ unread: true, badgeDigit: true, mutedByBell: true }), true)
  assert.equal(isMutedRow({ unread: true, badgeDigit: true, mutedByBell: false }), false)

  assert.equal(normalizeWatchRow(watchRow('x', { mutedByName: true })).mutedByName, true)
  assert.equal(normalizeWatchRow(watchRow('x', { mutedByName: false })).mutedByName, false)
  assert.equal(normalizeWatchRow(watchRow('x')).mutedByName, undefined)
  assert.equal(normalizeWatchRow(watchRow('x', { mutedByBell: true })).mutedByBell, true)
  assert.equal(normalizeWatchRow(watchRow('x', { bellPx: 14 })).bellPx, 14)
  assert.equal(normalizeWatchRow(watchRow('x')).mutedByBell, undefined)
})

test('群聊：preflight 确认是群聊后只记录，不回复', async (t) => {
  let rows = []
  const { plugin, bridge } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => groupEnvelope,
    read: () => readEnvelope([{ text: '班长: 明天交作业', dir: 'in' }]),
    send: () => sentEnvelope,
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('班群', { preview: '[2条] 班长: 明天交作业' })]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.recorded, 1)
  assert.equal(scanned.details[0].reason, 'group')
  assert.equal(scanned.details[0].kind, 'group')
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
})

test('preflight 拿不准（unknown）时也放弃回复', async (t) => {
  let rows = []
  const { plugin, bridge } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => ({ ok: true, data: { ok: true, mode: 'preflight', kindHint: 'unknown' } }),
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('拿不准的人')]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.details[0].reason, 'unconfirmed')
})

// ---------------------------------------------------------------- 去重 / 重试

test('handled：同一会话再次未读时跳过，不会重复回复', async (t) => {
  let rows = []
  const { plugin, bridge } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  }, { cooldownMinutes: 0 })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  const first = await plugin.tools.scanNow.execute({})
  assert.equal(first.replied, 1)

  const second = await plugin.tools.scanNow.execute({})
  // 同一条消息（同会话、同预览、同时间）在源头就被去重，不会再进 inbox。
  assert.equal(second.replied, 0)
  assert.equal(second.details.length, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 1)
})

test('发送失败：同一文本最多重试 2 次，第 4 次扫描直接跳过', async (t) => {
  let rows = []
  const { plugin, bridge } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => ({ ok: true, data: { ok: true, mode: 'send', sent: false, error: '窗口没找到' } }),
  }, { cooldownMinutes: 0 })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  const results = []
  for (let index = 0; index < 4; index += 1) {
    results.push(await plugin.tools.scanNow.execute({}))
  }

  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 3)
  assert.equal(results[0].failed, 1)
  assert.equal(results[1].failed, 1)
  assert.equal(results[2].failed, 1)
  assert.equal(results[3].skipped, 1)
  assert.equal(results[3].details[0].reason, 'retry-exhausted')
})

// ---------------------------------------------------------------- probe 全量

test('wechat_scan_now full=true：走 probe -Scroll，群聊只记录', async (t) => {
  let rows = []
  const { plugin, bridge } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    probe: () => ({
      ok: true,
      data: {
        ok: true,
        mode: 'probe',
        rows: [{ name: '班群', title: '班群', preview: '班长: 收作业', time: '10:00', kind: 'group', unread: true }],
      },
    }),
    preflight: () => groupEnvelope,
    read: () => readEnvelope([{ text: '班长: 收作业', dir: 'in' }]),
    send: () => sentEnvelope,
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = []
  const scanned = await plugin.tools.scanNow.execute({ full: true })
  assert.equal(scanned.source, 'full')
  const probes = bridge.calls.filter((call) => call.mode === 'probe')
  assert.equal(probes.length, 1)
  assert.equal(probes[0].extra.scroll, true)
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.recorded, 1)
  assert.equal(scanned.details[0].kind, 'group')
})

// ---------------------------------------------------------------- stop

test('未 start 时手动扫描：只建立基线，不记录也不发送', async (t) => {
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope([watchRow('老未读甲'), watchRow('老未读乙')]),
  })
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.ok, true)
  assert.equal(scanned.newMessages, 0)
  assert.match(scanned.summary, /只建立基线/)
  assert.deepEqual(
    (await readState(dir)).baselineUnread.map((item) => item.name).sort(),
    ['老未读甲', '老未读乙'].sort(),
  )
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)
  assert.deepEqual(await readInbox(dir), [])
})

test('stop：清掉 baselineUnread，下一轮重新建立', async (t) => {
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope([watchRow('老未读甲')]),
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  const stopped = await plugin.tools.away.execute({ action: 'stop' })
  assert.equal(stopped.ok, true)
  const state = await readState(dir)
  assert.equal(state.active, false)
  assert.deepEqual(state.baselineUnread, [])
})

test('status / digest 仍能正常返回', async (t) => {
  const { plugin } = await newPlugin(t, {
    watch: () => watchEnvelope([]),
  })
  const status = await plugin.tools.away.execute({ action: 'status' })
  assert.equal(status.ok, true)
  assert.match(status.summary, /不在值守/)
  const digest = await plugin.tools.away.execute({ action: 'digest' })
  assert.equal(digest.ok, true)
})

// ---------------------------------------------------------------- 主动摘要

test('摘要文案：最多列 3 条，超出用「等 N 条」收尾', () => {
  const entries = [
    { session: '甲', text: '在吗', action: 'replied' },
    { session: '乙', text: '吃了吗', action: 'recorded' },
    { session: '丙', text: '救命', action: 'replied' },
    { session: '丁', text: '速回', action: 'recorded' },
  ]
  assert.equal(
    digestEntriesText(entries),
    '甲「在吗」→ 已回复；乙「吃了吗」→ 仅记录；丙「救命」→ 已回复；等 1 条',
  )

  const at = new Date(2026, 10, 10, 18, 44, 0).toISOString()
  assert.equal(
    buildDigestText([{ session: '小比格', text: '在吗', action: 'replied' }], at),
    '值守摘要 18:44 · 小比格「在吗」→ 已回复',
  )
  assert.equal(
    buildDigestText([{ session: '辅导员', text: '马上来', action: 'replied' }], at, true),
    '值守摘要 18:44 · 紧急 · 辅导员「马上来」→ 已回复',
  )
})

test('normalizeState：lastDigest 与 pendingDigest 只认合法字段', () => {
  const state = normalizeState({
    lastDigest: { at: '2026-11-10T10:00:00.000Z', text: '值守摘要 10:00 · 甲「在吗」→ 已回复' },
    pendingDigest: [
      { at: '2026-11-10T10:01:00.000Z', session: '乙', text: '吃了吗', action: 'recorded' },
      { session: '' },
      null,
      { session: '丙' },
    ],
  })
  assert.deepEqual(state.lastDigest, {
    at: '2026-11-10T10:00:00.000Z',
    text: '值守摘要 10:00 · 甲「在吗」→ 已回复',
  })
  assert.equal(state.pendingDigest.length, 2)
  assert.deepEqual(state.pendingDigest[0], {
    at: '2026-11-10T10:01:00.000Z',
    session: '乙',
    text: '吃了吗',
    action: 'recorded',
  })
  assert.equal(state.pendingDigest[1].session, '丙')
  assert.equal(state.pendingDigest[1].action, 'recorded')
  assert.deepEqual(normalizeState({}).lastDigest, { at: '', text: '' })
  assert.deepEqual(normalizeState({}).pendingDigest, [])
})

test('主动摘要：首次来信立即播报，之后按 digestEveryMinutes 合并', async (t) => {
  let rows = []
  const notices = []
  let clock = new Date(2026, 10, 10, 10, 0, 0).getTime()
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  }, { notify: true, digestEveryMinutes: 20 }, {
    notify: (title, body) => notices.push({ title, body }),
    now: () => new Date(clock),
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })

  // 10:00 第一条新消息：还没有上一条摘要，立即播报。
  rows = [watchRow('小明')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 1)
  assert.equal(notices[0].title, '微信值守')
  assert.equal(notices[0].body, '值守摘要 10:00 · 小明「在吗」→ 已回复')
  const first = await readState(dir)
  assert.equal(first.lastDigest.text, notices[0].body)
  assert.deepEqual(first.pendingDigest, [])
  const status = await plugin.tools.away.execute({ action: 'status' })
  assert.match(status.summary, /最近一条摘要：值守摘要 10:00 · 小明「在吗」→ 已回复/)

  // 10:05 又来一条：距上次播报只有 5 分钟，只累积、不播报。
  clock += 5 * 60_000
  rows = [watchRow('小明'), watchRow('小比格')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 1)
  const pending = (await readState(dir)).pendingDigest
  assert.equal(pending.length, 1)
  assert.equal(pending[0].session, '小比格')
  assert.equal(pending[0].action, 'replied')

  // 10:21 超过 20 分钟：把累积的合成一条播报，然后清空 pending。
  clock += 16 * 60_000
  rows = [watchRow('小明'), watchRow('小比格'), watchRow('小张')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 2)
  assert.equal(notices[1].body, '值守摘要 10:21 · 小比格「在吗」→ 已回复；小张「在吗」→ 已回复')
  const after = await readState(dir)
  assert.deepEqual(after.pendingDigest, [])
  assert.equal(after.lastDigest.text, notices[1].body)

  const digestText = await readFile(join(dir, 'digest.md'), 'utf8')
  assert.match(digestText, /值守摘要 10:00 · 小明「在吗」→ 已回复/)
  assert.match(digestText, /值守摘要 10:21 · 小比格「在吗」→ 已回复；小张「在吗」→ 已回复/)
})

test('主动摘要：紧急消息立即单独通知，不参与合并', async (t) => {
  let rows = []
  const notices = []
  let clock = new Date(2026, 10, 10, 11, 0, 0).getTime()
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: (extra) => readEnvelope([
      { text: extra.session === '小明' ? '吃了吗' : '马上来办公室', dir: 'in' },
    ]),
    send: () => sentEnvelope,
  }, { notify: true, digestEveryMinutes: 20 }, {
    notify: (title, body) => notices.push({ title, body }),
    now: () => new Date(clock),
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  rows = [watchRow('辅导员')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 1)
  assert.equal(notices[0].body, '值守摘要 11:00 · 紧急 · 辅导员「马上来办公室」→ 已回复')
  assert.deepEqual((await readState(dir)).pendingDigest, [])

  // 同一轮之后又来一条普通消息：只入队，不因为刚发过紧急通知再合并播报。
  clock += 60_000
  rows = [watchRow('辅导员'), watchRow('小明')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 1)
  const pending = (await readState(dir)).pendingDigest
  assert.equal(pending.length, 1)
  assert.equal(pending[0].session, '小明')
})

test('通知通道：Host 有 notifications 服务时优先走它', async (t) => {
  let rows = []
  const hostCalls = []
  let clock = new Date(2026, 10, 10, 13, 0, 0).getTime()
  const { plugin } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  }, { notify: true }, {
    now: () => new Date(clock),
    ctx: {
      get: (name) => (name === 'notifications'
        ? { notify: (title, body) => hostCalls.push({ title, body }) }
        : undefined),
    },
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  await plugin.tools.scanNow.execute({})
  assert.equal(hostCalls.length, 1)
  assert.equal(hostCalls[0].title, '微信值守')
  assert.equal(hostCalls[0].body, '值守摘要 13:00 · 小明「在吗」→ 已回复')
})

test('stop：未播报的摘要并进结束清单，不额外弹通知', async (t) => {
  let rows = []
  const notices = []
  let clock = new Date(2026, 10, 10, 12, 0, 0).getTime()
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  }, { notify: true, digestEveryMinutes: 20 }, {
    notify: (title, body) => notices.push({ title, body }),
    now: () => new Date(clock),
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 1)

  clock += 2 * 60_000
  rows = [watchRow('小明'), watchRow('小比格')]
  await plugin.tools.scanNow.execute({})
  assert.equal(notices.length, 1)
  assert.equal((await readState(dir)).pendingDigest.length, 1)

  const stopped = await plugin.tools.away.execute({ action: 'stop' })
  // 只多出原有的「值守结束」通知，pending 不单独播报。
  assert.equal(notices.length, 2)
  assert.match(notices[1].body, /值守结束/)
  // 未播报摘要不再拼进汇总（明细已覆盖），但 pendingDigest 必须清空。
  assert.equal(/未播报摘要/u.test(stopped.summary), false)
  assert.deepEqual((await readState(dir)).pendingDigest, [])
  const digestText = await readFile(join(dir, 'digest.md'), 'utf8')
  assert.equal(/未播报 1 条摘要/u.test(digestText), false)
})

// ---------------------------------------------------------------- 回复后收起会话

test('回复成功后调用 deselect，并把结果写进 inbox.deselected', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
    deselect: () => deselectEnvelope,
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.replied, 1)

  // start 会先把面板收起一次（进入闲置态），回复后再收一次。
  const deselects = bridge.calls.filter((call) => call.mode === 'deselect')
  assert.equal(deselects.length, 2)
  // 发送在前、收起在后：回复完才关面板（start 那次 deselect 在最前面，用 lastIndexOf 跳过它）。
  const modes = bridge.calls.map((call) => call.mode)
  assert.equal(modes.indexOf('send') < modes.lastIndexOf('deselect'), true)

  const inbox = await readInbox(dir)
  assert.equal(inbox[0].action, 'replied')
  assert.equal(inbox[0].deselected, true)
})

test('deselect 失败（返回 ok=false / 抛异常）不影响「已回复」的判定', async (t) => {
  let rows = []
  let attempt = 0
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: (extra) => readEnvelope([{ text: `${extra.session} 说在吗`, dir: 'in' }]),
    send: () => sentEnvelope,
    deselect: () => {
      attempt += 1
      if (attempt === 1) throw new Error('面板没反应')
      return { ok: true, data: { ok: false, mode: 'deselect', error: '找不到收起按钮' } }
    },
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  const first = await plugin.tools.scanNow.execute({})
  assert.equal(first.replied, 1)
  assert.equal(first.failed, 0)

  rows = [watchRow('小明'), watchRow('小比格')]
  const second = await plugin.tools.scanNow.execute({})
  assert.equal(second.replied, 1)

  const replied = (await readInbox(dir)).filter((record) => record.action === 'replied')
  assert.deepEqual(replied.map((record) => record.session), ['小明', '小比格'])
  assert.deepEqual(replied.map((record) => record.deselected), [false, false])
  // start 一次 + 两次回复各一次。
  assert.equal(bridge.calls.filter((call) => call.mode === 'deselect').length, 3)
})

// ---------------------------------------------------------------- 标题优先判群聊

test('标题判定：isGroupTitle=true 时即使 kindHint=private 也按群聊只记录', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => titleGroupEnvelope,
    read: () => readEnvelope([{ text: '班长: 明天交作业', dir: 'in' }]),
    send: () => sentEnvelope,
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('班群', { preview: '[2条] 班长: 明天交作业' })]
  const scanned = await plugin.tools.scanNow.execute({})

  assert.equal(scanned.replied, 0)
  assert.equal(scanned.recorded, 1)
  assert.equal(scanned.details[0].kind, 'group')
  assert.equal(scanned.details[0].reason, 'group')
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)

  const inbox = await readInbox(dir)
  assert.equal(inbox[0].kindSource, 'title')
})

test('标题判定：isGroupTitle=false 且 chatTitle 非空时按私聊回复', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => titlePrivateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
    deselect: () => deselectEnvelope,
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  const scanned = await plugin.tools.scanNow.execute({})

  assert.equal(scanned.replied, 1)
  assert.equal(scanned.details[0].kind, 'private')
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 1)
  const inbox = await readInbox(dir)
  assert.equal(inbox[0].kindSource, 'title')
})

// ---------------------------------------------------------------- 打开中会话兜底

test('open-chat：selectedRow 的 preview/time 变化触发候选，按文本去重，并持久化 lastSelectedRow', async (t) => {
  let rows = [watchRow('老未读甲')]
  let selected = selectedRow('小明', '在吗', '10:00')
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows, { selectedRow: selected }),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '你在干嘛', dir: 'in' }]),
    send: () => sentEnvelope,
    deselect: () => deselectEnvelope,
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  const baseline = await readState(dir)
  assert.deepEqual(baseline.lastSelectedRow, { name: '小明', preview: '在吗', time: '10:00' })

  // 微信把打开中的会话新消息立刻标已读：没有红点，只能靠 preview/time 变化发现。
  selected = selectedRow('小明', '你在干嘛', '10:01')
  const first = await plugin.tools.scanNow.execute({})
  assert.equal(first.newMessages, 1)
  assert.equal(first.replied, 1)
  assert.equal(first.details[0].session, '小明')
  assert.equal(first.details[0].reason, 'open-chat')
  assert.equal(bridge.calls.filter((call) => call.mode === 'read').length, 1)

  const inbox = await readInbox(dir)
  assert.equal(inbox[0].action, 'replied')
  assert.equal(inbox[0].reason, 'open-chat')

  const afterFirst = await readState(dir)
  assert.deepEqual(afterFirst.lastSelectedRow, { name: '小明', preview: '你在干嘛', time: '10:01' })
  assert.equal('unread' in afterFirst.lastSelectedRow, false)
  assert.deepEqual(afterFirst.handled['小明'].text, '你在干嘛')

  // 同一快照再扫一次：没有变化，不重复回复。
  const same = await plugin.tools.scanNow.execute({})
  assert.equal(same.newMessages, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 1)

  // preview 又变了，但 read 到的还是同一条文本：按 handled 去重，不再发送。
  selected = selectedRow('小明', '又一条新预览', '10:02')
  const third = await plugin.tools.scanNow.execute({})
  assert.equal(third.newMessages, 1)
  assert.equal(third.replied, 0)
  assert.equal(third.details[0].reason, 'handled')
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 1)
})

test('open-chat：selectedRow 为 null 时不触发候选，lastSelectedRow 存 null', async (t) => {
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope([]),
  })
  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.newMessages, 0)
  assert.equal((await readState(dir)).lastSelectedRow, null)
})

test('normalizeState：lastSelectedRow 只保留 {name, preview, time}', () => {
  assert.deepEqual(
    normalizeState({ lastSelectedRow: { name: ' 小明 ', preview: '在吗', time: '10:00', unread: true } }).lastSelectedRow,
    { name: '小明', preview: '在吗', time: '10:00' },
  )
  assert.equal(normalizeState({ lastSelectedRow: { name: '' } }).lastSelectedRow, null)
  assert.equal(normalizeState({}).lastSelectedRow, null)
})

// ---------------------------------------------------------------- 只记录路径：读真实内容 + 标回未读

const markUnreadEnvelope = (extra = {}) => ({
  ok: true,
  data: { ok: true, changed: true, session: 'x', method: 'context-menu', menuFound: true, rowUnreadAfter: true, ms: 900, ...extra },
})

test('只记录（排除名单）：切进会话读真实文本，收起后把会话标回未读', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([
      { text: '昨天 18:20', dir: 'unknown' },
      { text: '啊', dir: 'in' },
    ]),
    deselect: () => deselectEnvelope,
    markunread: () => markUnreadEnvelope(),
  }, { excludeSessions: ['广告'] })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('某某广告号', { preview: '[1条] 啊' })]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.recorded, 1)
  assert.equal(scanned.details[0].reason, 'excluded')

  // 记录路径也要 read：取真实文本，取最近 20 条。
  const reads = bridge.calls.filter((call) => call.mode === 'read')
  assert.equal(reads.length, 1)
  assert.equal(reads[0].extra.session, '某某广告号')
  assert.equal(reads[0].extra.limit, 20)
  // 读完必须收起，再用右键菜单把红点还回去。
  // 第一个 deselect 来自 start（ensureIdleUi 先把微信摆成闲置态）。
  const modes = bridge.calls.map((call) => call.mode).filter((mode) => mode !== 'watch' && mode !== 'preflight')
  // 顺序：start 先收起 → read → 先标未读 → 再收起
  assert.deepEqual(modes, ['deselect', 'read', 'markunread', 'deselect'])
  const marks = bridge.calls.filter((call) => call.mode === 'markunread')
  assert.equal(marks.length, 1)
  assert.equal(marks[0].extra.session, '某某广告号')
  assert.equal(bridge.calls.filter((call) => call.mode === 'send').length, 0)

  const record = (await readInbox(dir)).find((item) => item.session === '某某广告号')
  assert.equal(record.message, '啊')
  assert.equal(record.previewText, '[1条] 啊')
  assert.equal(record.readVia, 'chat')
  assert.equal(record.markedUnread, true)
  assert.equal(record.deselected, true)
})

test('只记录：markunread 失败只 warn，记录照写（markedUnread:false）', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '明天见', dir: 'in' }]),
    deselect: () => deselectEnvelope,
    markunread: () => ({ ok: false, error: 'menu-item-not-found: 标为未读' }),
  }, { excludeSessions: ['广告'] })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('某某广告号', { preview: '[2条] 明天见' })]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.recorded, 1)
  assert.equal(scanned.failed, 0)
  const record = (await readInbox(dir)).find((item) => item.session === '某某广告号')
  assert.equal(record.message, '明天见')
  assert.equal(record.markedUnread, false)
  assert.equal(bridge.calls.filter((call) => call.mode === 'markunread').length, 1)
})

test('只记录：read 失败退回列表预览，不标未读，也不丢记录', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    deselect: () => deselectEnvelope,
  }, { excludeSessions: ['广告'] })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('某某广告号', { preview: '[3条] 在吗' })]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.recorded, 1)
  // 桥没有 read handler：读失败 → 必须回退预览，并且不要对着没打开的会话乱点右键。
  assert.equal(bridge.calls.filter((call) => call.mode === 'markunread').length, 0)
  const record = (await readInbox(dir)).find((item) => item.session === '某某广告号')
  assert.equal(record.message, '[3条] 在吗')
  assert.equal(record.previewText, '[3条] 在吗')
  assert.equal(record.readVia, 'preview')
  assert.equal(record.markedUnread, undefined)
})

test('readRecordedChat=false：只记录路径完全不碰 read / markunread', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '真实内容', dir: 'in' }]),
    deselect: () => deselectEnvelope,
    markunread: () => markUnreadEnvelope(),
  }, { excludeSessions: ['广告'], readRecordedChat: false })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('某某广告号', { preview: '[1条] 真实内容' })]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.recorded, 1)
  assert.equal(bridge.calls.filter((call) => call.mode === 'read').length, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'markunread').length, 0)
  const record = (await readInbox(dir)).find((item) => item.session === '某某广告号')
  assert.equal(record.message, '[1条] 真实内容')
  assert.equal(record.readVia, 'preview')
})

test('群聊只记录：同样读真实文本并标回未读', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => groupEnvelope,
    read: () => readEnvelope([{ text: '班长: 明天交作业', dir: 'in' }]),
    deselect: () => deselectEnvelope,
    markunread: () => markUnreadEnvelope(),
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('班群', { preview: '[2条] 班长: 明天交作业' })]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.replied, 0)
  assert.equal(scanned.details[0].reason, 'group')
  assert.equal(bridge.calls.filter((call) => call.mode === 'read').length, 1)
  assert.equal(bridge.calls.filter((call) => call.mode === 'markunread').length, 1)
  const record = (await readInbox(dir)).find((item) => item.session === '班群')
  assert.equal(record.message, '班长: 明天交作业')
  assert.equal(record.readVia, 'chat')
  assert.equal(record.markedUnread, true)
})

test('已经回复过的会话：收起会话，并把红点还回去', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
    deselect: () => deselectEnvelope,
    markunread: () => markUnreadEnvelope(),
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [watchRow('小明')]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.replied, 1)
  // 回复完也要标未读：用户回来时要能看见"谁找过我"。
  const marks = bridge.calls.filter((call) => call.mode === 'markunread')
  assert.equal(marks.length, 1)
  assert.deepEqual(marks[0].extra.allowFoldToggle, true)
  const record = (await readInbox(dir)).find((item) => item.session === '小明')
  assert.equal(record.deselected, true)
  assert.equal(record.markedUnread, true)
})

test('免打扰 / 服务号：既不做 read，也不做 markunread', async (t) => {
  let rows = []
  const { plugin, bridge, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '不该被读到', dir: 'in' }]),
    deselect: () => deselectEnvelope,
    markunread: () => markUnreadEnvelope(),
  })

  await plugin.tools.away.execute({ action: 'start', activity: '在开会' })
  rows = [
    watchRow('25农学院互助群1', { preview: '[1条] Milky_: 寻周四早八', badgeDigit: false }),
    watchRow('微信支付', { preview: '[1条] 扣款成功' }),
  ]
  const scanned = await plugin.tools.scanNow.execute({})
  assert.equal(scanned.newMessages, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'read').length, 0)
  assert.equal(bridge.calls.filter((call) => call.mode === 'markunread').length, 0)
  assert.equal((await readInbox(dir)).length, 0)
})

// ---------------------------------------------------------------- 连续消息不被吞

test('连续消息：同一条预览、同一分钟、未读条数递增，两条都要处理', async (t) => {
  let rows = []
  let clock = new Date(2026, 10, 12, 15, 30, 0).getTime()
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '帮我带个饭', dir: 'in' }]),
    send: () => sentEnvelope,
  }, {}, { now: () => new Date(clock) })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  rows = [watchRow('小明', { preview: '[1条] 帮我带个饭', time: '15:30' })]
  await plugin.tools.scanNow.execute({})
  rows = [watchRow('小明', { preview: '[2条] 帮我带个饭', time: '15:30' })]
  await plugin.tools.scanNow.execute({})

  const inbox = await readInbox(dir)
  assert.equal(inbox.filter((r) => r.action === 'replied').length, 2, JSON.stringify(inbox, null, 2))
})

test('连续消息：短消息贴回红点后，再来一条同样的短消息仍要处理', async (t) => {
  let rows = []
  let clock = new Date(2026, 10, 12, 15, 40, 0).getTime()
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => groupEnvelope,
    read: () => readEnvelope([{ text: '动画表情', dir: 'in' }]),
    send: () => sentEnvelope,
    markUnread: () => markUnreadEnvelope(),
    deselect: () => deselectEnvelope,
  }, {}, { now: () => new Date(clock) })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  // 群聊只记录：会走 read → markunread，等于我们自己也贴了一个红点回去。
  rows = [watchRow('某群', { preview: '[1条] 动画表情', time: '15:40' })]
  await plugin.tools.scanNow.execute({})
  // 下一轮看到的正是我们自己贴的那个红点（预览一样、条数还是 1）→ 应跳过。
  clock += 30_000
  await plugin.tools.scanNow.execute({})
  // 对方又发了一个同样的表情：条数变成 2 → 必须当成新来信。
  clock += 30_000
  rows = [watchRow('某群', { preview: '[2条] 动画表情', time: '15:41' })]
  await plugin.tools.scanNow.execute({})

  const inbox = await readInbox(dir)
  assert.equal(inbox.filter((r) => r.session === '某群').length, 2, JSON.stringify(inbox, null, 2))
})

test('静默一分钟：一分钟内补发只记录，超过一分钟再发就再回一条', async (t) => {
  let rows = []
  let clock = new Date(2026, 10, 12, 16, 0, 0).getTime()
  const sent = []
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '帮我带个饭', dir: 'in' }]),
    send: () => { sent.push(1); return sentEnvelope },
  }, { cooldownMinutes: 1 }, { now: () => new Date(clock) })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })

  rows = [watchRow('小明', { preview: '[1条] 帮我带个饭', time: '16:00' })]
  await plugin.tools.scanNow.execute({})

  // 30 秒后又发一条：还在静默窗口里，只记账不回复。
  clock += 30_000
  rows = [watchRow('小明', { preview: '[2条] 顺便带瓶水', time: '16:00' })]
  await plugin.tools.scanNow.execute({})
  assert.equal(sent.length, 1, '一分钟内不应该再发第二条')

  // 再过 40 秒（距上次回复 70 秒）又发一条：应该再回一条 follow-up。
  clock += 40_000
  rows = [watchRow('小明', { preview: '[3条] 多带点纸巾', time: '16:01' })]
  await plugin.tools.scanNow.execute({})
  assert.equal(sent.length, 2, '超过一分钟后应该再回一条')

  const inbox = await readInbox(dir)
  const replies = inbox.filter((r) => r.action === 'replied')
  assert.equal(replies.length, 2)
  assert.match(replies[1].reply, /以上内容我都收到了/u)
})

test('静默窗口到点：他不再发新消息，也要补一条 follow-up 把刚才那几条一起应答', async (t) => {
  let rows = []
  let clock = new Date(2026, 10, 12, 16, 30, 0).getTime()
  const sent = []
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '帮我带个饭', dir: 'in' }]),
    send: () => { sent.push(1); return sentEnvelope },
  }, { cooldownMinutes: 1 }, { now: () => new Date(clock) })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  rows = [watchRow('小明', { preview: '[1条] 帮我带个饭', time: '16:30' })]
  await plugin.tools.scanNow.execute({})

  // 20 秒后补了一条：静默窗口内，只记账。
  clock += 20_000
  rows = [watchRow('小明', { preview: '[2条] 顺便带瓶水', time: '16:30' })]
  await plugin.tools.scanNow.execute({})
  assert.equal(sent.length, 1)

  // 他不再发了。再过 60 秒（距上次回复 80 秒），应该自动补一条。
  clock += 60_000
  await plugin.tools.scanNow.execute({})
  assert.equal(sent.length, 2, '静默到点应该补发一条')

  const inbox = await readInbox(dir)
  const catchUp = inbox.find((r) => r.reason === 'follow-up-catchup')
  assert.ok(catchUp !== undefined, JSON.stringify(inbox, null, 2))
  assert.match(catchUp.reply, /以上内容我都收到了/u)
})

test('每条首轮回复都要表达「有事直接说、消息我会记下」', async (t) => {
  let rows = []
  let clock = new Date(2026, 10, 12, 16, 0, 0).getTime()
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => sentEnvelope,
  }, { cooldownMinutes: 0.02 }, { now: () => new Date(clock) })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  for (let i = 0; i < 12; i += 1) {
    rows = [watchRow('小明', { preview: `[${i + 1}条] 在吗${i}`, time: `16:0${i % 10}` })]
    await plugin.tools.scanNow.execute({})
    clock += 5_000
  }

  const inbox = await readInbox(dir)
  const replies = inbox.map((r) => r.reply).filter((r) => typeof r === 'string' && r !== '')
  assert.ok(replies.length >= 1, JSON.stringify(inbox.slice(0, 3), null, 2))
  for (const text of replies) {
    assert.match(text, /您有事可以直接说/u, text)
    assert.match(text, /消息我会记下/u, text)
  }
})

test('回复里的「看不了手机」要和活动自洽：上课→看不了手机，洗澡→手机不在身边', async (t) => {
  async function replyFor(activity) {
    let rows = []
    let clock = new Date(2026, 10, 12, 17, 0, 0).getTime()
    const { plugin, dir } = await newPlugin(t, {
      watch: () => watchEnvelope(rows),
      preflight: () => privateEnvelope,
      read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
      send: () => sentEnvelope,
    }, {}, { now: () => new Date(clock) })
    await plugin.tools.away.execute({ action: 'start', activity })
    rows = [watchRow('小明', { preview: '[1条] 在吗', time: '17:00' })]
    await plugin.tools.scanNow.execute({})
    const inbox = await readInbox(dir)
    return inbox.map((r) => r.reply).filter((r) => typeof r === 'string' && r !== '')[0] ?? ''
  }

  const classReply = await replyFor('在上实验课')
  assert.match(classReply, /暂时看不了手机/u, classReply)
  assert.doesNotMatch(classReply, /手机不在身边/u, classReply)

  const bathReply = await replyFor('在洗澡')
  assert.match(bathReply, /手机不在身边/u, bathReply)
  assert.doesNotMatch(bathReply, /暂时看不了手机/u, bathReply)

  const phoneReply = await replyFor('在进行 USB 调试，手机被占用了')
  assert.doesNotMatch(phoneReply, /手机不在身边|暂时看不了手机/u, phoneReply)
})

test('补发一直失败：试满 3 次就放弃，只留一条失败记录，不再刷屏', async (t) => {
  let rows = []
  let clock = new Date(2026, 10, 12, 17, 0, 0).getTime()
  let sendCount = 0
  const { plugin, dir } = await newPlugin(t, {
    watch: () => watchEnvelope(rows),
    preflight: () => privateEnvelope,
    read: () => readEnvelope([{ text: '在吗', dir: 'in' }]),
    send: () => {
      sendCount += 1
      // 第一次（首轮回复）成功，之后补发全部失败，模拟会话已不在可见列表。
      return sendCount === 1 ? sentEnvelope : { ok: true, data: { ok: true, mode: 'send', sent: false, error: 'session-not-found: 小明' } }
    },
  }, { cooldownMinutes: 1 }, { now: () => new Date(clock) })

  await plugin.tools.away.execute({ action: 'start', activity: '在上实验课' })
  rows = [watchRow('小明', { preview: '[1条] 在吗', time: '17:00' })]
  await plugin.tools.scanNow.execute({})
  assert.equal(sendCount, 1)

  // 静默窗口里又来一条：入待补发队列。
  clock += 20_000
  rows = [watchRow('小明', { preview: '[2条] 顺便带瓶水', time: '17:00' })]
  await plugin.tools.scanNow.execute({})

  // 到点后连续三轮都发不出去。
  clock += 60_000
  await plugin.tools.scanNow.execute({})
  await plugin.tools.scanNow.execute({})
  await plugin.tools.scanNow.execute({})
  assert.equal(sendCount, 4, '首轮回复 + 三次补发尝试')

  // 放弃之后不再重试。
  await plugin.tools.scanNow.execute({})
  assert.equal(sendCount, 4, '放弃后不该继续重试')

  const inbox = await readInbox(dir)
  const giveUp = inbox.filter((r) => typeof r.reason === 'string' && r.reason.startsWith('follow-up-give-up'))
  assert.equal(giveUp.length, 1, JSON.stringify(inbox, null, 2))
  const spam = inbox.filter((r) => typeof r.reason === 'string' && r.reason.startsWith('follow-up-send-failed'))
  assert.equal(spam.length, 0, '中间失败不该写 inbox')
})

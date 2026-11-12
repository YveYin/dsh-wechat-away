/**
 * dsh-wechat-away 的手机端网页控制层。
 *
 * 不依赖第三方包，只用 node:http / node:crypto / node:fs。
 * 它不是一个独立进程：由插件在 Host 里启动，监听 0.0.0.0:<port>，
 * 这样手机经 Tailscale（或同一 Wi-Fi）就能访问。
 *
 * 所有写操作都落成 requests/req-<毫秒>.json —— 与桌面快捷方式走同一条路径，
 * 因此两边行为永远一致，不存在两套逻辑。
 */

import { createServer } from 'node:http'
import { randomBytes } from 'node:crypto'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const TOKEN_FILE = 'web-token.txt'
const REQUESTS_DIR = 'requests'
const SUMMARY_FILE = 'last-summary.md'

/** 读文本，兼容 BOM；文件不存在返回 null。 */
async function readTextOrNull(path) {
  try {
    const text = await readFile(path, 'utf8')
    return text.charCodeAt(0) === 0xfeff ? text.slice(1) : text
  } catch {
    return null
  }
}

async function readJsonOrNull(path) {
  const text = await readTextOrNull(path)
  if (text === null) return null
  try {
    return JSON.parse(text)
  } catch {
    return null
  }
}

/** 首次启动时生成并落盘一个 32 字节随机令牌。 */
async function ensureToken(stateDir) {
  const path = join(stateDir, TOKEN_FILE)
  const existing = (await readTextOrNull(path))?.trim()
  if (existing !== undefined && existing !== null && existing.length >= 32) return existing
  const token = randomBytes(16).toString('hex')
  await writeFile(path, `${token}\n`, 'utf8')
  return token
}

/** 请求体解析，限制 64KB，避免被大包打满内存。 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > 64 * 1024) {
        reject(new Error('body-too-large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8')
      if (raw.trim() === '') return resolve({})
      try {
        resolve(JSON.parse(raw))
      } catch {
        reject(new Error('bad-json'))
      }
    })
    req.on('error', reject)
  })
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  })
  res.end(body)
}

function sendText(res, status, body, type = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'content-type': type,
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  })
  res.end(body)
}

/**
 * 启动网页服务。
 * @returns {Promise<{ port:number, token:string, close:()=>Promise<void> }>}
 */
export async function startAwayWeb(options) {
  const stateDir = options.stateDir
  const port = Number.isInteger(options.port) && options.port > 0 ? options.port : 4318
  const log = typeof options.log === 'function' ? options.log : () => {}
  const pageHtml = options.pageHtml

  await mkdir(join(stateDir, REQUESTS_DIR), { recursive: true })
  const token = await ensureToken(stateDir)
  const requestsDir = join(stateDir, REQUESTS_DIR)
  const statePath = join(stateDir, 'state.json')
  const heartbeatPath = join(stateDir, 'heartbeat')
  const summaryPath = join(stateDir, SUMMARY_FILE)

  const authorized = (req, url) => {
    const header = req.headers['x-away-token']
    if (typeof header === 'string' && header === token) return true
    const query = url.searchParams.get('k')
    return query !== null && query === token
  }

  const writeRequest = async (payload) => {
    const name = `req-${Date.now()}.json`
    await writeFile(join(requestsDir, name), JSON.stringify(payload), 'utf8')
    return name
  }

  const handler = async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    const path = url.pathname

    if (path === '/away' || path === '/away/' || path === '/') {
      // 页面本身不需要令牌：它拿不到数据，只是让用户把令牌填进来。
      sendText(res, 200, pageHtml, 'text/html; charset=utf-8')
      return
    }

    if (!authorized(req, url)) {
      sendJson(res, 401, { ok: false, error: 'unauthorized' })
      return
    }

    if (path === '/away/status') {
      const state = (await readJsonOrNull(statePath)) ?? {}
      const beat = (await readTextOrNull(heartbeatPath))?.trim() ?? ''
      const beatAt = Date.parse(beat)
      const heartbeatAge = Number.isFinite(beatAt) ? Date.now() - beatAt : null
      const summary = (await readTextOrNull(summaryPath)) ?? ''
      sendJson(res, 200, {
        ok: true,
        active: state.active === true,
        activity: typeof state.activity === 'string' ? state.activity : '',
        ownerName: typeof state.ownerName === 'string' ? state.ownerName : '',
        untilMode: typeof state.untilMode === 'string' ? state.untilMode : '',
        untilText: typeof state.untilText === 'string' ? state.untilText : '',
        until: typeof state.until === 'string' ? state.until : '',
        startedAt: typeof state.startedAt === 'string' ? state.startedAt : '',
        intervalMinutes: typeof state.intervalMinutes === 'number' ? state.intervalMinutes : null,
        heartbeatAge,
        heartbeatOk: heartbeatAge !== null && heartbeatAge < 15_000,
        summary,
      })
      return
    }

    if (path === '/away/start' && req.method === 'POST') {
      let body
      try {
        body = await readBody(req)
      } catch (error) {
        sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
        return
      }
      const activity = typeof body.activity === 'string' ? body.activity.trim() : ''
      if (activity === '') {
        sendJson(res, 400, { ok: false, error: 'activity-required' })
        return
      }
      const mode = body.mode === 'clock' ? 'clock' : body.mode === 'duration' ? 'duration' : ''
      if (mode === '') {
        sendJson(res, 400, { ok: false, error: 'mode-required' })
        return
      }
      const payload = { action: 'start', activity, mode }
      if (mode === 'clock') {
        const untilAt = typeof body.untilAt === 'string' ? body.untilAt : ''
        if (!Number.isFinite(Date.parse(untilAt))) {
          sendJson(res, 400, { ok: false, error: 'bad-untilAt' })
          return
        }
        payload.untilAt = new Date(untilAt).toISOString()
        payload.untilText = typeof body.untilText === 'string' ? body.untilText : ''
      } else {
        const minutes = Number(body.durationMinutes)
        if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 24 * 60) {
          sendJson(res, 400, { ok: false, error: 'bad-duration' })
          return
        }
        payload.durationMinutes = Math.round(minutes)
        payload.untilText = typeof body.untilText === 'string' ? body.untilText : ''
      }
      const name = await writeRequest(payload)
      log(`网页端请求已提交：start ${activity}（${name}）`)
      sendJson(res, 200, { ok: true, request: name })
      return
    }

    if (path === '/away/set-owner' && req.method === 'POST') {
      let body
      try {
        body = await readBody(req)
      } catch (error) {
        sendJson(res, 400, { ok: false, error: String(error.message ?? error) })
        return
      }
      const ownerName = typeof body.ownerName === 'string' ? body.ownerName.trim().slice(0, 24) : ''
      if (ownerName === '') {
        sendJson(res, 400, { ok: false, error: 'ownerName-required' })
        return
      }
      const name = await writeRequest({ action: 'set-owner', ownerName })
      log(`网页端请求已提交：set-owner ${ownerName}（${name}）`)
      sendJson(res, 200, { ok: true, request: name, ownerName })
      return
    }

    if (path === '/away/stop' && req.method === 'POST') {
      const name = await writeRequest({ action: 'stop' })
      log(`网页端请求已提交：stop（${name}）`)
      sendJson(res, 200, { ok: true, request: name })
      return
    }

    sendJson(res, 404, { ok: false, error: 'not-found' })
  }

  const server = createServer((req, res) => {
    handler(req, res).catch((error) => {
      log(`网页端处理失败：${String(error?.message ?? error)}`)
      try {
        sendJson(res, 500, { ok: false, error: 'internal' })
      } catch {
        // 响应已经发出去时忽略。
      }
    })
  })

  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(port, '0.0.0.0', () => {
      server.removeListener('error', reject)
      resolve()
    })
  })

  return {
    port,
    token,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  }
}

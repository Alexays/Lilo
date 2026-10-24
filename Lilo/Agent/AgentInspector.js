// Runs in the page world of an agent tab's Web Inspector frontend: sends protocol commands for the
// agent and keeps what the agent reads later. The frontend is private to one tab.
(() => {
  if (window.__liloInspector) return
  const maxEvents = 1000
  const events = []
  // Requests seen since the connection, by protocol request id, for network_response.
  const requests = new Map()
  // The main frame's current page load, shared by the entries of its requests.
  let page = { url: WI.networkManager.mainFrame?.mainResource?.url ?? null, index: 0 }
  const rules = []
  let nextRuleId = 1
  // Intercepted requests a rule's delay holds, released by reset.
  const held = new Map()
  // Fields of emulate the agent set, undone by reset.
  const emulation = {}
  // The running performance profile: every message of its domains, whole. The last one stays for
  // summaries over another time window or function.
  let profile = null
  let lastProfile = null
  // Each class's count and bytes at the previous heap snapshot, for the next one's growth.
  let previousHeap = null
  // The last profile or heap snapshot as JSON text, handed to Lilo in chunks: one string of tens of MB
  // does not come back whole from the frontend.
  let pendingRaw = ''
  // The latest memory sample, by category, of the Memory domain.
  let lastMemory = null
  const profileDomains = ['Timeline', 'ScriptProfiler', 'CPUProfiler', 'Memory']
  const maxProfileMessages = 50000
  // Only domains the agent sent a command to: the frontend itself keeps many busy.
  const tracked = new Set()
  const agentObjectGroup = 'lilo-agent'

  const dispatchEvent = InspectorBackend.Connection.prototype._dispatchEvent
  if (typeof dispatchEvent === 'function') {
    InspectorBackend.Connection.prototype._dispatchEvent = function (message) {
      const method = message.method ?? ''
      if (method.startsWith('Network.')) noteRequest(method, message.params ?? {})
      if (method === 'Page.frameNavigated' && !message.params?.frame?.parentId) {
        notePageLoad(message.params?.frame ?? {})
        // What the agent evaluated on the page left would keep that page's Window alive.
        WI.mainTarget?.RuntimeAgent?.releaseObjectGroup?.invoke({ objectGroup: agentObjectGroup }).catch(() => {})
      }
      if (method === 'Memory.trackingUpdate') lastMemory = message.params?.event
      if (profile && profileDomains.includes(method.split('.')[0])) {
        // A capped profile still keeps the starts and ends: the samples all come with ScriptProfiler's end.
        const bound = /\.(trackingStart|trackingComplete|recordingStarted|recordingStopped)$/.test(method)
        if (profile.messages.length < maxProfileMessages || bound) profile.messages.push({ method, params: message.params })
        else if (!profile.capped) {
          profile.capped = true
          stopInstruments()
        }
      }
      if (tracked.has(method.split('.')[0])) {
        let text = JSON.stringify({ method, params: message.params })
        if (text.length > 5000) text = text.slice(0, 5000) + '...'
        events.push({ method, text })
        if (events.length > maxEvents) events.shift()
      }
      return dispatchEvent.call(this, message)
    }
  }

  // The frontend queues backend messages for a zero delay timer that has not run yet when a read comes
  // right after the page acted: the requests it made wait there, unseen by the hook above.
  function drainBackendMessages() {
    while (WI._messagesToDispatch.length) WI.dispatchNextQueuedMessageFromBackend()
  }

  function noteRequest(method, params) {
    const entry = requests.get(params.requestId)
    switch (method) {
      case 'Network.requestWillBeSent':
        if (entry && params.redirectResponse) {
          // A redirect goes on under the same id: the hop stays listed under its own.
          let hop = 1
          while (requests.has(`${params.requestId}~${hop}`)) hop++
          requests.set(`${params.requestId}~${hop}`, { ...entry, response: params.redirectResponse, endedAt: params.timestamp, redirect: true })
          if (requests.size > 1000) requests.delete(requests.keys().next().value)
        }
        requests.delete(params.requestId)
        requests.set(params.requestId, {
          request: params.request, type: params.type, startedAt: params.timestamp, walltime: params.walltime, received: 0, encoded: 0, page, loaderId: params.loaderId
        })
        if (requests.size > 1000) requests.delete(requests.keys().next().value)
        break
      case 'Network.requestServedFromMemoryCache': {
        const resource = params.resource ?? {}
        requests.delete(params.requestId)
        requests.set(params.requestId, {
          request: { url: resource.url, method: 'GET', headers: {} }, type: resource.type, startedAt: params.timestamp,
          endedAt: params.timestamp, walltime: Date.now() / 1000, response: { ...resource.response, source: 'memory-cache' }, page
        })
        if (requests.size > 1000) requests.delete(requests.keys().next().value)
        break
      }
      case 'Network.responseReceived':
        if (entry) Object.assign(entry, { response: params.response, responseAt: params.timestamp })
        break
      case 'Network.dataReceived':
        if (entry) {
          entry.received += params.dataLength ?? 0
          entry.encoded += params.encodedDataLength ?? 0
        }
        break
      case 'Network.loadingFinished':
        if (entry) Object.assign(entry, { endedAt: params.timestamp, metrics: params.metrics })
        break
      case 'Network.loadingFailed':
        if (entry) Object.assign(entry, { endedAt: params.timestamp, failed: params.errorText || 'failed' })
        break
    }
  }

  // Only a commit tells a main frame from a frame: the document's request, sent before, joins the page it loaded.
  function notePageLoad(frame) {
    page = { url: frame.url, index: page.index + 1 }
    const document = [...requests.values()].findLast(entry => entry.type === 'Document' && entry.loaderId === frame.loaderId)
    if (document) document.page = page
  }

  function base64(text) {
    const bytes = new TextEncoder().encode(text)
    let binary = ''
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
    return btoa(binary)
  }

  async function settle(agent, requestId, rule, stage, url) {
    rule.hits++
    if (rule.delayMs) {
      held.set(requestId, { agent, stage })
      await new Promise(resolve => setTimeout(resolve, rule.delayMs))
      // Gone: reset already let it through.
      if (!held.delete(requestId)) return
    }
    let response = rule.response
    try {
      if (response?.path) {
        // $1 and up take the URL's groups, so one rule serves a whole folder; read now, so a rebuilt file comes fresh.
        const match = rule.regex.exec(url) ?? []
        const path = response.path.replace(/\$(\d+|&)/g, (_, group) => {
          const part = (group === '&' ? match[0] : match[group]) ?? ''
          try { return decodeURIComponent(part) } catch { return part }
        })
        const file = await window.webkit.messageHandlers.liloAgentFile.postMessage(path)
        if (!file) rule.lastError = `No file at ${path}`
        response = file ? { ...file, ...response } : { status: 404, body: `No file at ${path}` }
      }
      if (response) {
        const args = {
          requestId, content: response.bodyBase64 ?? base64(response.body ?? ''), base64Encoded: true,
          mimeType: response.mimeType ?? 'text/plain', status: response.status ?? 200,
          statusText: response.statusText ?? '', headers: response.headers ?? {}
        }
        await (stage === 'request' ? agent.interceptRequestWithResponse : agent.interceptWithResponse).invoke(args)
      } else if (rule.error) {
        await agent.interceptRequestWithError.invoke({ requestId, errorType: rule.error })
      } else if (rule.modify) {
        await agent.interceptWithRequest.invoke({ requestId, ...rule.modify })
      } else {
        await agent.interceptContinue.invoke({ requestId, stage })
      }
    } catch (error) {
      const message = error.message ?? error
      // The page cancelled the request (a navigation, an abort) before the rule applied: nothing was sent.
      if (/already been processed|Missing pending/.test(message)) {
        rule.lastError = `${message}: ${url} was dropped by the page before the rule applied, it was not sent`
        return
      }
      // A blocked request must never reach the network, even when failing it did not work.
      if (rule.error) {
        rule.lastError = `${message}: ${url} could not be failed and was held, never sent`
        return
      }
      // A request that cannot take the rule's outcome must still not hang the page.
      rule.lastError = `${message}: ${url} went to the network`
      agent.interceptContinue.invoke({ requestId, stage }).catch(() => {})
    }
  }

  // The agent's rules go first; anything else stays with the frontend (the user's Local Overrides).
  const observer = WI.NetworkObserver.prototype
  for (const [name, stage] of [['requestIntercepted', 'request'], ['responseIntercepted', 'response']]) {
    const original = observer[name]
    observer[name] = function (requestId, payload) {
      // An intercepted response carries no method nor body: its request, seen first, does.
      const request = requests.get(requestId)?.request
      const method = payload.method ?? request?.method
      const body = stage === 'request' ? payload.postData : request?.postData
      // Parsed once, only for a rule with bodyJson whose URL matches; a batch (an array) matches by any item.
      let items
      const parsed = () => items ??= (() => { try { return [JSON.parse(body)].flat() } catch { return [] } })()
      const rule = rules.find(r => r.stage === stage && r.regex.test(payload.url) && (!r.methods || r.methods.includes(method)) &&
        (!r.bodyRegex || r.bodyRegex.test(body ?? '')) &&
        (!r.bodyFields || parsed().some(item => r.bodyFields.every(([field, test]) => test(item?.[field])))))
      if (!rule) return original.call(this, requestId, payload)
      settle(this._target.NetworkAgent, requestId, rule, stage, payload.url)
    }
  }

  // Who a sample's time belongs to: its first frame with a script, a native call billed to its caller.
  function origin(url, pageHost) {
    if (!url) return 'native'
    let host
    try {
      const parsed = new URL(url)
      if (!parsed.protocol.startsWith('http')) return parsed.protocol.includes('extension') ? 'extension' : 'firstParty'
      host = parsed.hostname
    } catch { return 'native' }
    if (host === pageHost) return 'firstParty'
    const site = name => name.split('.').slice(-2).join('.')
    return site(host) === site(pageHost) ? 'sameSite' : 'thirdParty'
  }

  // fromMs and toMs bound it to a window of the profile; focus lists the call paths leading to the
  // functions whose name contains it.
  function summarize({ messages, durationMs, pageURL }, { fromMs = 0, toMs = Infinity, focus } = {}) {
    let pageHost = ''
    try { pageHost = new URL(pageURL).hostname } catch {}
    // A page that moved to a new process starts a new clock: times count from the last start.
    const starts = messages.map(({ method, params }) =>
      method === 'ScriptProfiler.trackingStart' ? params.timestamp : method === 'Timeline.recordingStarted' ? params.startTime : null
    ).filter(time => time != null)
    const base = starts.at(-1) ?? 0
    const at = time => Math.round((time - base) * 1000)
    const inWindow = time => time == null || ((time - base) * 1000 >= fromMs && (time - base) * 1000 <= toMs)
    const round = value => Math.round(value * 10) / 10
    const top = (map, limit) => [...map].sort((a, b) => b[1] - a[1]).slice(0, limit)
    const count = (map, key, by = 1) => map.set(key, (map.get(key) ?? 0) + by)
    // Each type's records overlap and nest: their time is the union of their spans, never more than the profile.
    const records = new Map()
    // Main thread tasks of 50 ms or more, and the marks of console.timeStamp.
    const longTasks = []
    const markers = []
    let lastTime = base
    const addRecord = (record, topLevel) => {
      if (inWindow(record.startTime)) {
        const entry = records.get(record.type) ?? { count: 0, spans: [] }
        entry.count++
        if (record.endTime > record.startTime) entry.spans.push([record.startTime, record.endTime])
        records.set(record.type, entry)
        lastTime = Math.max(lastTime, record.endTime ?? record.startTime)
        if (record.type === 'TimeStamp') markers.push({ label: String(record.data?.message ?? ''), time: record.startTime })
        if (topLevel && record.type !== 'Screenshot' && record.endTime - record.startTime >= 0.05) longTasks.push(record)
      }
      for (const child of record.children ?? []) addRecord(child, false)
    }
    const covered = spans => {
      let total = 0
      let end = -Infinity
      for (const [from, to] of spans.sort((a, b) => a[0] - b[0])) {
        if (to <= end) continue
        total += to - Math.max(from, end)
        end = to
      }
      return total * 1000
    }
    // A native frame has no line; a script without a URL (eval, inline in a data: page) has one.
    const isScript = frame => !!frame.url || frame.line >= 0
    // A data: URL holds the whole document.
    const where = frame => !frame.url ? '(script without URL)' : frame.url.length > 150 ? `${frame.url.slice(0, 150)}...` : frame.url
    const frameName = frame => `${frame.name || '(anonymous)'} ${isScript(frame) ? `${where(frame)}:${frame.line}` : '(native)'}`
    const self = new Map()
    const callers = new Map()
    const inclusive = new Map()
    const files = new Map()
    const fileOrigins = new Map()
    const origins = new Map()
    const paths = new Map()
    // Each sample in the window as its time and its own function, for the long tasks and the marks.
    const timed = []
    let samples = 0
    const cpu = []
    const memory = {}
    for (const { method, params } of messages) {
      if (method === 'Timeline.eventRecorded') addRecord(params.record, true)
      else if (method === 'ScriptProfiler.trackingComplete') {
        const traces = params.samples?.stackTraces ?? []
        // Many samples come without a time (0): each takes the next timed one's, the last ones the one before.
        const times = traces.map(trace => trace.timestamp || null)
        for (let k = times.length - 2; k >= 0; k--) times[k] ??= times[k + 1]
        for (let k = 1; k < times.length; k++) times[k] ??= times[k - 1]
        traces.forEach((trace, k) => {
          const frames = trace.stackFrames ?? []
          if (!frames.length || !inWindow(times[k])) return
          samples++
          const names = frames.map(frameName)
          timed.push([times[k], names[0]])
          count(self, names[0])
          if (names[1]) {
            const byCaller = callers.get(names[0]) ?? new Map()
            count(byCaller, names[1])
            callers.set(names[0], byCaller)
          }
          for (const name of new Set(names)) count(inclusive, name)
          const owner = frames.find(isScript)
          const file = owner ? where(owner) : '(native)'
          const source = !owner ? 'native' : owner.url ? origin(owner.url, pageHost) : 'scriptWithoutURL'
          count(files, file)
          fileOrigins.set(file, source)
          count(origins, source)
          // By name or by file: an anonymous arrow function or a component has only its file to go by.
          const focused = focus ? names.findIndex(name => name.includes(focus)) : -1
          if (focused >= 0) count(paths, names.slice(focused, focused + 6).join(' <- '))
        })
      } else if (method === 'CPUProfiler.trackingUpdate') {
        if (inWindow(params.event.timestamp)) cpu.push(params.event.usage)
      } else if (method === 'Memory.trackingUpdate' && inWindow(params.event.timestamp)) {
        for (const category of params.event.categories) memory[category.type] = Math.max(memory[category.type] ?? 0, category.size)
      }
    }
    const percent = value => round(value * 100 / samples)
    // The functions running most between two times, by their share of the samples taken then.
    const topBetween = (from, to) => {
      const between = new Map()
      let total = 0
      for (const [time, name] of timed) {
        if (time == null || time < from || time > to) continue
        total++
        count(between, name)
      }
      return top(between, 3).map(([name, value]) => ({ function: name, percent: round(value * 100 / total) }))
    }
    const duration = record => record.endTime - record.startTime
    const summary = {
      durationMs,
      samples,
      byOrigin: Object.fromEntries(top(origins, 5).map(([name, value]) => [name, percent(value)])),
      topFunctions: top(self, 20).map(([name, value]) => ({
        function: name, samples: value, percent: percent(value),
        callers: top(callers.get(name) ?? new Map(), 3).map(([caller, n]) => ({ function: caller, samples: n }))
      })),
      topInclusive: top(inclusive, 15).map(([name, value]) => ({ function: name, percent: percent(value) })),
      byFile: top(files, 15).map(([file, value]) => ({ file, percent: percent(value), origin: fileOrigins.get(file) })),
      longTasks: {
        count: longTasks.length,
        totalMs: Math.round(longTasks.reduce((sum, task) => sum + duration(task), 0) * 1000),
        longest: longTasks.sort((a, b) => duration(b) - duration(a)).slice(0, 15).sort((a, b) => a.startTime - b.startTime).map(task => ({
          atMs: at(task.startTime), durationMs: Math.round(duration(task) * 1000),
          type: task.data?.type ? `${task.type} ${task.data.type}` : task.type,
          topFunctions: topBetween(task.startTime, task.endTime)
        }))
      },
      records: Object.fromEntries([...records].map(([type, entry]) => [type, { count: entry.count, totalMs: Math.round(covered(entry.spans)) }])
        .sort((a, b) => b[1].totalMs - a[1].totalMs)),
      cpuPercent: cpu.length ? { average: round(cpu.reduce((a, b) => a + b, 0) / cpu.length), max: round(Math.max(...cpu)) } : null,
      peakMemoryMB: Object.fromEntries(Object.entries(memory).map(([type, bytes]) => [type, round(bytes / 1048576)]))
    }
    // Each mark opens a section that runs to the next one, the last to the end of the profile.
    if (markers.length) {
      markers.sort((a, b) => a.time - b.time)
      summary.markers = markers.slice(0, 50).map((marker, k) => {
        const until = markers[k + 1]?.time ?? lastTime
        return {
          label: marker.label, atMs: at(marker.time), durationMs: Math.round((until - marker.time) * 1000),
          longTasks: longTasks.filter(task => task.startTime >= marker.time && task.startTime < until).length,
          topFunctions: topBetween(marker.time, until)
        }
      })
    }
    if (fromMs > 0 || toMs < Infinity) summary.window = { fromMs, toMs: toMs === Infinity ? null : toMs }
    if (focus) summary.focus = paths.size ? top(paths, 10).map(([path, value]) => ({ path, samples: value, percent: percent(value) })) : `No sample ran a function or file matching "${focus}"`
    return summary
  }

  // Each instrument starts on its own, as the inspector's Timelines tab does. The frontend's instruments
  // take a screenshot each frame, which costs the page time: those come only when asked for.
  async function startInstruments(target) {
    await target.ScriptProfilerAgent.startTracking.invoke({ includeSamples: true })
    await target.CPUProfilerAgent?.startTracking.invoke({})
    await target.MemoryAgent?.startTracking.invoke({})
    await target.TimelineAgent.setInstruments?.invoke({ instruments: profile?.screenshots ? ['Timeline', 'Screenshot'] : ['Timeline'] })
    await target.TimelineAgent.start.invoke({})
  }

  async function stopInstruments() {
    const targets = profile?.targets ?? [WI.mainTarget]
    for (const target of targets) {
      for (const agent of [target.TimelineAgent, target.MemoryAgent, target.CPUProfilerAgent, target.ScriptProfilerAgent]) {
        const stopping = (agent?.stop ?? agent?.stopTracking)?.invoke({}).catch(() => {})
        await Promise.race([stopping, new Promise(resolve => setTimeout(resolve, 1000))])
      }
    }
    // Back to the frontend's own instruments, for a recording from its Timelines tab.
    try { WI.timelineManager._updateAutoCaptureInstruments?.(targets) } catch {}
  }

  const sameInterception = (a, b) => a.urlPattern === b.urlPattern && a.stage === b.stage

  const interception = rule => ({ url: rule.urlPattern, stage: rule.stage, caseSensitive: true, isRegex: true })

  function intercept(target, rule) {
    // The frontend usually has interception on already, and then says so with an error. Both go out at
    // once: a new target resuming right after must have them before it loads anything.
    target.NetworkAgent.setInterceptionEnabled.invoke({ enabled: true }).catch(() => {})
    return target.NetworkAgent.addInterception.invoke(interception(rule))
  }

  async function removeInterception(rule) {
    if (rules.some(r => sameInterception(r, rule))) return
    await WI.mainTarget.NetworkAgent.removeInterception.invoke(interception(rule)).catch(() => {})
  }

  // textReplace's [pattern, replacement] pairs: a pattern is literal text, matched as whole words in any
  // case, or /a regex/flags. Stringified into the page, so it uses nothing of the frontend.
  function textRules(pairs) {
    if (!Array.isArray(pairs) || !pairs.length) throw new Error('textReplace is a list of [pattern, replacement] pairs, or null')
    return pairs.map(pair => {
      const [pattern, replacement] = Array.isArray(pair) ? pair : []
      if (pair?.length !== 2 || typeof pattern !== 'string' || !pattern || typeof replacement !== 'string') {
        throw new Error(`textReplace: ${JSON.stringify(pair)} is not a [pattern, replacement] pair of strings`)
      }
      const slash = pattern.lastIndexOf('/')
      const flags = pattern.slice(slash + 1)
      const isRegex = pattern.startsWith('/') && slash > 1 && /^[dgimsuv]*$/.test(flags)
      const regex = isRegex
        ? new RegExp(pattern.slice(1, slash), flags.replace('g', '') + 'g')
        : new RegExp(`(?<![\\p{L}\\p{N}_])${pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?![\\p{L}\\p{N}_])`, 'giu')
      // It would match again each time the page touches the node, and grow.
      if (regex.test(replacement)) throw new Error(`textReplace: "${replacement}" matches its own pattern ${pattern}`)
      regex.lastIndex = 0
      return { pattern, regex, replacement: isRegex ? replacement : () => replacement }
    })
  }

  // Runs in the page world of one frame, stringified: replaces text as the page renders it, batched per
  // frame. Called again with other rules it starts over; with null it stops and puts the page's text back.
  function replaceText(rules, json) {
    const key = Symbol.for('lilo.textReplace')
    const running = window[key]
    if (running?.json === json) return running
    running?.stop()
    if (!rules) return null
    const replace = text => rules.reduce((result, { regex, replacement }) => result.replace(regex, replacement), text)
    const skipped = new Set(['script', 'style', 'noscript', 'template'])
    const attributes = ['title', 'alt', 'aria-label', 'placeholder']
    const fields = new Map([HTMLInputElement, HTMLTextAreaElement].map(type => [type.prototype, Object.getOwnPropertyDescriptor(type.prototype, 'value')]))
    const field = node => fields.get(node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype)
    const isField = node => (node.localName === 'input' && node.type !== 'hidden') || node.localName === 'textarea'
    // What each node showed before, put back on stop where the page has not changed it since.
    const originals = new WeakMap()
    const changed = new Set()
    // Closed shadow roots are reachable only from attachShadow.
    const shadows = new WeakMap()
    const watched = new WeakSet()
    const pending = new Set()
    const attributeTargets = new Set()
    let frame = 0
    let timer = 0

    const read = (node, name) => name === 'data' ? node.data : name === 'value' ? field(node).get.call(node) : node.getAttribute(name)
    const write = (node, name, value) => {
      if (name === 'data') node.data = value
      else if (name === 'value') field(node).set.call(node, value)
      else node.setAttribute(name, value)
    }
    function fix(node, name) {
      const value = read(node, name)
      if (!value) return
      const next = replace(value)
      if (next === value) return
      let saved = originals.get(node)
      if (!saved) {
        originals.set(node, saved = new Map())
        changed.add(new WeakRef(node))
      }
      saved.set(name, [value, next])
      write(node, name, next)
    }
    function fixElement(element) {
      for (const name of attributes) fix(element, name)
      if (isField(element)) fix(element, 'value')
    }
    function walk(root, onElement, onText) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode: node => skipped.has(node.localName) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
      })
      for (let node = root; node; node = walker.nextNode()) {
        if (node.nodeType === Node.TEXT_NODE) onText(node)
        if (node.nodeType !== Node.ELEMENT_NODE) continue
        onElement(node)
        const shadow = node.shadowRoot ?? shadows.get(node)
        if (shadow) {
          watch(shadow)
          walk(shadow, onElement, onText)
        }
      }
    }
    function visit(node) {
      if (skipped.has(node.localName) || skipped.has(node.parentNode?.localName)) return
      walk(node, fixElement, text => fix(text, 'data'))
    }

    const options = { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: [...attributes, 'value'] }
    function note(records) {
      for (const record of records) {
        if (record.type === 'attributes') attributeTargets.add(record.target)
        else if (record.type === 'characterData') pending.add(record.target)
        else for (const node of record.addedNodes) pending.add(node)
      }
    }
    function flush() {
      note(observer.takeRecords())
      cancelAnimationFrame(frame)
      clearTimeout(timer)
      frame = 0
      for (const element of attributeTargets) if (element.isConnected) fixElement(element)
      for (const node of pending) if (node.isConnected) visit(node)
      attributeTargets.clear()
      pending.clear()
      // The records of the replacements themselves.
      observer.takeRecords()
    }
    const observer = new MutationObserver(records => {
      note(records)
      if (frame || !(pending.size || attributeTargets.size)) return
      // Before the frame paints; the timer covers a page that renders no frames.
      frame = requestAnimationFrame(flush)
      timer = setTimeout(flush, 250)
    })
    function watch(root) {
      if (watched.has(root)) return
      watched.add(root)
      observer.observe(root, options)
    }

    // A value the page sets never shows in a mutation.
    const patched = new Map()
    for (const [prototype, descriptor] of fields) {
      const replacing = { ...descriptor, set(value) { descriptor.set.call(this, value); if (isField(this)) fix(this, 'value') } }
      Object.defineProperty(prototype, 'value', replacing)
      patched.set(prototype, replacing)
    }
    const attachShadow = Element.prototype.attachShadow
    const attaching = function (...args) {
      const shadow = attachShadow.apply(this, args)
      shadows.set(this, shadow)
      watch(shadow)
      return shadow
    }
    Element.prototype.attachShadow = attaching
    const typed = event => {
      const target = event.composedPath()[0]
      if (target?.localName && isField(target)) fix(target, 'value')
    }
    window.addEventListener('input', typed, true)

    function stop() {
      observer.disconnect()
      cancelAnimationFrame(frame)
      clearTimeout(timer)
      window.removeEventListener('input', typed, true)
      for (const [prototype, descriptor] of fields) {
        if (Object.getOwnPropertyDescriptor(prototype, 'value')?.set === patched.get(prototype).set) Object.defineProperty(prototype, 'value', descriptor)
      }
      if (Element.prototype.attachShadow === attaching) Element.prototype.attachShadow = attachShadow
      for (const ref of changed) {
        const node = ref.deref()
        for (const [name, [original, replaced]] of (node && originals.get(node)) ?? []) {
          if (read(node, name) === replaced) write(node, name, original)
        }
      }
      delete window[key]
    }
    const instance = {
      json, stop, flush,
      // A setter the page took before this script ran skips the patched one.
      fixField: element => fix(element, 'value'),
      shadowOf: element => element.shadowRoot ?? shadows.get(element)
    }
    Object.defineProperty(window, key, { value: instance, configurable: true })
    watch(document)
    visit(document)
    observer.takeRecords()
    return instance
  }

  // Runs in the page world of one frame, stringified: where `rules` still match what a capture would show,
  // the rendered text (across elements, so a name split by markup counts too) and the fields.
  function findText(rules) {
    const running = window[Symbol.for('lilo.textReplace')]
    running?.flush()
    const found = []
    const check = (text, what) => {
      for (const { pattern, regex } of rules) {
        regex.lastIndex = 0
        const match = text && regex.exec(text)
        if (match) found.push(`${pattern} in ${what} "${text.slice(Math.max(0, match.index - 20), match.index + match[0].length + 20).trim()}"`)
      }
    }
    check(document.body?.innerText, 'the text')
    const visit = root => {
      for (const element of root.querySelectorAll('*')) {
        if ((element.localName === 'input' && element.type !== 'hidden') || element.localName === 'textarea') {
          running?.fixField(element)
          if (element.checkVisibility?.({ visibilityProperty: true, opacityProperty: true }) !== false) {
            check(element.value, 'a field value')
            if (!element.value) check(element.placeholder, 'a placeholder')
          }
        }
        const shadow = running?.shadowOf(element) ?? element.shadowRoot
        if (!shadow) continue
        for (const child of shadow.children) check(child.innerText, 'shadow DOM text')
        visit(shadow)
      }
    }
    visit(document)
    return found
  }

  const guardedPairs = guard => Array.isArray(guard) ? guard.map(pattern => [pattern, '']) : []

  const replacer = pairs => `(${replaceText})(${pairs ? `(${textRules})(${JSON.stringify(pairs)})` : 'null'}, ${JSON.stringify(JSON.stringify(pairs ?? null))})`

  // The page has one bootstrap script: textReplace and initScript share it.
  function bootstrap(page, { textReplace, initScript }) {
    const source = [textReplace && replacer(textReplace), initScript != null && String(initScript)].filter(Boolean).join(';\n')
    return page.setBootstrapScript.invoke(source ? { source } : {})
  }

  // Runs `expression` in the page world of every frame the inspector knows; a frame gone meanwhile gives null.
  function inFrames(expression) {
    return Promise.all(WI.networkManager.frames.map(frame => {
      const context = frame.pageExecutionContext
      return context?.target.RuntimeAgent.evaluate.invoke({
        expression, contextId: context.id, returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true
      }).then(response => ({ frame, response }), () => null) ?? null
    }))
  }

  const emulationChoices = {
    colorScheme: ['light', 'dark'], reducedMotion: ['reduce', 'no-preference'], contrast: ['more', 'no-preference'], media: ['print', 'screen']
  }

  function appliers(target) {
    const page = target.PageAgent
    const network = target.NetworkAgent
    const preference = (name, values) => value => page.overrideUserPreference.invoke(value == null ? { name } : { name, value: values[value] })
    const setting = name => value => page.overrideSetting.invoke(value == null ? { setting: name } : { setting: name, value: !!value })
    return {
      userAgent: value => page.overrideUserAgent.invoke(value == null ? {} : { value: String(value) }),
      colorScheme: preference('PrefersColorScheme', { light: 'Light', dark: 'Dark' }),
      reducedMotion: preference('PrefersReducedMotion', { reduce: 'Reduce', 'no-preference': 'NoPreference' }),
      contrast: preference('PrefersContrast', { more: 'More', 'no-preference': 'NoPreference' }),
      media: value => {
        // Each new page's DOM tree view sets the media type from the frontend's print styles toggle.
        WI.printStylesEnabled = value === 'print'
        return page.setEmulatedMedia.invoke({ media: value ?? '' })
      },
      javascript: setting('ScriptEnabled'),
      images: setting('ImagesEnabled'),
      cache: value => network.setResourceCachingDisabled.invoke({ disabled: value === false }),
      extraHeaders: value => network.setExtraHTTPHeaders.invoke({ headers: value ?? {} }),
      initScript: value => bootstrap(page, { ...emulation, initScript: value }),
      textReplace: async value => {
        await bootstrap(page, { ...emulation, textReplace: value })
        await inFrames(replacer(value))
      },
      textReplaceGuard: async () => {}
    }
  }

  // A cross-site navigation swaps the page's process, and its new target starts with nothing: give it
  // the agent's rules and emulation again, before the paused target resumes and loads the page.
  const prepared = new WeakSet()
  function prepare(target) {
    if (prepared.has(target) || !target.PageAgent || !target.NetworkAgent) return
    prepared.add(target)
    const applied = []
    for (const rule of rules) {
      if (applied.some(r => sameInterception(r, rule))) continue
      applied.push(rule)
      intercept(target, rule).catch(() => {})
    }
    const apply = appliers(target)
    for (const [key, value] of Object.entries(emulation)) apply[key](value).catch(() => {})
  }
  const resumeIfPaused = WI.Target.prototype._resumeIfPaused
  if (typeof resumeIfPaused === 'function') {
    WI.Target.prototype._resumeIfPaused = function () {
      prepare(this)
      return resumeIfPaused.call(this)
    }
  }
  // Each new document of a frame gets textReplace as its page world starts: the bootstrap script only
  // reaches the main frame's.
  const contextCreated = WI.RuntimeObserver.prototype.executionContextCreated
  if (typeof contextCreated === 'function') {
    WI.RuntimeObserver.prototype.executionContextCreated = function (payload) {
      if (emulation.textReplace && WI.ExecutionContext.typeFromPayload(payload) === WI.ExecutionContext.Type.Normal) {
        this._target.RuntimeAgent.evaluate.invoke({
          expression: replacer(emulation.textReplace), contextId: payload.id, returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true
        }).catch(() => {})
      }
      return contextCreated.call(this, payload)
    }
  }
  WI.targetManager.addEventListener(WI.TargetManager.Event.TargetAdded, event => {
    const target = event.data.target
    prepare(target)
    // The profile follows the page into its new process; the samples of the one left are lost with it.
    if (profile && !profile.capped && target.ScriptProfilerAgent) {
      profile.targets.push(target)
      startInstruments(target).catch(() => {})
    }
  })

  // A command to a gone target never answers.
  WI.targetManager.addEventListener(WI.TargetManager.Event.TargetRemoved, event => {
    if (profile) profile.targets = profile.targets.filter(target => target !== event.data.target)
  })

  // Timings come from the network: the event of a response reaches the frontend once the page's busy
  // thread gets to it, while the end of a load carries when the last byte came.
  function describe(entry) {
    const response = entry.response ?? {}
    const start = response.timing?.startTime ?? entry.startedAt
    const ttfb = response.timing?.responseStart > 0 ? response.timing.responseStart : entry.responseAt != null ? (entry.responseAt - start) * 1000 : null
    return {
      method: entry.request.method, url: entry.request.url, type: entry.type,
      status: response.status ?? null, statusText: response.statusText ?? null, mimeType: response.mimeType ?? null,
      source: response.source ?? null, ttfbMs: ttfb == null ? null : Math.round(ttfb),
      durationMs: entry.endedAt == null ? null : Math.max(Math.round((entry.endedAt - start) * 1000), Math.round(ttfb ?? 0)),
      sizeBytes: entry.metrics?.responseBodyDecodedSize ?? (entry.received || null),
      transferBytes: entry.metrics?.responseBodyBytesReceived ?? (entry.encoded || null),
      failed: entry.failed ?? false
    }
  }

  // A response still coming is waited for a moment: its body and its timings come with its end.
  async function finished(entries) {
    for (let waited = 0; waited < 1000 && entries.some(entry => !entry.endedAt); waited += 50) {
      await new Promise(resolve => setTimeout(resolve, 50))
    }
  }

  const cut = (text, maxChars) => text.length > maxChars ? `${text.slice(0, maxChars)}... (${maxChars} of ${text.length} characters)` : text

  // A JSON value's structure without its data: each key's type, and each array's length and first item.
  function shape(value, depth = 0) {
    if (Array.isArray(value)) return value.length ? [`${value.length} items`, depth < 5 ? shape(value[0], depth + 1) : '...'] : []
    if (value && typeof value === 'object') {
      if (depth >= 5) return '{...}'
      const keys = Object.keys(value)
      const result = Object.fromEntries(keys.slice(0, 40).map(key => [key, shape(value[key], depth + 1)]))
      if (keys.length > 40) result['...'] = `${keys.length - 40} more keys`
      return result
    }
    return typeof value === 'string' ? `string (${value.length})` : value === null ? 'null' : typeof value
  }

  // The response body as text, or its size when binary; nothing for a request still loading or failed.
  async function body(requestId, entry, maxChars) {
    if (!entry.endedAt || entry.failed || entry.redirect || entry.response?.source === 'memory-cache') return {}
    try {
      const { body, base64Encoded } = await WI.mainTarget.NetworkAgent.getResponseBody.invoke({ requestId })
      const mimeType = entry.response?.mimeType ?? ''
      const isText = /^(text\/|application\/(json|javascript|xml|.*\+json|.*\+xml))|svg/.test(mimeType)
      const headers = entry.response?.headers ?? {}
      const charset = /charset=["']?([\w-]+)/i.exec(headers['Content-Type'] ?? headers['content-type'] ?? '')?.[1]
      const decode = bytes => {
        try { return new TextDecoder(charset ?? 'utf-8').decode(bytes) } catch { return new TextDecoder().decode(bytes) }
      }
      const text = !base64Encoded ? body : isText ? decode(Uint8Array.from(atob(body), c => c.charCodeAt(0))) : null
      if (text === null) {
        const bytes = Math.floor(body.length * 3 / 4) - (body.endsWith('==') ? 2 : body.endsWith('=') ? 1 : 0)
        return { body: `(binary, ${bytes} bytes)`, raw: { text: body, encoding: 'base64' } }
      }
      const shown = { body: cut(text, maxChars), raw: { text } }
      // The HAR asks for no cut text (0): it has no use for a shape either.
      if (maxChars > 0 && text.length > maxChars && /json/.test(mimeType)) {
        try { shown.bodyShape = shape(JSON.parse(text)) } catch {}
      }
      return shown
    } catch (error) {
      return { body: `(unavailable: ${error.message})` }
    }
  }

  async function archive(matches) {
    const pairs = headers => Object.entries(headers ?? {}).map(([name, value]) => ({ name, value: String(value) }))
    const entries = await Promise.all(matches.map(async ([requestId, entry]) => {
      const described = describe(entry)
      const { raw } = await body(requestId, entry, 0)
      const contentType = Object.entries(entry.request.headers ?? {}).find(([name]) => name.toLowerCase() === 'content-type')?.[1] ?? ''
      let queryString = []
      try { queryString = [...new URL(described.url).searchParams].map(([name, value]) => ({ name, value })) } catch {}
      return {
        startedDateTime: new Date((entry.walltime ?? 0) * 1000).toISOString(),
        time: described.durationMs ?? 0,
        request: {
          method: described.method, url: described.url, httpVersion: '', headers: pairs(entry.request.headers), queryString, cookies: [],
          headersSize: -1, bodySize: entry.request.postData?.length ?? 0,
          ...(entry.request.postData ? { postData: { mimeType: contentType, text: entry.request.postData } } : {})
        },
        response: {
          status: described.status ?? 0, statusText: described.statusText ?? '', httpVersion: '', headers: pairs(entry.response?.headers),
          cookies: [], content: { size: described.sizeBytes ?? -1, mimeType: described.mimeType ?? '', ...raw },
          redirectURL: '', headersSize: -1, bodySize: described.transferBytes ?? -1
        },
        cache: {},
        timings: {
          send: 0, wait: described.ttfbMs ?? -1,
          receive: described.durationMs != null && described.ttfbMs != null ? described.durationMs - described.ttfbMs : -1
        }
      }
    }))
    return { log: { version: '1.2', creator: { name: 'Lilo', version: '1' }, pages: [], entries } }
  }

  // A DOM node's wrapper: the snapshot flags elements (documents aside), text and fragments go by class.
  const domClasses = new Set(['Text', 'Comment', 'CDATASection', 'DocumentFragment', 'ShadowRoot'])
  const cutURL = url => url.length > 150 ? `${url.slice(0, 150)}...` : url

  // The snapshot's objects and references, indexed for the retainer and detached tree queries.
  function heapGraph({ nodes, edges, nodeClassNames, edgeTypes, edgeNames }) {
    const classOf = new Map()
    const dom = new Set()
    for (let i = 0; i + 3 < nodes.length; i += 4) {
      const name = nodeClassNames[nodes[i + 2]]
      classOf.set(nodes[i], name)
      if ((nodes[i + 3] & 4 && !name.endsWith('Document')) || domClasses.has(name)) dom.add(nodes[i])
    }
    const outgoing = new Map()
    const incoming = new Map()
    const add = (map, key, e) => {
      const list = map.get(key)
      if (list) list.push(e)
      else map.set(key, [e])
    }
    for (let e = 0; e + 3 < edges.length; e += 4) {
      add(outgoing, edges[e], e)
      add(incoming, edges[e + 1], e)
    }
    const label = e => {
      const type = edgeTypes[edges[e + 2]]
      return type === 'Index' ? `[${edges[e + 3]}]` : type === 'Internal' ? '(internal)' : edgeNames[edges[e + 3]]
    }
    const isFunction = id => /Function$/.test(classOf.get(id) ?? '')
    // Each function's name and where it is defined, asked once.
    const names = new Map()
    const functionName = id => {
      if (!names.has(id)) {
        names.set(id, WI.mainTarget.HeapAgent.getPreview.invoke({ heapObjectId: id }).then(({ functionDetails: details }) => {
          if (!details) return null
          const script = WI.debuggerManager.scriptForIdentifier?.(details.location?.scriptId, WI.mainTarget)
          return `${details.displayName || details.name || '(anonymous)'}${script?.url ? ` ${cutURL(script.url)}:${details.location.lineNumber + 1}` : ''}`
        }, () => null))
      }
      return names.get(id)
    }
    // An object as its class; a function with its name, a closure's scope with a function keeping it.
    async function describe(id) {
      if (id === 0) return '<root>'
      const name = classOf.get(id) ?? '?'
      const holder = isFunction(id) ? id : name === 'JSLexicalEnvironment' ? (incoming.get(id) ?? []).map(e => edges[e]).find(isFunction) : null
      const fn = holder != null ? await functionName(holder) : null
      return !fn ? name : holder === id ? `${name} ${fn}` : `${name} (scope of ${fn})`
    }
    // The shortest chain of references from the roots to an object `isTarget` takes. The roots' own
    // references to DOM wrappers are the DOM tree keeping them, not a script: the path goes around them.
    async function pathTo(isTarget) {
      const parentEdge = new Map([[0, -1]])
      let queue = [0]
      let found = null
      while (queue.length && found === null) {
        const next = []
        for (const id of queue) {
          for (const e of outgoing.get(id) ?? []) {
            const to = edges[e + 1]
            if (parentEdge.has(to) || (id === 0 && dom.has(to))) continue
            parentEdge.set(to, e)
            if (isTarget(to)) { found = to; break }
            next.push(to)
          }
          if (found !== null) break
        }
        queue = next
      }
      if (found === null) return null
      const steps = []
      for (let id = found; parentEdge.get(id) >= 0; id = edges[parentEdge.get(id)]) {
        steps.unshift(`${label(parentEdge.get(id))} ${await describe(id)}`)
      }
      return ['<root>', ...steps].join(' -> ')
    }
    return { classOf, dom, edges, incoming, label, isFunction, describe, pathTo }
  }

  // The class's retainers, by what they are and the reference holding it, and the shortest path to one of
  // its objects from a garbage collection root.
  async function retainers(graph, className) {
    const { classOf, dom, edges, label, describe } = graph
    const targets = new Set([...classOf].filter(([, name]) => name === className).map(([id]) => id))
    if (!targets.size) throw new Error(`No object of class ${className} in the heap`)
    const referrers = [...targets].flatMap(id => graph.incoming.get(id) ?? [])
    // Functions and scopes are named, as long as there are not too many to ask about.
    const named = new Set(referrers.map(e => edges[e]).filter(id => graph.isFunction(id) || classOf.get(id) === 'JSLexicalEnvironment').slice(0, 300))
    const byRetainer = new Map()
    for (const e of referrers) {
      const from = edges[e]
      const key = `${named.has(from) ? await describe(from) : classOf.get(from) ?? '<root>'} ${label(e)}`
      byRetainer.set(key, (byRetainer.get(key) ?? 0) + 1)
    }
    const path = await graph.pathTo(id => targets.has(id))
    const isDOM = [...targets].some(id => dom.has(id))
    return {
      byRetainer: [...byRetainer].sort((a, b) => b[1] - a[1]).slice(0, 15).map(([retainer, count]) => ({ retainer, count })),
      pathFromRoot: path ?? (isDOM
        ? 'no script keeps one: their DOM tree does (a document, or a detached tree one of its nodes is kept)'
        : 'unreachable from the roots: garbage the next collection frees')
    }
  }

  // Runs in the page on DOM wrappers: for each, the index of its detached tree's root, -1 in a document.
  const detachedScript = `function (...nodes) {
    const roots = new Map()
    const rootOf = nodes.map(node => {
      if (node.isConnected) return -1
      let root = node
      while (root.parentNode) root = root.parentNode
      if (!roots.has(root)) roots.set(root, roots.size)
      return roots.get(root)
    })
    const describe = node => node.nodeType !== 1 ? node.nodeName
      : '<' + node.localName + (node.id ? '#' + node.id : '') + (node.classList.length ? '.' + [...node.classList].slice(0, 2).join('.') : '') + '>'
    return { rootOf, roots: [...roots.keys()].map(root => ({ root: describe(root), nodes: (root.querySelectorAll ? root.querySelectorAll('*').length : 0) + 1 })) }
  }`

  // DOM trees out of every document that something still keeps, the largest with what holds them.
  async function detachedTrees(graph) {
    const { HeapAgent, RuntimeAgent } = WI.mainTarget
    const candidates = [...graph.dom].slice(0, 5000)
    const group = 'lilo-detached'
    const objects = await Promise.all(candidates.map(id =>
      HeapAgent.getRemoteObject.invoke({ heapObjectId: id, objectGroup: group }).then(({ result }) => result, () => null)
    ))
    // One call per world: a function takes only objects of its own world.
    const byWorld = new Map()
    candidates.forEach((id, k) => {
      const objectId = objects[k]?.objectId
      if (!objectId) return
      let world = ''
      try { world = JSON.parse(objectId).injectedScriptId } catch {}
      byWorld.set(world, [...byWorld.get(world) ?? [], [id, objectId]])
    })
    const trees = []
    try {
      for (const wrappers of byWorld.values()) {
        const { result } = await RuntimeAgent.callFunctionOn.invoke({
          objectId: wrappers[0][1], functionDeclaration: detachedScript, arguments: wrappers.map(([, objectId]) => ({ objectId })), returnByValue: true
        })
        const { rootOf = [], roots = [] } = result?.value ?? {}
        const found = roots.map(root => ({ ...root, wrappers: new Set() }))
        wrappers.forEach(([id], k) => { if (rootOf[k] >= 0) found[rootOf[k]].wrappers.add(id) })
        trees.push(...found)
      }
    } finally {
      RuntimeAgent.releaseObjectGroup.invoke({ objectGroup: group }).catch(() => {})
    }
    trees.sort((a, b) => b.nodes - a.nodes)
    const largest = []
    for (const tree of trees.slice(0, 5)) {
      // What holds the tree: the scripts' references to its nodes, not the structures describing them.
      const holding = [...tree.wrappers].flatMap(id => graph.incoming.get(id) ?? []).filter(e => {
        const from = graph.edges[e]
        return from !== 0 && !tree.wrappers.has(from) && !graph.classOf.get(from)?.startsWith('Structure')
      })
      const keptBy = [...new Set(await Promise.all(holding.slice(0, 20).map(async e => `${await graph.describe(graph.edges[e])} ${graph.label(e)}`)))]
      largest.push({
        root: tree.root, nodes: tree.nodes, keptBy: keptBy.slice(0, 3),
        pathFromRoot: await graph.pathTo(id => tree.wrappers.has(id)) ?? 'no path from a root'
      })
    }
    return { trees: trees.length, nodes: trees.reduce((sum, tree) => sum + tree.nodes, 0), largest }
  }

  // A collection frees the wrappers it finds dead, but the DOM nodes they held go after it, and what those
  // nodes kept only with the next one.
  async function collectGarbage() {
    for (let i = 0; i < 3; i++) {
      await WI.mainTarget.HeapAgent.gc.invoke({})
      await new Promise(resolve => setTimeout(resolve, 50))
    }
  }

  const callable = (method) => {
    const [domain, command] = method.split('.')
    const fn = WI.mainTarget?.[domain + 'Agent']?.[command]
    if (typeof fn?.invoke !== 'function') throw new Error(`Unknown command ${method}: call devtools_command without method for the list`)
    return fn
  }

  window.__liloInspector = {
    send({ method, params }) {
      const fn = callable(method)
      tracked.add(method.split('.')[0])
      // Released at the next page load: with no group, an evaluated object lives as long as its page's injected script.
      if (method === 'Runtime.evaluate' && params?.objectGroup == null) params = { ...params, objectGroup: agentObjectGroup }
      return fn.invoke(params ?? {})
    },
    commands() {
      return [...WI.mainTarget._supportedCommandParameters.keys()].sort().join('\n')
    },
    events({ prefix = '', limit = 50, clear = false }) {
      drainBackendMessages()
      const count = Math.max(1, Math.min(limit | 0, maxEvents))
      const matching = events.filter(e => e.method.startsWith(prefix)).slice(-count).map(e => e.text)
      if (clear) events.length = 0
      return matching.join('\n')
    },
    async addRule(rule) {
      const outcomes = ['response', 'error', 'modify'].filter(key => rule[key] != null)
      if (outcomes.length > 1) throw new Error('Pass one of response, error or modify')
      const stage = rule.stage ?? 'request'
      if (!['request', 'response'].includes(stage)) throw new Error('stage is request or response')
      if (stage === 'response' && outcomes[0] && outcomes[0] !== 'response') throw new Error(`${outcomes[0]} works at the request stage only`)
      if (!rule.urlPattern) throw new Error('urlPattern is required')
      if (rules.length >= 100) throw new Error('At most 100 rules: remove some first')
      const regex = new RegExp(rule.urlPattern)
      if (rule.methods != null && (!Array.isArray(rule.methods) || !rule.methods.length)) throw new Error('methods is a list, like ["POST", "PUT"]')
      const methods = rule.methods?.map(method => String(method).toUpperCase())
      const bodyRegex = rule.bodyPattern != null ? new RegExp(rule.bodyPattern) : null
      const bodyJson = rule.bodyJson
      if (bodyJson != null && (typeof bodyJson !== 'object' || Array.isArray(bodyJson) || !Object.keys(bodyJson).length)) {
        throw new Error('bodyJson is an object of top-level fields, like {"operationName": "^GetUser$"}')
      }
      // A string is a regex over the field's value (its JSON when not a string); any other value must equal it.
      const bodyFields = bodyJson && Object.entries(bodyJson).map(([field, expected]) => {
        if (typeof expected !== 'string') return [field, value => JSON.stringify(value) === JSON.stringify(expected)]
        const regex = new RegExp(expected)
        return [field, value => value !== undefined && regex.test(typeof value === 'string' ? value : JSON.stringify(value))]
      })
      const added = { ...rule, methods, stage, regex, bodyRegex, bodyFields, id: nextRuleId++, hits: 0 }
      if (!rules.some(r => sameInterception(r, added))) await intercept(WI.mainTarget, added)
      rules.push(added)
      return added.id
    },
    async removeRule({ id }) {
      const index = rules.findIndex(r => r.id === id)
      if (index < 0) throw new Error(`No rule ${id}`)
      const [rule] = rules.splice(index, 1)
      await removeInterception(rule)
    },
    rules() {
      return rules.map(({ regex, bodyRegex, bodyFields, response, ...rule }) => ({
        ...rule, response: response && { ...response, body: undefined, bodyBase64: undefined }
      }))
    },
    async clearRules() {
      for (const rule of rules.splice(0)) await removeInterception(rule)
      for (const [requestId, { agent, stage }] of held) agent.interceptContinue.invoke({ requestId, stage }).catch(() => {})
      held.clear()
    },
    // One request in full, the most recent matching; with all, every matching one, oldest first; with
    // har, every matching one as a HAR archive.
    async response({ url = '', requestId: id, method, all = false, har = false, responseBody = true, maxChars }) {
      drainBackendMessages()
      const matches = id != null
        ? [...requests].filter(([requestId]) => requestId === String(id))
        : [...requests].filter(([, entry]) => (!method || entry.request.method === method.toUpperCase()) && entry.request.url?.includes(url))
      if (!matches.length) {
        throw new Error(id != null ? `No request ${id}` : `No request to ${url || 'any URL'} since the inspector connected: reload the tab, then ask again`)
      }
      if (all || har) await finished(matches.slice(-200).map(([, entry]) => entry))
      if (har) return JSON.stringify(await archive(matches))
      if (all) {
        const origin = Math.min(...matches.map(([, entry]) => entry.startedAt))
        const listed = await Promise.all(matches.slice(-200).map(async ([requestId, entry]) => {
          const result = { requestId, ...describe(entry), startMs: Math.round((entry.startedAt - origin) * 1000) }
          if (entry.request.postData) result.requestBody = cut(entry.request.postData, maxChars ?? 2000)
          if (!responseBody) return result
          const { raw, ...shown } = await body(requestId, entry, maxChars ?? 2000)
          return Object.assign(result, shown)
        }))
        return JSON.stringify(listed, null, 2)
      }
      const exact = matches.filter(([, entry]) => entry.request.url === url)
      const [requestId, entry] = (exact.length ? exact : matches).at(-1)
      await finished([entry])
      const result = { requestId, ...describe(entry), requestHeaders: entry.request.headers, responseHeaders: entry.response?.headers ?? null }
      if (entry.request.postData) result.requestBody = cut(entry.request.postData, maxChars ?? 5000)
      if (!responseBody) return JSON.stringify(result, null, 2)
      const { raw, ...shown } = await body(requestId, entry, maxChars ?? 5000)
      return JSON.stringify(Object.assign(result, shown), null, 2)
    },
    // read_network_requests while the inspector is connected: the same requests, ids and timings as network_response.
    list({ urlPattern = '', exclude = [], limit = 50 }) {
      drainBackendMessages()
      let shownPage
      const shown = url => url?.includes(urlPattern) && !exclude.some(text => text && url.includes(text))
      // By page load, so a late request of the page left stays with it: sort keeps the order inside each.
      const matching = [...requests].filter(([, entry]) => shown(entry.request.url)).sort((a, b) => a[1].page.index - b[1].page.index)
      return matching.slice(-Math.max(1, limit | 0)).map(([requestId, entry]) => {
        const { method, url, status, failed, mimeType, sizeBytes, durationMs } = describe(entry)
        const details = [mimeType, sizeBytes != null && `${sizeBytes} B`, durationMs != null && `${durationMs} ms`].filter(Boolean)
        const line = `${requestId} ${method} ${failed ? 'failed' : status ?? 'pending'} ${url}${details.length ? ` (${details.join(', ')})` : ''}`
        if (entry.page === shownPage) return line
        shownPage = entry.page
        return `-- Page load: ${entry.page.url ?? 'the page shown when the inspector connected'}\n${line}`
      }).join('\n')
    },
    // Applies the given fields, null resetting one; returns every field set now.
    async emulate(changes) {
      const apply = appliers(WI.mainTarget)
      // Everything is checked first: a bad field must not leave the ones before it applied.
      for (const [key, value] of Object.entries(changes)) {
        if (!apply[key]) throw new Error(`Unknown emulation field ${key}`)
        if (value != null && emulationChoices[key] && !emulationChoices[key].includes(value)) {
          throw new Error(`${key}: ${emulationChoices[key].join(' or ')}`)
        }
        if (key === 'textReplace' && value != null) textRules(value)
        if (key === 'textReplaceGuard' && value != null) {
          if (typeof value !== 'boolean' && (!Array.isArray(value) || !value.length || value.some(pattern => typeof pattern !== 'string'))) {
            throw new Error('textReplaceGuard: true, or a list of patterns')
          }
          if (Array.isArray(value)) textRules(guardedPairs(value))
        }
      }
      for (const [key, value] of Object.entries(changes)) {
        await apply[key](value)
        if (value == null) delete emulation[key]
        else emulation[key] = value
      }
      const state = { ...emulation }
      if (state.initScript != null) state.initScript = `(${String(state.initScript).length} characters)`
      return state
    },
    // What textReplaceGuard refuses a capture for, null when nothing matches.
    async textLeaks() {
      const pairs = [...emulation.textReplace ?? [], ...guardedPairs(emulation.textReplaceGuard)]
      if (!emulation.textReplaceGuard || !pairs.length) return null
      const found = []
      for (const result of await inFrames(`(${findText})((${textRules})(${JSON.stringify(pairs)}))`)) {
        if (!result) continue
        const { frame, response } = result
        if (response.wasThrown) found.push(`the check failed in ${frame.url}`)
        else found.push(...(response.result?.value ?? []).map(leak => `${leak} (${frame.url})`))
      }
      if (!found.length) return null
      return `textReplaceGuard: a guarded pattern is still visible, no capture taken. ${found.slice(0, 3).join('; ')}`
    },
    async startProfile({ screenshots = false }) {
      if (profile) throw new Error('A profile is already running: call performance stop')
      const target = WI.mainTarget
      profile = { startedAt: Date.now(), messages: [], targets: [target], screenshots }
      lastProfile = null
      try {
        await startInstruments(target)
      } catch (error) {
        await stopInstruments()
        profile = null
        throw error
      }
    },
    async stopProfile(options) {
      if (!profile) throw new Error('Call performance start first')
      const running = profile
      await stopInstruments()
      // The sampling profiler sends its samples once tracking completes, long after a long profile.
      const deadline = Date.now() + 10000
      while (!running.messages.some(m => m.method === 'ScriptProfiler.trackingComplete') && Date.now() < deadline) {
        await new Promise(resolve => setTimeout(resolve, 50))
      }
      profile = null
      lastProfile = { messages: running.messages, durationMs: Date.now() - running.startedAt, pageURL: options.pageURL, capped: running.capped }
      const summary = summarize(lastProfile, options)
      if (running.capped) summary.stoppedEarly = `${maxProfileMessages} messages recorded: the profile stopped there`
      pendingRaw = JSON.stringify(running.messages)
      return summary
    },
    summarizeProfile(options) {
      if (!lastProfile) throw new Error('No profile yet: call performance start, then stop')
      return summarize(lastProfile, options)
    },
    async heapSnapshot({ className }) {
      // Without it, the next snapshot frees what this one still counted, and its growth reads as a leak.
      await collectGarbage()
      const { snapshotData } = await WI.mainTarget.HeapAgent.snapshot.invoke({})
      const snapshot = JSON.parse(snapshotData)
      // Each node is id, size, class name index, flags.
      const classes = new Map()
      for (let i = 0; i + 3 < snapshot.nodes.length; i += 4) {
        const name = snapshot.nodeClassNames[snapshot.nodes[i + 2]]
        const entry = classes.get(name) ?? { count: 0, bytes: 0 }
        entry.count++
        entry.bytes += snapshot.nodes[i + 1]
        classes.set(name, entry)
      }
      const top = key => [...classes].sort((a, b) => b[1][key] - a[1][key]).slice(0, 20).map(([name, entry]) => ({ class: name, ...entry }))
      const summary = { byCount: top('count'), byBytes: top('bytes') }
      if (previousHeap) {
        const growth = new Map([...classes].map(([name, entry]) => {
          const before = previousHeap.get(name) ?? { count: 0, bytes: 0 }
          return [name, { count: entry.count - before.count, bytes: entry.bytes - before.bytes }]
        }))
        for (const [name, before] of previousHeap) if (!classes.has(name)) growth.set(name, { count: -before.count, bytes: -before.bytes })
        summary.sincePrevious = [...growth].filter(([, entry]) => entry.count || entry.bytes)
          .sort((a, b) => Math.abs(b[1].bytes) - Math.abs(a[1].bytes)).slice(0, 20).map(([name, entry]) => ({ class: name, ...entry }))
      }
      previousHeap = classes
      const graph = heapGraph(snapshot)
      try {
        summary.detachedDOM = await detachedTrees(graph)
      } catch (error) {
        summary.detachedDOM = `unavailable: ${error.message ?? error}`
      }
      if (className) summary.retainers = await retainers(graph, className)
      pendingRaw = snapshotData
      return summary
    },
    collectGarbage,
    // A memory sample by category: the running profile's latest, else one taken now.
    async memory() {
      if (!profile) {
        lastMemory = null
        await WI.mainTarget.MemoryAgent.startTracking.invoke({})
        for (let waited = 0; !lastMemory && waited < 2000; waited += 50) await new Promise(resolve => setTimeout(resolve, 50))
        await WI.mainTarget.MemoryAgent.stopTracking.invoke({}).catch(() => {})
      }
      return Object.fromEntries((lastMemory?.categories ?? []).map(({ type, size }) => [type, Math.round(size / 104857.6) / 10]))
    },
    // The next piece of the last profile or snapshot's JSON, from `from`; the last piece lets it go.
    rawChunk({ from, length }) {
      let end = Math.min(from + length, pendingRaw.length)
      // A piece ending between the two halves of a surrogate pair would break the character.
      if (end < pendingRaw.length && /[\uD800-\uDBFF]/.test(pendingRaw[end - 1])) end--
      const text = pendingRaw.slice(from, end)
      if (end >= pendingRaw.length) pendingRaw = ''
      return { text, next: end }
    },
    track({ domains }) {
      for (const domain of domains) tracked.add(domain)
    },
    async reset() {
      tracked.clear()
      events.length = 0
      lastProfile = null
      previousHeap = null
      pendingRaw = ''
      if (profile) {
        await stopInstruments()
        profile = null
      }
      await window.__liloInspector.clearRules()
      await window.__liloInspector.emulate(Object.fromEntries(Object.keys(emulation).map(key => [key, null])))
    }
  }
})()

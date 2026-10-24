// Runs after AgentInspector.js in a tab's Web Inspector frontend: speaks the Chrome DevTools Protocol
// for chrome.debugger over WebKit's inspector protocol. Commands come from cdpSend; events of the CDP
// domains some extension enabled go to native through the liloDebuggerEvent handler.
(() => {
  const inspector = window.__liloInspector
  if (!inspector || inspector.cdpSend) return
  // CDP domains an attached extension enabled; nothing is translated while empty.
  let enabled = new Set()
  let exceptionCount = 0
  // Emulation and new-document scripts the extensions set, undone when the last one detaches.
  const overrides = new Map()
  const newDocumentScripts = new Map()
  let nextScriptId = 1

  class ProtocolError extends Error {
    constructor (code, message) {
      super(message)
      this.code = code
    }
  }
  const notFound = method => new ProtocolError(-32601, `'${method}' wasn't found`)
  const agent = domain => {
    const found = WI.mainTarget?.[domain + 'Agent']
    if (!found) throw new ProtocolError(-32000, 'Target is not available')
    return found
  }
  const runtime = () => agent('Runtime')
  const page = () => agent('Page')
  const dom = () => agent('DOM')
  const network = () => agent('Network')
  // WebKit's invoke rejects an explicit undefined for a typed parameter.
  const defined = object => Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined))

  // MARK: - Shapes

  const unserializable = new Set(['NaN', 'Infinity', '-Infinity', '-0'])
  function remote (object) {
    if (!object) return object
    const { size, classPrototype, ...out } = object
    if (object.type === 'number' && unserializable.has(object.description)) {
      out.unserializableValue = object.description
      delete out.value
    } else if (object.type === 'bigint') {
      out.unserializableValue = object.description.endsWith('n') ? object.description : `${object.description}n`
      delete out.value
    } else if (object.subtype === 'class') {
      delete out.subtype
    } else if (object.type === 'object' && !object.subtype && object.className === 'Promise') {
      out.subtype = 'promise'
    }
    return out
  }

  function evaluation (response) {
    const result = remote(response.result)
    if (!response.wasThrown) return { result }
    const text = result?.description?.split('\n')[0] ?? 'Uncaught'
    return { result, exceptionDetails: { exceptionId: ++exceptionCount, text: `Uncaught ${text}`, lineNumber: 0, columnNumber: 0, exception: result } }
  }

  function node (payload) {
    if (!payload) return payload
    const { layoutFlags, ...out } = payload
    out.backendNodeId = payload.nodeId
    for (const key of ['children', 'shadowRoots', 'pseudoElements']) if (payload[key]) out[key] = payload[key].map(node)
    for (const key of ['contentDocument', 'templateContent']) if (payload[key]) out[key] = node(payload[key])
    return out
  }

  function frame (payload) {
    const secure = /^(https|wss|file):/.test(payload.url ?? '') || payload.url === 'about:blank'
    return {
      ...payload,
      domainAndRegistry: '',
      secureContextType: secure ? 'Secure' : 'InsecureScheme',
      crossOriginIsolatedContextType: 'NotIsolated',
      gatedAPIFeatures: []
    }
  }

  function frameTree (tree, withResources) {
    const out = { frame: frame(tree.frame) }
    if (tree.childFrames) out.childFrames = tree.childFrames.map(child => frameTree(child, withResources))
    if (withResources) out.resources = (tree.resources ?? []).map(resource => ({ ...resource, type: resourceType(resource.type) }))
    return out
  }

  const resourceTypes = { StyleSheet: 'Stylesheet', Beacon: 'Ping' }
  const resourceType = type => resourceTypes[type] ?? type ?? 'Other'

  function response (payload) {
    if (!payload) return payload
    const { source, security, ...out } = payload
    return {
      ...out,
      fromDiskCache: source === 'disk-cache',
      fromServiceWorker: source === 'service-worker',
      fromPrefetchCache: false,
      connectionReused: false,
      connectionId: 0,
      encodedDataLength: 0,
      securityState: /^(https|wss):/.test(payload.url ?? '') ? 'secure' : 'neutral'
    }
  }

  function executionContexts () {
    const contexts = []
    for (const found of WI.networkManager.frames ?? []) {
      const context = found.pageExecutionContext
      if (!context) continue
      contexts.push({
        id: context.id,
        origin: found.securityOrigin ?? '',
        name: '',
        uniqueId: String(context.id),
        auxData: { isDefault: true, type: 'default', frameId: found.id }
      })
    }
    return contexts
  }

  // MARK: - Events

  const consoleTypes = { warning: 'warning', error: 'error', info: 'info', debug: 'debug' }
  const domEvents = new Set([
    'DOM.documentUpdated', 'DOM.attributeModified', 'DOM.attributeRemoved', 'DOM.inlineStyleInvalidated',
    'DOM.characterDataModified', 'DOM.childNodeCountUpdated', 'DOM.childNodeRemoved', 'DOM.shadowRootPopped',
    'DOM.pseudoElementRemoved'
  ])
  const passedEvents = new Set([
    'Network.dataReceived', 'Network.webSocketCreated', 'Network.webSocketClosed', 'Network.webSocketFrameSent',
    'Network.webSocketFrameReceived', 'Network.webSocketFrameError', 'Network.webSocketHandshakeResponseReceived',
    'Page.loadEventFired', 'Page.domContentEventFired'
  ])

  // Each WebKit event as the CDP events it stands for; an empty list drops it.
  function translate (method, params) {
    if (passedEvents.has(method) || domEvents.has(method)) return [[method, params]]
    switch (method) {
      case 'Network.requestWillBeSent': {
        const { walltime, targetId, ...rest } = params
        const request = { ...params.request, hasPostData: params.request?.postData != null, initialPriority: 'High' }
        request.referrerPolicy ??= 'strict-origin-when-cross-origin'
        return [[method, {
          ...rest, request, wallTime: walltime, type: resourceType(params.type), redirectHasExtraInfo: false,
          redirectResponse: params.redirectResponse ? response(params.redirectResponse) : undefined
        }]]
      }
      case 'Network.responseReceived':
        return [[method, { ...params, type: resourceType(params.type), response: response(params.response), hasExtraInfo: false }]]
      case 'Network.loadingFinished': {
        const metrics = params.metrics ?? {}
        const encodedDataLength = (metrics.responseHeaderBytesReceived ?? 0) + (metrics.responseBodyBytesReceived ?? 0)
        return [[method, { requestId: params.requestId, timestamp: params.timestamp, encodedDataLength }]]
      }
      case 'Network.loadingFailed':
        return [[method, { requestId: params.requestId, timestamp: params.timestamp, type: 'Other', errorText: params.errorText, canceled: !!params.canceled }]]
      case 'Network.requestServedFromMemoryCache':
        return [[method, { requestId: params.requestId }]]
      case 'Network.webSocketWillSendHandshakeRequest': {
        const { walltime, ...rest } = params
        return [[method, { ...rest, wallTime: walltime }]]
      }
      case 'Page.frameNavigated': {
        const events = [[method, { frame: frame(params.frame), type: 'Navigation' }]]
        if (!params.frame?.parentId) events.push(['Runtime.executionContextsCleared', {}])
        return events
      }
      case 'Page.frameDetached':
        return [[method, { frameId: params.frameId, reason: 'remove' }]]
      case 'Runtime.executionContextCreated': {
        const context = params.context
        if (context.type === 'internal') return []
        const origin = WI.networkManager.frameForIdentifier?.(context.frameId)?.securityOrigin ?? ''
        const isDefault = context.type === 'normal'
        return [[method, { context: { id: context.id, origin, name: context.name ?? '', uniqueId: String(context.id), auxData: { isDefault, type: isDefault ? 'default' : 'isolated', frameId: context.frameId } } }]]
      }
      case 'DOM.setChildNodes':
        return [[method, { parentId: params.parentId, nodes: (params.nodes ?? []).map(node) }]]
      case 'DOM.childNodeInserted':
        return [[method, { ...params, node: node(params.node) }]]
      case 'DOM.shadowRootPushed':
        return [[method, { hostId: params.hostId, root: node(params.root) }]]
      case 'DOM.pseudoElementAdded':
        return [[method, { parentId: params.parentId, pseudoElement: node(params.pseudoElement) }]]
      case 'Console.messageAdded': {
        const message = params.message ?? {}
        const stackTrace = message.stackTrace?.callFrames
          ? { callFrames: message.stackTrace.callFrames.map(({ functionName, url, scriptId, lineNumber, columnNumber }) => ({ functionName, url, scriptId: scriptId ?? '0', lineNumber, columnNumber })) }
          : undefined
        if (message.source === 'javascript' && message.level === 'error') {
          return [['Runtime.exceptionThrown', {
            timestamp: Date.now(),
            exceptionDetails: { exceptionId: ++exceptionCount, text: message.text, lineNumber: Math.max(0, (message.line ?? 1) - 1), columnNumber: Math.max(0, (message.column ?? 1) - 1), url: message.url, stackTrace }
          }]]
        }
        if (message.source !== 'console-api') return []
        const type = message.type === 'log' || !message.type ? consoleTypes[message.level] ?? 'log' : message.type
        const args = (message.parameters ?? [{ type: 'string', value: message.text }]).map(remote)
        const context = WI.networkManager.mainFrame?.pageExecutionContext?.id ?? 1
        return [['Runtime.consoleAPICalled', { type, args, executionContextId: context, timestamp: Date.now(), stackTrace }]]
      }
    }
    return []
  }

  const domainOf = method => method.slice(0, method.indexOf('.'))
  // Console messages are CDP Runtime events.
  const cdpDomain = { Console: 'Runtime' }

  const dispatchEvent = InspectorBackend.Connection.prototype._dispatchEvent
  if (typeof dispatchEvent === 'function') {
    InspectorBackend.Connection.prototype._dispatchEvent = function (message) {
      if (enabled.size) {
        const method = message.method ?? ''
        const domain = domainOf(method)
        if (enabled.has(cdpDomain[domain] ?? domain)) {
          try {
            for (const [name, params] of translate(method, message.params ?? {})) {
              window.webkit?.messageHandlers?.liloDebuggerEvent?.postMessage({ method: name, params: JSON.parse(JSON.stringify(params)) })
            }
          } catch {
            // A malformed event must never break the frontend's own dispatch.
          }
        }
      }
      return dispatchEvent.call(this, message)
    }
  }

  // MARK: - Commands

  async function nodeIdOf (params) {
    if (params.nodeId) return params.nodeId
    if (params.backendNodeId) return params.backendNodeId
    if (params.objectId) {
      // Pushing a node needs the document on the frontend.
      await new Promise(resolve => WI.domManager.requestDocument(resolve))
      return (await dom().requestNode.invoke({ objectId: params.objectId })).nodeId
    }
    throw new ProtocolError(-32000, 'Either nodeId, backendNodeId or objectId must be specified')
  }

  async function objectIdOf (params, objectGroup) {
    if (params.objectId) return params.objectId
    const { object } = await dom().resolveNode.invoke(defined({ nodeId: await nodeIdOf(params), objectGroup }))
    return object.objectId
  }

  /** What `functionDeclaration` returns, called on the node. */
  async function onNode (params, functionDeclaration) {
    const objectId = await objectIdOf(params, 'lilo-debugger')
    try {
      const response = await runtime().callFunctionOn.invoke({ objectId, functionDeclaration, returnByValue: true })
      if (response.wasThrown) throw new ProtocolError(-32000, response.result?.description ?? 'Could not run on the node')
      return response.result.value
    } finally {
      if (!params.objectId) runtime().releaseObject.invoke({ objectId }).catch(() => {})
    }
  }

  // CDP's quads, viewport coordinates: content, padding, border and margin edges.
  const boxModel = `function () {
    const r = this.getBoundingClientRect()
    const style = getComputedStyle(this)
    const edges = side => ['Top', 'Right', 'Bottom', 'Left'].map(edge => parseFloat(style[side.replace('*', edge)]) || 0)
    const quad = ([top, right, bottom, left], sign) => {
      const x1 = r.left - sign * left, y1 = r.top - sign * top, x2 = r.right + sign * right, y2 = r.bottom + sign * bottom
      return [x1, y1, x2, y1, x2, y2, x1, y2]
    }
    const border = edges('border*Width')
    const padding = edges('padding*')
    return {
      content: quad(border.map((width, i) => width + padding[i]), -1),
      padding: quad(border, -1),
      border: quad([0, 0, 0, 0], 1),
      margin: quad(edges('margin*'), 1),
      width: Math.round(r.width),
      height: Math.round(r.height)
    }
  }`

  async function screenshot (params) {
    const metrics = await layoutMetrics()
    const clip = params.clip
    const rect = clip
      ? { x: clip.x, y: clip.y, width: clip.width, height: clip.height, coordinateSystem: 'Page' }
      : { x: 0, y: 0, width: metrics.cssLayoutViewport.clientWidth, height: metrics.cssLayoutViewport.clientHeight, coordinateSystem: 'Viewport' }
    if (params.captureBeyondViewport && !clip) {
      Object.assign(rect, { width: metrics.cssContentSize.width, height: metrics.cssContentSize.height, coordinateSystem: 'Page' })
    }
    const { dataURL } = await page().snapshotRect.invoke(rect)
    if (params.format !== 'jpeg') return { data: dataURL.slice(dataURL.indexOf(',') + 1) }
    const image = new Image()
    image.src = dataURL
    await image.decode()
    const canvas = document.createElement('canvas')
    canvas.width = image.naturalWidth
    canvas.height = image.naturalHeight
    canvas.getContext('2d').drawImage(image, 0, 0)
    const jpeg = canvas.toDataURL('image/jpeg', (params.quality ?? 80) / 100)
    return { data: jpeg.slice(jpeg.indexOf(',') + 1) }
  }

  async function layoutMetrics () {
    const response = await runtime().evaluate.invoke({
      expression: `[scrollX, scrollY, innerWidth, innerHeight, document.documentElement.scrollWidth, document.documentElement.scrollHeight,
        visualViewport ? visualViewport.offsetLeft : 0, visualViewport ? visualViewport.offsetTop : 0,
        visualViewport ? visualViewport.width : innerWidth, visualViewport ? visualViewport.height : innerHeight,
        visualViewport ? visualViewport.scale : 1, document.documentElement.clientWidth, document.documentElement.clientHeight]`,
      returnByValue: true
    })
    const [pageX, pageY, , , width, height, offsetX, offsetY, visualWidth, visualHeight, scale, clientWidth, clientHeight] = response.result.value
    const layoutViewport = { pageX, pageY, clientWidth, clientHeight }
    const visualViewport = { offsetX, offsetY, pageX: pageX + offsetX, pageY: pageY + offsetY, clientWidth: visualWidth, clientHeight: visualHeight, scale, zoom: 1 }
    const contentSize = { x: 0, y: 0, width, height }
    return { layoutViewport, visualViewport, contentSize, cssLayoutViewport: layoutViewport, cssVisualViewport: visualViewport, cssContentSize: contentSize }
  }

  async function override (key, apply, value) {
    if (value == null && !overrides.has(key)) return {}
    await apply(value)
    if (value == null) overrides.delete(key)
    else overrides.set(key, apply)
    return {}
  }

  const preferences = {
    'prefers-color-scheme': ['PrefersColorScheme', { light: 'Light', dark: 'Dark' }],
    'prefers-reduced-motion': ['PrefersReducedMotion', { reduce: 'Reduce', 'no-preference': 'NoPreference' }],
    'prefers-contrast': ['PrefersContrast', { more: 'More', 'no-preference': 'NoPreference' }]
  }

  function setNewDocumentScripts () {
    const source = [...newDocumentScripts.values()].join(';\n')
    return page().setBootstrapScript.invoke(source ? { source } : {})
  }

  // The WebKit domains each CDP domain's events come from. The frontend may not have enabled them all
  // yet; it needs them on, so disable leaves them be.
  const backingDomains = { Runtime: ['Runtime', 'Console'], Page: ['Page'], Network: ['Network'], DOM: [] }

  const commands = {
    'Runtime.evaluate': async params => {
      let response = await runtime().evaluate.invoke(defined({
        expression: String(params.expression ?? ''),
        objectGroup: params.objectGroup,
        includeCommandLineAPI: params.includeCommandLineAPI,
        doNotPauseOnExceptionsAndMuteConsole: params.silent,
        contextId: params.contextId,
        returnByValue: params.awaitPromise ? false : params.returnByValue,
        generatePreview: params.generatePreview,
        emulateUserGesture: params.userGesture
      }))
      if (params.awaitPromise && !response.wasThrown && response.result?.className === 'Promise') {
        response = await runtime().awaitPromise.invoke(defined({ promiseObjectId: response.result.objectId, returnByValue: params.returnByValue, generatePreview: params.generatePreview }))
      } else if (params.awaitPromise && params.returnByValue && !response.wasThrown && response.result?.objectId) {
        response = await runtime().callFunctionOn.invoke({ objectId: response.result.objectId, functionDeclaration: 'function () { return this }', returnByValue: true })
      }
      return evaluation(response)
    },
    'Runtime.callFunctionOn': async params => {
      let objectId = params.objectId
      if (!objectId) {
        if (params.executionContextId == null) throw new ProtocolError(-32000, 'Either ObjectId or executionContextId must be specified')
        const global = await runtime().evaluate.invoke({ expression: 'globalThis', contextId: params.executionContextId, objectGroup: params.objectGroup ?? 'lilo-debugger' })
        objectId = global.result.objectId
      }
      // A global fetched here would hold its Window, reloads and all, until released.
      const ownGlobal = !params.objectId ? objectId : null
      const response = await runtime().callFunctionOn.invoke(defined({
        objectId,
        functionDeclaration: String(params.functionDeclaration ?? ''),
        arguments: params.arguments?.map(arg => defined({ value: arg.value, objectId: arg.objectId })),
        doNotPauseOnExceptionsAndMuteConsole: params.silent,
        returnByValue: params.returnByValue,
        generatePreview: params.generatePreview,
        emulateUserGesture: params.userGesture,
        awaitPromise: params.awaitPromise
      })).finally(() => { if (ownGlobal) runtime().releaseObject.invoke({ objectId: ownGlobal }).catch(() => {}) })
      return evaluation(response)
    },
    'Runtime.awaitPromise': async params => evaluation(await runtime().awaitPromise.invoke(defined({
      promiseObjectId: params.promiseObjectId, returnByValue: params.returnByValue, generatePreview: params.generatePreview
    }))),
    'Runtime.getProperties': async params => {
      const response = await runtime().getProperties.invoke(defined({ objectId: params.objectId, ownProperties: params.ownProperties, generatePreview: params.generatePreview }))
      const descriptor = ({ nativeGetter, isPrivate, ...property }) => ({
        ...property,
        value: remote(property.value), get: remote(property.get), set: remote(property.set), symbol: remote(property.symbol),
        configurable: !!property.configurable, enumerable: !!property.enumerable
      })
      let properties = response.properties ?? []
      if (params.accessorPropertiesOnly) properties = properties.filter(property => property.get || property.set)
      return {
        result: properties.filter(property => !property.isPrivate).map(descriptor),
        internalProperties: (response.internalProperties ?? []).map(property => ({ name: property.name, value: remote(property.value) })),
        privateProperties: properties.filter(property => property.isPrivate).map(({ name, value, get, set }) => ({ name, value: remote(value), get: remote(get), set: remote(set) }))
      }
    },
    'Runtime.releaseObject': async params => runtime().releaseObject.invoke({ objectId: params.objectId }).then(() => ({})),
    'Runtime.releaseObjectGroup': async params => runtime().releaseObjectGroup.invoke({ objectGroup: params.objectGroup }).then(() => ({})),
    'Runtime.runIfWaitingForDebugger': async () => ({}),
    'Page.reload': async params => page().reload.invoke(defined({ ignoreCache: params.ignoreCache })).then(() => ({})),
    'Page.getFrameTree': async () => ({ frameTree: frameTree((await page().getResourceTree.invoke({})).frameTree, false) }),
    'Page.getResourceTree': async () => ({ frameTree: frameTree((await page().getResourceTree.invoke({})).frameTree, true) }),
    'Page.getResourceContent': async params => page().getResourceContent.invoke({ frameId: params.frameId, url: params.url }),
    'Page.captureScreenshot': screenshot,
    'Page.getLayoutMetrics': layoutMetrics,
    'Page.addScriptToEvaluateOnNewDocument': async params => {
      const identifier = String(nextScriptId++)
      newDocumentScripts.set(identifier, String(params.source ?? ''))
      await setNewDocumentScripts()
      return { identifier }
    },
    'Page.removeScriptToEvaluateOnNewDocument': async params => {
      if (newDocumentScripts.delete(params.identifier)) await setNewDocumentScripts()
      return {}
    },
    'Network.setExtraHTTPHeaders': async params => override('extraHeaders', value => network().setExtraHTTPHeaders.invoke({ headers: value ?? {} }), params.headers),
    'Network.getResponseBody': async params => network().getResponseBody.invoke({ requestId: params.requestId }),
    'Network.setCacheDisabled': async params => override('cache', value => network().setResourceCachingDisabled.invoke({ disabled: !!value }), params.cacheDisabled || null),
    'Network.setUserAgentOverride': async params => override('userAgent', value => page().overrideUserAgent.invoke(value ? { value } : {}), params.userAgent || null),
    'Network.getCookies': async () => ({
      cookies: ((await page().getCookies.invoke({})).cookies ?? []).map(cookie => ({ ...cookie, size: cookie.name.length + cookie.value.length, expires: cookie.session ? -1 : cookie.expires / 1000 }))
    }),
    'DOM.getDocument': async () => ({ root: node((await dom().getDocument.invoke({})).root) }),
    'DOM.requestChildNodes': async params => dom().requestChildNodes.invoke(defined({ nodeId: await nodeIdOf(params), depth: params.depth })).then(() => ({})),
    'DOM.querySelector': async params => dom().querySelector.invoke({ nodeId: params.nodeId, selector: String(params.selector) }),
    'DOM.querySelectorAll': async params => dom().querySelectorAll.invoke({ nodeId: params.nodeId, selector: String(params.selector) }),
    'DOM.getOuterHTML': async params => dom().getOuterHTML.invoke({ nodeId: await nodeIdOf(params) }),
    'DOM.setOuterHTML': async params => dom().setOuterHTML.invoke({ nodeId: params.nodeId, outerHTML: String(params.outerHTML) }).then(() => ({})),
    'DOM.setAttributeValue': async params => dom().setAttributeValue.invoke({ nodeId: params.nodeId, name: String(params.name), value: String(params.value) }).then(() => ({})),
    'DOM.setAttributesAsText': async params => dom().setAttributesAsText.invoke(defined({ nodeId: params.nodeId, text: String(params.text), name: params.name })).then(() => ({})),
    'DOM.removeAttribute': async params => dom().removeAttribute.invoke({ nodeId: params.nodeId, name: String(params.name) }).then(() => ({})),
    'DOM.removeNode': async params => dom().removeNode.invoke({ nodeId: params.nodeId }).then(() => ({})),
    'DOM.setNodeValue': async params => dom().setNodeValue.invoke({ nodeId: params.nodeId, value: String(params.value) }).then(() => ({})),
    'DOM.getAttributes': async params => dom().getAttributes.invoke({ nodeId: params.nodeId }),
    'DOM.requestNode': async params => ({ nodeId: await nodeIdOf({ objectId: params.objectId }) }),
    'DOM.resolveNode': async params => {
      const { object } = await dom().resolveNode.invoke(defined({ nodeId: await nodeIdOf(params), objectGroup: params.objectGroup }))
      return { object: remote(object) }
    },
    'DOM.focus': async params => dom().focus.invoke({ nodeId: await nodeIdOf(params) }).then(() => ({})),
    'DOM.getBoxModel': async params => ({ model: await onNode(params, boxModel) }),
    'DOM.getContentQuads': async params => ({ quads: [(await onNode(params, boxModel)).border] }),
    'DOM.scrollIntoViewIfNeeded': async params => {
      await onNode(params, "function () { this.scrollIntoView({ block: 'center', inline: 'center' }) }")
      return {}
    },
    'DOM.performSearch': async params => dom().performSearch.invoke({ query: String(params.query) }),
    'DOM.getSearchResults': async params => dom().getSearchResults.invoke({ searchId: params.searchId, fromIndex: params.fromIndex, toIndex: params.toIndex }),
    'DOM.discardSearchResults': async params => dom().discardSearchResults.invoke({ searchId: params.searchId }).then(() => ({})),
    'Emulation.setUserAgentOverride': async params => override('userAgent', value => page().overrideUserAgent.invoke(value ? { value } : {}), params.userAgent || null),
    'Emulation.setScriptExecutionDisabled': async params => override('javascript', value => page().overrideSetting.invoke(value ? { setting: 'ScriptEnabled', value: false } : { setting: 'ScriptEnabled' }), params.value || null),
    'Emulation.setEmulatedMedia': async params => {
      await override('media', value => page().setEmulatedMedia.invoke({ media: value ?? '' }), params.media || null)
      const features = new Map((params.features ?? []).map(feature => [feature.name, feature.value]))
      for (const [name, [preference, values]] of Object.entries(preferences)) {
        const value = values[features.get(name)] ?? null
        await override(name, chosen => page().overrideUserPreference.invoke(chosen ? { name: preference, value: chosen } : { name: preference }), value)
      }
      return {}
    },
    'Input.insertText': async params => {
      await runtime().evaluate.invoke({ expression: `document.execCommand('insertText', false, ${JSON.stringify(String(params.text ?? ''))})` })
      return {}
    }
  }

  Object.assign(inspector, {
    /** One CDP command: `{result, events}` with the CDP events it causes, or `{error}`. */
    async cdpSend ({ method, params }) {
      try {
        const [domain, command] = method.split('.')
        if (command === 'enable' || command === 'disable') {
          if (!Object.hasOwn(backingDomains, domain)) throw notFound(method)
          if (command === 'enable') await Promise.all(backingDomains[domain].map(name => agent(name).enable.invoke({})))
          const events = method === 'Runtime.enable'
            ? executionContexts().map(context => ({ method: 'Runtime.executionContextCreated', params: { context } }))
            : []
          return { result: {}, events }
        }
        if (!Object.hasOwn(commands, method)) throw notFound(method)
        const run = commands[method]
        const result = await run(params ?? {})
        return { result: JSON.parse(JSON.stringify(result ?? {})) }
      } catch (error) {
        return { error: { code: error instanceof ProtocolError ? error.code : -32000, message: error?.message ?? String(error) } }
      }
    },
    /** The CDP domains whose events go to native: the union of every attached extension's. */
    cdpDomains ({ domains }) {
      enabled = new Set(domains)
    },
    /** The last extension detached: what they changed goes back. */
    async cdpReset () {
      enabled = new Set()
      const changed = [...overrides.values()]
      overrides.clear()
      for (const apply of changed) await apply(null).catch(() => {})
      if (newDocumentScripts.size) {
        newDocumentScripts.clear()
        await setNewDocumentScripts().catch(() => {})
      }
    }
  })
})()

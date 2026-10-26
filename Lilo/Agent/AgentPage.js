// Page reading for agents, run in Lilo's "lilo-agent" content world: page scripts cannot see or
// tamper with it. Elements get refs ("ref_N") that stay the same for the life of the document; a
// frame's refs carry its own prefix ("fxxxxx_ref_N"), so Lilo knows which frame to ask.
(() => {
  if (window.__liloAgent) return
  const prefix = window === window.top ? '' : 'f' + Math.random().toString(36).slice(2, 8) + '_'
  const refOf = new WeakMap()
  const elementOf = new Map()
  let nextRef = 1

  const ref = el => {
    let id = refOf.get(el)
    if (!id) {
      id = prefix + 'ref_' + nextRef++
      refOf.set(el, id)
      elementOf.set(id, new WeakRef(el))
    }
    return id
  }
  const element = id => {
    const el = elementOf.get(id)?.deref()
    if (!el || !el.isConnected) throw new Error(`Element ${id} not found: read the page again`)
    return el
  }

  const implicitRoles = {
    A: el => el.hasAttribute('href') ? 'link' : null,
    BUTTON: () => 'button', SELECT: el => el.multiple ? 'listbox' : 'combobox', TEXTAREA: () => 'textbox',
    IMG: () => 'img', NAV: () => 'navigation', MAIN: () => 'main', HEADER: () => 'banner', FOOTER: () => 'contentinfo',
    ASIDE: () => 'complementary', FORM: () => 'form', DIALOG: () => 'dialog', UL: () => 'list', OL: () => 'list',
    LI: () => 'listitem', TABLE: () => 'table', TR: () => 'row', TD: () => 'cell', TH: () => 'columnheader',
    H1: () => 'heading', H2: () => 'heading', H3: () => 'heading', H4: () => 'heading', H5: () => 'heading', H6: () => 'heading',
    SUMMARY: () => 'button', LABEL: () => 'label', P: () => 'paragraph', SECTION: () => 'region', ARTICLE: () => 'article',
    OPTION: () => 'option', IFRAME: () => 'iframe', VIDEO: () => 'video', AUDIO: () => 'audio'
  }
  const inputRoles = {
    button: 'button', submit: 'button', reset: 'button', image: 'button', checkbox: 'checkbox', radio: 'radio',
    range: 'slider', number: 'spinbutton', search: 'searchbox', file: 'button', hidden: null
  }
  const role = el => {
    const explicit = el.getAttribute('role')
    if (explicit) return explicit.split(' ')[0]
    if (el.tagName === 'INPUT') return el.type in inputRoles ? inputRoles[el.type] : 'textbox'
    if (el.isContentEditable && !el.parentElement?.isContentEditable) return 'textbox'
    return implicitRoles[el.tagName]?.(el) ?? null
  }
  const interactive = el => {
    const r = role(el)
    return ['link', 'button', 'textbox', 'searchbox', 'checkbox', 'radio', 'combobox', 'listbox', 'slider', 'spinbutton',
      'switch', 'tab', 'menuitem', 'option'].includes(r) || el.hasAttribute('onclick') || el.tabIndex >= 0 && el.tagName !== 'BODY' && r !== null
  }
  const nameFromContent = new Set(['button', 'link', 'heading', 'option', 'cell', 'columnheader', 'tab', 'menuitem', 'label',
    'listitem', 'checkbox', 'radio', 'switch', 'treeitem', 'tooltip'])
  // Icon fonts (SF Symbols and the like) draw their glyphs from private-use code points: odd characters as text.
  const privateUse = /[\uE000-\uF8FF\u{F0000}-\u{FFFFD}\u{100000}-\u{10FFFD}]/gu
  const clip = (text, max = 100) => {
    const flat = (text || '').replace(privateUse, '').replace(/\s+/g, ' ').trim()
    return flat.length > max ? flat.slice(0, max) + '...' : flat
  }
  const name = el => {
    const labelled = el.getAttribute('aria-labelledby')
    if (labelled) return clip(labelled.split(' ').map(id => el.ownerDocument.getElementById(id)?.innerText ?? '').join(' '))
    const direct = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title')
    if (direct) return clip(direct)
    if (el.labels?.length) return clip([...el.labels].map(l => l.innerText).join(' '))
    if (el.placeholder) return clip(el.placeholder)
    // Landmarks and containers are named by their label only: their text shows as their children.
    if (!nameFromContent.has(role(el))) return ''
    return clip(el.innerText ?? el.textContent)
  }
  // An empty box that clips its content, like a collapsed menu: nothing inside shows.
  const clipped = el => {
    const box = el.getBoundingClientRect()
    if (box.width && box.height) return false
    const style = getComputedStyle(el)
    return !box.width && style.overflowX !== 'visible' || !box.height && style.overflowY !== 'visible'
  }
  // The element itself: read_page stops at the first hidden one, so its tree leaves out what they hold.
  const visible = el =>
    el.getAttribute('aria-hidden') !== 'true' && el.checkVisibility({ checkOpacity: false, checkVisibilityCSS: true }) && !clipped(el)
  // find meets elements one by one: an ancestor hides them as well. checkVisibility covers its display and visibility.
  const shown = el => {
    if (!visible(el) || el.parentElement?.closest('[aria-hidden="true"]')) return false
    for (let ancestor = el.parentElement; ancestor; ancestor = ancestor.parentElement) if (clipped(ancestor)) return false
    return true
  }
  const details = el => {
    const parts = []
    if (el.tagName === 'A' && el.href) parts.push(`href="${clip(el.getAttribute('href'), 200)}"`)
    if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
      if (el.type && el.tagName === 'INPUT') parts.push(`type="${el.type}"`)
      if (el.type === 'checkbox' || el.type === 'radio') parts.push(el.checked ? 'checked' : 'unchecked')
      else if (el.value) parts.push(`value="${clip(el.value, 200)}"`)
    }
    if (el.disabled) parts.push('disabled')
    if (/^H[1-6]$/.test(el.tagName)) parts.push(`level=${el.tagName[1]}`)
    return parts.length ? ' ' + parts.join(' ') : ''
  }

  const readPage = ({ filter = 'all', refId, depth = 15, maxChars = 50000 } = {}) => {
    const root = refId ? element(refId) : document.body
    const lines = []
    let size = 0
    let truncated = false
    const emit = (level, text) => {
      if (truncated) return
      const line = '  '.repeat(level) + '- ' + text
      if (size + line.length > maxChars) { truncated = true; return }
      lines.push(line)
      size += line.length + 1
    }
    const walk = (el, level) => {
      if (truncated || level > depth || !visible(el)) return
      const r = role(el)
      const isInteractive = interactive(el)
      const shown = filter === 'interactive' ? isInteractive : r !== null || isInteractive
      if (shown) emit(filter === 'interactive' ? 0 : level, `${r ?? 'generic'} "${name(el)}" [${ref(el)}]${details(el)}`)
      // An interactive element's name already holds its text.
      if (isInteractive && filter === 'interactive') return
      const childLevel = shown ? level + 1 : level
      for (const node of (el.shadowRoot ?? el).childNodes) {
        if (node.nodeType === Node.ELEMENT_NODE) walk(node, childLevel)
        else if (node.nodeType === Node.TEXT_NODE && filter === 'all' && !isInteractive && !(r === 'heading' || r === 'link')) {
          const text = clip(node.textContent, 200)
          if (text) emit(childLevel, `text "${text}"`)
        }
      }
    }
    walk(root, 0)
    if (prefix && !lines.length) return ''
    const header = `${prefix ? 'Frame' : 'Page'}: ${document.title}\nURL: ${clip(location.href, 200)}\nViewport: ${innerWidth}x${innerHeight}, scrolled to ${Math.round(scrollX)},${Math.round(scrollY)}\n`
    return header + lines.join('\n') + (truncated ? `\n[Output truncated at ${maxChars} characters: pass a refId to read one part, or a smaller depth]` : '')
  }

  const find = ({ query, limit = 20 }) => {
    const needle = String(query ?? '').toLowerCase()
    const matches = []
    // Into open shadow roots, as read_page goes: web components hold many pickers and menus.
    const elements = function* (root) {
      for (const el of root.querySelectorAll('*')) {
        yield el
        if (el.shadowRoot) yield* elements(el.shadowRoot)
      }
    }
    for (const el of document.body ? elements(document.body) : []) {
      if (matches.length >= limit) break
      const r = role(el)
      if (r === null && !interactive(el)) continue
      const line = `${r ?? 'generic'} "${name(el)}"`
      if (!(line + details(el)).toLowerCase().includes(needle) || !shown(el)) continue
      matches.push(`${line} [${ref(el)}]${details(el)}`)
    }
    return matches
  }

  const text = ({ maxChars = 50000 } = {}) => {
    const root = document.querySelector('article') ?? document.querySelector('main') ?? document.body
    const body = (root?.innerText ?? '').replace(privateUse, '').trim()
    return `Title: ${document.title}\nURL: ${clip(location.href, 200)}\n\n` +
      (body.length > maxChars ? body.slice(0, maxChars) + `\n[Output truncated at ${maxChars} characters]` : body)
  }

  const setValue = ({ ref: id, value }) => {
    const el = element(id)
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
    el.focus?.()
    if (el.tagName === 'SELECT') {
      const option = [...el.options].find(o => o.value === String(value) || o.text.trim() === String(value))
      if (!option) throw new Error(`No option "${value}" in ${id}: options are ${[...el.options].map(o => o.text.trim()).join(', ')}`)
      el.value = option.value
    } else if (el.type === 'checkbox' || el.type === 'radio') {
      el.checked = value === true || value === 'true'
    } else if (el.isContentEditable) {
      el.textContent = String(value)
    } else if ('value' in el) {
      // The prototype setter, so frameworks that wrap the value property (React) see the change.
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, String(value))
    } else {
      throw new Error(`${id} is not a form field`)
    }
    el.dispatchEvent(new Event('input', { bubbles: true }))
    el.dispatchEvent(new Event('change', { bubbles: true }))
    return `Set ${id} to ${JSON.stringify(value)}`
  }

  const rect = ({ ref: id, scroll = true }) => {
    const el = element(id)
    // An element already under its own center stays where the agent's last screenshot showed it. One a
    // scrolled container crops, or something covers, is in the window yet not what a click there hits.
    const reachable = box => {
      const x = box.left + box.width / 2, y = box.top + box.height / 2
      const hit = x >= 0 && y >= 0 && x < innerWidth && y < innerHeight && el.getRootNode().elementFromPoint(x, y)
      return !!hit && (hit === el || el.contains(hit))
    }
    if (scroll && !reachable(el.getBoundingClientRect())) el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
    const box = el.getBoundingClientRect()
    const x = box.left + box.width / 2, y = box.top + box.height / 2
    // Reported rather than clicked: a click at the wrong place would still read as done.
    if (!box.width || !box.height || !el.checkVisibility()) throw new Error(`${id} is hidden: read the page again`)
    if (scroll && !reachable(box)) {
      const cover = el.getRootNode().elementFromPoint(x, y)
      const label = cover ? cover.tagName.toLowerCase() + (cover.id ? '#' + cover.id : '') + [...cover.classList].slice(0, 3).map(c => '.' + c).join('') : 'nothing'
      throw new Error(`${id} is covered by ${label} at (${Math.round(x)}, ${Math.round(y)}): close it, or click by coordinate`)
    }
    return { x, y, width: box.width, height: box.height }
  }

  // The element a wheel at (x, y) would scroll, or the document.
  const scroller = ({ x, y }) => {
    for (let el = document.elementFromPoint(x, y); el && el !== document.documentElement; el = el.parentElement) {
      const style = getComputedStyle(el)
      if (/(auto|scroll)/.test(style.overflowY + style.overflowX) && (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) return el
    }
    return document.scrollingElement ?? document.documentElement
  }
  const scrollState = point => { const el = scroller(point); return `${el.scrollLeft},${el.scrollTop}` }
  const scrollBy = ({ x, y, dx, dy }) => { scroller({ x, y }).scrollBy(dx, dy); return scrollState({ x, y }) }

  const dropFile = ({ ref: id, x, y, name: fileName, type, base64 }) => {
    const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0))
    const file = new File([bytes], fileName, { type })
    const transfer = new DataTransfer()
    transfer.items.add(file)
    const target = id ? element(id) : document.elementFromPoint(x, y)
    if (!target) throw new Error('No element at that point')
    if (target.tagName === 'INPUT' && target.type === 'file') {
      target.files = transfer.files
      target.dispatchEvent(new Event('input', { bubbles: true }))
      target.dispatchEvent(new Event('change', { bubbles: true }))
      return `Set ${fileName} on the file input`
    }
    for (const type of ['dragenter', 'dragover', 'drop']) {
      target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: transfer }))
    }
    return `Dropped ${fileName}`
  }

  // In a frame, coordinates are the frame's own and not the tab's: its elements get DOM events instead
  // of real clicks. click() keeps what a click activates (links, checkboxes, submit buttons).
  const act = ({ ref: id, action, modifiers = '' }) => {
    const el = element(id)
    el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
    if (action === 'scroll_to') return `Scrolled ${id} into view`
    const box = el.getBoundingClientRect()
    const keys = String(modifiers).toLowerCase().split('+')
    const base = {
      bubbles: true, cancelable: true, composed: true, view: window, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2,
      ctrlKey: keys.includes('ctrl'), shiftKey: keys.includes('shift'), altKey: keys.includes('alt'), metaKey: keys.includes('cmd') || keys.includes('meta')
    }
    const fire = (Type, type, extra = {}) => el.dispatchEvent(new Type(type, { ...base, pointerType: 'mouse', isPrimary: true, ...extra }))
    fire(PointerEvent, 'pointerover')
    fire(MouseEvent, 'mouseover')
    fire(PointerEvent, 'pointermove')
    fire(MouseEvent, 'mousemove')
    if (action === 'hover') return `Hovered ${id}`
    const right = action === 'right_click'
    const button = right ? 2 : 0
    const clicks = { double_click: 2, triple_click: 3 }[action] ?? 1
    for (let detail = 1; detail <= clicks; detail++) {
      fire(PointerEvent, 'pointerdown', { button, buttons: right ? 2 : 1, detail })
      fire(MouseEvent, 'mousedown', { button, buttons: right ? 2 : 1, detail })
      if (detail === 1) el.focus?.()
      fire(PointerEvent, 'pointerup', { button, detail })
      fire(MouseEvent, 'mouseup', { button, detail })
      if (right) fire(MouseEvent, 'contextmenu', { button, detail })
      else el.click()
    }
    if (clicks === 2) fire(MouseEvent, 'dblclick', { detail: 2 })
    return `${right ? 'Right-clicked' : 'Clicked'} ${id} in its frame`
  }

  // fetch() from this content world goes out as the page's own request: its origin, its CORS rules and
  // its profile's cookies. The body is read up to maxBytes only, so a huge response costs nothing past it.
  const request = async ({ url, method = 'GET', headers = {}, body, credentials = 'same-origin', responseType = 'text', maxBytes }) => {
    let response
    try {
      response = await fetch(url, { method, headers, body, credentials })
    } catch (e) {
      // An error must not carry the credentials the agent passed.
      let message = String(e?.message ?? e)
      for (const [key, value] of Object.entries(headers)) {
        if (/^(cookie|authorization)$/i.test(key) && value) message = message.replaceAll(String(value), '[redacted]')
      }
      throw new Error(`${method} ${url} failed: ${message} (a cross-origin request needs the server's CORS headers, as for the page)`)
    }
    const chunks = []
    let size = 0
    let truncated = false
    const reader = response.body?.getReader()
    while (reader) {
      const { done, value } = await reader.read()
      if (done) break
      if (size + value.length > maxBytes) {
        chunks.push(value.subarray(0, maxBytes - size))
        size = maxBytes
        truncated = true
        reader.cancel()
        break
      }
      chunks.push(value)
      size += value.length
    }
    const bytes = new Uint8Array(size)
    let offset = 0
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
    let result
    if (responseType === 'base64') {
      let binary = ''
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
      result = btoa(binary)
    } else {
      result = new TextDecoder().decode(bytes)
      if (responseType === 'json' && !truncated) try { result = JSON.parse(result) } catch {}
    }
    const shown = {}
    for (const [key, value] of response.headers) if (!/^(set-cookie2?|authorization|proxy-authorization)$/i.test(key)) shown[key] = value
    return { status: response.status, statusText: response.statusText, url: response.url, redirected: response.redirected, headers: shown, bytes: size, truncated, body: result }
  }

  // Matched as whole words once lowercased and stripped of accents.
  const consequentialWords = /\b(send|pay|payment|buy|purchase|order|checkout|delete|transfer|publish|post|tweet|reply|sign ?up|register|subscribe|donate|envoyer|payer|paiement|acheter|commander|supprimer|virement|transferer|publier|poster|repondre|inscription|inscrire|souscrire)\b/
  // The label of the control a click on `ref` or at (x, y), or Enter in the focused field, would trigger, when it
  // sends, pays, buys, orders, deletes, transfers, publishes or signs up; null otherwise.
  const consequential = ({ ref: id, x, y, enter }) => {
    const controls = 'button, a[href], input[type=submit], input[type=button], input[type=image], [role=button], [role=link], [role=menuitem]'
    const focused = document.activeElement
    // The focused field is in a frame's own document, out of reach from here: Lilo asks the frames.
    if (enter && ['IFRAME', 'FRAME'].includes(focused?.tagName)) return { inFrame: true }
    let start = enter ? focused : id ? element(id) : document.elementFromPoint(x, y)
    // A click on a frame lands on what the frame shows there (a click by ref, at its center): the point follows
    // into each frame's own viewport, past its border and padding.
    if (!enter && ['IFRAME', 'FRAME'].includes(start?.tagName)) {
      const center = start.getBoundingClientRect()
      let [px, py] = id ? [center.left + center.width / 2, center.top + center.height / 2] : [x, y]
      while (['IFRAME', 'FRAME'].includes(start?.tagName)) {
        const box = start.getBoundingClientRect()
        const style = getComputedStyle(start)
        px -= box.left + start.clientLeft + parseFloat(style.paddingLeft)
        py -= box.top + start.clientTop + parseFloat(style.paddingTop)
        // Another origin's document is out of reach: what the click does there is unknown, so the user decides.
        if (!start.contentDocument) {
          let host = ''
          try { host = new URL(start.src, location.href).host } catch {}
          return clip(start.title) || host || start.tagName.toLowerCase()
        }
        start = start.contentDocument.elementFromPoint(px, py)
      }
    }
    // Enter in a form's text field submits it: its submit button, else the form itself, says what that does.
    const target = start?.closest(controls) ?? (enter && focused?.tagName === 'INPUT' && focused.form
      ? focused.form.querySelector('button:not([type]), button[type=submit], input[type=submit], input[type=image]') ?? focused.form
      : null)
    if (!target) return null
    const label = name(target) || clip(target.value)
    const action = (target.form ?? target).getAttribute?.('action') ?? ''
    const words = `${label} ${action}`.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase()
    return consequentialWords.test(words) ? label || clip(action) : null
  }

  // Screenshots. A requestAnimationFrame never fires in a page that is not painted: the timeout keeps it from hanging.
  const painted = () => new Promise(resolve => {
    const done = () => resolve()
    requestAnimationFrame(() => requestAnimationFrame(done))
    setTimeout(done, 100)
  })
  const target = ({ ref: id, selector }) => {
    if (id) return element(id)
    const el = document.querySelector(selector)
    if (!el) throw new Error(`No element matches ${selector}`)
    return el
  }
  const instantScroll = (x, y) => scrollTo({ left: x, top: y, behavior: 'instant' })
  // Readies the page for a capture: lazy content loads as the range scrolls by, then images and fonts finish.
  // Returns the scroll position to put back, or null when the page stays scrolled to the element, as a click leaves it.
  const captureScroll = async ({ ref: id, selector, fullPage, maxHeight }) => {
    const el = fullPage ? null : target({ ref: id, selector })
    const start = { x: scrollX, y: scrollY }
    const box = el?.getBoundingClientRect()
    if (box && (!box.width || !box.height || !el.checkVisibility())) throw new Error(`${id ?? selector} is hidden: read the page again`)
    const fits = box && box.width <= innerWidth && box.height <= innerHeight
    if (fits) {
      if (box.top < 0 || box.left < 0 || box.bottom > innerHeight || box.right > innerWidth) {
        el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })
        await painted()
      }
    } else {
      const from = el ? box.top + scrollY : 0
      const height = () => el ? el.getBoundingClientRect().height : document.documentElement.scrollHeight
      // Bounded in time too: an endless feed keeps growing as it scrolls.
      const deadline = Date.now() + 10000
      for (let y = from; y < from + Math.min(height(), maxHeight) && Date.now() < deadline; y += innerHeight) {
        instantScroll(scrollX, y)
        await painted()
      }
      instantScroll(0, 0)
      await painted()
    }
    const root = el ?? document
    // Shown ones only, above the cut: an image the scroll never reached does not load, and would hold the wait.
    const images = [...root.querySelectorAll('img')].filter(img => {
      const r = img.getBoundingClientRect()
      return r.width && r.height && (el || r.top < maxHeight)
    })
    await Promise.race([
      Promise.all([document.fonts.ready, ...images.map(img => img.decode().catch(() => {}))]),
      new Promise(resolve => setTimeout(resolve, 5000))
    ])
    return fits ? null : start
  }
  // The capture's box in document CSS pixels, and where the viewport is.
  const captureBox = ({ ref: id, selector, fullPage }) => {
    const root = document.documentElement
    const page = { width: Math.max(root.scrollWidth, innerWidth), height: Math.max(root.scrollHeight, document.body?.scrollHeight ?? 0) }
    const viewport = { scrollX, scrollY, innerWidth, innerHeight, pageWidth: page.width, pageHeight: page.height }
    // The client width leaves out a scrollbar, which a full-page capture does not draw.
    if (fullPage) return { x: 0, y: 0, width: root.clientWidth || innerWidth, height: page.height, ...viewport }
    const box = target({ ref: id, selector }).getBoundingClientRect()
    return { x: box.left + scrollX, y: box.top + scrollY, width: box.width, height: box.height, ...viewport }
  }
  const captureRestore = ({ x, y }) => instantScroll(x, y)

  window.__liloAgent = {
    prefix: () => prefix, readPage, find, text, setValue, rect, scrollState, scrollBy, dropFile, act, request, consequential,
    captureScroll, captureBox, captureRestore
  }
})()

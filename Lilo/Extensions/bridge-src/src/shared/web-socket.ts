// WebKit's WebSocket constructor in an extension worker waits on the main thread and never returns (WEBKIT-GAPS.md
// gap 33), so this one runs over Lilo's URLSession. SW-safe: no window/document/webkit.
import { bridgeEvents, gapCall } from './ipc.ts';
import { reportGapListener } from './gap-event.ts';

const CONNECTING = 0, OPEN = 1, CLOSING = 2, CLOSED = 3;
const open = new Map<number, LiloWebSocket>();

bridgeEvents.set('webSocket.onEvent', (event: any) => open.get(event?.id)?.receive(event));

function base64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

class LiloWebSocket extends EventTarget {
  static readonly CONNECTING = CONNECTING;
  static readonly OPEN = OPEN;
  static readonly CLOSING = CLOSING;
  static readonly CLOSED = CLOSED;
  readonly CONNECTING = CONNECTING;
  readonly OPEN = OPEN;
  readonly CLOSING = CLOSING;
  readonly CLOSED = CLOSED;
  readonly url: string;
  private readonly origin: string;
  readyState = CONNECTING;
  protocol = '';
  extensions = '';
  bufferedAmount = 0;
  binaryType: 'blob' | 'arraybuffer' = 'blob';
  onopen: ((event: Event) => void) | null = null;
  onmessage: ((event: MessageEvent) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onclose: ((event: Event) => void) | null = null;
  private id?: number;
  /** Sends in order, a Blob's bytes included. */
  private sending: Promise<unknown> = Promise.resolve();

  constructor(url: string | URL, protocols?: string | string[]) {
    super();
    const parsed = new URL(String(url), (globalThis as any).location?.href);
    if (parsed.protocol === 'http:') parsed.protocol = 'ws:';
    if (parsed.protocol === 'https:') parsed.protocol = 'wss:';
    if (!['ws:', 'wss:'].includes(parsed.protocol) || parsed.hash) {
      throw new DOMException(`The URL '${String(url)}' is invalid.`, 'SyntaxError');
    }
    this.url = parsed.href;
    this.origin = parsed.origin;
    reportGapListener('webSocket.onEvent');
    const list = protocols === undefined ? [] : Array.isArray(protocols) ? protocols : [protocols];
    gapCall<number>('webSocket', 'connect', { url: this.url, protocols: list }).then((id) => {
      this.id = id;
      open.set(id, this);
      // Closed while connecting.
      if (this.readyState === CLOSING) gapCall('webSocket', 'close', { id, code: 1000 }).catch(() => {});
    }, () => this.receive({ type: 'error' }, { type: 'close', code: 1006, reason: '', wasClean: false }));
  }

  send(data: string | ArrayBufferLike | ArrayBufferView | Blob): void {
    if (this.readyState === CONNECTING) throw new DOMException("Failed to execute 'send' on 'WebSocket': Still in CONNECTING state.", 'InvalidStateError');
    if (this.readyState !== OPEN) return;
    const id = this.id;
    const bytes = async () => data instanceof Blob ? new Uint8Array(await data.arrayBuffer())
      : ArrayBuffer.isView(data) ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data as ArrayBufferLike);
    this.sending = this.sending.then(async () => gapCall('webSocket', 'send', typeof data === 'string' ? { id, text: data } : { id, binary: base64(await bytes()) }))
      .catch(() => {});
  }

  close(code?: number, reason?: string): void {
    if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
      throw new DOMException(`The close code must be either 1000, or between 3000 and 4999. ${code} is neither.`, 'InvalidAccessError');
    }
    if (this.readyState === CLOSING || this.readyState === CLOSED) return;
    this.readyState = CLOSING;
    if (this.id !== undefined) gapCall('webSocket', 'close', { id: this.id, code: code ?? 1000, reason }).catch(() => {});
  }

  /** Native's event, or the ones a failed connection stands for. */
  receive(...events: any[]): void {
    for (const event of events) {
      if (event.type === 'open') {
        // Closed while connecting: it never opens.
        if (this.readyState !== CONNECTING) continue;
        this.readyState = OPEN;
        this.protocol = event.protocol ?? '';
        this.fire(new Event('open'));
      } else if (event.type === 'message') {
        let data: string | ArrayBuffer = event.text;
        if (typeof data !== 'string') {
          const binary = atob(event.binary ?? '');
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          data = bytes.buffer;
        }
        this.fire(new MessageEvent('message', { data: typeof data === 'string' || this.binaryType === 'arraybuffer' ? data : new Blob([data]), origin: this.origin }));
      } else if (event.type === 'error') {
        this.fire(new Event('error'));
      } else if (event.type === 'close') {
        this.readyState = CLOSED;
        if (this.id !== undefined) open.delete(this.id);
        const close = new Event('close');
        Object.defineProperties(close, { code: { value: event.code }, reason: { value: event.reason ?? '' }, wasClean: { value: event.wasClean } });
        this.fire(close);
      }
    }
  }

  private fire(event: Event): void {
    this.dispatchEvent(event);
    (this as any)[`on${event.type}`]?.call(this, event);
  }
}

export function installWorkerWebSocket(scope: any): void {
  Object.defineProperty(scope, 'WebSocket', { value: LiloWebSocket, configurable: true, writable: true });
}

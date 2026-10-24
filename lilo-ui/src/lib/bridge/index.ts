// Communication layer between the Svelte chrome and the native host.

import type {
  AnyBridgeEventEnvelope,
  BridgeCommandPayloadMap,
  BridgeEventEnvelope,
  BridgeEventName,
  BridgeInitialStatePayload,
  OptionalPayloadCommandName,
  RequiredPayloadCommandName,
} from './protocol';

export type {
  BridgeCommandPayloadMap,
  BridgeBrowserStatePatchPayload,
  BridgeBrowserStateChangedPayload,
  BridgeDownloadSnapshot,
  BridgeExtensionSnapshot,
  BridgeExtensionUpdateCheck,
  BridgeInitialStatePayload,
  BridgeProfileSnapshot,
  BridgeSpaceSnapshot,
  BridgeTabSnapshot,
  BridgeTabUpdatedPayload,
} from './protocol';

type UnknownBridgePayload = Record<string, unknown>;
type BridgeEventHandler = (data: UnknownBridgePayload) => void;
type DispatchableBridgePayload = UnknownBridgePayload | AnyBridgeEventEnvelope;

interface LiloMessageHandler {
  postMessage(message: { action: string; payload: UnknownBridgePayload }): void;
}

interface LiloBridgeReceiver {
  receive(msg: DispatchableBridgePayload): void;
  receiveBatch(msgs: DispatchableBridgePayload[]): void;
}

declare global {
  interface Window {
    __lilo?: LiloBridgeReceiver;
    __liloBootstrapEvents?: DispatchableBridgePayload[];
    webkit?: {
      messageHandlers?: {
        lilo?: LiloMessageHandler;
      };
    };
  }
}

const listeners = new Map<string, Set<BridgeEventHandler>>();
let bootstrapEvents = Array.isArray(window.__liloBootstrapEvents)
  ? [...window.__liloBootstrapEvents]
  : [];

window.__liloBootstrapEvents = [];

/**
 * The preloaded chrome web view's message handler exists only once the window controller adopts it, and
 * `postMessage` is a silent no-op until then: a caller recording what it sent must check this.
 */
export function isBridgeReady(): boolean {
  return Boolean(window.webkit?.messageHandlers?.lilo);
}

/** Send a typed command to the native host. */
export function postMessage<K extends OptionalPayloadCommandName>(action: K, payload?: BridgeCommandPayloadMap[K]): void;
export function postMessage<K extends RequiredPayloadCommandName>(action: K, payload: BridgeCommandPayloadMap[K]): void;
export function postMessage(action: string, payload: UnknownBridgePayload = {}): void {
  window.webkit?.messageHandlers?.lilo?.postMessage({ action, payload });
}

/** Subscribe to typed events from the native host. Returns an unsubscribe function. */
export function on<K extends BridgeEventName>(event: K, handler: (data: BridgeEventEnvelope<K>) => void): () => void;
export function on(event: string, handler: BridgeEventHandler): () => void {
  let eventHandlers = listeners.get(event);
  if (!eventHandlers) {
    eventHandlers = new Set();
    listeners.set(event, eventHandlers);
  }
  eventHandlers.add(handler);
  return () => eventHandlers?.delete(handler);
}

export function consumeBootstrapEvents(): void {
  const pendingEvents = bootstrapEvents;
  bootstrapEvents = [];
  for (const event of pendingEvents) {
    dispatch(event);
  }
  rethrowHandlerFailure();
}

export function takeBootstrapInitialState(): BridgeInitialStatePayload | undefined {
  const index = bootstrapEvents.findIndex((event) => getEventName(event) === 'initialState');
  if (index < 0) {
    return undefined;
  }

  const [initialStateEvent] = bootstrapEvents.splice(index, 1) as [BridgeEventEnvelope<'initialState'>];
  const { event: _event, ...payload } = initialStateEvent;
  return payload;
}

// A throwing handler must not starve the other handlers or the rest of a batch: its error is held, and the first
// one rethrown once everything is delivered, so the native call still fails and logs it.
let handlerFailure: { error: unknown } | null = null;

/** Dispatch an event received from Swift. */
function dispatch(data: DispatchableBridgePayload): void {
  const event = getEventName(data);
  if (!event) return;
  const handlers = listeners.get(event);
  if (!handlers) return;

  for (const handler of handlers) {
    try {
      handler(data as UnknownBridgePayload);
    } catch (error) {
      console.error(`Bridge handler for ${event} failed`, error);
      handlerFailure ??= { error };
    }
  }
}

function rethrowHandlerFailure(): void {
  const failure = handlerFailure;
  handlerFailure = null;
  if (failure) throw failure.error;
}

function getEventName(data: DispatchableBridgePayload): string | undefined {
  return typeof data === 'object'
    && data !== null
    && 'event' in data
    && typeof data.event === 'string'
    ? data.event
    : undefined;
}

window.__lilo = {
  receive(msg: DispatchableBridgePayload) {
    dispatch(msg);
    rethrowHandlerFailure();
  },
  receiveBatch(msgs: DispatchableBridgePayload[]) {
    for (const msg of msgs) {
      dispatch(msg);
    }
    rethrowHandlerFailure();
  },
};

// chrome.mdns. Lilo browses a service type while a listener filters on it: each type is its own gap event,
// `mdns.onServiceList/<serviceType>`, carrying that type's services.
import { bridgeEvents, gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { ChromeEvent } from '../shared/chrome-event.ts';
import { reportGapListener, reportGapListenerRemoved } from '../shared/gap-event.ts';

interface MDnsService {
  serviceName: string;
  serviceHostPort: string;
  ipAddress: string;
  serviceData: string[];
}

type Listener = (services: MDnsService[]) => void;

class ServiceListEvent extends ChromeEvent<[MDnsService[]]> {
  /** Each listener's serviceType filter. One without starts no browse, and hears every type this context's others filter on. */
  private readonly types = new Map<Listener, string | undefined>();

  override addListener(listener: Listener, filter?: { serviceType?: unknown }): void {
    if (this.types.has(listener)) return;
    const type = typeof filter?.serviceType === 'string' && filter.serviceType !== '' ? filter.serviceType : undefined;
    super.addListener(listener);
    this.types.set(listener, type);
    if (type === undefined || this.listening(type) > 1) return;
    const name = `mdns.onServiceList/${type}`;
    bridgeEvents.set(name, (services: MDnsService[]) => this.fire(type, services));
    // Lilo learns a page's listeners by name only: this names the type for it to browse.
    gapCall('mdns', 'watch', { serviceType: type }).catch(() => {});
    reportGapListener(name);
  }

  override removeListener(listener: Listener): void {
    if (!this.types.has(listener)) return;
    const type = this.types.get(listener);
    super.removeListener(listener);
    this.types.delete(listener);
    if (type === undefined || this.listening(type) > 0) return;
    bridgeEvents.delete(`mdns.onServiceList/${type}`);
    reportGapListenerRemoved(`mdns.onServiceList/${type}`);
  }

  private listening(type: string): number {
    let count = 0;
    for (const filter of this.types.values()) if (filter === type) count += 1;
    return count;
  }

  /** The listeners as of now whose filter is `type` or none. */
  private fire(type: string, services: MDnsService[]): void {
    for (const [listener, filter] of [...this.types]) {
      if (filter !== undefined && filter !== type) continue;
      try {
        listener(services);
      } catch (err) {
        console.error(`Error in event handler: ${String(err)}`);
      }
    }
  }
}

export const mdnsAugmentation = {
  MAX_SERVICE_INSTANCES_PER_EVENT: 2048,
  onServiceList: new ServiceListEvent(),
  forceDiscovery(callback?: () => void) {
    return callbackify(() => gapCall<void>('mdns', 'forceDiscovery'), callback);
  },
};

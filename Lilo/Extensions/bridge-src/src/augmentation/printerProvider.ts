// The macOS print panel lists no extension printers, so none of these events ever fires. SW-safe: no window/document/webkit.
import { createChromeEventsFromNames } from '../shared/chrome-event.ts';

export const printerProviderAugmentation = createChromeEventsFromNames([
  'onGetPrintersRequested', 'onGetUsbPrinterInfoRequested', 'onGetCapabilityRequested', 'onPrintRequested',
]);

// Native dispatches (requestId, text) but Chrome's listener takes (text, suggest): suggest closes over the requestId
// and its results travel back as a separate gap call. SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { GapChromeEvent, gapMethod, reportGapListener, reportGapListenerRemoved } from '../shared/gap-event.ts';

type OmniboxSuggestion = { content: string; description: string; deletable?: boolean };
type SuggestFn = (suggestResults: OmniboxSuggestion[]) => void;
type InputChangedListener = (text: string, suggest: SuggestFn) => void;

/**
 * Custom event for onInputChanged: native dispatches (requestId, text); we deliver (text, suggest)
 * to listeners, where suggest(results) routes back natively as a gap call carrying the requestId.
 */
class OmniboxInputChangedEvent {
  private listeners = new Set<InputChangedListener>();
  addListener(listener: InputChangedListener): void {
    this.listeners.add(listener);
    reportGapListener('omnibox.onInputChanged');
  }
  removeListener(listener: InputChangedListener): void {
    this.listeners.delete(listener);
    if (this.listeners.size === 0) reportGapListenerRemoved('omnibox.onInputChanged');
  }
  hasListener(listener: InputChangedListener): boolean { return this.listeners.has(listener); }
  hasListeners(): boolean { return this.listeners.size > 0; }

  dispatch(requestId: string, text: string): void {
    const suggest: SuggestFn = (suggestResults) => {
      gapCall('omnibox', 'sendSuggestions', { requestId, suggestions: suggestResults ?? [] }).catch(() => {});
    };
    // Listeners as of now: one added during dispatch waits for the next input, as in Chrome.
    for (const listener of [...this.listeners]) {
      try { listener(text, suggest); } catch (err) {
        console.error('[lilo:omnibox] onInputChanged listener threw:', err instanceof Error ? err.message : String(err));
      }
    }
  }
}

export const omniboxAugmentation = {
  setDefaultSuggestion: gapMethod('omnibox', 'setDefaultSuggestion', ['suggestion']),
  onInputStarted: new GapChromeEvent<[]>('omnibox', 'onInputStarted'),
  onInputChanged: new OmniboxInputChangedEvent(),
  onInputEntered: new GapChromeEvent<[string, string]>('omnibox', 'onInputEntered'),
  onInputCancelled: new GapChromeEvent<[]>('omnibox', 'onInputCancelled'),
  onDeleteSuggestion: new GapChromeEvent<[string]>('omnibox', 'onDeleteSuggestion'),
};

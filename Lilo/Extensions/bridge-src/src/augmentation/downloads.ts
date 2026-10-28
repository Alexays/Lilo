import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { GapChromeEvent, createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';

interface FilenameSuggestion {
  filename?: string;
  conflictAction?: string;
}

/**
 * Lilo waits for one answer from each context that listens: its listeners share one `suggest`, as in Chrome, which is
 * called with no suggestion once they return unless one returned true to call it later.
 */
class DeterminingFilenameEvent extends GapChromeEvent<[unknown, (suggestion?: FilenameSuggestion) => void]> {
  override dispatch(item: unknown, requestId?: unknown): void {
    let suggestable = true;
    const suggest = (suggestion?: FilenameSuggestion) => {
      if (!suggestable) {
        console.error('suggestCallback may not be called more than once.');
        return;
      }
      suggestable = false;
      const { filename, conflictAction } = suggestion ?? {};
      gapCall('downloads', 'suggestFilename', { requestId, filename, conflictAction }).catch(() => {});
    };
    let later = false;
    for (const listener of this.snapshot() as Array<(...args: unknown[]) => unknown>) {
      try {
        if (listener(item, suggest) === true) later = true;
      } catch (err) {
        console.error(`Error in event handler: ${String(err)}`);
      }
    }
    if (suggestable && !later) suggest();
  }
}

export const downloadsAugmentation = {
  download(options: any, callback?: (downloadId: number) => void) {
    // A save panel, or the onDeterminingFilename listeners, can hold the start: as Chrome, no timeout.
    return callbackify(() => gapCall<number>('downloads', 'download', options, 0), callback);
  },
  search: gapMethod('downloads', 'search'),
  pause: gapMethod('downloads', 'pause', ['downloadId']),
  resume: gapMethod('downloads', 'resume', ['downloadId']),
  cancel: gapMethod('downloads', 'cancel', ['downloadId']),
  open(downloadId: number) {
    gapCall<void>('downloads', 'open', { downloadId }).catch(() => {});
  },
  show(downloadId: number) {
    gapCall<void>('downloads', 'show', { downloadId }).catch(() => {});
  },
  erase: gapMethod('downloads', 'erase'),
  removeFile: gapMethod('downloads', 'removeFile', ['downloadId']),
  getFileIcon(downloadId: number, options?: any, callback?: (iconURL: string) => void) {
    // Chrome allows getFileIcon(id, cb) or getFileIcon(id, options, cb).
    const [opts, cb] = typeof options === 'function' ? [{}, options] : [options ?? {}, callback];
    return callbackify(
      () => gapCall<string>('downloads', 'getFileIcon', { downloadId, size: opts?.size }),
      cb
    );
  },
  acceptDanger: gapMethod('downloads', 'acceptDanger', ['downloadId']),
  setUiOptions(options: { enabled: boolean }, callback?: () => void) {
    return callbackify(() => gapCall<void>('downloads', 'setUiOptions', { enabled: options?.enabled }), callback);
  },
  showDefaultFolder() {
    gapCall<void>('downloads', 'showDefaultFolder', {}).catch(() => {});
  },
  ...createGapEventsFromNames('downloads', ['onCreated', 'onChanged', 'onErased']),
  onDeterminingFilename: new DeterminingFilenameEvent('downloads', 'onDeterminingFilename'),
};

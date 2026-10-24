import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';

export const downloadsAugmentation = {
  download(options: any, callback?: (downloadId: number) => void) {
    // A save panel waits on the user, so it gets no timeout.
    return callbackify(() => gapCall<number>('downloads', 'download', options, options?.saveAs ? 0 : undefined), callback);
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
  ...createGapEventsFromNames('downloads', ['onCreated', 'onChanged', 'onErased', 'onDeterminingFilename']),
};

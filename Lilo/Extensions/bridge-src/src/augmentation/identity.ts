import { createGapEventsFromNames, gapMethod } from '../shared/gap-event.ts';
import { bridgeChrome, callbackify } from '../shared/callbackify.ts';
import { gapCall } from '../shared/ipc.ts';

interface AuthTokenResult {
  token?: string;
  grantedScopes?: string[];
}

export const identityAugmentation = {
  /** Resolves `{ token, grantedScopes }`; a callback gets `(token, grantedScopes)`, as in Chrome. */
  getAuthToken(details?: any, callback?: (token?: string, grantedScopes?: string[]) => void): Promise<AuthTokenResult> | undefined {
    const [opts, cb] = typeof details === 'function' ? [{}, details] : [details ?? {}, callback];
    // An interactive sign-in waits on the user: no timeout.
    return callbackify(
      () => gapCall<AuthTokenResult>('identity', 'getAuthToken', opts, opts.interactive ? 0 : undefined),
      cb && ((r?: AuthTokenResult) => cb(r?.token, r?.grantedScopes))
    );
  },
  clearAllCachedAuthTokens: gapMethod('identity', 'clearAllCachedAuthTokens'),
  removeCachedAuthToken(details: any, callback?: () => void) {
    return callbackify(
      () => gapCall<void>('identity', 'removeCachedAuthToken', details),
      callback
    );
  },
  getRedirectURL(path?: string): string {
    // Chrome: https://<extensionid>.chromiumapp.org/<path>. Used as the OAuth redirect target and
    // matched by AuthNavDelegate on the native side.
    const suffix = (path ?? '').replace(/^\//, '');
    return `https://${bridgeChrome()?.runtime?.id ?? ''}.chromiumapp.org/${suffix}`;
  },
  launchWebAuthFlow(details: any, callback?: (responseUrl: string) => void): Promise<string> | undefined {
    return callbackify(
      () => gapCall<string>('identity', 'launchWebAuthFlow', details, 0),
      callback
    );
  },
  /** Lilo has no browser account: Chrome's answer for a profile nobody signed in to. */
  getProfileUserInfo(details?: any, callback?: (info: { email: string; id: string }) => void) {
    const cb = typeof details === 'function' ? details : callback;
    return callbackify(async () => ({ email: '', id: '' }), cb);
  },
  ...createGapEventsFromNames('identity', ['onSignInChanged']),
};

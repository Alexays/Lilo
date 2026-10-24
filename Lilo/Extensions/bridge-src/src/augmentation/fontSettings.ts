// chrome.fontSettings, kept per extension by native, which applies what WebKit can render.
//
// SW-safe: no window/document/webkit.
import { gapCall } from '../shared/ipc.ts';
import { callbackify } from '../shared/callbackify.ts';
import { chromeEnum } from '../shared/chrome-enum.ts';
import { createGapEventsFromNames } from '../shared/gap-event.ts';

const scripts = `Afak Arab Aran Armi Armn Avst Bali Bamu Bass Batk Beng Blis Bopo Brah Brai Bugi Buhd Cakm Cans Cari
Cham Cher Cirt Copt Cprt Cyrl Cyrs Deva Dsrt Dupl Egyd Egyh Egyp Elba Ethi Geor Geok Glag Goth Gran Grek Gujr Guru
Hang Hani Hano Hans Hant Hebr Hluw Hmng Hung Inds Ital Java Jpan Jurc Kali Khar Khmr Khoj Knda Kpel Kthi Lana Laoo
Latf Latg Latn Lepc Limb Lina Linb Lisu Loma Lyci Lydi Mand Mani Maya Mend Merc Mero Mlym Moon Mong Mroo Mtei Mymr
Narb Nbat Nkgb Nkoo Nshu Ogam Olck Orkh Orya Osma Palm Perm Phag Phli Phlp Phlv Phnx Plrd Prti Rjng Roro Runr Samr
Sara Sarb Saur Sgnw Shaw Shrd Sind Sinh Sora Sund Sylo Syrc Syre Syrj Syrn Tagb Takr Tale Talu Taml Tang Tavt Telu
Teng Tfng Tglg Thaa Thai Tibt Tirh Ugar Vaii Visp Wara Wole Xpeo Xsux Yiii Zmth Zsym Zyyy`.split(/\s+/);

const families = ['standard', 'sansserif', 'serif', 'fixed', 'cursive', 'fantasy', 'math'];

// Chrome checks both enums against the schema before sending, and throws.
function checkFont(method: string, details: unknown) {
  for (const [property, values] of [['genericFamily', families], ['script', scripts]] as const) {
    const value = (details as Record<string, unknown> | undefined)?.[property];
    if (value === undefined && property === 'script') continue;
    if (!values.includes(value as string)) {
      throw new TypeError(`Error in invocation of fontSettings.${method}(object details, optional function callback): `
        + `Error at parameter 'details': Error at property '${property}': `
        + (value === undefined ? 'Property is required.' : `Value must be one of ${values.join(', ')}.`));
    }
  }
}

function call(method: string, details: unknown, callback?: (result?: any) => void, returnsValue = false) {
  return callbackify(async () => {
    const result = await gapCall('fontSettings', method, details ?? {});
    return returnsValue ? result : undefined;
  }, callback);
}

const sizeNames = ['DefaultFontSize', 'DefaultFixedFontSize', 'MinimumFontSize'] as const;
const sizeVerbs = ['get', 'set', 'clear'] as const;
type SizeCall = (details?: unknown, callback?: (result?: any) => void) => ReturnType<typeof call>;

// The size calls take an unused optional `details` first, so a lone function is the callback.
const sizes = Object.fromEntries(sizeNames.flatMap((name) => sizeVerbs.map((verb) => [
  `${verb}${name}`,
  (details?: unknown, callback?: (result?: any) => void) => typeof details === 'function'
    ? call(`${verb}${name}`, {}, details as (result?: any) => void, verb === 'get')
    : call(`${verb}${name}`, details, callback, verb === 'get'),
]))) as Record<`${typeof sizeVerbs[number]}${typeof sizeNames[number]}`, SizeCall>;

export const fontSettingsAugmentation = {
  ScriptCode: chromeEnum(scripts),
  GenericFamily: chromeEnum(families),
  LevelOfControl: chromeEnum(['not_controllable', 'controlled_by_other_extensions', 'controllable_by_this_extension', 'controlled_by_this_extension']),
  getFont(details: unknown, callback?: (result: any) => void) {
    checkFont('getFont', details);
    return call('getFont', details, callback, true);
  },
  setFont(details: unknown, callback?: () => void) {
    checkFont('setFont', details);
    return call('setFont', details, callback);
  },
  clearFont(details: unknown, callback?: () => void) {
    checkFont('clearFont', details);
    return call('clearFont', details, callback);
  },
  getFontList(callback?: (result: any) => void) {
    return call('getFontList', {}, callback, true);
  },
  ...sizes,
  ...createGapEventsFromNames('fontSettings', ['onFontChanged', 'onDefaultFontSizeChanged', 'onDefaultFixedFontSizeChanged', 'onMinimumFontSizeChanged']),
};

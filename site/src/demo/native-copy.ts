import type { DemoLocale } from "./world.ts";

export type NativeCatalogs = Record<DemoLocale, Record<string, string>>;

let catalogs: NativeCatalogs = { en: {}, fr: {} };

export const installNativeCopy = (copy: NativeCatalogs) => {
  catalogs = copy;
};

export const nativeCopy =
  (locale: DemoLocale) =>
  (key: string, ...args: (string | number)[]): string => {
    let index = 0;

    return (catalogs[locale][key] ?? catalogs.en[key] ?? key).replaceAll(
      /%%|%(?:(?<position>\d+)\$)?(?:ll|l)?[@diu]/gu,
      (placeholder, position: string | undefined) => {
        if (placeholder === "%%") {
          return "%";
        }

        const argument = position ? Number(position) - 1 : index;

        if (!position) {
          index += 1;
        }

        return String(args[argument] ?? placeholder);
      }
    );
  };

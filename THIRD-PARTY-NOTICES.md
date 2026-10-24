# Third-party notices

Lilo is MIT-licensed (see [LICENSE](LICENSE)). It bundles or depends on the
following third-party components, which keep their own licenses.

## Swift packages

Declared in `project.yml` and `Package.swift`, pinned in `Package.resolved`.

### GRDB.swift

- https://github.com/groue/GRDB.swift
- License: MIT - Copyright (c) 2015-2025 Gwendal Roué

### Sparkle

- https://github.com/sparkle-project/Sparkle, embedded as `Sparkle.framework`
- License: MIT - Copyright (c) 2006-2013 Andy Matuschak, and the other holders
  listed in Sparkle's LICENSE. That file also carries the licenses of the
  components Sparkle bundles: bsdiff/bspatch (BSD-2-Clause), sais-lite (MIT),
  ed25519 (zlib) and SUSignatureVerifier (BSD-2-Clause)

## libghostty-vt (Ghostty)

- Built by `make vt-build` from the Ghostty commit pinned in the `Makefile`
  (https://github.com/ghostty-org/ghostty) and linked statically into Lilo
- License: MIT - Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
- Bundles simdutf (Apache License 2.0 or MIT), Highway (Apache License 2.0 or
  BSD-3-Clause) and uucode (MIT)

## Chrome UI bundle

`lilo-ui/` lists only build tools and type definitions in its
`package.json`. What ends up in the bundle embedded in the app:

- **Svelte** (https://github.com/sveltejs/svelte), its client runtime compiled
  into the bundle. License: MIT - Copyright (c) 2016-2025 Svelte Contributors
- **clsx** (https://github.com/lukeed/clsx), used by the Svelte runtime for
  `class` attributes. License: MIT - Copyright (c) Luke Edwards

## Extension bridge bundles

The bundles built from `Lilo/Extensions/bridge-src/` (`ChromeAPIAugmentation.js`
and the other generated `Lilo/Extensions/*.js` files) contain only Lilo's own
code: their npm packages are build tools and type definitions.

## Readability.js

- File: `Lilo/Reader/Readability.js`
- Origin: Mozilla's Readability library, based on Arc90's readability.js
  (https://github.com/mozilla/readability)
- License: Apache License 2.0 - Copyright (c) 2010 Arc90 Inc. The full license
  text is referenced in the file header.

## Public Suffix List

- File: `Lilo/Extensions/public-suffix-list.dat`, refreshed by `make public-suffix-list`
  from https://publicsuffix.org/list/public_suffix_list.dat
- License: Mozilla Public License 2.0 (https://mozilla.org/MPL/2.0/); the file keeps
  the list's license header

## Terminal color presets

`Lilo/Terminal/TerminalTheme.swift` carries the color values of these published
palettes, all MIT-licensed: Catppuccin, Tokyo Night, Dracula, Solarized,
Gruvbox, Nord, One Dark and GitHub's Primer colors.

## Fonts and icons

The app ships no font: its interface and terminal use the macOS system fonts.
Its icons are Lilo's own SVGs and Apple's SF Symbols, which macOS provides.
The setup's passwords step shows each password manager's own extension icon,
taken from its Chrome Web Store package by `make password-manager-icons` into
`lilo-ui/public/password-managers/`; each logo belongs to its owner and only
names that product.

The landing site (`site/`) serves **Nunito**
(https://github.com/googlefonts/nunito), `site/public/fonts/nunito-latin-wght.woff2`,
under the SIL Open Font License 1.1 - Copyright 2014 The Nunito Project Authors.
The license text is in `site/public/fonts/OFL.txt`.

## Filter lists

At runtime Lilo can download public filter lists (EasyList, EasyPrivacy, and
uBlock Origin asset lists) to power content blocking. These lists are fetched
from their official distribution points and are not redistributed with Lilo;
they remain under their own licenses (GPLv3 and others).

Lilo understands uBlock Origin and AdGuard filter syntax and resource names,
but includes none of their code.

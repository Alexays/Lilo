# Why the chrome is a web view

Lilo's sidebar, tab strip, command bar, panels and settings are a Svelte app ([`lilo-ui/`](../lilo-ui/)) in one `WKWebView` laid over the page ([ARCHITECTURE.md](ARCHITECTURE.md#overlay-hud-design)). What needs the system stays native: the window frame, glass and grain (`WindowFrameView`), the traffic lights, the content's slide when the sidebar toggles, and the menu bar.

This note weighs that split against an all-native chrome, with measurements of what the web view actually costs.

## The trade

| | Web chrome (today) | Native chrome (AppKit or SwiftUI) |
|-|-|-|
| Memory | One more WebKit process: 68 MB footprint | None of that process; the views' own memory instead (not measured) |
| Idle work | None measurable with a page visible | None expected |
| Launch | Chrome first paint at 370 ms, before the page (463 ms) | Could paint with the window (195 ms); not measured |
| Animation | No hitch measured; CSS transitions composite off the main thread | Core Animation, the same compositor |
| Look | System conventions rebuilt in CSS: fonts, spacing, focus rings, motion | Native controls for free |
| System surfaces | Cannot blur the page under it; glass and grain are drawn natively underneath | Direct access to materials and vibrancy |
| Glue code | A bridge (about 3,300 lines in `Lilo/Bridge/`) and input routing between two views (about 1,100 lines in `Lilo/Window/Chrome*.swift`) | Neither |
| Iteration | Hot reload, and the whole UI in any browser without Xcode (`make ui-preview`) | An Xcode build per change, or SwiftUI previews |
| Tests | 83 unit test files (`make ui-test`) and 68 Playwright specs (`make e2e`) run against a fake host, without the app | XCTest or XCUITest through the app |
| Reuse | The website's interactive demo uses the same components and bridge protocol | None |
| Translation | 15 JSON catalogs with a parity check | The same catalogs through `.localized`, as native strings already are |

## Why web, then

The measurements below show one clear cost: about 68 MB for the chrome's process, 36 MB more than a static page's. At idle it does nothing measurable, it paints before the page, and Instruments found no animation hitch in the sidebar, tab or Space switches.

What the web view buys is speed of work on a large interface: about 140 components and 81,000 lines of Svelte and TypeScript, developed with hot reload, tested without the app, previewed in a browser and reused by the website. A native rewrite would give back the memory, part of the launch time and the bridge, and lose that loop.

The data supports keeping the web chrome. It does not show that a native chrome would be slower or heavier: that was not measured.

## When a screen moves to native

- **A measured cost that traces to the web layer**, which a native version would remove. "Native is faster" is not enough without a number.
- **A system surface the web cannot draw:** a material or blur of the page, vibrancy, window controls, menus. These are already native, and new ones go the same way.

Everything else stays in Svelte.

Two costs are open, and neither is yet traced to the web layer:

- **An empty Space, frontmost, keeps three processes busy.** On a Space with no page, Lilo opens the command bar. While Lilo is frontmost, the app, the chrome and the GPU process then use 1.4 to 1.6 % CPU each, with about 150 wakeups/s in the app. Behind another app, the same state idles. The chrome's code has no endless animation. The bar draws a full-window `backdrop-filter` blur, so the caret blinking under it would fit, but this is unconfirmed.
- **A sidebar toggle misses about 2 frames on the main thread** at 120 Hz. The slide is a native Core Animation transform, so nothing stutters on screen. Where those frames go was not profiled.

## Measurements

MacBook Pro (Mac16,8, M4 Pro, 48 GB), built-in 120 Hz display, macOS 27.2 (26B123), plugged in. Lilo 0.14.3 Release (`09e9bdb3e` with the grain change later committed as `0848a07d7`), on the WebKit of macOS (22625.2.8.11.9), with a throwaway profile. Measured on 2026-11-03 with the usual apps open, so the ranges include normal desktop noise.

**Launch.** Ten launches of a returning profile with three tabs (`make startup-bench RUNS=10 TABS=3`), in ms after process start:

| Mark | Median | Range |
|------|-------:|------:|
| Window shown | 195 | 193 to 219 |
| Chrome first paint (`chromeVisualReady`) | 370 | 347 to 406 |
| Page content painted | 463 | 439 to 499 |

**Memory and idle, a page visible.** Four launches, each left alone for 60 s, then sampled over 30 or 60 s, twice frontmost and twice behind another app. Medians, with ranges in parentheses:

| Process | Footprint | CPU | Wakeups/s |
|---------|----------:|----:|----------:|
| App | 77 MB (73 to 79) | 0.03 % (0.02 to 0.21) | 1.7 (0.8 to 13.9) |
| Chrome WebContent | 68 MB (67 to 69) | 0.02 % (0.00 to 0.03) | 1.1 (0.1 to 2.2) |
| Page WebContent, static page | 32 MB (32 to 32) | 0.07 % (0.01 to 0.14) | 4.8 (1.0 to 6.6) |
| GPU | 17 MB (17 to 27) | 0.01 % | 0.7 |

100 % CPU is one core. The page is the launch benchmark's minimal local page, so its row is a floor: a real site's process holds far more.

**Empty Space, frontmost.** Four launches: the app at 1.38 % CPU and 152 wakeups/s, the chrome at 1.56 % and 35 wakeups/s with 95 MB, the GPU process at 1.63 % with 119 MB.

**Interactions.** Two runs of 6 sidebar toggles, 12 tab switches, 7 Space switches and 6 sidebar toggles on a grain Space. Instruments' Animation Hitches template counted no hitch. Lilo's performance recording counted the main-thread frames missed: 12 and 13 for the solid sidebar, 6 and 13 for the tabs, 3 and 16 for the Spaces, 9 and 5 for the grain sidebar.

**Method.** `make startup-bench` builds the Release app and gives the launch marks. For memory and idle work, `proc_pid_rusage` was read for each of Lilo's processes at the start and end of the idle window. A performance recording (Help > Record Performance Session) tells the chrome's WebContent from the page's. Interactions were keystrokes sent by System Events, with `xctrace record --template 'Animation Hitches'` attached. The driver was a throwaway script on the benchmark's profile setup, not a make target. [ENERGY.md](ENERGY.md) gives the whole app's idle power: 6 mW above an idle Mac.

**Limits.** One machine, one display. Only two interaction runs. Neither open cost was profiled down to a function, and no native chrome was built to compare against.

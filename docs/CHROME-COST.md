# What the chrome web view costs

Lilo draws its sidebar, tab strip and panels in a dedicated `WKWebView` over native AppKit layers ([ARCHITECTURE.md](ARCHITECTURE.md#overlay-hud-design)). This note measures what that web view costs, to tell whether a screen would gain from moving to native.

## Conclusion

On this Mac, with a page visible, the chrome web view's process holds 68 MB of footprint, 36 MB more than the process of a static page, and does no measurable work at idle. Its first paint lands 370 ms after launch, about 90 ms before the page's. Instruments found no animation hitch in any run. Nothing measured here makes a native rewrite pay off.

Two costs remain, neither of them yet traced to the web layer:

- **An empty Space, frontmost, keeps three processes busy.** When the window shows a Space with no page, Lilo opens the command bar. While Lilo is frontmost, the app, the chrome and the GPU process then use 1.4 to 1.6 % CPU each, with about 150 wakeups/s in the app. Behind another app, the same state idles. See [Empty Space](#empty-space).
- **A sidebar toggle misses about 2 frames on the main thread** at 120 Hz. The slide is a native Core Animation transform, so the miss is not a hitch on screen, and it was not profiled.

## Results

MacBook Pro (Mac16,8, M4 Pro, 48 GB), built-in 120 Hz display, macOS 27.2 (26B123), plugged in. Lilo 0.14.3 Release (`09e9bdb3e` with the grain change later committed as `0848a07d7`), on the WebKit of macOS (22625.2.8.11.9), with a throwaway profile. Measured on 2026-11-03, with the usual apps open, so the spreads include normal desktop noise.

### Launch

Ten launches of a returning profile with three tabs, `make startup-bench RUNS=10 TABS=3`. Milliseconds after process start: median, then min and max.

| Mark | Median | Range |
|------|-------:|------:|
| Window shown (`windowShown`) | 195 | 193 to 219 |
| Chrome bundle served (`chromeServed:index.js`) | 297 | 262 to 315 |
| Chrome state received (`chromeInitialStateReceived`) | 327 | 308 to 363 |
| **Chrome first paint** (`chromeVisualReady`) | **370** | 347 to 406 |
| Page content painted (`firstContentPainted`) | 463 | 439 to 499 |

With onboarding pending, the chrome's first paint takes 379 ms (350 to 444).

### Memory and idle work, a page visible

Four launches. Each was left alone for 60 s, then sampled over 30 or 60 s: twice frontmost, twice behind another app. Footprint is the figure Activity Monitor shows. Resident memory also counts shared framework pages, so footprint is the one to compare.

| Process | Footprint | Resident | CPU | Wakeups/s | Energy |
|---------|----------:|---------:|----:|----------:|-------:|
| App (`Lilo`) | 77 MB (73 to 79) | 216 MB | 0.03 % (0.02 to 0.21) | 1.7 (0.8 to 13.9) | 0.06 mW |
| **Chrome WebContent** | **68 MB** (67 to 69) | 80 MB | **0.02 %** (0.00 to 0.03) | **1.1** (0.1 to 2.2) | **0.11 mW** |
| Page WebContent, static page | 32 MB (32 to 32) | 46 MB | 0.07 % (0.01 to 0.14) | 4.8 (1.0 to 6.6) | 0.05 mW |
| GPU | 17 MB (17 to 27) | 30 MB | 0.01 % | 0.7 | 0.02 mW |
| Networking | 7 MB | 16 MB | 0.00 % | 0.2 | 0.00 mW |
| Spare WebContent, prewarmed by WebKit | 7 MB | 17 MB | 0.00 % | 0.2 | 0.00 mW |

CPU, wakeups and energy are medians. 100 % CPU is one core. The page is the minimal local page of the launch benchmark, so its row is a floor: a real site's process holds far more.

### Empty Space

In four launches the window reopened on an empty Space, with the command bar open over it. These runs were frontmost.

| Process | Footprint | CPU | Wakeups/s | Energy |
|---------|----------:|----:|----------:|-------:|
| App | 74 MB | 1.38 % (1.37 to 1.49) | 152 (151 to 153) | 1.2 mW |
| Chrome WebContent | 95 MB | 1.56 % (1.54 to 1.73) | 35 (34 to 35) | 1.0 mW |
| GPU | 119 MB | 1.63 % (1.61 to 1.75) | 13 (13 to 13) | 0.9 mW |

Launched onto the same Space behind another app, the chrome WebContent still holds 87 to 92 MB, so the bar is open, yet every process idles (0.02 % CPU, 1 wakeup/s). The work therefore needs Lilo frontmost with the bar's field focused. No continuous animation was found in the chrome's code. The bar draws a full-window `backdrop-filter` blur, so the caret blinking under it would fit, but this is a lead, not a measured cause.

### Interactions

Scripted keystrokes in the two runs that started on the Space with tabs: 6 sidebar toggles, 12 tab switches (Cmd-1 to Cmd-3), 7 Space switches, then 6 sidebar toggles on a Space with the grain material. Animation hitches are counted by Instruments' Animation Hitches template for the app. Main-thread frames missed come from Lilo's performance recording (Help > Record Performance Session), which counts the frames a 120 Hz display link expected but the main thread did not deliver.

| Interaction | Hitches | Main-thread frames missed |
|-------------|--------:|--------------------------:|
| Sidebar toggle, solid Space (6) | 0 | 12 and 13 |
| Tab switch (12) | 0 | 6 and 13 |
| Space switch (7) | 0 | 3 and 16 |
| Sidebar toggle, grain Space (6) | 0 | 9 and 5 |

The three other runs started on the empty Space, where tab switches had no tab to show; they also recorded no hitch. The sidebar's misses come one pair per toggle, at its start. The grain material's overlay layer misses no more frames than the solid frame.

## Method

- **Build.** `make startup-bench` builds the Release app into `.derived.noindex/bench` with `scripts/bench_startup.sh`, ad-hoc signed. Every launch uses a throwaway home (`CFFIXED_USER_HOME`, `LILO_APP_SUPPORT_DIR`), seeded by a first launch that opens local pages and lets the filter lists compile, as the benchmark scripts do.
- **Launch.** The benchmark's own marks, from `LILO_STARTUP_BENCH_OUT` (`MainWindowController+WindowChrome.swift`).
- **Memory and idle work.** `proc_pid_rusage` read for the app and each WebKit process, at the start and the end of the window: CPU time, package idle and interrupt wakeups, energy (`ri_energy_nj`), footprint and resident size. Processes count as Lilo's when macOS holds the same app responsible for them. A short performance recording tells the chrome's WebContent from the page's: it labels the chrome's process, and its footprint matches one of them.
- **Interactions.** `xctrace record --template 'Animation Hitches' --attach` during keystrokes sent by System Events, with a performance recording running alongside.

The driver was a throwaway script built on the bench's profile setup, not a make target. `make e2e-energy` and `make energy-browsers` were not rerun: the first only checks that idle work stays absent, and [ENERGY.md](ENERGY.md) already gives Lilo's whole-app idle power, 6 mW above an idle Mac.

## Limits

- One machine and one display. Without ProMotion, the 120 Hz figures do not apply.
- Only two interaction runs started on the Space with tabs, so the main-thread counts are indications, not distributions.
- Neither the sidebar's missed frames nor the empty Space's idle work was profiled down to a function.

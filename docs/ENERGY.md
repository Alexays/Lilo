# Energy: Lilo, Safari, Chrome and Firefox

Lilo runs on WebKit, the engine inside macOS, so it uses about as little energy as Safari. With the same tabs on the same Mac, Chrome draws about 3 times Lilo's power and Firefox about 10 times.

## Results

MacBook Pro (M4 Pro, 48 GB), macOS 27.0.1, plugged in. Lilo 0.11.0 (`93e8173e`), Safari 27.0.1, Chrome 156.0.8078.49, Firefox 159.0. Medians of 3 rounds of 60 s each, measured on 2026-10-29.

**Idle**: five static pages, the first one visible.

| Browser | Power above idle Mac | CPU | Energy impact |
|---------|---------------------:|----:|--------------:|
| Lilo    |   6 mW | 0.11 % |  0.04 |
| Safari  |   3 mW | 0.14 % |  0.11 |
| Chrome  |  62 mW | 1.25 % | 10.33 |
| Firefox |  45 mW | 1.09 % | 46.29 |

**Active**: a visible page with a CSS animation and a clock ticking every second, and four background tabs whose timers update the page four times a second.

| Browser | Power above idle Mac | CPU | Energy impact |
|---------|---------------------:|----:|--------------:|
| Lilo    |  37 mW |  1.38 % |  0.54 |
| Safari  |  34 mW |  1.22 % |  0.49 |
| Chrome  | 102 mW | 14.70 % | 69.12 |
| Firefox | 370 mW | 26.85 % | 72.88 |

- **Power above idle Mac** is the whole Mac's CPU and GPU power during the run, minus a sample taken with no browser open at the start of each round (53 to 68 mW). Idle readings under about 15 mW are within that noise: Lilo and Safari are indistinguishable from an idle Mac.
- **CPU** sums every process of the browser's coalition: the app, its helpers, and its web, GPU and network processes. 100 % is one core.
- **Energy impact** is the macOS score Activity Monitor shows. It weighs CPU, GPU and wakeups, and suits comparing browsers on one Mac better than reading as an absolute. Chrome's idle score moved between 10 and 62 from one round to the next.

## Method

`make energy-browsers` runs [scripts/energy_browsers.sh](../scripts/energy_browsers.sh):

1. A local server serves the pages, so the network plays no part.
2. Each browser except Safari gets a throwaway profile, opened once for a minute so first-run work (component downloads, filter lists) is done, then copied for every run. Lilo is the Release build of the checkout. Safari has a single profile, the real one.
3. Each run opens the scenario's tabs with the first one visible, brings the browser to the front, waits 30 s, then samples it with `powermetrics`: once a second for 60 s, or every 5 s for a session. A run is kept only if the browser stayed frontmost.
4. Each scenario of a round starts with a sample with no browser open, and the order of the browsers rotates each round so drift over the night hits each alike.

The scenarios:

- **idle**: five static pages.
- **active**: a visible page with a CSS animation and a 1 s clock, and four background tabs whose timers update the page four times a second.
- **video**: a muted 1080p H.264 loop in the visible tab, and four static tabs.
- **session**: twenty tabs for 15 minutes, the visible one static and the background ones a mix of timers, animations, a page polling the server every 5 s, and static pages. It shows how each browser treats tabs left in the background: Lilo freezes them after 5 minutes plugged in, after 1 minute on battery.

Besides power, CPU and energy impact, each run records:

- **late** power and CPU, over the last third of the sample, where a session shows background tabs once frozen or throttled;
- **memory**, the footprint Activity Monitor shows, summed over the browser's processes at the end of the sample;
- **fps**, the animation frame rate of the visible page. On a 120 Hz display some browsers draw at 60 fps by default, which costs less but is a real difference, not an engine one;
- **video_s**, how far the video played, which confirms it ran;
- the **power source**: macOS and the browsers save more on battery.

The summary gives the median of each metric and the spread of power (min and max). No extension and no content blocker runs in any browser; on local pages, Lilo's default filter lists have nothing to block. Chrome's coalition includes GoogleUpdater, which Chrome starts.

To reproduce, quit other apps (Safari included), plug the Mac in, and leave it alone, unlocked, for about 5 hours: overnight suits it. Run a short pass first to grant the Automation permissions it asks for:

```bash
scripts/energy_browsers.sh --rounds 1 --duration 10 --session 60 --out build/energy-browsers-smoke
make energy-browsers
```

`BROWSERS`, `SCENARIOS`, `ROUNDS`, `DURATION`, `SESSION` and `APP` change what is measured. The video scenario needs `ffmpeg`. The medians land in `build/energy-browsers/summary.tsv` and every run in `runs.tsv`, with the processes measured.
